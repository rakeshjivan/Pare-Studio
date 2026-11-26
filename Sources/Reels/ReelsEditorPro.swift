// The full editor behind Edit Video: live playback with every effect previewed, Camtasia-style keys,
// split / select / delete, undo, text and logo overlays, colour, rotate and flip, fades, audio clean-up
// and output size.
//
// Saving: everything that depends on the original timeline (cuts, timed blurs, text, logos, colour,
// rotation, fades, audio) is done in one first pass; then the usual save runs on that copy
// (crop, whole-video blurs, speed, output size, smaller file, GIF, framed).

import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import UniformTypeIdentifiers

// MARK: - Edit data

struct RGBA: Equatable, Hashable {
    var r: Double, g: Double, b: Double, a: Double
    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
    static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
    static let banner = RGBA(r: 0.07, g: 0.09, b: 0.14, a: 0.82)
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    init(r: Double, g: Double, b: Double, a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(_ c: Color) {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        r = Double(n.redComponent); g = Double(n.greenComponent); b = Double(n.blueComponent); a = Double(n.alphaComponent)
    }
}

struct TextOverlay: Identifiable, Equatable {
    enum Style: String, CaseIterable, Identifiable { case plain = "Plain", box = "Box", banner = "Banner"; var id: String { rawValue } }
    let id = UUID()
    var text = "Your text"
    var size: Double = 0.06          // letter height as a share of the picture height
    var bold = true
    var colour = RGBA.white
    var style: Style = .banner
    var background = RGBA.banner
    var center = CGPoint(x: 0.5, y: 0.85)
    var range: ClosedRange<Double>?  // nil = whole video
}

struct ImageOverlay: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var width: Double = 0.16         // share of the picture width
    var opacity: Double = 1
    var center = CGPoint(x: 0.88, y: 0.12)
    var range: ClosedRange<Double>?
}

struct Look: Equatable {
    var brightness: Double = 0      // -0.3 ... 0.3
    var contrast: Double = 1        // 0.5 ... 1.5
    var saturation: Double = 1      // 0 ... 2
    var isDefault: Bool { abs(brightness) < 0.001 && abs(contrast - 1) < 0.001 && abs(saturation - 1) < 0.001 }
}

struct AudioFX: Equatable {
    var volume: Double = 1          // 0 ... 2
    var mute = false
    var normalise = false
    var denoise = false
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var isDefault: Bool { abs(volume - 1) < 0.001 && !mute && !normalise && !denoise && fadeIn == 0 && fadeOut == 0 }
}

/// Everything you can undo.
struct EditState: Equatable {
    var trimStart: Double, trimEnd: Double
    var cuts: [CutRange], splits: [Double]
    var crop: CGRect
    var blurs: [CGRect], blurTimes: [ClosedRange<Double>?]
    var speed: Double
    var texts: [TextOverlay], images: [ImageOverlay]
    var look: Look
    var rotation: Int, flipH: Bool, flipV: Bool
    var fadeIn: Double, fadeOut: Double
    var audio: AudioFX
    var outputHeight: Int
}

// MARK: - What the live preview draws (read on the video thread)

struct EffectSnapshot: @unchecked Sendable {
    struct Blur { var rect: CGRect; var range: ClosedRange<Double>? }
    struct Art { var image: CGImage; var center: CGPoint; var widthFrac: Double; var opacity: Double; var range: ClosedRange<Double>? }
    var rotation = 0, flipH = false, flipV = false
    var look = Look()
    var blurs: [Blur] = []
    var art: [Art] = []
    var fadeIn = 0.0, fadeOut = 0.0, trimStart = 0.0, trimEnd = 0.0
}

final class EffectBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snap = EffectSnapshot()
    func set(_ s: EffectSnapshot) { lock.withLock { snap = s } }
    func get() -> EffectSnapshot { lock.withLock { snap } }
}

