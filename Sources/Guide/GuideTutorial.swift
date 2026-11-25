// Tutorial — the narrated tutorial video.
// Built from the recorded screenshots: the camera eases in on each click, a cursor glides to it and
// clicks (with a click sound), the step appears as a caption, and the narrator reads each step.
// Starts and ends with the chosen intro and outro (designed card or your own clip).
// 1920×1080, 30 fps, H.264 + AAC. Everything is made on this Mac.

import AppKit
import AVFoundation
import VideoToolbox

enum TutorialVideo {
    static let W: CGFloat = 1920, H: CGFloat = 1080
    static let fps: Int32 = 30
    static let clickAt = 1.45          // seconds into a step when the click happens
    static let crossfade = 0.35

    // MARK: Plan

    struct StepShot {
        let image: CGImage
        let start: CGRect, zoom: CGRect      // camera, in image pixels (top-left origin)
        let from: CGPoint?, to: CGPoint?     // cursor path
        let highlight: CGRect?
        let clicks: Int                      // 0, 1 or 2 (double-click)
        let number: Int
        let text: String
    }

    enum Content {
        case card(intro: Bool)
        case step(StepShot)
        case note(number: Int, text: String)
        case clip(URL)
        case slide(CGImage)
    }

    struct Shot {
        var content: Content
        var duration: Double
        var narration: URL?
        var narrationStart = 0.5
        var clickTimes: [Double] = []
    }

    struct Look {
        var background = NSColor(hex: "#FAF7F4")
        var text = NSColor(hex: "#1E2326")
        var accent = NSColor(hex: "#B07058")
        var highlight = NSColor(hex: "#628034")
        var soft: NSColor { accent.blended(withFraction: 0.62, of: background) ?? accent }
        var wordmark = ""
        var tagline = ""
        var website = ""
        var logo: CGImage?
        var title = ""
        var subtitle = ""
        var outroLine = ""

        init() {}
        init(brand: Brand?, logo: CGImage?, guide: Guide) {
            if let b = brand {
                background = NSColor(hex: b.background); text = NSColor(hex: b.text)
                accent = NSColor(hex: b.accent); highlight = NSColor(hex: b.highlight)
                wordmark = b.wordmark; tagline = b.tagline; website = b.website
            }
            self.logo = logo
            title = guide.title.plain.trimmed.isEmpty ? "Tutorial" : guide.title.plain.trimmed
            subtitle = guide.summary.plain.trimmed.isEmpty ? tagline : guide.summary.plain.trimmed
            outroLine = tagline.isEmpty ? "Thanks for watching." : tagline
        }
    }

    // MARK: Make the video

    static func make(guide: Guide, to url: URL, progress: @escaping (String) -> Void) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("tutorial-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let (shots, look) = try await buildShots(guide: guide, work: work, progress: progress)

        // 3. Pictures → silent video.
        let silent = work.appendingPathComponent("silent.mp4")
        try await writeVideo(shots, look: look, to: silent, progress: progress)

        // 4. Sound: narration, clicks and any clip audio.
        progress("Adding the sound…")
        let click = work.appendingPathComponent("click.caf")
        try writeClickSound(to: click)
        try await mix(video: silent, shots: shots, click: click, to: url)
    }

