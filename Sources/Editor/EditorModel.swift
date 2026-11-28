// Pare Studio's multi-track video editor: projects made of clips on tracks, with transitions,
// a media bin, live preview, undo, saved projects and Camtasia import.

import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Project

enum EditMediaKind: String, Codable { case video, audio, image }

struct MediaItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var kind: EditMediaKind
    var duration: Double          // seconds (images: 0)
    var width: Double = 0
    var height: Double = 0
    var hasAudio = false
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum TransitionKind: String, Codable, CaseIterable, Identifiable {
    case none = "None", crossfade = "Crossfade", dip = "Dip to black", wipe = "Wipe", slide = "Slide"
    var id: String { rawValue }
}

struct Clip: Identifiable, Codable, Equatable {
    var id = UUID()
    var mediaID: UUID
    var start: Double             // where it sits on the timeline
    var inPoint: Double = 0       // where it starts in its media
    var duration: Double          // how long it plays
    var volume: Double = 1
    var muted = false
    var opacity: Double = 1
    var scale: Double = 1         // 1 = fit the canvas
    var offsetX: Double = 0       // share of the canvas width
    var offsetY: Double = 0
    var transition: TransitionKind = .none   // into this clip, from whatever is before it
    var transitionDuration: Double = 1
    var linkID: UUID?             // clips that move, trim and split together (a video and its sound)
    var videoOnly: Bool?          // a video clip whose sound lives on its own clip on a sound track
    var end: Double { start + duration }
}

struct Track: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var isAudio = false
    var clips: [Clip] = []
    var muted = false
    var hidden = false
}

struct ProjectCanvas: Codable, Equatable, Hashable {
    var width: Int = 1920
    var height: Int = 1080
    var label: String {
        switch (width, height) {
        case (1920, 1080): return "Widescreen 1080p"
        case (1280, 720): return "Widescreen 720p"
        case (3840, 2160): return "4K"
        case (1080, 1920): return "Vertical (phones)"
        case (1080, 1080): return "Square"
        case (1440, 1080): return "4:3"
        default: return "\(width)×\(height)"
        }
    }
    static let presets: [ProjectCanvas] = [ProjectCanvas(width: 1920, height: 1080), ProjectCanvas(width: 1280, height: 720), ProjectCanvas(width: 3840, height: 2160),
                                    ProjectCanvas(width: 1080, height: 1920), ProjectCanvas(width: 1080, height: 1080), ProjectCanvas(width: 1440, height: 1080)]
}

struct EditorProject: Codable, Equatable {
    var name = "Untitled"
    var canvas = ProjectCanvas()
    var media: [MediaItem] = []
    var tracks: [Track] = [Track(name: "Track 2"), Track(name: "Track 1"), Track(name: "Audio", isAudio: true)]

    var duration: Double { tracks.flatMap(\.clips).map(\.end).max() ?? 0 }
    func item(_ id: UUID) -> MediaItem? { media.first { $0.id == id } }
}

// MARK: - The editor

@MainActor
final class EditorModel: ObservableObject {
    static let shared = EditorModel()

    @Published var project = EditorProject()
    @Published var fileURL: URL?
    @Published var selectedClip: UUID?
    @Published var time: Double = 0
    @Published var playing = false
    @Published var zoom: Double = 60            // points per second
    @Published var status: String?
    @Published var problem: String?
    @Published var busy = false
    @Published var progress: Double?
    @Published var thumbs: [UUID: CGImage] = [:]
    @Published var snapping = true
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var typing = false

