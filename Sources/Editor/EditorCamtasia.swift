// Opens a Camtasia project (.cmproj on a Mac, or a .tscproj file) as a Pare Studio project.
// Brings in the media, tracks, clip timing and trims, groups (flattened) and transitions.
// Anything Camtasia-only (callouts, behaviours, cursor effects, device frames, speed changes)
// is listed so nothing is lost without saying.

import Foundation
import AppKit

enum CamtasiaReader {
    static let ticks = 705_600_000.0

    /// A number that Camtasia may write as 12, 12.5 or "441/2".
    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String {
            let parts = s.split(separator: "/")
            if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0 { return a / b }
            return Double(s)
        }
        if let d = v as? [String: Any] { return num(d["defaultValue"]) ?? num(d["value"]) }
        return nil
    }

    static func transition(_ name: String) -> TransitionKind {
        let n = name.lowercased()
        if n.contains("black") || n.contains("through") || n.contains("dip") { return .dip }
        if n.contains("wipe") || n.contains("reveal") || n.contains("swipe") || n.contains("barn") { return .wipe }
        if n.contains("slide") || n.contains("push") || n.contains("cube") || n.contains("flip") || n.contains("spin") { return .slide }
        return .crossfade
    }

    struct Placed {
        var media: [String: Any]       // the IMFile/VMFile/AMFile/UMFile dictionary
        var start: Double
        var duration: Double
        var inPoint: Double
        var id: Int?
    }
}