    /// Plans every part of the video and records its narration (which sets how long each part lasts).
    static func buildShots(guide: Guide, work: URL, progress: @escaping (String) -> Void) async throws -> ([Shot], Look) {

        let (brand, logoURL, introFile, outroFile, jobs) = await MainActor.run { () -> (Brand?, URL?, URL?, URL?, [(Step, URL?)]) in
            let bs = BrandStore.shared
            let b = bs.brand(guide.brandID)
            return (b, bs.fileURL(b?.logo), bs.fileURL(b?.introFile), bs.fileURL(b?.outroFile),
                    guide.steps.map { s in (s, s.image.map { GuideStore.shared.imageURL(guide.id, $0) }) })
        }
        let look = Look(brand: brand, logo: logoURL.flatMap(GuideStore.loadImage), guide: guide)

        // 1. Pictures and camera moves.
        progress("Preparing the pictures…")
        let planned: [(Content, Step)] = await Task.detached(priority: .userInitiated) {
            TutorialVideo.plan(guide: guide, jobs: jobs)
        }.value

        // 2. Narration, which sets how long each part lasts.
        var shots: [Shot] = []
        let total = planned.count + (brand == nil ? 0 : 2)
        var spoken = 0
        func narrate(_ text: String?, _ name: String) async throws -> (URL, Double)? {
            guard let t = text?.trimmed, !t.isEmpty else { return nil }
            spoken += 1
            progress("Recording narration \(spoken) of \(total)… (\(Narrator.summary))")
            return try await Narrator.record(t, name: name, in: work)
        }

        // Intro: the built-in designed card, or your own slide or video.
        if let b = brand {
            if b.builtIn {
                let n = try await narrate(guide.introNarration ?? look.title, "intro")
                shots.append(Shot(content: .card(intro: true), duration: max(3.2, 0.6 + (n?.1 ?? 0) + 0.7),
                                  narration: n?.0, narrationStart: 0.6))
            } else if let f = introFile {
                if Brand.isImage(f.lastPathComponent), let img = GuideStore.loadImage(f) {
                    let n = try await narrate(guide.introNarration, "intro")
                    shots.append(Shot(content: .slide(img), duration: max(3.5, 0.6 + (n?.1 ?? 0) + 0.7),
                                      narration: n?.0, narrationStart: 0.6))
                } else {
                    shots.append(Shot(content: .clip(f), duration: try await clipDuration(f)))
                }
            }
        }
        var stepIndex = 0
        for (c, step) in planned {
            stepIndex += 1
            let custom = step.narration?.trimmed ?? ""
            let words = custom.isEmpty ? step.text.plain : custom
            let n = try await narrate(words, "step\(stepIndex)")
            var shot = Shot(content: c, duration: 0, narration: n?.0, narrationStart: 0.45)
            if case .step(let st) = c {
                shot.clickTimes = st.clicks == 2 ? [clickAt, clickAt + 0.14] : st.clicks == 1 ? [clickAt] : []
                shot.duration = max(3.4, 0.45 + (n?.1 ?? 0) + 0.75, clickAt + 1.2)
            } else {
                shot.duration = max(3.0, 0.45 + (n?.1 ?? 0) + 0.75)
            }
            shots.append(shot)
        }
        // Outro: the built-in designed card, or your own slide or video.
        if let b = brand {
            if b.builtIn {
                let n = try await narrate(guide.outroNarration, "outro")
                shots.append(Shot(content: .card(intro: false), duration: max(3.4, 0.5 + (n?.1 ?? 0) + 0.9),
                                  narration: n?.0, narrationStart: 0.5))
            } else if let f = outroFile {
                if Brand.isImage(f.lastPathComponent), let img = GuideStore.loadImage(f) {
                    let n = try await narrate(guide.outroNarration, "outro")
                    shots.append(Shot(content: .slide(img), duration: max(3.5, 0.5 + (n?.1 ?? 0) + 0.9),
                                      narration: n?.0, narrationStart: 0.5))
                } else {
                    shots.append(Shot(content: .clip(f), duration: try await clipDuration(f)))
                }
            }
        }
        guard !shots.isEmpty else { throw PGError("This guide has no steps with pictures yet.") }
        return (shots, look)
    }

    static func clipDuration(_ url: URL) async throws -> Double {
        let d = try await AVURLAsset(url: url).load(.duration).seconds
        guard d.isFinite, d > 0 else { throw PGError("Couldn't read the intro/outro clip \(url.lastPathComponent).") }
        return min(d, 30)
    }