    let player = AVPlayer()
    private var observer: Any?
    private var fromPlayer = false
    private var rebuildTask: Task<Void, Never>?
    private var builtProject: EditorProject?
    private var keepAlive: [AnyObject] = []
    private var undoStack: [EditorProject] = []
    private var redoStack: [EditorProject] = []
    private var lastProject: EditorProject?
    private var lastPush = Date.distantPast
    private var applying = false

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, t.seconds.isFinite else { return }
                if self.playing, t.seconds >= self.project.duration - 0.02 { self.pause() }
                self.fromPlayer = true
                self.time = t.seconds
                self.fromPlayer = false
            }
        }
        lastProject = project
    }

    var duration: Double { project.duration }

    // MARK: Changes, undo, preview

    /// Called whenever the project changes: undo history and a fresh preview.
    func projectChanged() {
        if !applying, let last = lastProject, last != project {
            if Date().timeIntervalSince(lastPush) > 0.6 {
                undoStack.append(last)
                if undoStack.count > 200 { undoStack.removeFirst() }
                redoStack.removeAll()
            }
            lastPush = Date()
        }
        lastProject = project
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        schedulePreview()
        autosave()
    }

    func undo() {
        guard let p = undoStack.popLast() else { return }
        redoStack.append(project)
        applying = true; project = p; applying = false
        lastProject = p; lastPush = .distantPast
        canUndo = !undoStack.isEmpty; canRedo = true
        schedulePreview()
    }

    func redo() {
        guard let p = redoStack.popLast() else { return }
        undoStack.append(project)
        applying = true; project = p; applying = false
        lastProject = p; lastPush = .distantPast
        canUndo = true; canRedo = !redoStack.isEmpty
        schedulePreview()
    }

    /// Rebuilds the preview a moment after the last change (so dragging stays smooth).
    func schedulePreview() {
        rebuildTask?.cancel()
        rebuildTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await rebuildPreview()
        }
    }

    func rebuildPreview() async {
        guard project != builtProject else { return }
        let p = project
        let wasPlaying = playing
        let at = time
        CompositionBuilder.lastProblem = nil
        guard let built = await CompositionBuilder.build(p, thumbs: false) else {
            player.replaceCurrentItem(with: nil)
            builtProject = p
            if p.duration > 0.05 {
                problem = "The preview couldn't be made: " + (CompositionBuilder.lastProblem ?? "unknown reason") + "."
            }
            return
        }
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        player.replaceCurrentItem(with: item)
        keepAlive = built.keep
        builtProject = p
        if let why = CompositionBuilder.lastProblem { problem = "Part of the preview is missing: \(why)." }
        seek(at)
        if wasPlaying { player.play() }
        // Say so if AVFoundation refuses the preview, rather than showing a blank screen.
        Task { [weak item] in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let item, self.player.currentItem === item else { return }
                if item.status == .readyToPlay { return }
                if item.status == .failed {
                    let e = item.error as NSError?
                    self.problem = "The preview couldn't play: \(e?.localizedDescription ?? "unknown error")"
                        + (e?.localizedFailureReason.map { " (\($0))" } ?? "")
                        + (e.map { " [\($0.domain) \($0.code)]" } ?? "")
                    return
                }
            }
        }
    }

    func timeChanged() {
        guard !fromPlayer, !playing else { return }
        seek(time)
    }

    func seek(_ t: Double) {
        player.seek(to: CMTime(seconds: max(0, min(t, duration)), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() { playing ? pause() : play() }

    func play(rate: Float = 1) {
        guard duration > 0 else { return }
        if time >= duration - 0.05 { seek(0) }
        playing = true
        player.rate = rate
    }

    func pause() { player.pause(); playing = false }

    func step(frames n: Int) { pause(); time = min(max(0, time + Double(n) / 30), duration) }
    func step(seconds s: Double) { pause(); time = min(max(0, time + s), duration) }

    // MARK: Media

    func importMedia() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .audio, .image, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .png, .jpeg]
        panel.message = "Choose videos, sound and pictures to use in this project."
        if panel.runModal() == .OK { Task { await add(panel.urls) } }
    }

    /// Adds files to the media bin. Returns the new items.
    @discardableResult
    func add(_ urls: [URL]) async -> [MediaItem] {
        var added: [MediaItem] = []
        for u in urls {
            if let existing = project.media.first(where: { $0.path == u.path }) { added.append(existing); continue }
            let ext = u.pathExtension.lowercased()
            if ext == "cmproj" || ext == "tscproj" { await importCamtasia(u); continue }
            guard let item = await Self.probe(u) else { problem = "Couldn't read \(u.lastPathComponent)."; continue }
            project.media.append(item)
            added.append(item)
            makeThumb(item)
        }
        projectChanged()
        // Nothing on the timeline yet: put what was just added on it, one after another.
        if project.tracks.allSatisfy({ $0.clips.isEmpty }) {
            for item in added { place(item) }
            selectedClip = nil
            if !added.isEmpty { status = "Added to the timeline. Press Space to play." }
        }
        return added
    }

    static func probe(_ u: URL) async -> MediaItem? {
        if let t = UTType(filenameExtension: u.pathExtension), t.conforms(to: .image) {
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
            let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 1920
            let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 1080
            return MediaItem(path: u.path, kind: .image, duration: 0, width: w, height: h)
        }
        let asset = AVURLAsset(url: u)
        guard let d = try? await asset.load(.duration).seconds, d.isFinite, d > 0 else { return nil }
        let v = try? await asset.loadTracks(withMediaType: .video).first
        let a = (try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false
        if let v {
            let size = (try? await v.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
            let tf = (try? await v.load(.preferredTransform)) ?? .identity
            let s = size.applying(tf)
            return MediaItem(path: u.path, kind: .video, duration: d, width: abs(s.width), height: abs(s.height), hasAudio: a)
        }
        return a ? MediaItem(path: u.path, kind: .audio, duration: d, hasAudio: true) : nil
    }

    func makeThumb(_ m: MediaItem) {
        guard thumbs[m.id] == nil else { return }
        let id = m.id
        Task.detached(priority: .utility) {
            var img: CGImage?
            switch m.kind {
            case .image:
                if let src = CGImageSourceCreateWithURL(m.url as CFURL, nil) {
                    img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                       kCGImageSourceThumbnailMaxPixelSize: 240] as CFDictionary)
                }
            case .video:
                let g = AVAssetImageGenerator(asset: AVURLAsset(url: m.url))
                g.appliesPreferredTrackTransform = true
                g.maximumSize = CGSize(width: 240, height: 240)
                img = try? await g.image(at: CMTime(seconds: min(1, m.duration / 2), preferredTimescale: 600)).image
            case .audio:
                img = nil
            }
            if let img { await MainActor.run { EditorModel.shared.thumbs[id] = img } }
        }
    }

    func removeMedia(_ id: UUID) {
        for i in project.tracks.indices { project.tracks[i].clips.removeAll { $0.mediaID == id } }
        project.media.removeAll { $0.id == id }
        projectChanged()
    }

    // MARK: Clips

    /// Puts media on a track at a time (or at the end of the track).
    func place(_ m: MediaItem, onTrack trackID: UUID? = nil, at t: Double? = nil) {
        let wantAudio = m.kind == .audio
        var ti = trackID.flatMap { id in project.tracks.firstIndex { $0.id == id } }
        if let i = ti, project.tracks[i].isAudio != wantAudio { ti = nil }
        if ti == nil { ti = project.tracks.lastIndex { $0.isAudio == wantAudio } }
        guard let i = ti else { return }
        let length = m.kind == .image ? 5 : m.duration
        let startAt = t ?? (project.tracks[i].clips.map(\.end).max() ?? 0)
        var c = Clip(mediaID: m.id, start: max(0, startAt), duration: length)
        if m.kind == .video, m.hasAudio {
            // Like Camtasia: the sound goes on its own clip on a sound track, linked to the picture.
            let link = UUID()
            c.linkID = link
            c.videoOnly = true
            var a = Clip(mediaID: m.id, start: c.start, duration: length)
            a.linkID = link
            let ai = freeSoundTrack(from: c.start, to: c.end)
            project.tracks[ai].clips.append(a)
            project.tracks[ai].clips.sort { $0.start < $1.start }
        }
        project.tracks[i].clips.append(c)
        project.tracks[i].clips.sort { $0.start < $1.start }
        selectedClip = c.id
        if project.tracks.reduce(0, { $0 + $1.clips.count }) == 1 {
            // First clip: match the canvas to it.
            if m.kind == .video, m.width > 0, m.height > 0 {
                project.canvas = m.height > m.width ? ProjectCanvas(width: 1080, height: 1920)
                    : (abs(m.width / m.height - 1) < 0.05 ? ProjectCanvas(width: 1080, height: 1080) : ProjectCanvas(width: 1920, height: 1080))
            }
        }
        projectChanged()
    }

    /// A sound track with nothing in the way between two times (a new one if they're all busy).
    private func freeSoundTrack(from a: Double, to b: Double) -> Int {
        if let i = project.tracks.firstIndex(where: { t in t.isAudio && !t.clips.contains { $0.start < b - 0.01 && $0.end > a + 0.01 } }) { return i }
        let n = project.tracks.filter(\.isAudio).count + 1
        project.tracks.append(Track(name: n == 1 ? "Audio" : "Audio \(n)", isAudio: true))
        return project.tracks.count - 1
    }

    /// The other clips linked to this one.
    func partners(of id: UUID) -> [UUID] {
        guard let l = location(of: id), let link = project.tracks[l.track].clips[l.clip].linkID else { return [] }
        return project.tracks.flatMap(\.clips).filter { $0.linkID == link && $0.id != id }.map(\.id)
    }

    /// Gives linked clips the same timing (and transition) as this one.
    private func syncPartners(of id: UUID) {
        guard let l = location(of: id) else { return }
        let c = project.tracks[l.track].clips[l.clip]
        for pid in partners(of: id) {
            guard let pl = location(of: pid) else { continue }
            project.tracks[pl.track].clips[pl.clip].start = c.start
            project.tracks[pl.track].clips[pl.clip].inPoint = c.inPoint
            project.tracks[pl.track].clips[pl.clip].duration = c.duration
            project.tracks[pl.track].clips[pl.clip].transition = c.transition
            project.tracks[pl.track].clips[pl.clip].transitionDuration = c.transitionDuration
            project.tracks[pl.track].clips.sort { $0.start < $1.start }
        }
    }

    /// Moves a video clip's own sound onto a linked clip on a sound track.
    func separateSound(_ id: UUID) {
        guard let l = location(of: id), !project.tracks[l.track].isAudio else { return }
        var c = project.tracks[l.track].clips[l.clip]
        guard let m = project.item(c.mediaID), m.hasAudio, c.videoOnly != true else { return }
        let link = c.linkID ?? UUID()
        c.linkID = link
        c.videoOnly = true
        project.tracks[l.track].clips[l.clip] = c
        var a = Clip(mediaID: m.id, start: c.start, inPoint: c.inPoint, duration: c.duration, volume: c.volume, muted: c.muted)
        a.linkID = link
        let ai = freeSoundTrack(from: c.start, to: c.end)
        project.tracks[ai].clips.append(a)
        project.tracks[ai].clips.sort { $0.start < $1.start }
        projectChanged()
    }

    var isLinked: Bool { selectedClip.map { !partners(of: $0).isEmpty } ?? false }

    /// Lets the picture and sound of the selected clip be moved separately.
    func unlinkSelected() {
        guard let id = selectedClip else { return }
        for cid in [id] + partners(of: id) {
            if let l = location(of: cid) { project.tracks[l.track].clips[l.clip].linkID = nil }
        }
        projectChanged()
    }

    func location(of id: UUID) -> (track: Int, clip: Int)? {
        for (ti, t) in project.tracks.enumerated() {
            if let ci = t.clips.firstIndex(where: { $0.id == id }) { return (ti, ci) }
        }
        return nil
    }

    var selected: Clip? { selectedClip.flatMap { location(of: $0) }.map { project.tracks[$0.track].clips[$0.clip] } }

    func updateSelected(_ f: (inout Clip) -> Void) {
        guard let id = selectedClip, let l = location(of: id) else { return }
        f(&project.tracks[l.track].clips[l.clip])
        syncPartners(of: id)
        projectChanged()
    }

    func deleteSelected() {
        guard let id = selectedClip else { return }
        for cid in [id] + partners(of: id) {
            if let l = location(of: cid) { project.tracks[l.track].clips.remove(at: l.clip) }
        }
        selectedClip = nil
        projectChanged()
    }

    /// Splits the selected clip (or whatever is under the playhead on the top track) at the playhead.
    func splitAtPlayhead() {
        let t = time
        var target = selectedClip.flatMap { location(of: $0) }
        if let l = target, !(project.tracks[l.track].clips[l.clip].start < t && project.tracks[l.track].clips[l.clip].end > t) { target = nil }
        if target == nil {
            for (ti, tr) in project.tracks.enumerated() {
                if let ci = tr.clips.firstIndex(where: { $0.start < t - 0.05 && $0.end > t + 0.05 }) { target = (ti, ci); break }
            }
        }
        guard let l = target else { return }
        let first = project.tracks[l.track].clips[l.clip]
        let cut = t - first.start
        guard cut > 0.05, first.duration - cut > 0.05 else { return }
        let newLink: UUID? = first.linkID == nil ? nil : UUID()
        var selectedHalf: UUID?
        for cid in [first.id] + partners(of: first.id) {
            guard let cl = location(of: cid) else { continue }
            var a = project.tracks[cl.track].clips[cl.clip]
            var b = a
            b.id = UUID()
            b.start = t
            b.inPoint = a.inPoint + cut
            b.duration = a.duration - cut
            b.transition = .none
            b.linkID = newLink
            a.duration = cut
            project.tracks[cl.track].clips[cl.clip] = a
            project.tracks[cl.track].clips.insert(b, at: cl.clip + 1)
            if cid == first.id { selectedHalf = b.id }
        }
        selectedClip = selectedHalf
        projectChanged()
    }

    /// Moves a clip to a new start (and track), snapping to other clip edges and the playhead.
    func move(_ id: UUID, to start: Double, track newTrack: Int? = nil) {
        guard let l = location(of: id) else { return }
        var c = project.tracks[l.track].clips[l.clip]
        var s = max(0, start)
        if snapping { s = snap(s, length: c.duration, ignoring: id) }
        c.start = s
        let linked = partners(of: id)
        var dest = l.track
        if let nt = newTrack, project.tracks.indices.contains(nt), project.tracks[nt].isAudio == project.tracks[l.track].isAudio { dest = nt }
        project.tracks[l.track].clips.remove(at: l.clip)
        project.tracks[dest].clips.append(c)
        project.tracks[dest].clips.sort { $0.start < $1.start }
        if !linked.isEmpty { syncPartners(of: id) }
        projectChanged()
    }

    /// Changes a clip's start or end edge (trimming the media too).
    func trim(_ id: UUID, edge leading: Bool, to t: Double) {
        guard let l = location(of: id), let m = project.item(project.tracks[l.track].clips[l.clip].mediaID) else { return }
        var c = project.tracks[l.track].clips[l.clip]
        var x = t
        if snapping { x = snapEdge(x, ignoring: id) }
        let maxLen = m.kind == .image ? 36_000 : m.duration
        if leading {
            let delta = min(max(x - c.start, -c.inPoint), c.duration - 0.1)
            c.start += delta; c.inPoint += delta; c.duration -= delta
            if c.start < 0 { c.inPoint -= c.start; c.duration += c.start; c.start = 0 }
        } else {
            c.duration = min(max(0.1, x - c.start), maxLen - c.inPoint)
        }
        project.tracks[l.track].clips[l.clip] = c
        syncPartners(of: id)
        projectChanged()
    }

    private func snapTargets(ignoring id: UUID) -> [Double] {
        var out: [Double] = [0, time]
        let skip = Set([id] + partners(of: id))
        for t in project.tracks { for c in t.clips where !skip.contains(c.id) { out.append(c.start); out.append(c.end) } }
        return out
    }

    private func snap(_ s: Double, length: Double, ignoring id: UUID) -> Double {
        let tol = 8 / zoom
        let others = snapTargets(ignoring: id)
        for p in others {
            if abs(s - p) < tol { return p }
            if abs(s + length - p) < tol { return p - length }
        }
        return s
    }

    private func snapEdge(_ x: Double, ignoring id: UUID) -> Double {
        let tol = 8 / zoom
        let others = snapTargets(ignoring: id)
        return others.first { abs($0 - x) < tol } ?? x
    }

    /// Slides every clip left to remove the gaps on each track.
    func closeGaps() {
        for i in project.tracks.indices {
            var t = 0.0
            for k in project.tracks[i].clips.indices.sorted(by: { project.tracks[i].clips[$0].start < project.tracks[i].clips[$1].start }) {
                let overlap = project.tracks[i].clips[k].transition == .crossfade ? project.tracks[i].clips[k].transitionDuration : 0
                project.tracks[i].clips[k].start = max(0, t - overlap)
                t = project.tracks[i].clips[k].end
            }
        }
        projectChanged()
    }

    func addTrack(audio: Bool) {
        let n = project.tracks.filter { $0.isAudio == audio }.count + 1
        let t = Track(name: audio ? "Audio \(n)" : "Track \(n)", isAudio: audio)
        if audio { project.tracks.append(t) } else { project.tracks.insert(t, at: 0) }
        projectChanged()
    }

    func removeTrack(_ id: UUID) {
        guard project.tracks.count > 1 else { return }
        project.tracks.removeAll { $0.id == id }
        projectChanged()
    }

    // MARK: Projects

    static var projectsFolder: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pare Studio/Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func newProject() {
        pause()
        applying = true
        project = EditorProject()
        applying = false
        fileURL = nil; selectedClip = nil; time = 0
        undoStack = []; redoStack = []; lastProject = project; canUndo = false; canRedo = false
        schedulePreview()
    }

    private var autosaveTask: Task<Void, Never>?
    private func autosave() {
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, !project.tracks.flatMap(\.clips).isEmpty else { return }
            let url = fileURL ?? Self.freshURL(project.name)
            if (try? write(to: url)) != nil { fileURL = url }
        }
    }

    /// A project file name that isn't taken yet.
    static func freshURL(_ name: String) -> URL {
        var url = projectsFolder.appendingPathComponent(name + ".pareedit")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = projectsFolder.appendingPathComponent("\(name) \(n).pareedit"); n += 1
        }
        return url
    }

    func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(project).write(to: url, options: .atomic)
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = project.name + ".pareedit"
        panel.allowedContentTypes = [UTType(filenameExtension: "pareedit") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        project.name = url.deletingPathExtension().lastPathComponent
        do { try write(to: url); fileURL = url; status = "Saved \(url.lastPathComponent)." }
        catch { problem = error.localizedDescription }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pareedit") ?? .json, UTType(filenameExtension: "cmproj") ?? .package,
                                     UTType(filenameExtension: "tscproj") ?? .json]
        panel.directoryURL = Self.projectsFolder
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Open a Pare Studio project, or a Camtasia project (.cmproj or .tscproj)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "cmproj" || ext == "tscproj" { Task { await importCamtasia(url) }; return }
        do {
            let p = try JSONDecoder().decode(EditorProject.self, from: Data(contentsOf: url))
            load(p, from: url)
            let missing = p.media.filter { !FileManager.default.fileExists(atPath: $0.path) }
            problem = missing.isEmpty ? nil : "Can't find: " + missing.map { $0.url.lastPathComponent }.joined(separator: ", ")
        } catch { problem = "Couldn't open that project: \(error.localizedDescription)" }
    }

    /// Replaces the open project (fresh undo history).
    func load(_ p: EditorProject, from url: URL?) {
        pause()
        applying = true; project = p; applying = false
        fileURL = url; selectedClip = nil; time = 0
        undoStack = []; redoStack = []; lastProject = p; canUndo = false; canRedo = false
        for m in p.media { makeThumb(m) }
        schedulePreview()
        if url == nil { autosave() }
    }

    var recentProjects: [URL] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.projectsFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "pareedit" }
            .sorted { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            .prefix(6).map { $0 }
    }

    // MARK: Export

    func exportVideo() {
        guard duration > 0 else { problem = "Add some clips first."; return }
        pause()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = project.name + ".mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; progress = 0; problem = nil
        status = "Making the video…"
        let p = project
        Task {
            do {
                try await CompositionBuilder.export(p, to: url) { f in
                    Task { @MainActor in EditorModel.shared.progress = f }
                }
                status = "Saved \(url.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                problem = "Export failed: \(error.localizedDescription)"
                status = nil
            }
            busy = false; progress = nil
        }
    }
}
