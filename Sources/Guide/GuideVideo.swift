// Video — MP4 and GIF exports. Each step is shown full-frame with its instruction as a caption.
// Optional narration uses the Mac's built-in voices (no account or key needed).

import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum VideoMaker {
    static let size = CGSize(width: 1920, height: 1080)

    /// One finished frame: the step picture above a caption bar.
    static func frame(_ item: ExportItem, total: Int, size: CGSize = VideoMaker.size) -> CGImage? {
        let W = size.width, H = size.height
        guard let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let k = W / 1920
        ctx.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let captionH = 170 * k
        if let img = item.image {
            let area = CGRect(x: 40 * k, y: captionH + 20 * k, width: W - 80 * k, height: H - captionH - 60 * k)
            let s = min(area.width / CGFloat(img.width), area.height / CGFloat(img.height))
            let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h))
        }
        // Caption (drawn with AppKit text, bottom-left origin context).
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let badge = CGRect(x: 60 * k, y: captionH / 2 - 30 * k, width: 60 * k, height: 60 * k)
        (NSColor(cgColor: Renderer.accent) ?? .systemRed).setFill()
        NSBezierPath(ovalIn: badge).fill()
        let num = NSAttributedString(string: "\(item.number)", attributes: [
            .font: NSFont.systemFont(ofSize: 28 * k, weight: .bold), .foregroundColor: NSColor.white])
        let ns = num.size()
        num.draw(at: CGPoint(x: badge.midX - ns.width / 2, y: badge.midY - ns.height / 2))
        let text = NSMutableAttributedString()
        for part in item.text.boldParts {
            text.append(NSAttributedString(string: part.text, attributes: [
                .font: NSFont.systemFont(ofSize: 40 * k, weight: part.bold ? .bold : .medium),
                .foregroundColor: NSColor.white]))
        }
        let textRect = CGRect(x: 150 * k, y: 20 * k, width: W - 210 * k, height: captionH - 40 * k)
        let bounds = text.boundingRect(with: textRect.size, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let r = CGRect(x: textRect.minX, y: textRect.midY - min(bounds.height, textRect.height) / 2,
                       width: textRect.width, height: min(bounds.height, textRect.height))
        text.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: GIF

    static func gif(guide: Guide, items: [ExportItem], to url: URL) throws {
        let gifSize = CGSize(width: 1200, height: 675)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, items.count, nil) else {
            throw PGError("Couldn't create the GIF.")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for it in items {
            guard let f = frame(it, total: items.count, size: gifSize) else { continue }
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 3.0,
                                                         kCGImagePropertyGIFUnclampedDelayTime: 3.0]] as CFDictionary
            CGImageDestinationAddImage(dest, f, props)
        }
        guard CGImageDestinationFinalize(dest) else { throw PGError("Couldn't write the GIF.") }
    }

    // MARK: MP4

    static func mp4(guide: Guide, items: [ExportItem], narrate: Bool, to url: URL,
                    progress: @escaping (String) -> Void) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // Narration first: each step lasts as long as its sentence (at least 3.5 s).
        var audio: [URL?] = Array(repeating: nil, count: items.count)
        var durations: [Double] = Array(repeating: 3.5, count: items.count)
        if narrate {
            for (i, it) in items.enumerated() {
                progress("Recording narration \(i + 1) of \(items.count)…")
                let file = work.appendingPathComponent("n\(i).caf")
                if let secs = try? await Speech.write(it.text.plain, to: file), secs > 0 {
                    audio[i] = file
                    durations[i] = max(3.5, secs + 0.9)
                }
            }
        }

        progress("Making the video…")
        let silent = narrate ? work.appendingPathComponent("silent.mp4") : url
        try? fm.removeItem(at: silent)
        try await writeFrames(items, durations: durations, to: silent)

        guard narrate, audio.contains(where: { $0 != nil }) else { return }
        progress("Adding narration…")
        let comp = AVMutableComposition()
        let videoAsset = AVURLAsset(url: silent)
        guard let vSrc = try await videoAsset.loadTracks(withMediaType: .video).first,
              let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw PGError("Couldn't build the video.") }
        let vDur = try await videoAsset.load(.duration)
        try vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vSrc, at: .zero)
        var t = 0.0
        for (i, a) in audio.enumerated() {
            defer { t += durations[i] }
            guard let a else { continue }
            let asset = AVURLAsset(url: a)
            guard let src = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let d = try await asset.load(.duration)
            try aTrack.insertTimeRange(CMTimeRange(start: .zero, duration: d), of: src,
                                       at: CMTime(seconds: t + 0.4, preferredTimescale: 600))
        }
        try? fm.removeItem(at: url)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw PGError("Couldn't export the video.")
        }
        export.outputURL = url
        export.outputFileType = .mp4
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        if export.status != .completed {
            throw PGError(export.error?.localizedDescription ?? "Couldn't export the video.")
        }
    }

    private static func writeFrames(_ items: [ExportItem], durations: [Double], to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? PGError("Couldn't start the video.") }
        writer.startSession(atSourceTime: .zero)

        var t = 0.0
        var lastBuffer: CVPixelBuffer?
        for (i, it) in items.enumerated() {
            guard let img = frame(it, total: items.count), let pb = pixelBuffer(img, pool: adaptor.pixelBufferPool) else { continue }
            // Show the frame, then repeat it each second so players can seek smoothly.
            var s = 0.0
            while s < durations[i] {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000) }
                adaptor.append(pb, withPresentationTime: CMTime(seconds: t + s, preferredTimescale: 600))
                s += 1
            }
            t += durations[i]
            lastBuffer = pb
        }
        if let pb = lastBuffer {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000) }
            adaptor.append(pb, withPresentationTime: CMTime(seconds: t - 0.04, preferredTimescale: 600))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: t, preferredTimescale: 600))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? PGError("Couldn't finish the video.") }
    }

    private static func pixelBuffer(_ img: CGImage, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
        if pb == nil {
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &pb)
        }
        guard let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(img, in: CGRect(origin: .zero, size: size))
        return buf
    }
}

// MARK: - Built-in Mac voice to a sound file

final class Speech: NSObject {
    /// Speaks `text` into `url` and returns the length in seconds.
    static func write(_ text: String, to url: URL) async throws -> Double {
        let synth = AVSpeechSynthesizer()
        let utt = AVSpeechUtterance(string: text)
        if let id = UserDefaults.standard.string(forKey: "voiceID"), let v = AVSpeechSynthesisVoice(identifier: id) {
            utt.voice = v
        } else {
            utt.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
        }
        let job = SpeechJob(synth: synth, url: url)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Double, Error>) in
            job.continuation = c
            synth.write(utt) { buffer in job.receive(buffer) }
        }
    }

    static var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") || $0.language.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }
}

/// Holds the state while a sentence is being spoken into a file.
private final class SpeechJob {
    let synth: AVSpeechSynthesizer   // kept alive until finished
    let url: URL
    var continuation: CheckedContinuation<Double, Error>?
    var file: AVAudioFile?
    var frames: AVAudioFramePosition = 0

    init(synth: AVSpeechSynthesizer, url: URL) {
        self.synth = synth
        self.url = url
    }

    func receive(_ buffer: AVAudioBuffer) {
        guard let c = continuation, let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 {
            let secs = file.map { Double(frames) / $0.processingFormat.sampleRate } ?? 0
            file = nil   // closes the file
            continuation = nil
            c.resume(returning: secs)
            return
        }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                       commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
            }
            try file?.write(from: pcm)
            frames += AVAudioFramePosition(pcm.frameLength)
        } catch {
            continuation = nil
            c.resume(throwing: error)
        }
    }
}