    /// Works out the pictures and camera moves for every step.
    static func plan(guide: Guide, jobs: [(Step, URL?)]) -> [(Content, Step)] {
        var out: [(Content, Step)] = []
        var prev: (CGPoint, CGSize)?
        var number = 0
        for (step, url) in jobs {
            if step.kind == .note && url == nil {
                number += 1
                out.append((.note(number: number, text: step.text), step))
                continue
            }
            guard let url, let base = GuideStore.loadImage(url) else { continue }
            number += 1
            // Blurs applied; our own cursor and highlight are drawn in the video instead of the static marker.
            var clean = step
            clean.showHighlight = false
            clean.crop = nil
            clean.zoomOverride = nil
            guard let img = Renderer.render(clean, base: base, zoom: .off, maxWidth: 2880) else { continue }
            let f = CGFloat(img.width) / CGFloat(base.width)
            let size = CGSize(width: img.width, height: img.height)
            func sc(_ r: CGRect) -> CGRect { CGRect(x: r.minX * f, y: r.minY * f, width: r.width * f, height: r.height * f) }

            let full = fit16x9(around: CGRect(origin: .zero, size: size))
            var zoomRect = full
            let z: Zoom = step.zoomOverride ?? guide.zoom
            if let c = step.crop { zoomRect = fit16x9(around: sc(c), within: size) }
            else if let r = Renderer.autoZoom(step, zoom: z, size: CGSize(width: base.width, height: base.height)) {
                zoomRect = fit16x9(around: sc(r), within: size)
            }
            let to = step.clickPoint.map { CGPoint(x: $0.x * f, y: $0.y * f) }
            var from: CGPoint?
            if let to {
                if let pr = prev { from = CGPoint(x: pr.0.x / pr.1.width * size.width, y: pr.0.y / pr.1.height * size.height) }
                else { from = CGPoint(x: zoomRect.midX + zoomRect.width * 0.18, y: zoomRect.midY + zoomRect.height * 0.22) }
                prev = (to, size)
            }
            let start = lerp(full, zoomRect, 0.4)
            let clicks: Int
            switch step.kind {
            case .click, .rightClick: clicks = to == nil ? 0 : 1
            case .doubleClick: clicks = to == nil ? 0 : 2
            case .type: clicks = to == nil ? 0 : 1
            case .shortcut, .note: clicks = 0
            }
            out.append((.step(StepShot(image: img, start: start, zoom: zoomRect, from: from, to: to,
                                       highlight: step.showHighlight ? step.highlight.map(sc) : nil,
                                       clicks: clicks, number: number, text: step.text)), step))
        }
        return out
    }

