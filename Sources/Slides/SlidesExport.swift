// Export — a Camtasia project (slides on track 1, the sound on track 2, every slide in the
// Media Bin) or a finished MP4.

import Foundation
import AppKit
import AVFoundation

enum Export {
    static let ticksPerSecond: Int64 = 705_600_000

    struct Plan {
        var slides: [Slide]
        var cues: [Cue]
        var duration: Double
        var wav: URL
        var recording: URL?
        var includeRecording: Bool
        var title: String
        /// Only these slide indexes go in the Media Bin (nil = every slide).
        var binOnly: Set<Int>? = nil
        /// Keyword finds, added as timeline markers.
        var finds: [Find] = []
    }

    // MARK: Camtasia

    static func camtasia(_ p: Plan, to requested: URL) throws {
        let fm = FileManager.default
        let url = requested.pathExtension.lowercased() == "cmproj" ? requested : requested.appendingPathExtension("cmproj")
        let work = fm.temporaryDirectory.appendingPathComponent("cm-\(UUID().uuidString)")
        let bundle = work.appendingPathComponent("project.cmproj")
        let media = bundle.appendingPathComponent("media")
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd'T'HHmmss"
            return f.string(from: Date())
        }()
        var nextID = 1
        func newID() -> Int { defer { nextID += 1 }; return nextID }
        var folder = 0
        func add(_ file: URL, as name: String) throws -> String {
            folder += 1
            let dir = media.appendingPathComponent("\(folder)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: file, to: dir.appendingPathComponent(name))
            return "./media/\(folder)/\(name)"
        }
        func track(_ type: Int, range: Int, editRate: Int, rect: [Int], sampleRate: Int, bits: Int, channels: Int, name: String) -> [String: Any] {
            ["range": [0, range], "type": type, "editRate": editRate, "trackRect": rect, "sampleRate": sampleRate,
             "bitDepth": bits, "numChannels": channels, "integratedLUFS": 100.0, "peakLevel": -1.0, "tag": 0,
             "metaData": "\(name);", "parameters": [String: Any]()]
        }
        func source(_ id: Int, src: String, rect: [Int], tracks: [[String: Any]]) -> [String: Any] {
            ["id": id, "src": src, "rect": rect, "lastMod": stamp, "loudnessNormalization": true,
             "sourceTracks": tracks, "metadata": ["timeAdded": stamp]]
        }
        func clip(_ type: String, src: Int, start: Int64, duration: Int64, mediaDuration: Int64) -> [String: Any] {
            var c: [String: Any] = [
                "id": newID(), "_type": type, "start": start, "duration": duration, "mediaStart": 0,
                "mediaDuration": mediaDuration, "scalar": 1,
                "metadata": ["audiateLinkedSession": "", "clipSpeedAttribute": ["type": "bool", "value": false],
                             "colorAttribute": ["type": "color", "value": [0, 0, 0, 0]], "effectApplied": "none"],
                "animationTracks": [String: Any](), "parameters": [String: Any](), "effects": [Any](),
                "src": src, "trackNumber": 0,
            ]
            if type == "AMFile" {
                c["attributes"] = ["ident": "", "gain": 1.0, "mixToMono": false, "loudnessNormalization": true, "sourceFileOffset": 0]
                c["channelNumber"] = "0"
            } else {
                c["attributes"] = ["ident": ""]
                if type == "IMFile" { c["trimStartSum"] = 0 }
            }
            return c
        }
        func ticks(_ s: Double) -> Int64 { Int64((s * Double(ticksPerSecond)).rounded()) }

        // The slides in the Media Bin (every slide, or this recording's range).
        var bin: [[String: Any]] = []
        var slideSource: [Int: Int] = [:]
        for (i, s) in p.slides.enumerated() where p.binOnly?.contains(i) ?? true {
            let name = String(format: "Slide %02d.", s.number) + (s.url.pathExtension.isEmpty ? "png" : s.url.pathExtension.lowercased())
            let w = Int(s.size.width), h = Int(s.size.height)
            let id = newID()
            bin.append(source(id, src: try add(s.url, as: name), rect: [0, 0, w, h],
                              tracks: [track(1, range: 1, editRate: 600, rect: [0, 0, w, h], sampleRate: 600, bits: 0, channels: 0, name: name)]))
            slideSource[i] = id
        }
        // The sound.
        let audioFile = try AVAudioFile(forReading: p.wav)
        let samples = Int(audioFile.length)
        let wavName = p.wav.lastPathComponent
        let audioID = newID()
        bin.append(source(audioID, src: try add(p.wav, as: wavName), rect: [0, 0, 0, 0],
                          tracks: [track(2, range: samples, editRate: 44100, rect: [0, 0, 0, 0], sampleRate: 44100, bits: 16, channels: 2, name: wavName)]))
        // Optionally the original recording too (Media Bin only).
        if p.includeRecording, let rec = p.recording, ["mp4", "mov", "m4v"].contains(rec.pathExtension.lowercased()) {
            let asset = AVURLAsset(url: rec)
            let dur = asset.duration.seconds
            let size = asset.tracks(withMediaType: .video).first.map { $0.naturalSize.applying($0.preferredTransform) } ?? CGSize(width: 1920, height: 1080)
            let w = Int(abs(size.width)), h = Int(abs(size.height))
            let fps = Int((asset.tracks(withMediaType: .video).first?.nominalFrameRate ?? 30).rounded())
            let name = rec.lastPathComponent
            bin.append(source(newID(), src: try add(rec, as: name), rect: [0, 0, w, h], tracks: [
                track(0, range: Int(dur * Double(fps)), editRate: fps, rect: [0, 0, w, h], sampleRate: fps, bits: 24, channels: 0, name: name),
                track(2, range: Int(dur * 44100), editRate: 44100, rect: [0, 0, 0, 0], sampleRate: 44100, bits: 16, channels: 2, name: name),
            ]))
        }

        // Track 1: the slides, one after another.
        var slideClips: [[String: Any]] = []
        for (i, c) in p.cues.enumerated() {
            let end = i + 1 < p.cues.count ? p.cues[i + 1].start : p.duration
            guard end > c.start, let src = slideSource[c.slide] else { continue }
            slideClips.append(clip("IMFile", src: src, start: ticks(c.start), duration: ticks(end - c.start), mediaDuration: 1))
        }
        // Track 2: the sound, whole.
        let audioTicks = Int64(samples) * ticksPerSecond / 44100
        let audioClips = [clip("AMFile", src: audioID, start: 0, duration: audioTicks, mediaDuration: audioTicks)]

        func attributes() -> [String: Any] {
            ["ident": "", "audioMuted": false, "videoHidden": false, "magnetic": false, "matte": 0, "solo": false,
             "metadata": ["IsLocked": "False", "trackHeight": "54"]]
        }
        // Keyword finds as timeline markers (labelled flags above the timeline).
        var timelineParameters: [String: Any] = [:]
        let markerTimes = p.finds.map { f -> [String: Any] in
            let t = ticks(f.start)
            return ["time": t, "endTime": t, "value": f.search, "duration": 0]
        }
        if !markerTimes.isEmpty {
            timelineParameters["toc"] = ["type": "string", "keyframes": markerTimes]
        }
        let project: [String: Any] = [
            "title": p.title, "description": "", "author": "",
            "targetLoudness": -18.0, "shouldApplyLoudnessNormalization": true,
            "videoFormatFrameRate": 30, "audioFormatSampleRate": 44100, "allowSubFrameEditing": false,
            "width": 1920.0, "height": 1080.0, "version": "10.0", "editRate": ticksPerSecond,
            "authoringClientName": ["name": "Camtasia", "platform": "Mac", "version": "2026.0.7"],
            "sourceBin": bin,
            "timeline": [
                "id": newID(),
                "sceneTrack": ["scenes": [["csml": ["tracks": [
                    ["trackIndex": 0, "medias": slideClips, "parameters": [String: Any]()],
                    ["trackIndex": 1, "medias": audioClips, "parameters": [String: Any]()],
                ]]]]],
                "trackAttributes": [attributes(), attributes()],
                "captionAttributes": [
                    "enabled": true, "fontName": "Arial", "fontSize": 32, "backgroundColor": [0, 0, 0, 204],
                    "foregroundColor": [255, 255, 255, 255], "lang": "en", "alignment": 0, "defaultFontSize": true,
                    "opacity": 0.5, "backgroundEnabled": true, "backgroundOnlyAroundText": true,
                ],
                "backgroundColor": [0, 0, 0, 255], "parameters": timelineParameters, "gain": 1.0,
                "legacyAttenuateAudioMix": false,
            ],
            "metadata": ["hasNotifiedAboutHFRMedia": false],
        ]
        let json = try JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: bundle.appendingPathComponent("project.tscproj"))
        try emptyPlist.write(to: bundle.appendingPathComponent("bookmarks.plist"), atomically: true, encoding: .utf8)
        try docPrefs.write(to: bundle.appendingPathComponent("docPrefs"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: url)
        try fm.moveItem(at: bundle, to: url)
    }

