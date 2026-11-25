// Camtasia export — the tutorial video as a Camtasia project (.cmproj) you can open and keep editing:
// track 1 holds one video clip per part (intro, each step, outro) with the zooms, cursor and captions
// already drawn in, track 2 the narration lines, track 3 the click sounds. Add transitions, music,
// callouts and so on in Camtasia. A captions file (.srt) is saved beside it for File › Import › Captions.

import Foundation
import AppKit
import AVFoundation

enum CamtasiaExport {
    /// Camtasia's timeline counts time in ticks: 705,600,000 per second.
    static let ticksPerSecond: Int64 = 705_600_000

    static func make(guide: Guide, to requested: URL, progress: @escaping (String) -> Void) async throws {
        let fm = FileManager.default
        let url = requested.pathExtension.lowercased() == "cmproj" ? requested : requested.appendingPathExtension("cmproj")
        let work = fm.temporaryDirectory.appendingPathComponent("camtasia-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let (shots, look) = try await TutorialVideo.buildShots(guide: guide, work: work, progress: progress)

        // Build the project in a temporary folder, then move it into place.
        let bundle = work.appendingPathComponent("project.cmproj")
        let media = bundle.appendingPathComponent("media")
        try fm.createDirectory(at: media, withIntermediateDirectories: true)

        var sourceBin: [[String: Any]] = []
        var videoClips: [[String: Any]] = []
        var voiceClips: [[String: Any]] = []
        var clickClips: [[String: Any]] = []
        var srt: [String] = []
        var nextID = 1
        func newID() -> Int { defer { nextID += 1 }; return nextID }

        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd'T'HHmmss"
            return f.string(from: Date())
        }()

        /// Copies a file into media/<n>/ and returns its path inside the project.
        func addFile(_ file: URL, name: String) throws -> String {
            let folder = media.appendingPathComponent("\(sourceBin.count + 1)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent(name)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: file, to: dest)
            return "./media/\(sourceBin.count + 1)/\(name)"
        }

        func videoSource(_ src: String, frames: Int, name: String) -> Int {
            let id = newID()
            sourceBin.append([
                "id": id, "src": src, "rect": [0, 0, Int(TutorialVideo.W), Int(TutorialVideo.H)],
                "lastMod": stamp, "loudnessNormalization": true,
                "sourceTracks": [[
                    "range": [0, frames], "type": 0, "editRate": TutorialVideo.fps,
                    "trackRect": [0, 0, Int(TutorialVideo.W), Int(TutorialVideo.H)],
                    "sampleRate": 48000, "bitDepth": 24, "numChannels": 0, "integratedLUFS": 100.0,
                    "peakLevel": -1.0, "tag": 0, "metaData": "\(name);", "parameters": [String: Any](),
                ]],
                "metadata": ["timeAdded": stamp],
            ])
            return id
        }

        func audioSource(_ src: String, samples: Int, name: String) -> Int {
            let id = newID()
            sourceBin.append([
                "id": id, "src": src, "rect": [0, 0, 0, 0], "lastMod": stamp, "loudnessNormalization": true,
                "sourceTracks": [[
                    "range": [0, samples], "type": 2, "editRate": 44100, "trackRect": [0, 0, 0, 0],
                    "sampleRate": 44100, "bitDepth": 16, "numChannels": 2, "integratedLUFS": 100.0,
                    "peakLevel": -1.0, "tag": 0, "metaData": "\(name);", "parameters": [String: Any](),
                ]],
                "metadata": ["timeAdded": stamp],
            ])
            return id
        }

        func clip(_ type: String, src: Int, start: Int64, duration: Int64, audio: Bool, gain: Double = 1) -> [String: Any] {
            var c: [String: Any] = [
                "id": newID(), "_type": type, "start": start, "duration": duration,
                "mediaStart": 0, "mediaDuration": duration, "scalar": 1,
                "metadata": [
                    "audiateLinkedSession": "",
                    "clipSpeedAttribute": ["type": "bool", "value": false],
                    "colorAttribute": ["type": "color", "value": [0, 0, 0, 0]],
                    "effectApplied": "none",
                ],
                "animationTracks": [String: Any](), "parameters": [String: Any](), "effects": [Any](),
                "src": src, "trackNumber": 0,
            ]
            if audio {
                c["attributes"] = ["ident": "", "gain": gain, "mixToMono": false, "loudnessNormalization": true, "sourceFileOffset": 0]
                c["channelNumber"] = "0"
            } else {
                c["attributes"] = ["ident": ""]
            }
            return c
        }

        /// Narration and clicks are converted to 44.1 kHz 16-bit stereo WAV, which Camtasia reads everywhere.
        func wav(_ input: URL, name: String) -> (URL, Int)? {
            let out = work.appendingPathComponent(name)
            try? fm.removeItem(at: out)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            p.arguments = ["-f", "WAVE", "-d", "LEI16@44100", "-c", "2", input.path, out.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            p.waitUntilExit()
            guard p.terminationStatus == 0, let f = try? AVAudioFile(forReading: out) else { return nil }
            return (out, Int(f.length))
        }

        func ticks(frames: Int) -> Int64 { Int64(frames) * ticksPerSecond / Int64(TutorialVideo.fps) }
        func ticks(seconds: Double) -> Int64 { Int64((seconds * Double(ticksPerSecond)).rounded()) }
        func ticks(samples: Int) -> Int64 { Int64(samples) * ticksPerSecond / 44100 }

        let click = work.appendingPathComponent("click.caf")
        try TutorialVideo.writeClickSound(to: click)
        var clickSource: (id: Int, samples: Int)?

        var at: Int64 = 0          // timeline position in ticks
        var seconds = 0.0          // the same, in seconds, for captions
        var stepNumber = 0
        for (i, shot) in shots.enumerated() {
            let label: String
            switch shot.content {
            case .card(let intro): label = intro ? "Intro" : "Outro"
            case .slide: label = i == 0 ? "Intro" : "Outro"
            case .clip: label = i == 0 ? "Intro" : "Outro"
            case .step, .note: stepNumber += 1; label = String(format: "Step %02d", stepNumber)
            }
            progress("Making Camtasia clip \(i + 1) of \(shots.count): \(label)…")
            let frames = TutorialVideo.frames(shot.duration)
            let name = "\(String(format: "%02d", i + 1)) \(label).mp4"
            let file = work.appendingPathComponent(name)
            // Each part on its own, with no fades: transitions are yours to add in Camtasia.
            try await TutorialVideo.writeVideo([shot], look: look, to: file, fades: false) { _ in }
            let vid = videoSource(try addFile(file, name: name), frames: frames, name: name)
            let dur = ticks(frames: frames)
            videoClips.append(clip("VMFile", src: vid, start: at, duration: dur, audio: false))

            // The intro/outro video's own sound goes on the narration track.
            if case .clip(let u) = shot.content, let sound = wav(u, name: "\(String(format: "%02d", i + 1)) \(label) sound.wav") {
                let (w, samples) = sound
                let len = min(samples, Int(shot.duration * 44100))
                let aid = audioSource(try addFile(w, name: w.lastPathComponent), samples: samples, name: w.lastPathComponent)
                voiceClips.append(clip("AMFile", src: aid, start: at, duration: ticks(samples: len), audio: true))
            }
            if let n = shot.narration, let voice = wav(n, name: "\(String(format: "%02d", i + 1)) \(label) voice.wav") {
                let (w, samples) = voice
                let aid = audioSource(try addFile(w, name: w.lastPathComponent), samples: samples, name: w.lastPathComponent)
                voiceClips.append(clip("AMFile", src: aid, start: at + ticks(seconds: shot.narrationStart),
                                       duration: ticks(samples: samples), audio: true))
            }
            if !shot.clickTimes.isEmpty {
                if clickSource == nil, let c = wav(click, name: "click.wav") {
                    clickSource = (audioSource(try addFile(c.0, name: "click.wav"), samples: c.1, name: "click.wav"), c.1)
                }
                if let cs = clickSource {
                    for c in shot.clickTimes {
                        clickClips.append(clip("AMFile", src: cs.id, start: at + ticks(seconds: c),
                                               duration: ticks(samples: cs.samples), audio: true, gain: 0.55))
                    }
                }
            }
            // Captions: the step text while that step is on screen.
            let captionText: String? = {
                switch shot.content {
                case .step(let st): return st.text
                case .note(_, let text): return text
                default: return nil
                }
            }()
            if let t = captionText?.plain.trimmed, !t.isEmpty {
                let from = seconds + 0.3, to = seconds + Double(frames) / Double(TutorialVideo.fps) - 0.1
                srt.append("\(srt.count + 1)\n\(srtTime(from)) --> \(srtTime(to))\n\(t)\n")
            }
            at += dur
            seconds += Double(frames) / Double(TutorialVideo.fps)
        }

        // The original full-screen screenshots, in the media bin only (not on the timeline), so you can
        // build your own shots in Camtasia. Blurs are kept so private details stay hidden; the highlight
        // box, drawings, crop and zoom are left off.
        progress("Adding the screenshots to the media bin…")
        let shotJobs: [(Int, Step, URL)] = await MainActor.run {
            guide.steps.enumerated().compactMap { i, st in
                st.image.map { (i + 1, st, GuideStore.shared.imageURL(guide.id, $0)) }
            }
        }
        for (n, st, imgURL) in shotJobs {
            let png: Data? = await Task.detached(priority: .userInitiated) {
                guard let base = GuideStore.loadImage(imgURL) else { return nil }
                var clean = st
                clean.showHighlight = false
                clean.annotations = nil
                clean.crop = nil
                clean.zoomOverride = .off
                return Renderer.render(clean, base: base, zoom: .off).flatMap(Renderer.png)
            }.value
            guard let png, let img = NSBitmapImageRep(data: png) else { continue }
            let name = String(format: "Screenshot %02d.png", n)
            let tmp = work.appendingPathComponent(name)
            try png.write(to: tmp)
            let src = try addFile(tmp, name: name)
            let id = newID()
            let w = img.pixelsWide, h = img.pixelsHigh
            sourceBin.append([
                "id": id, "src": src, "rect": [0, 0, w, h], "lastMod": stamp, "loudnessNormalization": true,
                "sourceTracks": [[
                    "range": [0, 1], "type": 1, "editRate": 600, "trackRect": [0, 0, w, h],
                    "sampleRate": 600, "bitDepth": 0, "numChannels": 0, "integratedLUFS": 100.0,
                    "peakLevel": -1.0, "tag": 0, "metaData": "\(name);", "parameters": [String: Any](),
                ]],
                "metadata": ["timeAdded": stamp],
            ])
        }

        func attributes() -> [String: Any] {
            ["ident": "", "audioMuted": false, "videoHidden": false, "magnetic": false, "matte": 0, "solo": false,
             "metadata": ["IsLocked": "False", "trackHeight": "54"]]
        }
        let project: [String: Any] = [
            "title": guide.title.plain, "description": guide.summary.plain, "author": "",
            "targetLoudness": -18.0, "shouldApplyLoudnessNormalization": true,
            "videoFormatFrameRate": TutorialVideo.fps, "audioFormatSampleRate": 44100,
            "allowSubFrameEditing": false, "width": Double(TutorialVideo.W), "height": Double(TutorialVideo.H),
            "version": "10.0", "editRate": ticksPerSecond,
            "authoringClientName": ["name": "Camtasia", "platform": "Mac", "version": "2026.0.7"],
            "sourceBin": sourceBin,
            "timeline": [
                "id": newID(),
                "sceneTrack": ["scenes": [["csml": ["tracks": [
                    ["trackIndex": 0, "medias": videoClips, "parameters": [String: Any]()],
                    ["trackIndex": 1, "medias": voiceClips, "parameters": [String: Any]()],
                    ["trackIndex": 2, "medias": clickClips, "parameters": [String: Any]()],
                ]]]]],
                "trackAttributes": [attributes(), attributes(), attributes()],
                "captionAttributes": [
                    "enabled": true, "fontName": "Arial", "fontSize": 32, "backgroundColor": [0, 0, 0, 204],
                    "foregroundColor": [255, 255, 255, 255], "lang": "en", "alignment": 0, "defaultFontSize": true,
                    "opacity": 0.5, "backgroundEnabled": true, "backgroundOnlyAroundText": true,
                ],
                "backgroundColor": [0, 0, 0, 255], "parameters": [String: Any](), "gain": 1.0,
                "legacyAttenuateAudioMix": false,
            ],
            "metadata": ["hasNotifiedAboutHFRMedia": false],
        ]
        let json = try JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: bundle.appendingPathComponent("project.tscproj"))
        try Self.emptyPlist.write(to: bundle.appendingPathComponent("bookmarks.plist"), atomically: true, encoding: .utf8)
        try Self.docPrefs.write(to: bundle.appendingPathComponent("docPrefs"), atomically: true, encoding: .utf8)

        try? fm.removeItem(at: url)
        try fm.moveItem(at: bundle, to: url)
        if !srt.isEmpty {
            let captions = url.deletingPathExtension().appendingPathExtension("srt")
            try srt.joined(separator: "\n").write(to: captions, atomically: true, encoding: .utf8)
        }
    }

    static func srtTime(_ s: Double) -> String {
        let ms = Int((max(0, s) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    static let emptyPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict/>
    </plist>
    """

    static let docPrefs = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>DocPrefIsAssetPanelOpen</key>
    \t<integer>1</integer>
    \t<key>DocPrefIsPropertiesOpen</key>
    \t<integer>1</integer>
    \t<key>DocPrefPlayheadTime</key>
    \t<string>0</string>
    \t<key>DocPrefPreviewAutoFit</key>
    \t<integer>1</integer>
    \t<key>DocPrefTrackHeights</key>
    \t<array>
    \t\t<integer>54</integer>
    \t\t<integer>54</integer>
    \t\t<integer>54</integer>
    \t</array>
    \t<key>SaveAsStandaloneProject</key>
    \t<real>1</real>
    </dict>
    </plist>
    """
}