    /// The smallest 16:9 rectangle around `r` (kept inside `within` when it fits).
    static func fit16x9(around r: CGRect, within: CGSize? = nil) -> CGRect {
        var w = r.width, h = r.height
        if w / max(h, 1) < 16.0 / 9.0 { w = h * 16 / 9 } else { h = w * 9 / 16 }
        var x = r.midX - w / 2, y = r.midY - h / 2
        if let s = within {
            if w <= s.width { x = min(max(0, x), s.width - w) } else { x = (s.width - w) / 2 }
            if h <= s.height { y = min(max(0, y), s.height - h) } else { y = (s.height - h) / 2 }
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }
    static func ease(_ t: Double) -> CGFloat { let x = max(0, min(1, t)); return CGFloat(x * x * (3 - 2 * x)) }
    static func seg(_ t: Double, _ a: Double, _ b: Double) -> CGFloat { ease((t - a) / (b - a)) }

    // MARK: Video frames

    /// `fades`: crossfade between parts and fade in/out at the ends (off for Camtasia clips, where you add your own transitions).
    static func writeVideo(_ shots: [Shot], look: Look, to url: URL, fades: Bool = true,
                           progress: @escaping (String) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(W), AVVideoHeightKey: Int(H),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(W), kCVPixelBufferHeightKey as String: Int(H),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? PGError("Couldn't start the video.") }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = shots.reduce(0) { $0 + frames($1.duration) }
        var frameIndex: Int64 = 0
        var last: CGImage?
        for (si, shot) in shots.enumerated() {
            let n = frames(shot.duration)
            var clip: ClipReader?
            if case .clip(let u) = shot.content { clip = try? ClipReader(url: u) }
            // Frames are drawn on every processor core at once, then added to the video in order.
            // (Intro/outro video clips are read in order, so those frames are drawn one at a time.)
            let batch = clip == nil ? max(2, ProcessInfo.processInfo.activeProcessorCount) : 1
            var fi = 0
            while fi < n {
                let range = fi..<min(fi + batch, n)
                var bufs: [CVPixelBuffer] = []
                for _ in range {
                    guard let pb = buffer(adaptor.pixelBufferPool) else { throw PGError("Out of memory making the video.") }
                    bufs.append(pb)
                }
                let previous = last
                let frameBuffers = bufs
                let clipReader = clip
                let endImage = ImageBox()
                let isLastShot = si == shots.count - 1
                let drawOne: (Int) -> Void = { k in
                    let f = range.lowerBound + k
                    let t = Double(f) / Double(fps)
                    let pb = frameBuffers[k]
                    CVPixelBufferLockBaseAddress(pb, [])
                    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
                    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(W), height: Int(H),
                                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                    else { return }
                    ctx.interpolationQuality = .high
                    draw(shot, t: t, look: look, clip: clipReader, in: ctx)
                    // Crossfade from the end of the last part, or fade in/out at the very start and end.
                    if fades, si > 0, t < crossfade, let previous {
                        ctx.saveGState()
                        ctx.setAlpha(1 - seg(t, 0, crossfade))
                        ctx.draw(previous, in: CGRect(x: 0, y: 0, width: W, height: H))
                        ctx.restoreGState()
                    }
                    if fades, si == 0, t < 0.5 { fill(ctx, .white, alpha: 1 - seg(t, 0, 0.5)) }
                    if fades, isLastShot, t > shot.duration - 0.5 { fill(ctx, .white, alpha: seg(t, shot.duration - 0.5, shot.duration)) }
                    if f == n - 1 { endImage.set(ctx.makeImage()) }
                }
                if bufs.count > 1 {
                    DispatchQueue.concurrentPerform(iterations: bufs.count, execute: drawOne)
                } else {
                    drawOne(0)
                }
                if let img = endImage.get() { last = img }
                for pb in bufs {
                    while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                    adaptor.append(pb, withPresentationTime: CMTime(value: frameIndex, timescale: fps))
                    frameIndex += 1
                    if frameIndex % 60 == 0 {
                        progress("Building the video… \(Int(Double(frameIndex) / Double(max(1, totalFrames)) * 100))%")
                    }
                }
                fi = range.upperBound
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: frameIndex, timescale: fps))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? PGError("Couldn't finish the video.") }
    }

    static func frames(_ seconds: Double) -> Int { max(1, Int((seconds * Double(fps)).rounded())) }

    private static func buffer(_ pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
        if pb == nil { CVPixelBufferCreate(nil, Int(W), Int(H), kCVPixelFormatType_32BGRA, nil, &pb) }
        return pb
    }

    private static func fill(_ ctx: CGContext, _ c: NSColor, alpha: CGFloat) {
        guard alpha > 0 else { return }
        ctx.setFillColor(c.withAlphaComponent(alpha).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    }

    static func draw(_ shot: Shot, t: Double, look: Look, clip: ClipReader?, in ctx: CGContext) {
        switch shot.content {
        case .card(let intro):
            drawCard(intro: intro, look: look, t: t, in: ctx)
        case .note(let number, let text):
            fill(ctx, look.background, alpha: 1)
            text2(ctx, text.plain, font: .systemFont(ofSize: 56, weight: .semibold), color: look.text,
                  rect: CGRect(x: 240, y: 380, width: W - 480, height: 320), align: .center)
            badge(ctx, number, center: CGPoint(x: W / 2, y: 760), radius: 34, look: look)
        case .slide(let img):
            fill(ctx, .black, alpha: 1)
            let s = min(W / CGFloat(img.width), H / CGFloat(img.height))
            let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
            ctx.draw(img, in: CGRect(x: (W - w) / 2, y: (H - h) / 2, width: w, height: h))
        case .clip:
            fill(ctx, .black, alpha: 1)
            if let img = clip?.frame(at: t) {
                let s = min(W / CGFloat(img.width), H / CGFloat(img.height))
                let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
                ctx.draw(img, in: CGRect(x: (W - w) / 2, y: (H - h) / 2, width: w, height: h))
            }
        case .step(let st):
            drawStep(st, shot: shot, t: t, look: look, in: ctx)
        }
    }

    private static func drawStep(_ st: StepShot, shot: Shot, t: Double, look: Look, in ctx: CGContext) {
        // Camera: ease in towards the click, then a slow push for the rest of the step.
        var cam = lerp(st.start, st.zoom, seg(t, 0.1, 1.2))
        let push = 0.03 * seg(t, 1.2, max(1.3, shot.duration))
        cam = cam.insetBy(dx: cam.width * push / 2, dy: cam.height * push / 2)
        let k = W / cam.width
        fill(ctx, NSColor(white: 0.1, alpha: 1), alpha: 1)
        let iw = CGFloat(st.image.width), ih = CGFloat(st.image.height)
        ctx.draw(st.image, in: CGRect(x: -cam.minX * k, y: -(ih - cam.maxY) * k, width: iw * k, height: ih * k))
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - cam.minX) * k, y: H - (p.y - cam.minY) * k) }

        // Highlight box after the click.
        if let h = st.highlight, let first = shot.clickTimes.first, t > first {
            let a = seg(t, first, first + 0.3)
            let o = map(CGPoint(x: h.minX, y: h.minY)), e = map(CGPoint(x: h.maxX, y: h.maxY))
            let r = CGRect(x: o.x, y: e.y, width: e.x - o.x, height: o.y - e.y).insetBy(dx: -8, dy: -8)
            let cr = max(0, min(10, r.width / 2 - 0.5, r.height / 2 - 0.5))
            let path = CGPath(roundedRect: r, cornerWidth: cr, cornerHeight: cr, transform: nil)
            ctx.setFillColor(look.accent.withAlphaComponent(0.12 * a).cgColor)
            ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(look.accent.withAlphaComponent(a).cgColor)
            ctx.setLineWidth(4)
            ctx.addPath(path); ctx.strokePath()
        }

        // Cursor glides to the target, then clicks.
        if let to = st.to {
            let from = st.from ?? to
            let m = seg(t, 0.35, clickAt - 0.1)
            let p = CGPoint(x: from.x + (to.x - from.x) * m, y: from.y + (to.y - from.y) * m)
            let sp = map(p)
            for c in shot.clickTimes { ripple(ctx, at: sp, k: (t - c) / 0.5, look: look) }
            cursor(ctx, at: sp, pressed: shot.clickTimes.contains { t >= $0 && t < $0 + 0.12 })
        }

        // Where the click lands once the camera has settled, so Auto can keep the caption off it.
        var clickY: CGFloat?
        if let to = st.to {
            let kz = W / st.zoom.width
            clickY = H - (to.y - st.zoom.minY) * kz
        }
        caption(ctx, number: st.number, text: st.text, alpha: seg(t, 0.2, 0.55), look: look, clickY: clickY)
    }

    // MARK: Pieces

    private static func cursor(_ ctx: CGContext, at p: CGPoint, pressed: Bool) {
        let s: CGFloat = pressed ? 1.25 : 1.4
        let pts: [CGPoint] = [(0, 0), (0, 26), (7, 20), (12, 31), (17, 29), (12, 18), (21, 18)]
            .map { CGPoint(x: p.x + CGFloat($0.0) * s, y: p.y - CGFloat($0.1) * s) }
        let path = CGMutablePath()
        path.addLines(between: pts)
        path.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 1, height: -3), blur: 6, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor(white: 0.08, alpha: 1).cgColor)
        ctx.setLineWidth(2.4)
        ctx.setLineJoin(.round)
        ctx.addPath(path); ctx.strokePath()
    }

    private static func ripple(_ ctx: CGContext, at p: CGPoint, k: Double, look: Look) {
        guard k >= 0, k <= 1 else { return }
        let r = 14 + 46 * CGFloat(k), a = CGFloat(1 - k)
        ctx.setStrokeColor(look.accent.withAlphaComponent(0.85 * a).cgColor)
        ctx.setLineWidth(5)
        ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ctx.setFillColor(look.soft.withAlphaComponent(0.7 * a).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - r / 2, y: p.y - r / 2, width: r, height: r))
    }

    private static func badge(_ ctx: CGContext, _ n: Int, center c: CGPoint, radius r: CGFloat, look: Look) {
        ctx.setFillColor(look.soft.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        text2(ctx, "\(n)", font: .systemFont(ofSize: r * 0.95, weight: .bold), color: look.text,
              rect: CGRect(x: c.x - r, y: c.y - r * 0.62, width: r * 2, height: r * 1.3), align: .center)
    }

    private static func caption(_ ctx: CGContext, number: Int, text: String, alpha: CGFloat, look: Look, clickY: CGFloat? = nil) {
        let style = CaptionStyle.current
        guard style.on, alpha > 0 else { return }
        let shown = style.short ? CaptionStyle.shorten(text) : text
        let (fontSize, r, maxW): (CGFloat, CGFloat, CGFloat) =
            style.size == 0 ? (26, 17, 1100) : style.size == 2 ? (38, 24, 1480) : (32, 21, 1300)
        let str = NSMutableAttributedString()
        for part in shown.boldParts {
            str.append(NSAttributedString(string: part.text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: part.bold ? .bold : .medium),
                .foregroundColor: NSColor.white]))
        }
        let oneLine = ceil(fontSize * 1.25)
        let b = str.boundingRect(with: CGSize(width: maxW, height: 400), options: [.usesLineFragmentOrigin])
        let tw = min(maxW, ceil(b.width))
        let th = style.short ? oneLine : min(oneLine * 2, ceil(b.height))
        let padX = r * 1.5, gap = r * 2.9
        let pw = tw + padX + gap + padX, ph = max(r * 3.4, th + fontSize * 0.95)
        let margin: CGFloat = style.size == 0 ? 36 : 48
        // Auto: go to the top when the click would be under (or just above) the caption.
        var top = style.position == "top"
        if style.position == "auto", let y = clickY, y < margin + ph + 90 { top = true }
        let rise = (1 - alpha) * 18
        let y = top ? H - margin - ph + rise : margin - rise
        let pill = CGRect(x: (W - pw) / 2, y: y, width: pw, height: ph)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setFillColor(look.text.withAlphaComponent(0.9).cgColor)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: min(42, ph / 2), cornerHeight: min(42, ph / 2), transform: nil))
        ctx.fillPath()
        badge(ctx, number, center: CGPoint(x: pill.minX + padX + r, y: pill.midY), radius: r, look: look)
        withNS(ctx) { str.draw(with: CGRect(x: pill.minX + padX + gap, y: pill.midY - th / 2, width: tw, height: th),
                               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]) }
        ctx.restoreGState()
    }

    /// The designed intro or outro card.
    static func drawCard(intro: Bool, look: Look, t: Double, in ctx: CGContext) {
        fill(ctx, look.background, alpha: 1)
        let rise = (1 - seg(t, 0.05, 0.7)) * 22
        // Logo or wordmark, then a short accent bar.
        var y: CGFloat = H - 250 + rise
        if let logo = look.logo {
            let k = min(560 / CGFloat(logo.width), 120 / CGFloat(logo.height))
            let w = CGFloat(logo.width) * k, h = CGFloat(logo.height) * k
            ctx.draw(logo, in: CGRect(x: (W - w) / 2, y: y - h / 2, width: w, height: h))
            y -= 100
        } else if !look.wordmark.isEmpty {
            text2(ctx, look.wordmark, font: .systemFont(ofSize: 50, weight: .bold), color: look.text,
                  rect: CGRect(x: 0, y: y - 34, width: W, height: 70), align: .center)
            y -= 64
        }
        ctx.setFillColor(look.accent.cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: W / 2 - 40, y: y, width: 80, height: 6), cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.fillPath()
        let main = intro ? look.title : look.outroLine
        let sub = intro ? look.subtitle : (look.website.isEmpty ? "" : look.website)
        text2(ctx, main, font: .systemFont(ofSize: intro ? 84 : 76, weight: .bold), color: look.text,
              rect: CGRect(x: 160, y: H / 2 - 150 + rise, width: W - 320, height: 230), align: .center, vCenter: true)
        if !sub.isEmpty {
            text2(ctx, sub, font: .systemFont(ofSize: 40, weight: .semibold), color: look.highlight,
                  rect: CGRect(x: 160, y: H / 2 - 250 + rise, width: W - 320, height: 90), align: .center)
        }
        if intro, !look.website.isEmpty {
            text2(ctx, look.website, font: .systemFont(ofSize: 28, weight: .medium), color: look.text.withAlphaComponent(0.55),
                  rect: CGRect(x: 0, y: 70, width: W, height: 44), align: .center)
        }
    }

    /// A still of the intro or outro, for the preview in Settings.
    static func cardPreview(brand: Brand?, logo: CGImage?, intro: Bool, title: String, size: CGSize) -> CGImage? {
        var g = Guide(title: title)
        g.summary = ""
        let look = Look(brand: brand, logo: logo, guide: g)
        guard let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        drawCard(intro: intro, look: look, t: 2, in: ctx)
        return ctx.makeImage().flatMap { Renderer.scaled($0, width: Int(size.width)) }
    }

    private static func withNS(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func text2(_ ctx: CGContext, _ s: String, font: NSFont, color: NSColor, rect: CGRect,
                              align: NSTextAlignment, vCenter: Bool = false) {
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = .byWordWrapping
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
        var r = rect
        if vCenter {
            let b = a.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin])
            let h = min(rect.height, ceil(b.height))
            r = CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
        }
        withNS(ctx) { a.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]) }
    }

    // MARK: Sound

    /// A soft mouse click: a press and a release a moment later.
    static func writeClickSound(to url: URL) throws {
        let sr = 48_000.0
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sr * 0.14)) else { return }
        buf.frameLength = buf.frameCapacity
        let d = buf.floatChannelData![0]
        var seed: UInt32 = 7
        func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) * 2 - 1 }
        for i in 0..<Int(buf.frameLength) { d[i] = 0 }
        for (start, gain, freq) in [(0.0, Float(0.30), 3200.0), (0.075, Float(0.19), 4100.0)] {
            let s0 = Int(start * sr), n = Int(0.012 * sr)
            for j in 0..<n where s0 + j < Int(buf.frameLength) {
                let tt = Double(j) / sr
                let env = Float(exp(-tt * 700))
                d[s0 + j] += gain * env * (0.55 * noise() + 0.8 * Float(sin(2 * .pi * freq * tt)))
            }
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        try file.write(from: buf)
    }

    static func mix(video: URL, shots: [Shot], click: URL, to url: URL) async throws {
        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: video)
        guard let vSrc = try await vAsset.loadTracks(withMediaType: .video).first,
              let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw PGError("Couldn't build the video.") }
        let vDur = try await vAsset.load(.duration)
        try vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vSrc, at: .zero)

        let voice = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let clicks = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let extra = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let clickAsset = AVURLAsset(url: click)
        let clickSrc = try await clickAsset.loadTracks(withMediaType: .audio).first
        let clickDur = try await clickAsset.load(.duration)

        var t = 0.0
        for shot in shots {
            defer { t += Double(frames(shot.duration)) / Double(fps) }
            func at(_ s: Double) -> CMTime { CMTime(seconds: t + s, preferredTimescale: 48_000) }
            if let n = shot.narration {
                let a = AVURLAsset(url: n)
                if let src = try await a.loadTracks(withMediaType: .audio).first {
                    let d = try await a.load(.duration)
                    try? voice?.insertTimeRange(CMTimeRange(start: .zero, duration: d), of: src, at: at(shot.narrationStart))
                }
            }
            if let clickSrc {
                for c in shot.clickTimes {
                    try? clicks?.insertTimeRange(CMTimeRange(start: .zero, duration: clickDur), of: clickSrc, at: at(c))
                }
            }
            if case .clip(let u) = shot.content {
                let a = AVURLAsset(url: u)
                if let src = try await a.loadTracks(withMediaType: .audio).first {
                    let clipLen = try await a.load(.duration).seconds
                    let d = min(clipLen, shot.duration)
                    try? extra?.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: d, preferredTimescale: 48_000)),
                                                of: src, at: at(0))
                }
            }
        }
        for track in [voice, clicks, extra].compactMap({ $0 }) where track.segments.isEmpty {
            comp.removeTrack(track)
        }
        // Clicks a little quieter than the voice.
        let mixParams = AVMutableAudioMix()
        if let clicks, !clicks.segments.isEmpty {
            let p = AVMutableAudioMixInputParameters(track: clicks)
            p.setVolume(0.55, at: .zero)
            mixParams.inputParameters = [p]
        }
        try? FileManager.default.removeItem(at: url)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw PGError("Couldn't export the video.")
        }
        export.outputURL = url
        export.outputFileType = .mp4
        export.audioMix = mixParams
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        if export.status != .completed {
            throw PGError(export.error?.localizedDescription ?? "Couldn't export the video.")
        }
    }
}