    // MARK: MP4

    static func mp4(_ p: Plan, to url: URL, progress: @escaping (Double) -> Void) async throws {
        let fm = FileManager.default
        let size = CGSize(width: 1920, height: 1080)
        let silent = fm.temporaryDirectory.appendingPathComponent("slides-\(UUID().uuidString).mp4")
        defer { try? fm.removeItem(at: silent) }
        let writer = try AVAssetWriter(outputURL: silent, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? PGError("Couldn't start the video.") }
        writer.startSession(atSourceTime: .zero)
        func at(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
        for (i, c) in p.cues.enumerated() {
            let end = i + 1 < p.cues.count ? p.cues[i + 1].start : p.duration
            guard end > c.start, let pb = frame(p.slides[c.slide].url, size: size, pool: adaptor.pixelBufferPool) else { continue }
            var t = c.start
            while t < end {   // repeat each second so players can seek smoothly
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
                adaptor.append(pb, withPresentationTime: at(t))
                t += 1
            }
            progress(Double(i + 1) / Double(max(1, p.cues.count)) * 0.6)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: at(p.duration))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? PGError("Couldn't make the video.") }

        let comp = AVMutableComposition()
        let v = AVURLAsset(url: silent), a = AVURLAsset(url: p.wav)
        guard let vs = try await v.loadTracks(withMediaType: .video).first,
              let asrc = try await a.loadTracks(withMediaType: .audio).first,
              let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let at2 = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw PGError("Couldn't put the video together.") }
        let vd = try await v.load(.duration), ad = try await a.load(.duration)
        try vt.insertTimeRange(CMTimeRange(start: .zero, duration: vd), of: vs, at: .zero)
        try at2.insertTimeRange(CMTimeRange(start: .zero, duration: ad), of: asrc, at: .zero)
        try? fm.removeItem(at: url)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw PGError("Couldn't export the video.")
        }
        export.outputURL = url
        export.outputFileType = .mp4
        progress(0.7)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        guard export.status == .completed else { throw export.error ?? PGError("Couldn't export the video.") }
        progress(1)
    }

    /// A slide fitted into 1920×1080 on black.
    static func frame(_ url: URL, size: CGSize, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var pb: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
        if pb == nil { CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &pb) }
        guard let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let k = min(size.width / CGFloat(img.width), size.height / CGFloat(img.height))
        let w = CGFloat(img.width) * k, h = CGFloat(img.height) * k
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        return buf
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
    \t<key>DocPrefPreviewAutoFit</key>
    \t<integer>1</integer>
    \t<key>SaveAsStandaloneProject</key>
    \t<real>1</real>
    </dict>
    </plist>
    """
}