enum OverlayArt {
    /// Draws a text overlay at the size it will appear on a picture `frameHeight` pixels high.
    static func text(_ t: TextOverlay, frameHeight: CGFloat, frameWidth: CGFloat) -> CGImage? {
        let fontSize = max(8, CGFloat(t.size) * frameHeight)
        let font = NSFont.systemFont(ofSize: fontSize, weight: t.bold ? .bold : .regular)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(t.style == .plain ? 0.75 : 0)
        shadow.shadowBlurRadius = fontSize * 0.12
        shadow.shadowOffset = NSSize(width: 0, height: -fontSize * 0.04)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(cgColor: t.colour.cg) ?? .white,
            .paragraphStyle: para, .shadow: shadow,
        ]
        let str = NSAttributedString(string: t.text.isEmpty ? " " : t.text, attributes: attrs)
        let maxW = frameWidth * (t.style == .banner ? 0.92 : 0.9)
        let bounds = str.boundingRect(with: NSSize(width: maxW, height: frameHeight), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let padX = t.style == .plain ? fontSize * 0.2 : fontSize * 0.6
        let padY = t.style == .plain ? fontSize * 0.1 : fontSize * 0.35
        var w = ceil(bounds.width + padX * 2), h = ceil(bounds.height + padY * 2)
        if t.style == .banner { w = ceil(frameWidth) }
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        if t.style != .plain {
            ctx.setFillColor(t.background.cg)
            let r = CGRect(x: 0, y: 0, width: w, height: h)
            if t.style == .box {
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: fontSize * 0.3, cornerHeight: fontSize * 0.3, transform: nil))
                ctx.fillPath()
            } else {
                ctx.fill(r)
            }
        }
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        str.draw(with: NSRect(x: (w - bounds.width) / 2, y: padY, width: bounds.width, height: bounds.height),
                 options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// A logo or picture at its overlay size.
    static func image(_ o: ImageOverlay, frameWidth: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(o.url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = max(8, Int(CGFloat(o.width) * frameWidth))
        let h = max(8, Int(CGFloat(w) * CGFloat(img.height) / CGFloat(max(1, img.width))))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.setAlpha(CGFloat(o.opacity))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func png(_ img: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }
}

// MARK: - The editor's behaviour

extension CropModel {
    var editState: EditState {
        EditState(trimStart: trimStart, trimEnd: trimEnd, cuts: cuts, splits: splits, crop: crop,
                  blurs: blurs, blurTimes: blurTimes, speed: speed, texts: texts, images: images, look: look,
                  rotation: rotation, flipH: flipH, flipV: flipV, fadeIn: fadeIn, fadeOut: fadeOut,
                  audio: audioFX, outputHeight: outputHeight)
    }

    func apply(_ s: EditState) {
        applyingUndo = true
        let rotationChanged = s.rotation != rotation
        trimStart = s.trimStart; trimEnd = s.trimEnd; cuts = s.cuts; splits = s.splits; crop = s.crop
        blurs = s.blurs; blurTimes = s.blurTimes; speed = s.speed; texts = s.texts; images = s.images
        look = s.look; rotation = s.rotation; flipH = s.flipH; flipV = s.flipV; fadeIn = s.fadeIn; fadeOut = s.fadeOut
        audioFX = s.audio; outputHeight = s.outputHeight
        if rotationChanged { updateRotatedSize(); rebuildComposition() }
        applyingUndo = false
        lastState = s
        refreshEffects()
    }

    /// Called whenever the edit changes. Changes within a moment of each other (a drag) undo as one.
    func recordChange() {
        let now = editState
        defer { refreshEffects() }
        guard !applyingUndo else { return }
        guard let last = lastState else { lastState = now; return }
        guard last != now else { return }
        if Date().timeIntervalSince(lastPush) > 0.6 {
            undoStack.append(last)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastPush = Date()
        lastState = now
        canUndo = !undoStack.isEmpty
        canRedo = false
    }

    func undo() {
        guard let s = undoStack.popLast(), let cur = lastState else { return }
        redoStack.append(cur)
        apply(s)
        lastPush = .distantPast
        canUndo = !undoStack.isEmpty; canRedo = true
    }

    func redo() {
        guard let s = redoStack.popLast(), let cur = lastState else { return }
        undoStack.append(cur)
        apply(s)
        lastPush = .distantPast
        canUndo = true; canRedo = !redoStack.isEmpty
    }

    func resetEditorState() {
        cuts = []; splits = []; texts = []; images = []; look = Look(); rotation = 0; flipH = false; flipV = false
        fadeIn = 0; fadeOut = 0; audioFX = AudioFX(); outputHeight = 0
        markIn = nil; markOut = nil; selectedOverlay = nil; zoom = 1; waveform = []
        undoStack = []; redoStack = []; lastState = nil; canUndo = false; canRedo = false
        overlayArt = [:]
    }

    // MARK: Player

    func setUpPlayer(_ asset: AVURLAsset) {
        playerAsset = asset
        baseSize = videoSize
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        rebuildComposition()
        if playerObserver == nil {
            playerObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
                MainActor.assumeIsolated { self?.playerTick(t.seconds) }
            }
        }
        lastState = editState
        refreshEffects()
        seekPlayer(time)
        makeWaveform(asset)
    }

    func rebuildComposition() {
        guard let asset = playerAsset, let item = player.currentItem else { return }
        let box = effects
        let ctx = CIContext(options: [.cacheIntermediates: false])
        _ = ctx
        let comp = AVMutableVideoComposition(asset: asset) { req in
            let s = box.get()
            var img = req.sourceImage
            let t = req.compositionTime.seconds
            // Rotate and flip.
            if s.rotation != 0 || s.flipH || s.flipV {
                let e = img.extent
                var tf = CGAffineTransform.identity
                switch s.rotation {
                case 90: tf = CGAffineTransform(translationX: 0, y: e.width).rotated(by: -.pi / 2)
                case 180: tf = CGAffineTransform(translationX: e.width, y: e.height).rotated(by: .pi)
                case 270: tf = CGAffineTransform(translationX: e.height, y: 0).rotated(by: .pi / 2)
                default: break
                }
                img = img.transformed(by: tf)
                let r = img.extent
                if s.flipH { img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -r.maxX - r.minX, y: 0)) }
                if s.flipV { img = img.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -r.maxY - r.minY)) }
                let o = img.extent.origin
                img = img.transformed(by: CGAffineTransform(translationX: -o.x, y: -o.y))
            }
            let ext = img.extent
            let W = ext.width, H = ext.height
            // Colour.
            if !s.look.isDefault {
                img = img.applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: s.look.brightness, kCIInputContrastKey: s.look.contrast,
                    kCIInputSaturationKey: s.look.saturation])
            }
            // Blurs (in picture coordinates: 0,0 is the top left).
            for b in s.blurs where b.range?.contains(t) ?? true {
                let r = CGRect(x: b.rect.minX * W, y: (1 - b.rect.maxY) * H, width: b.rect.width * W, height: b.rect.height * H)
                let blurred = img.clampedToExtent().applyingGaussianBlur(sigma: max(8, min(r.width, r.height) * 0.18)).cropped(to: r)
                img = blurred.composited(over: img)
            }
            // Text and logos.
            for a in s.art where a.range?.contains(t) ?? true {
                let w = CGFloat(a.image.width), h = CGFloat(a.image.height)
                let x = a.center.x * W - w / 2, y = (1 - a.center.y) * H - h / 2
                let pic = CIImage(cgImage: a.image).transformed(by: CGAffineTransform(translationX: x, y: y))
                img = pic.composited(over: img)
            }
            // Fades from and to black.
            var f = 1.0
            if s.fadeIn > 0, t < s.trimStart + s.fadeIn { f = min(f, max(0, (t - s.trimStart) / s.fadeIn)) }
            if s.fadeOut > 0, t > s.trimEnd - s.fadeOut { f = min(f, max(0, (s.trimEnd - t) / s.fadeOut)) }
            if f < 0.999 {
                img = img.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: f, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: f, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: f, w: 0)])
            }
            req.finish(with: img.cropped(to: ext), context: nil)
        }
        let natural = comp.renderSize
        if rotation == 90 || rotation == 270 { comp.renderSize = CGSize(width: natural.height, height: natural.width) }
        item.videoComposition = comp
    }

    func updateRotatedSize() {
        videoSize = (rotation == 90 || rotation == 270) ? CGSize(width: baseSize.height, height: baseSize.width) : baseSize
    }

    /// Sends the current effects to the live preview and redraws the paused frame.
    func refreshEffects() {
        let frameW = videoSize.width, frameH = videoSize.height
        var s = EffectSnapshot()
        s.rotation = rotation; s.flipH = flipH; s.flipV = flipV
        s.look = look
        s.blurs = blurs.indices.map { EffectSnapshot.Blur(rect: blurs[$0], range: $0 < blurTimes.count ? blurTimes[$0] : nil) }
        for t in texts {
            if let img = art(for: t.id, key: "\(t)\(frameH)", make: { OverlayArt.text(t, frameHeight: frameH, frameWidth: frameW) }) {
                s.art.append(.init(image: img, center: t.style == .banner ? CGPoint(x: 0.5, y: t.center.y) : t.center,
                                   widthFrac: Double(CGFloat(img.width) / max(1, frameW)), opacity: 1, range: t.range))
            }
        }
        for o in images {
            if let img = art(for: o.id, key: "\(o)\(frameW)", make: { OverlayArt.image(o, frameWidth: frameW) }) {
                s.art.append(.init(image: img, center: o.center, widthFrac: o.width, opacity: o.opacity, range: o.range))
            }
        }
        s.fadeIn = fadeIn; s.fadeOut = fadeOut; s.trimStart = trimStart; s.trimEnd = trimEnd
        effects.set(s)
        if !playing { player.currentItem.map { _ in seekPlayer(time, force: true) } }
    }

    private func art(for id: UUID, key: String, make: () -> CGImage?) -> CGImage? {
        if let c = overlayArt[id], c.key == key { return c.image }
        guard let img = make() else { return nil }
        overlayArt[id] = (key, img)
        return img
    }

    /// Size of an overlay on the picture (0...1), for drawing its box on the canvas.
    func overlaySize(_ id: UUID) -> CGSize? {
        guard let a = overlayArt[id]?.image, videoSize.width > 0 else { return nil }
        return CGSize(width: CGFloat(a.width) / videoSize.width, height: CGFloat(a.height) / videoSize.height)
    }

    func seekPlayer(_ t: Double, force: Bool = false) {
        guard player.currentItem != nil else { return }
        let target = CMTime(seconds: max(0, min(duration, t)), preferredTimescale: 600)
        if !force, abs(player.currentTime().seconds - t) < 0.01 { return }
        let tol = playing ? CMTime(seconds: 0.05, preferredTimescale: 600) : .zero
        player.seek(to: target, toleranceBefore: tol, toleranceAfter: tol)
    }

    /// The playhead moved (scrubbing, buttons): show that frame.
    func timeChanged() {
        if fromPlayer { return }
        if isGIF { Task { await refreshFrame() }; return }
        seekPlayer(time)
    }

    private func playerTick(_ t: Double) {
        guard t.isFinite else { return }
        if playing {
            // Loop the selection, skip the parts cut out, stop (or loop) at the end.
            if loop, let a = markIn, let b = markOut, b > a, t >= b - 0.02 { seekPlayer(a, force: true); return }
            if let c = activeCuts.first(where: { t >= $0.start && t < $0.end - 0.02 }), player.rate > 0 {
                seekPlayer(c.end, force: true); return
            }
            if player.rate > 0, t >= trimEnd - 0.02 {
                if loop { seekPlayer(trimStart, force: true) } else { pause(); fromPlayer = true; time = trimEnd; fromPlayer = false }
                return
            }
            if player.rate < 0, t <= trimStart + 0.02 { pause(); return }
        }
        fromPlayer = true
        time = t
        fromPlayer = false
    }

    func togglePlay() { playing ? pause() : play() }

    func play(rate: Double = 1) {
        guard player.currentItem != nil, !isGIF else { return }
        if rate > 0, isCutOut(time) || time >= trimEnd - 0.05 {
            let start = time >= trimEnd - 0.05 || time < trimStart ? trimStart : (activeCuts.first { time >= $0.start && time < $0.end }?.end ?? time)
            seekPlayer(start, force: true)
        }
        playing = true
        player.rate = Float(rate * speed)
        shuttle = rate
    }

    func pause() {
        player.pause()
        playing = false
        shuttle = 0
    }

    /// J: back (faster each press). K: pause. L: forward (faster each press).
    func shuttleBack() {
        let canReverse = player.currentItem?.canPlayReverse ?? false
        guard canReverse else { pause(); time = max(0, time - 2); return }
        play(rate: shuttle < 0 ? max(-8, shuttle * 2) : -1)
    }

    func shuttleForward() { play(rate: shuttle > 0 ? min(8, shuttle * 2) : 1) }

    func stepFrames(_ n: Int) {
        pause()
        time = min(max(0, time + Double(n) / max(1, fps)), duration)
    }

    func stepSeconds(_ s: Double) {
        pause()
        time = min(max(0, time + s), duration)
    }

    // MARK: Split, select, delete

    func markInHere() { markIn = time; if let o = markOut, o <= time { markOut = nil } }
    func markOutHere() { markOut = time; if let i = markIn, i >= time { markIn = nil } }
    func clearSelection() { markIn = nil; markOut = nil }
    var hasSelection: Bool { if let a = markIn, let b = markOut { return b - a > 0.05 } else { return false } }

    func splitHere() {
        guard time > trimStart + 0.05, time < trimEnd - 0.05, !splits.contains(where: { abs($0 - time) < 0.05 }) else { return }
        splits.append(time)
        splits.sort()
    }

    /// The part between splits (or trim ends) that contains t.
    func segment(at t: Double) -> (start: Double, end: Double) {
        let edges = ([trimStart] + splits.filter { $0 > trimStart && $0 < trimEnd } + [trimEnd]).sorted()
        for i in 0..<(edges.count - 1) where t >= edges[i] && t <= edges[i + 1] { return (edges[i], edges[i + 1]) }
        return (trimStart, trimEnd)
    }

    func selectSegment(at t: Double) {
        let s = segment(at: t)
        markIn = s.start
        markOut = s.end
    }

    /// Delete: cut the selected part out (the parts either side are joined).
    func cutSelection() {
        guard let a = markIn, let b = markOut, b > a else { return }
        if a <= trimStart + 0.05 && b >= trimEnd - 0.05 { status = "That's the whole video. Select a smaller part to cut out."; return }
        if a <= trimStart + 0.05 { trimStart = b }
        else if b >= trimEnd - 0.05 { trimEnd = a }
        else {
            var merged = CutRange(start: a, end: b)
            cuts.removeAll { c in
                if c.end >= merged.start && c.start <= merged.end {
                    merged = CutRange(start: min(c.start, merged.start), end: max(c.end, merged.end)); return true
                }
                return false
            }
            cuts.append(merged)
            cuts.sort { $0.start < $1.start }
        }
        time = min(b, trimEnd)
        clearSelection()
    }

    func keepOnlySelection() {
        guard let a = markIn, let b = markOut, b > a else { return }
        trimStart = a; trimEnd = b
        cuts.removeAll { $0.end <= a || $0.start >= b }
        clearSelection()
    }

    func blurDuringSelection() {
        guard let a = markIn, let b = markOut, b > a else { return }
        blurs.append(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        blurTimes[blurs.count - 1] = a...b
    }

    func textDuringSelection() {
        guard let a = markIn, let b = markOut, b > a else { return }
        var t = TextOverlay()
        t.range = a...b
        texts.append(t)
        selectedOverlay = t.id
    }

    // MARK: Overlays

    func addText(timed: Bool) {
        var t = TextOverlay()
        if timed { t.range = time...min(duration, time + 5) }
        texts.append(t)
        selectedOverlay = t.id
    }

    func addImage(timed: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .image]
        panel.message = "Choose a logo or picture. PNGs with a see-through background work best."
        guard panel.runModal() == .OK, let u = panel.url else { return }
        var o = ImageOverlay(url: u)
        if timed { o.range = time...min(duration, time + 5) }
        images.append(o)
        selectedOverlay = o.id
    }

    func removeOverlay(_ id: UUID) {
        texts.removeAll { $0.id == id }
        images.removeAll { $0.id == id }
        overlayArt[id] = nil
        if selectedOverlay == id { selectedOverlay = nil }
    }

    func rotate(by deg: Int) {
        rotation = ((rotation + deg) % 360 + 360) % 360
        updateRotatedSize()
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        applyAspect()
        rebuildComposition()
    }

    // MARK: Waveform

    func makeWaveform(_ asset: AVURLAsset) {
        waveform = []
        let forURL = url
        let total = duration
        Task.detached(priority: .utility) {
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let fd = try? await track.load(.formatDescriptions).first,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
                  let reader = try? AVAssetReader(asset: asset) else { return }
            // Plain 16-bit sound at the recording's own rate and channels: every format can be read like this.
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            out.alwaysCopiesSampleData = false
            guard reader.canAdd(out) else { return }
            reader.add(out)
            guard reader.startReading() else { return }
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            let rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44100
            let bins = 2000
            let expected = max(1.0, total * rate * Double(channels))
            let perBin = max(1, Int(expected / Double(bins)))
            var peaks: [Float] = []
            peaks.reserveCapacity(bins + 10)
            var current: Int32 = 0, count = 0
            var chunk: [Int16] = []
            while let buf = out.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buf) else { continue }
                let len = CMBlockBufferGetDataLength(block)
                guard len >= 2 else { continue }
                if chunk.count < len / 2 { chunk = [Int16](repeating: 0, count: len / 2) }
                let n = len / 2
                let ok = chunk.withUnsafeMutableBytes { p -> Bool in
                    guard let base = p.baseAddress else { return false }
                    return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 2, destination: base) == kCMBlockBufferNoErr
                }
                guard ok else { continue }
                for j in 0..<n {
                    current = max(current, abs(Int32(chunk[j])))
                    count += 1
                    if count >= perBin { peaks.append(Float(current) / 32768); current = 0; count = 0 }
                }
            }
            if count > 0 { peaks.append(Float(current) / 32768) }
            guard !peaks.isEmpty else { return }
            let top = peaks.max() ?? 1
            let norm = peaks.map { top > 0 ? $0 / top : 0 }
            await MainActor.run { [weak self] in
                guard let self, self.url == forURL else { return }
                self.waveform = norm
            }
        }
    }

    // MARK: Save a still

    func saveFrame() {
        guard let asset = playerAsset else { return }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.videoComposition = player.currentItem?.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let t = time, crop = self.pixelRect, cropped = isCropped
        let base = (url?.deletingPathExtension().lastPathComponent ?? "Frame") + " frame " + TimingBar.fmt(t).replacingOccurrences(of: ":", with: ".")
        Task {
            guard let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else {
                status = "Couldn't read that frame."; return
            }
            let pic = cropped ? (img.cropping(to: crop) ?? img) : img
            let panel = NSSavePanel()
            panel.nameFieldStringValue = base + ".png"
            panel.allowedContentTypes = [.png]
            guard panel.runModal() == .OK, let out = panel.url else { return }
            if OverlayArt.png(pic, to: out) {
                status = "Saved the frame as “\(out.lastPathComponent)”."
                savedFile = out
            } else { status = "Couldn't save the frame." }
        }
    }

    // MARK: Saving: the first pass

    var hasStageOneEffects: Bool {
        !texts.isEmpty || !images.isEmpty || !look.isDefault || rotation != 0 || flipH || flipV
            || fadeIn > 0 || fadeOut > 0 || !audioFX.isDefault
    }

    /// Needs a first pass on the original video: cuts, timed blurs, overlays, colour, rotation, fades or audio.
    var needsFirstPass: Bool { hasCuts || hasTimedBlurs || hasStageOneEffects }

    /// Runs a save. With anything that depends on the original timeline, a first pass on the original video
    /// joins the kept parts and burns in timed blurs, text, logos, colour, rotation, fades and audio changes;
    /// the save then runs on that copy (named after the original), and the editor is put back afterwards.
    /// `finalIfPlain`: for a plain video save with nothing else to change, the first pass is the result.
    func withFirstPass(finalIfPlain: Bool, _ save: @escaping () -> Void) {
        pause()
        guard needsFirstPass, let src = url, !busy else { save(); return }
        guard let ff = ReelTools.find("ffmpeg") else {
            status = "ffmpeg isn't installed yet. Open the Download tab once so Pare Studio can fetch it."
            return
        }
        let keeps = keepSegments
        guard !keeps.isEmpty else { status = "Everything is cut out. Remove a cut or move its edges."; return }
        let timed: [(rect: CGRect, range: ClosedRange<Double>)] = blurs.indices.compactMap { i in
            i < blurTimes.count ? blurTimes[i].map { (blurs[i], $0) } : nil
        }
        let wholeBlurs = blurs.indices.filter { i in i >= blurTimes.count || blurTimes[i] == nil }.map { blurs[$0] }
        let plain = finalIfPlain && !isCropped && wholeBlurs.isEmpty && abs(speed - 1) < 0.001 && outputHeight == 0
        let size = videoSize
        // Pictures for the text and logos, at their exact size.
        var art: [(file: URL, x: Int, y: Int, range: ClosedRange<Double>?)] = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PareStudioPass-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        refreshEffects()
        for a in effects.get().art {
            let f = dir.appendingPathComponent("art-\(art.count).png")
            guard OverlayArt.png(a.image, to: f) else { continue }
            let x = Int(a.center.x * size.width - CGFloat(a.image.width) / 2)
            let y = Int(a.center.y * size.height - CGFloat(a.image.height) / 2)
            art.append((f, x, y, a.range))
        }
        let rot = rotation, fh = flipH, fv = flipV, lk = look, fi = fadeIn, fo = fadeOut, au = audioFX
        busy = true
        savedFile = nil
        progress = nil
        status = hasCuts ? "Joining the parts you're keeping…" : "Applying your edits…"
        let started = Date()
        Task {
            let srcHasAudio = (try? await AVURLAsset(url: src).loadTracks(withMediaType: .audio).isEmpty == false) ?? false
            let hasAudio = srcHasAudio && !au.mute
            let pass = dir.appendingPathComponent(src.deletingPathExtension().lastPathComponent + ".mp4")
            func even(_ v: CGFloat) -> Int { Int((v / 2).rounded(.down) * 2) }
            // 1. Rotate, flip and colour.
            var pre: [String] = []
            switch rot {
            case 90: pre.append("transpose=1")
            case 180: pre.append("hflip,vflip")
            case 270: pre.append("transpose=2")
            default: break
            }
            if fh { pre.append("hflip") }
            if fv { pre.append("vflip") }
            if !lk.isDefault { pre.append(String(format: "eq=brightness=%.3f:contrast=%.3f:saturation=%.3f", lk.brightness, lk.contrast, lk.saturation)) }
            var f = "[0:v]" + (pre.isEmpty ? "null" : pre.joined(separator: ",")) + "[v0src]"
            var cur = "v0src"
            // 2. Timed blurs, on the original timeline.
            for (k, tb) in timed.enumerated() {
                let w = max(16, even(tb.rect.width * size.width)), h = max(16, even(tb.rect.height * size.height))
                let x = even(tb.rect.minX * size.width), y = even(tb.rect.minY * size.height)
                let r = max(1, min(min(w, h) / 2 - 1, 40)), rc = max(1, min(r, min(w, h) / 4 - 1))
                f += ";[\(cur)]split[tm\(k)][ts\(k)];[ts\(k)]crop=\(w):\(h):\(x):\(y),boxblur=luma_radius=\(r):luma_power=3:chroma_radius=\(rc):chroma_power=3[tb\(k)];"
                f += String(format: "[tm%d][tb%d]overlay=%d:%d:enable='between(t,%.3f,%.3f)'[tv%d]", k, k, x, y, tb.range.lowerBound, tb.range.upperBound, k)
                cur = "tv\(k)"
            }
            // 3. Text and logos.
            for (k, a) in art.enumerated() {
                let enable = a.range.map { String(format: ":enable='between(t,%.3f,%.3f)'", $0.lowerBound, $0.upperBound) } ?? ""
                f += ";[\(cur)][\(k + 1):v]overlay=\(a.x):\(a.y):format=auto\(enable)[ov\(k)]"
                cur = "ov\(k)"
            }
            // 4. The kept parts, joined.
            let n = keeps.count
            f += ";[\(cur)]split=\(n)" + (0..<n).map { "[vs\($0)]" }.joined()
            if hasAudio { f += ";[0:a]asplit=\(n)" + (0..<n).map { "[as\($0)]" }.joined() }
            for (i, k) in keeps.enumerated() {
                f += String(format: ";[vs%d]trim=start=%.3f:end=%.3f,setpts=PTS-STARTPTS[v%d]", i, k.start, k.end, i)
                if hasAudio { f += String(format: ";[as%d]atrim=start=%.3f:end=%.3f,asetpts=PTS-STARTPTS[a%d]", i, k.start, k.end, i) }
            }
            f += ";" + keeps.indices.map { hasAudio ? "[v\($0)][a\($0)]" : "[v\($0)]" }.joined()
            f += "concat=n=\(n):v=1:a=\(hasAudio ? 1 : 0)[vc]" + (hasAudio ? "[ac]" : "")
            // 5. Fades (on the finished timeline) and sound.
            let length = keeps.reduce(0) { $0 + ($1.end - $1.start) }
            var vf: [String] = []
            if fi > 0 { vf.append(String(format: "fade=t=in:st=0:d=%.2f", min(fi, length / 2))) }
            if fo > 0 { vf.append(String(format: "fade=t=out:st=%.3f:d=%.2f", max(0, length - fo), min(fo, length / 2))) }
            f += ";[vc]" + (vf.isEmpty ? "null" : vf.joined(separator: ",")) + "[v]"
            if hasAudio {
                var af: [String] = []
                if abs(au.volume - 1) > 0.001 { af.append(String(format: "volume=%.2f", au.volume)) }
                if au.denoise { af.append("afftdn=nf=-25") }
                if au.normalise { af.append("loudnorm=I=-16:TP=-1.5:LRA=11") }
                if au.fadeIn > 0 { af.append(String(format: "afade=t=in:st=0:d=%.2f", min(au.fadeIn, length / 2))) }
                if au.fadeOut > 0 { af.append(String(format: "afade=t=out:st=%.3f:d=%.2f", max(0, length - au.fadeOut), min(au.fadeOut, length / 2))) }
                f += ";[ac]" + (af.isEmpty ? "anull" : af.joined(separator: ",")) + "[a]"
            }
            var base = ["-y", "-loglevel", "error", "-i", src.path]
            for a in art { base += ["-i", a.file.path] }
            base += ["-filter_complex", f, "-map", "[v]"]
            if hasAudio { base += ["-map", "[a]", "-c:a", "aac", "-b:a", "192k", "-ar", "48000"] } else { base += ["-an"] }
            let tail = ["-movflags", "+faststart", pass.path]
            // Mac video hardware first; the software encoder if that fails.
            var (code, log) = await ReelTools.capture(ff.path, base + ["-c:v", "h264_videotoolbox", "-q:v", "70"] + tail)
            if code != 0 {
                (code, log) = await ReelTools.capture(ff.path, base + ["-c:v", "libx264", "-preset", "veryfast", "-crf", "18"] + tail)
            }
            guard code == 0, FileManager.default.fileExists(atPath: pass.path) else {
                busy = false
                status = "Couldn't prepare the video: \(log.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))"
                try? FileManager.default.removeItem(at: dir)
                return
            }
            if plain {
                // Nothing else to change: the first pass is the finished video.
                nameSource = src
                let out = outputURL(for: src, ext: "mp4")
                nameSource = nil
                do {
                    try FileManager.default.moveItem(at: pass, to: out)
                    savedFile = out
                    let mb = Double((try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value ?? 0) / 1_048_576
                    status = "Saved “\(out.lastPathComponent)” in \(Self.duration(Date().timeIntervalSince(started))) · \(String(format: "%.0f", mb)) MB."
                } catch {
                    status = "Couldn't save: \(error.localizedDescription)"
                }
                busy = false
                try? FileManager.default.removeItem(at: dir)
                return
            }
            // Run the chosen save on the prepared copy, then put the editor back as it was.
            let kept = editState
            let keptURL = url, keptDuration = duration, keptTime = time, keptSize = videoSize, keptRotated = rotated
            busy = false
            applyingUndo = true
            url = pass
            nameSource = src
            duration = length
            trimStart = 0; trimEnd = length
            cuts = []; splits = []
            blurs = wholeBlurs
            blurTimes = wholeBlurs.map { _ in nil }
            texts = []; images = []; look = Look(); rotation = 0; flipH = false; flipV = false
            fadeIn = 0; fadeOut = 0; audioFX = AudioFX()
            rotated = false
            videoSize = size
            applyingUndo = false
            save()
            while busy { try? await Task.sleep(nanoseconds: 250_000_000) }
            applyingUndo = true
            url = keptURL
            nameSource = nil
            duration = keptDuration
            rotated = keptRotated
            videoSize = keptSize
            applyingUndo = false
            apply(kept)
            time = keptTime
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

// MARK: - Transport (under the picture)

struct TransportBar: View {
    @ObservedObject var model: CropModel

    var body: some View {
        HStack(spacing: 8) {
            Group {
                Button { model.pause(); model.time = model.trimStart } label: { Image(systemName: "backward.end.fill") }
                    .help("Go to the start")
                Button { model.shuttleBack() } label: { Image(systemName: "backward.fill") }
                    .help("Play backwards; press again for faster (J)")
                Button { model.togglePlay() } label: {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.title2).frame(width: 30)
                }
                .help(model.playing ? "Pause (Space or K)" : "Play (Space or L)")
                Button { model.shuttleForward() } label: { Image(systemName: "forward.fill") }
                    .help("Play; press again for faster (L)")
                Button { model.pause(); model.time = model.trimEnd } label: { Image(systemName: "forward.end.fill") }
                    .help("Go to the end")
                Divider().frame(height: 16)
                Button { model.stepFrames(-1) } label: { Image(systemName: "backward.frame") }
                    .help("Back one frame (←)")
                Button { model.stepFrames(1) } label: { Image(systemName: "forward.frame") }
                    .help("Forward one frame (→)")
            }
            .buttonStyle(.borderless)
            .disabled(model.isGIF)
            Text(Self.clock(model.time)).font(.system(.body, design: .monospaced).weight(.semibold))
            Text("/ " + Self.clock(model.duration)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            if model.playing, abs(model.shuttle) > 1 || model.shuttle < 0 {
                Text(String(format: "%@%g×", model.shuttle < 0 ? "◀︎ " : "", abs(model.shuttle)))
                    .font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
            }
            Toggle(isOn: $model.loop) { Image(systemName: "repeat") }
                .toggleStyle(.button).help("Loop the selection, or the whole kept video")
            Spacer()
            Group {
                Button { model.markInHere() } label: { Text("I").font(.caption.weight(.bold)) + Text(" Mark in") }
                    .help("Start a selection at the playhead (I)")
                Button { model.markOutHere() } label: { Text("O").font(.caption.weight(.bold)) + Text(" Mark out") }
                    .help("End the selection at the playhead (O)")
                Button { model.splitHere() } label: { Label("Split", systemImage: "scissors") }
                    .help("Split the video at the playhead (S). Click a part to select it, then Delete to cut it out.")
            }
            .controlSize(.small)
            Divider().frame(height: 16)
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $model.zoom, in: 1...30).frame(width: 110).help("Zoom the timeline")
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .disabled(model.busy)
    }

    static func clock(_ s: Double) -> String {
        guard s.isFinite else { return "0:00.00" }
        let cs = Int((s * 100).rounded(.down))
        let h = cs / 360_000, m = (cs / 6000) % 60, sec = (cs / 100) % 60, c = cs % 100
        return h > 0 ? String(format: "%d:%02d:%02d.%02d", h, m, sec, c) : String(format: "%d:%02d.%02d", m, sec, c)
    }
}

/// Appears when part of the video is selected.
struct SelectionBar: View {
    @ObservedObject var model: CropModel
    var body: some View {
        if let a = model.markIn, let b = model.markOut, b > a {
            HStack(spacing: 10) {
                Image(systemName: "selection.pin.in.out").foregroundStyle(Color.accentColor)
                Text("Selected \(TimingBar.fmt(a))–\(TimingBar.fmt(b)) (\(String(format: "%.1f", b - a)) s)").monospacedDigit()
                Button { model.cutSelection() } label: { Label("Cut out", systemImage: "scissors") }
                    .help("Remove this part; the parts either side are joined (Delete)")
                Button("Keep only this") { model.keepOnlySelection() }
                Button { model.blurDuringSelection() } label: { Label("Blur during this", systemImage: "drop.halffull") }
                Button { model.textDuringSelection() } label: { Label("Text during this", systemImage: "textformat") }
                Spacer()
                Button { model.clearSelection() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("Clear the selection (Esc)")
            }
            .controlSize(.small)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
            .disabled(model.busy)
        } else if model.markIn != nil || model.markOut != nil {
            Text(model.markIn != nil ? "Mark in at \(TimingBar.fmt(model.markIn!)). Move the playhead and press O (Mark out)." :
                    "Mark out at \(TimingBar.fmt(model.markOut!)). Move the playhead back and press I (Mark in).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Keyboard shortcuts for the editor (off while typing in a text box).
struct EditorKeys: View {
    @ObservedObject var model: CropModel
    var body: some View {
        ZStack {
            Button("") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("") { model.shuttleBack() }.keyboardShortcut("j", modifiers: [])
            Button("") { model.pause() }.keyboardShortcut("k", modifiers: [])
            Button("") { model.shuttleForward() }.keyboardShortcut("l", modifiers: [])
            Button("") { model.stepFrames(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.stepFrames(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { model.stepSeconds(-1) }.keyboardShortcut(.leftArrow, modifiers: [.shift])
            Button("") { model.stepSeconds(1) }.keyboardShortcut(.rightArrow, modifiers: [.shift])
            Button("") { model.markInHere() }.keyboardShortcut("i", modifiers: [])
            Button("") { model.markOutHere() }.keyboardShortcut("o", modifiers: [])
            Button("") { model.splitHere() }.keyboardShortcut("s", modifiers: [])
            Button("") { model.cutSelection() }.keyboardShortcut(.delete, modifiers: [])
            Button("") { model.clearSelection() }.keyboardShortcut(.escape, modifiers: [])
            Button("") { model.pause(); model.time = model.trimStart }.keyboardShortcut(.home, modifiers: [])
            Button("") { model.pause(); model.time = model.trimEnd }.keyboardShortcut(.end, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .disabled(model.typing || model.busy || model.url == nil)
        .allowsHitTesting(false)
    }
}

// MARK: - Inspector (right-hand panel)

struct EditorInspector: View {
    @ObservedObject var model: CropModel
    @FocusState private var editingText: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                section("Crop", "crop") {
                    Picker("Shape", selection: $model.aspect) {
                        ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if model.isCropped { Button("Show the whole picture") { model.crop = CGRect(x: 0, y: 0, width: 1, height: 1) } }
                }
                section("Blur", "drop.halffull") {
                    HStack {
                        Button("Whole video") { model.addBlur() }
                        Button("From playhead") { model.addTimedBlur() }
                    }
                    Text(model.blurs.isEmpty ? "Hides a name, a face or an ID. Drag the box on the picture; its purple bar on the timeline says when it shows."
                                             : "\(model.blurs.count) blur\(model.blurs.count == 1 ? "" : "s"). Drag on the picture; drag the purple bar ends on the timeline.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                section("Text", "textformat") {
                    HStack {
                        Button("Whole video") { model.addText(timed: false) }
                        Button("From playhead") { model.addText(timed: true) }
                    }
                    ForEach($model.texts) { $t in
                        if model.selectedOverlay == t.id {
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("Text", text: $t.text, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .lineLimit(1...4)
                                    .focused($editingText)
                                Picker("Style", selection: $t.style) {
                                    ForEach(TextOverlay.Style.allCases) { Text($0.rawValue).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                HStack {
                                    Text("Size")
                                    Slider(value: $t.size, in: 0.025...0.16)
                                    Toggle("Bold", isOn: $t.bold).toggleStyle(.button).controlSize(.small)
                                }
                                HStack {
                                    ColorPicker("Text", selection: Binding(get: { t.colour.color }, set: { t.colour = RGBA($0) }))
                                    if t.style != .plain {
                                        ColorPicker("Background", selection: Binding(get: { t.background.color }, set: { t.background = RGBA($0) }), supportsOpacity: true)
                                    }
                                }
                                .font(.caption)
                                HStack {
                                    Text("Place").font(.caption)
                                    Button("Top") { t.center.y = 0.12 }
                                    Button("Middle") { t.center = CGPoint(x: 0.5, y: 0.5) }
                                    Button("Lower third") { t.center = CGPoint(x: 0.5, y: 0.78) }
                                    Button("Bottom") { t.center.y = 0.9 }
                                }
                                .controlSize(.mini)
                                HStack {
                                    Button(t.range == nil ? "Show for part of the time" : "Show for the whole video") {
                                        t.range = t.range == nil ? model.time...min(model.duration, model.time + 5) : nil
                                    }
                                    Spacer()
                                    Button(role: .destructive) { model.removeOverlay(t.id) } label: { Image(systemName: "trash") }
                                }
                                .controlSize(.small)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
                        } else {
                            Button { model.selectedOverlay = t.id } label: {
                                HStack {
                                    Image(systemName: "textformat").foregroundStyle(.teal)
                                    Text(t.text.isEmpty ? "(empty)" : t.text).lineLimit(1)
                                    Spacer()
                                    Text(t.range.map { "\(TimingBar.fmt($0.lowerBound))–\(TimingBar.fmt($0.upperBound))" } ?? "whole video")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                section("Logo or picture", "photo") {
                    HStack {
                        Button("Whole video…") { model.addImage(timed: false) }
                        Button("From playhead…") { model.addImage(timed: true) }
                    }
                    ForEach($model.images) { $o in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "photo").foregroundStyle(.orange)
                                Text(o.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button(role: .destructive) { model.removeOverlay(o.id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                            }
                            HStack { Text("Size").font(.caption); Slider(value: $o.width, in: 0.04...0.6) }
                            HStack { Text("See-through").font(.caption); Slider(value: $o.opacity, in: 0.1...1) }
                            HStack {
                                Button("↖") { o.center = CGPoint(x: 0.12, y: 0.12) }
                                Button("↗") { o.center = CGPoint(x: 0.88, y: 0.12) }
                                Button("↙") { o.center = CGPoint(x: 0.12, y: 0.88) }
                                Button("↘") { o.center = CGPoint(x: 0.88, y: 0.88) }
                                Button(o.range == nil ? "Part of the time" : "Whole video") {
                                    o.range = o.range == nil ? model.time...min(model.duration, model.time + 5) : nil
                                }
                            }
                            .controlSize(.mini)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(model.selectedOverlay == o.id ? 0.12 : 0.05)))
                        .onTapGesture { model.selectedOverlay = o.id }
                    }
                }
                section("Colour", "camera.filters") {
                    labelledSlider("Brightness", $model.look.brightness, -0.3...0.3)
                    labelledSlider("Contrast", $model.look.contrast, 0.5...1.5)
                    labelledSlider("Saturation", $model.look.saturation, 0...2)
                    if !model.look.isDefault { Button("Reset colour") { model.look = Look() }.controlSize(.small) }
                }
                section("Rotate & flip", "rotate.right") {
                    HStack {
                        Button { model.rotate(by: -90) } label: { Image(systemName: "rotate.left") }.help("Rotate left")
                        Button { model.rotate(by: 90) } label: { Image(systemName: "rotate.right") }.help("Rotate right")
                        Toggle(isOn: $model.flipH) { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                            .toggleStyle(.button).help("Flip left to right")
                        Toggle(isOn: $model.flipV) { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                            .toggleStyle(.button).help("Flip upside down")
                    }
                }
                section("Fade", "circle.lefthalf.filled") {
                    Picker("Fade in", selection: $model.fadeIn) { fadeChoices }
                    Picker("Fade out", selection: $model.fadeOut) { fadeChoices }
                    Text("Fades the picture from and to black.").font(.caption).foregroundStyle(.secondary)
                }
                section("Sound", "speaker.wave.2") {
                    Toggle("Mute (no sound)", isOn: $model.audioFX.mute)
                    if !model.audioFX.mute {
                        labelledSlider("Volume", $model.audioFX.volume, 0...2, percent: true)
                        Toggle("Even out the loudness", isOn: $model.audioFX.normalise)
                            .help("Brings the whole recording to a steady, standard loudness")
                        Toggle("Reduce background noise", isOn: $model.audioFX.denoise)
                            .help("Lowers hum and hiss")
                        Picker("Fade in", selection: $model.audioFX.fadeIn) { fadeChoices }
                        Picker("Fade out", selection: $model.audioFX.fadeOut) { fadeChoices }
                    }
                }
                section("Speed", "gauge.with.dots.needle.67percent") {
                    Picker("Speed", selection: $model.speed) {
                        Text("1×").tag(1.0); Text("1.25×").tag(1.25); Text("1.5×").tag(1.5)
                        Text("1.75×").tag(1.75); Text("2×").tag(2.0)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text("Voices keep their normal pitch. The preview plays at this speed.").font(.caption).foregroundStyle(.secondary)
                }
                section("Size", "arrow.up.left.and.arrow.down.right") {
                    Picker("Output", selection: $model.outputHeight) {
                        Text("Original").tag(0); Text("1080p").tag(1080); Text("720p").tag(720); Text("480p").tag(480)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
            }
            .padding(10)
        }
        .disabled(model.busy)
        .onChange(of: editingText) { _, v in model.typing = v }
    }

    @ViewBuilder private var fadeChoices: some View {
        Text("None").tag(0.0); Text("0.5 s").tag(0.5); Text("1 s").tag(1.0); Text("2 s").tag(2.0)
    }

    private func section<C: View>(_ title: String, _ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.callout.weight(.semibold))
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    private func labelledSlider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, percent: Bool = false) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 70, alignment: .leading)
            Slider(value: value, in: range)
            Text(percent ? "\(Int(value.wrappedValue * 100))%" : String(format: "%.2f", value.wrappedValue))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
        }
    }
}