// MARK: - Reading frames from an intro/outro clip

/// Holds one image handed back from a frame drawn on another core.
final class ImageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CGImage?
    func set(_ i: CGImage?) { lock.withLock { image = i } }
    func get() -> CGImage? { lock.withLock { image } }
}

final class ClipReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var current: CGImage?
    private var nextSample: CMSampleBuffer?
    private var done = false

    init(url: URL) throws {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { throw PGError("That clip has no picture.") }
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        nextSample = output.copyNextSampleBuffer()
    }

    /// The clip's picture at `t` seconds (holds the last frame after the clip ends).
    func frame(at t: Double) -> CGImage? {
        while !done, let s = nextSample, CMSampleBufferGetPresentationTimeStamp(s).seconds <= t + 0.001 {
            if let pb = CMSampleBufferGetImageBuffer(s) {
                var img: CGImage?
                VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &img)
                if let img { current = img }
            }
            nextSample = output.copyNextSampleBuffer()
            if nextSample == nil { done = true }
        }
        return current
    }
}


/// How step captions look in tutorial videos (chosen in Export › Captions).
struct CaptionStyle {
    var on = true
    var size = 1            // 0 Small, 1 Medium, 2 Large
    var position = "auto"   // auto, bottom, top
    var short = false

    static var current: CaptionStyle {
        let d = UserDefaults.standard
        var c = CaptionStyle()
        if d.object(forKey: "captionsOn") != nil { c.on = d.bool(forKey: "captionsOn") }
        if d.object(forKey: "captionSize") != nil { c.size = d.integer(forKey: "captionSize") }
        c.position = d.string(forKey: "captionPosition") ?? "auto"
        c.short = d.bool(forKey: "captionShort")
        return c
    }

    /// "Next choose a level, then click **Compress PDF**" → "Click **Compress PDF**".
    static func shorten(_ text: String) -> String {
        let t = text.trimmed
        var parts: [String] = [t]
        for sep in [". ", "; ", ", ", " and then ", " then ", " and "] {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        parts = parts.map { $0.trimmed }.filter { !$0.isEmpty }
        // Don't split inside a **bold** name like "**Save and Close**".
        guard parts.count > 1, !parts.contains(where: { $0.components(separatedBy: "**").count % 2 == 0 }) else { return t }
        var pick = parts.last(where: { $0.contains("**") }) ?? parts[0]
        for lead in ["and ", "then ", "next ", "now ", "finally "] {
            while pick.lowercased().hasPrefix(lead) { pick = String(pick.dropFirst(lead.count)).trimmed }
        }
        if pick.hasSuffix(".") { pick.removeLast() }
        guard let f = pick.first else { return t }
        return f.uppercased() + pick.dropFirst()
    }
}