extension EditorModel {
    func importCamtasia(_ url: URL) async {
        busy = true; problem = nil
        status = "Opening the Camtasia project…"
        defer { busy = false }

        var projectFile = url
        var base = url.deletingLastPathComponent()
        if url.pathExtension.lowercased() == "cmproj" {
            base = url
            let fm = FileManager.default
            let inside = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            guard let f = inside.first(where: { $0.pathExtension.lowercased() == "tscproj" }) else {
                problem = "That Camtasia project has no project.tscproj inside it."; status = nil; return
            }
            projectFile = f
        }
        guard let data = try? Data(contentsOf: projectFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            problem = "Couldn't read that Camtasia project."; status = nil; return
        }

        var skipped: [String: Int] = [:]
        var missing: [String] = []
        var notes: Set<String> = []

        // Media in the Camtasia library.
        var bin: [Int: MediaItem] = [:]
        for entry in (root["sourceBin"] as? [[String: Any]]) ?? [] {
            guard let id = (entry["id"] as? NSNumber)?.intValue, let src = entry["src"] as? String else { continue }
            guard let file = Self.locate(src, base: base, projectFile: projectFile) else {
                missing.append((src as NSString).lastPathComponent); continue
            }
            if let item = await Self.probe(file) { bin[id] = item }
            else { missing.append(file.lastPathComponent + " (can't be read on a Mac)") }
        }

        var project = EditorProject()
        project.name = url.deletingPathExtension().lastPathComponent
        if let w = CamtasiaReader.num(root["width"]), let h = CamtasiaReader.num(root["height"]), w > 0, h > 0 {
            project.canvas = ProjectCanvas(width: Int(w.rounded()), height: Int(h.rounded()))
        }
        project.media = Array(Set(bin.values.map(\.id))).compactMap { id in bin.values.first { $0.id == id } }

        let timeline = root["timeline"] as? [String: Any] ?? [:]
        let attrs = (timeline["trackAttributes"] as? [[String: Any]]) ?? []
        let scenes = ((timeline["sceneTrack"] as? [String: Any])?["scenes"] as? [[String: Any]]) ?? []
        let csmlTracks = scenes.flatMap { (($0["csml"] as? [String: Any])?["tracks"] as? [[String: Any]]) ?? [] }

        var videoTracks: [Track] = []
        var audioTracks: [Track] = []

        for (n, t) in csmlTracks.enumerated() {
            let index = (t["trackIndex"] as? NSNumber)?.intValue ?? n
            let a = attrs.indices.contains(index) ? attrs[index] : [:]
            let name = (a["ident"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Track \(index + 1)"
            var placed: [CamtasiaReader.Placed] = []
            Self.flatten((t["medias"] as? [[String: Any]]) ?? [], offset: 0, window: nil, into: &placed, skipped: &skipped, notes: &notes)

            var video = Track(name: name)
            var audio = Track(name: name + " sound", isAudio: true)
            video.hidden = (a["videoHidden"] as? Bool) ?? false
            video.muted = (a["audioMuted"] as? Bool) ?? false
            audio.muted = video.muted
            var clipFor: [Int: (audio: Bool, id: UUID)] = [:]

            for p in placed {
                var m = p.media
                // A UMFile holds the picture and sound of one recording; use the picture part with the file's own sound.
                if (m["_type"] as? String) == "UMFile", let v = m["video"] as? [String: Any] { m = v.merging(m) { a, _ in a } }
                guard let src = (m["src"] as? NSNumber)?.intValue, let item = bin[src] else { continue }
                let params = m["parameters"] as? [String: Any] ?? [:]
                var c = Clip(mediaID: item.id, start: p.start, inPoint: p.inPoint, duration: p.duration)
                if let v = CamtasiaReader.num(params["volume"]) { c.volume = min(max(v, 0), 2) }
                if let o = CamtasiaReader.num(params["opacity"]) { c.opacity = min(max(o, 0), 1) }
                if let s = CamtasiaReader.num(params["scale0"]), s > 0 {
                    // Camtasia scales from the media's own size; ours is "fit the canvas".
                    let fit = item.width > 0 ? min(Double(project.canvas.width) / item.width, Double(project.canvas.height) / item.height) : 1
                    c.scale = min(max(s / max(fit, 0.0001), 0.05), 8)
                }
                if let x = CamtasiaReader.num(params["translation0"]) { c.offsetX = x / Double(project.canvas.width) }
                if let y = CamtasiaReader.num(params["translation1"]) { c.offsetY = -y / Double(project.canvas.height) }
                if let scalar = CamtasiaReader.num(m["scalar"]), abs(scalar - 1) > 0.001 { notes.insert("speed changes (played at normal speed)") }
                if item.kind == .audio {
                    audio.clips.append(c)
                    if let id = p.id { clipFor[id] = (true, c.id) }
                } else {
                    video.clips.append(c)
                    if let id = p.id { clipFor[id] = (false, c.id) }
                }
            }

            // Transitions sit on the track, between a left and a right clip.
            for tr in (t["transitions"] as? [[String: Any]]) ?? [] {
                let kind = CamtasiaReader.transition(tr["name"] as? String ?? "")
                let d = (CamtasiaReader.num(tr["duration"]) ?? CamtasiaReader.ticks) / CamtasiaReader.ticks
                guard let right = (tr["rightMedia"] as? NSNumber)?.intValue, let target = clipFor[right] else {
                    if tr["leftMedia"] != nil { notes.insert("transitions at the end of a clip") }
                    continue
                }
                if target.audio {
                    if let i = audio.clips.firstIndex(where: { $0.id == target.id }) { audio.clips[i].transition = kind; audio.clips[i].transitionDuration = d }
                } else if let i = video.clips.firstIndex(where: { $0.id == target.id }) {
                    video.clips[i].transition = kind; video.clips[i].transitionDuration = d
                }
            }

            video.clips.sort { $0.start < $1.start }
            audio.clips.sort { $0.start < $1.start }
            if !video.clips.isEmpty { videoTracks.append(video) }
            if !audio.clips.isEmpty { audioTracks.append(audio) }
        }

        // Camtasia's track 1 is the bottom; ours lists the top first.
        project.tracks = videoTracks.reversed() + audioTracks
        if project.tracks.isEmpty { project.tracks = EditorProject().tracks }
        if !project.tracks.contains(where: { $0.isAudio }) { project.tracks.append(Track(name: "Audio", isAudio: true)) }

        guard project.tracks.contains(where: { !$0.clips.isEmpty }) else {
            problem = "Nothing in that Camtasia project could be brought in." + (missing.isEmpty ? "" : " Missing: " + missing.joined(separator: ", "))
            status = nil
            return
        }

        load(project, from: nil)
        var said: [String] = []
        if !skipped.isEmpty {
            said.append("Left out (Camtasia-only): " + skipped.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))
        }
        if !notes.isEmpty { said.append("Not carried over: " + notes.sorted().joined(separator: ", ")) }
        if !missing.isEmpty { said.append("Can't find: " + missing.joined(separator: ", ")) }
        status = "Opened \(url.lastPathComponent)."
        problem = said.isEmpty ? nil : said.joined(separator: ". ") + "."
    }

    /// Finds a Camtasia media file, wherever the project was moved to.
    nonisolated static func locate(_ src: String, base: URL, projectFile: URL) -> URL? {
        let fm = FileManager.default
        var path = src
        if path.hasPrefix("file://"), let u = URL(string: path) { path = u.path }
        let candidates: [URL] = [
            path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path).standardizedFileURL,
            projectFile.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL,
            base.appendingPathComponent((path as NSString).lastPathComponent),
            base.deletingLastPathComponent().appendingPathComponent((path as NSString).lastPathComponent)]
        if let hit = candidates.first(where: { fm.fileExists(atPath: $0.path) }) { return hit }
        // Last try: anywhere inside the project folder with the same name.
        let name = (path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        if let e = fm.enumerator(at: base, includingPropertiesForKeys: nil) {
            for case let u as URL in e where u.lastPathComponent == name { return u }
        }
        return nil
    }

    /// Lays out clips (opening groups) on the main timeline.
    nonisolated static func flatten(_ medias: [[String: Any]], offset: Double, window: ClosedRange<Double>?,
                                    into out: inout [CamtasiaReader.Placed], skipped: inout [String: Int], notes: inout Set<String>) {
        let T = CamtasiaReader.ticks
        for m in medias {
            let type = m["_type"] as? String ?? "?"
            var start = offset + (CamtasiaReader.num(m["start"]) ?? 0) / T
            var dur = (CamtasiaReader.num(m["duration"]) ?? 0) / T
            var inPoint = (CamtasiaReader.num(m["mediaStart"]) ?? 0) / T
            if let w = window {
                // Keep only what shows inside the group's own window.
                if start < w.lowerBound { let cut = w.lowerBound - start; inPoint += cut; dur -= cut; start = w.lowerBound }
                if start + dur > w.upperBound { dur = w.upperBound - start }
            }
            guard dur > 0.01 else { continue }
            switch type {
            case "Group", "StitchedMedia":
                // A group plays its inner timeline from mediaStart; stitched media is clips joined end to end.
                let inner = (m["tracks"] as? [[String: Any]])?.flatMap { ($0["medias"] as? [[String: Any]]) ?? [] }
                    ?? (m["medias"] as? [[String: Any]]) ?? []
                let shift = start - inPoint
                flatten(inner, offset: shift, window: start...(start + dur), into: &out, skipped: &skipped, notes: &notes)
            case "IMFile", "VMFile", "AMFile", "UMFile", "ScreenVMFile", "ScreenIMFile":
                out.append(.init(media: m, start: start, duration: dur, inPoint: inPoint, id: (m["id"] as? NSNumber)?.intValue))
                if let effects = m["effects"] as? [Any], !effects.isEmpty { notes.insert("clip effects") }
                if let b = m["animationTracks"] as? [String: Any], !b.isEmpty { notes.insert("animations") }
            case "Callout": skipped["callouts", default: 0] += 1
            case "Behavior", "BehaviorMedia": skipped["behaviours", default: 0] += 1
            default: skipped[type, default: 0] += 1
            }
        }
    }
}
