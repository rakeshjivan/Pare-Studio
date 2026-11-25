// Render — turns a step's original screenshot into the finished picture:
// blurred areas, the highlight box and click marker, then the crop or automatic zoom.
// Also: finding private details (emails, phone and card numbers) to blur automatically.

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

enum Renderer {
    private static let ci = CIContext(options: [.cacheIntermediates: false])
    static let accent = CGColor(red: 1.0, green: 0.33, blue: 0.24, alpha: 1)

    /// The finished step picture. `maxWidth` shrinks large screenshots for export.
    static func render(_ step: Step, base: CGImage, zoom: Zoom, maxWidth: Int? = nil) -> CGImage? {
        let W = CGFloat(base.width), H = CGFloat(base.height)
        let full = CGRect(x: 0, y: 0, width: W, height: H)

        // 1. Blur (pixelate + soften so the text can't be read back).
        var image: CGImage = base
        if !step.blurs.isEmpty {
            var c = CIImage(cgImage: base)
            for b in step.blurs {
                let r = CGRect(x: b.minX, y: H - b.maxY, width: b.width, height: b.height).integral.intersection(full)
                guard !r.isNull, r.width > 1, r.height > 1 else { continue }
                let s = max(12, min(r.width, r.height) / 3)
                let px = c.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: ["inputScale": s, "inputCenter": CIVector(x: r.minX, y: r.minY)])
                    .applyingGaussianBlur(sigma: Double(s) / 2)
                    .cropped(to: r)
                c = px.composited(over: c)
            }
            if let out = ci.createCGImage(c, from: full) { image = out }
        }

        // 2. Highlight box and click marker.
        guard let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: full)
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)   // now top-left origin, same as the stored coordinates
        let u = CGFloat(step.scale)

        if step.showHighlight {
            if let h = step.highlight {
                let r = h.insetBy(dx: -4 * u, dy: -4 * u)
                let path = CGPath(roundedRect: r, cornerWidth: 6 * u, cornerHeight: 6 * u, transform: nil)
                ctx.setFillColor(accent.copy(alpha: 0.12)!)
                ctx.addPath(path); ctx.fillPath()
                ctx.setStrokeColor(accent)
                ctx.setLineWidth(3 * u)
                ctx.addPath(path); ctx.strokePath()
            }
            if let p = step.clickPoint {
                let rad = 11 * u
                let dot = CGRect(x: p.x - rad, y: p.y - rad, width: rad * 2, height: rad * 2)
                ctx.setFillColor(accent.copy(alpha: 0.35)!)
                ctx.fillEllipse(in: dot)
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
                ctx.setLineWidth(2.5 * u)
                ctx.strokeEllipse(in: dot)
                ctx.setFillColor(accent)
                ctx.fillEllipse(in: dot.insetBy(dx: rad * 0.6, dy: rad * 0.6))
            }
        }
        // Drawings: arrows, boxes, circles, labels, numbers.
        for m in step.marks { drawAnnotation(m, in: ctx, unit: u) }
        guard var out = ctx.makeImage() else { return nil }

        // 3. Crop, or zoom in around the click.
        if let c = step.crop ?? autoZoom(step, zoom: step.zoomOverride ?? zoom, size: CGSize(width: W, height: H)) {
            let r = c.integral.intersection(full)
            if !r.isNull, r.width > 10, r.height > 10, let cropped = out.cropping(to: r) { out = cropped }
        }
        if let m = maxWidth, out.width > m { return scaled(out, width: m) ?? out }
        return out
    }

    /// The part of the screenshot the finished picture shows (its crop or automatic zoom), in pixels.
    static func outputFrame(_ step: Step, zoom: Zoom, size: CGSize) -> CGRect {
        let full = CGRect(origin: .zero, size: size)
        if let c = step.crop ?? autoZoom(step, zoom: step.zoomOverride ?? zoom, size: size) {
            let r = c.integral.intersection(full)
            if !r.isNull, r.width > 10, r.height > 10 { return r }
        }
        return full
    }

    // MARK: Drawings

    /// Line width, arrow-head size and text size for a drawing, in pixels.
    static func metrics(_ m: Annotation, unit u: CGFloat) -> (line: CGFloat, head: CGFloat, font: CGFloat) {
        let k = CGFloat(m.size) * u
        return (4 * k, 18 * k, 16 * k)
    }

    static func labelText(_ m: Annotation, unit u: CGFloat) -> NSAttributedString {
        let f = metrics(m, unit: u).font
        let text = m.kind == .number ? (m.text.isEmpty ? "1" : m.text) : (m.text.isEmpty ? " " : m.text)
        let colour: NSColor = m.colour.onColourIsDark ? .black : .white
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: m.kind == .number ? f * 1.05 : f, weight: .semibold),
            .foregroundColor: colour,
        ])
    }

    /// The area a drawing covers, for clicking on it in the editor.
    static func bounds(_ m: Annotation, unit u: CGFloat) -> CGRect {
        let mt = metrics(m, unit: u)
        switch m.kind {
        case .arrow:
            return CGRect(x: min(m.a.x, m.b.x), y: min(m.a.y, m.b.y), width: abs(m.a.x - m.b.x), height: abs(m.a.y - m.b.y))
                .insetBy(dx: -mt.head, dy: -mt.head)
        case .box, .circle:
            return CGRect(x: min(m.a.x, m.b.x), y: min(m.a.y, m.b.y), width: abs(m.a.x - m.b.x), height: abs(m.a.y - m.b.y))
                .insetBy(dx: -mt.line * 2, dy: -mt.line * 2)
        case .text:
            let size = labelText(m, unit: u).boundingRect(with: CGSize(width: 420 * u, height: .greatestFiniteMagnitude),
                                                          options: [.usesLineFragmentOrigin, .usesFontLeading]).size
            let pad = mt.font * 0.55
            return CGRect(x: m.a.x, y: m.a.y, width: ceil(size.width) + pad * 2, height: ceil(size.height) + pad * 1.4)
        case .number:
            let r = mt.font * 1.15
            return CGRect(x: m.a.x - r, y: m.a.y - r, width: r * 2, height: r * 2)
        }
    }

    /// Draws one annotation. `ctx` uses top-left coordinates.
    static func drawAnnotation(_ m: Annotation, in ctx: CGContext, unit u: CGFloat) {
        let mt = metrics(m, unit: u)
        let colour = m.colour.cg
        let outline = CGColor(gray: m.colour == .white ? 0.15 : 1, alpha: 0.95)
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch m.kind {
        case .arrow:
            let dx = m.b.x - m.a.x, dy = m.b.y - m.a.y
            let len = max(1, hypot(dx, dy))
            let ux = dx / len, uy = dy / len
            let head = min(mt.head * 1.4, len * 0.6)
            let base = CGPoint(x: m.b.x - ux * head * 0.8, y: m.b.y - uy * head * 0.8)
            let wing = head * 0.6
            let left = CGPoint(x: m.b.x - ux * head - uy * wing, y: m.b.y - uy * head + ux * wing)
            let right = CGPoint(x: m.b.x - ux * head + uy * wing, y: m.b.y - uy * head - ux * wing)
            let headPath = CGMutablePath()
            headPath.move(to: m.b); headPath.addLine(to: left); headPath.addLine(to: right); headPath.closeSubpath()
            // White edge first, so the arrow shows on any background.
            let edge = mt.line * 0.9
            ctx.setStrokeColor(outline)
            ctx.setLineWidth(mt.line + edge)
            ctx.move(to: m.a); ctx.addLine(to: base); ctx.strokePath()
            ctx.setFillColor(outline)
            ctx.setLineWidth(edge)
            ctx.addPath(headPath); ctx.drawPath(using: .fillStroke)
            // Then the colour.
            ctx.setStrokeColor(colour)
            ctx.setLineWidth(mt.line)
            ctx.move(to: m.a); ctx.addLine(to: base); ctx.strokePath()
            ctx.setFillColor(colour)
            ctx.addPath(headPath); ctx.fillPath()
        case .box, .circle:
            let r = CGRect(x: min(m.a.x, m.b.x), y: min(m.a.y, m.b.y), width: abs(m.a.x - m.b.x), height: abs(m.a.y - m.b.y))
            let path = m.kind == .box
                ? CGPath(roundedRect: r, cornerWidth: min(10 * u, r.width / 2), cornerHeight: min(10 * u, r.height / 2), transform: nil)
                : CGPath(ellipseIn: r, transform: nil)
            for (c, extra) in [(outline, mt.line * 0.9), (colour, 0)] {
                ctx.setStrokeColor(c)
                ctx.setLineWidth(mt.line + extra)
                ctx.addPath(path); ctx.strokePath()
            }
        case .text, .number:
            let rect = bounds(m, unit: u)
            let path = m.kind == .number
                ? CGPath(ellipseIn: rect, transform: nil)
                : CGPath(roundedRect: rect, cornerWidth: mt.font * 0.4, cornerHeight: mt.font * 0.4, transform: nil)
            ctx.setShadow(offset: CGSize(width: 0, height: 2 * u), blur: 6 * u, color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(colour)
            ctx.addPath(path); ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(outline)
            ctx.setLineWidth(max(1.5, 1.5 * u))
            ctx.addPath(path); ctx.strokePath()
            let text = labelText(m, unit: u)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            if m.kind == .number {
                let sz = text.size()
                text.draw(at: CGPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
            } else {
                let pad = mt.font * 0.55
                text.draw(with: rect.insetBy(dx: pad, dy: pad * 0.7), options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.restoreGState()
    }

    /// A 16:10 window around the clicked element, kept inside the screenshot.
    static func autoZoom(_ step: Step, zoom: Zoom, size: CGSize) -> CGRect? {
        guard let f = zoom.fraction else { return nil }
        let focus: CGRect
        if let h = step.highlight { focus = h }
        else if let p = step.clickPoint { focus = CGRect(x: p.x, y: p.y, width: 1, height: 1) }
        else { return nil }
        var w = max(size.width * f, focus.width * 1.6)
        var h = w * 10 / 16
        if h < focus.height * 1.6 { h = focus.height * 1.6; w = h * 16 / 10 }
        w = min(w, size.width); h = min(h, size.height)
        var x = focus.midX - w / 2, y = focus.midY - h / 2
        x = min(max(0, x), size.width - w)
        y = min(max(0, y), size.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func scaled(_ img: CGImage, width: Int) -> CGImage? {
        let h = Int((CGFloat(img.height) * CGFloat(width) / CGFloat(img.width)).rounded())
        guard let ctx = CGContext(data: nil, width: width, height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: max(1, h)))
        return ctx.makeImage()
    }

    static func png(_ img: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    static func jpeg(_ img: CGImage, quality: Double = 0.85) -> Data? {
        NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}

// MARK: - Private details

enum Sensitive {
    static let patterns: [NSRegularExpression] = [
        #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,                         // email
        #"(?:\+?\d{1,3}[\s\-.]?)?(?:\(?\d{2,4}\)?[\s\-.]?)\d{3,4}[\s\-.]?\d{3,4}"#, // phone
        #"\b(?:\d[ \-]?){13,19}\b"#,                                           // card number
        #"\b\d{3}-\d{2}-\d{4}\b"#,                                             // US SSN
        #"\b\d{3}[ ]?\d{3}[ ]?\d{3}\b"#,                                       // AU TFN
        #"\b\d{4}[ ]?\d{5}[ ]?\d{1,2}\b"#,                                     // Medicare
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func matches(in s: String) -> [Range<String.Index>] {
        let ns = s as NSString
        var out: [Range<String.Index>] = []
        for p in patterns {
            for m in p.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                // Phone-like matches need at least 8 digits, to skip dates, times and prices.
                let digits = ns.substring(with: m.range).filter(\.isNumber).count
                if p.pattern.contains("@") || digits >= 8, let r = Range(m.range, in: s) { out.append(r) }
            }
        }
        return out
    }

    /// Replaces private details in typed text with dots.
    static func mask(_ s: String) -> String {
        var out = s
        for r in matches(in: s).sorted(by: { $0.lowerBound > $1.lowerBound }) {
            out.replaceSubrange(r, with: String(repeating: "•", count: 8))
        }
        return out
    }

    /// Rectangles (screenshot pixels, top-left origin) around private details in a picture.
    static func find(in image: CGImage) -> [CGRect] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([req])
        let W = CGFloat(image.width), H = CGFloat(image.height)
        var rects: [CGRect] = []
        for obs in req.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            for r in matches(in: cand.string) {
                guard let box = try? cand.boundingBox(for: r)?.boundingBox else { continue }
                let rect = CGRect(x: box.minX * W, y: (1 - box.maxY) * H, width: box.width * W, height: box.height * H)
                rects.append(rect.insetBy(dx: -6, dy: -4))
            }
        }
        return rects
    }
}

@MainActor
enum AutoBlur {
    @MainActor static var scanning = Set<UUID>()

    /// Looks through every step not yet checked and adds blur boxes over private details.
    static func scan(guideID: UUID, force: Bool = false) {
        guard !scanning.contains(guideID), let g = GuideStore.shared.guide(guideID) else { return }
        let store = GuideStore.shared
        let jobs: [(UUID, URL)] = g.steps.compactMap { s in
            guard force || !s.autoBlurDone, let name = s.image else { return nil }
            return (s.id, store.imageURL(guideID, name))
        }
        guard !jobs.isEmpty else { return }
        scanning.insert(guideID)
        NotificationCenter.default.post(name: .autoBlurChanged, object: nil)
        Task.detached(priority: .utility) {
            var found: [UUID: [CGRect]] = [:]
            for (id, url) in jobs {
                guard let img = GuideStore.loadImage(url) else { continue }
                found[id] = Sensitive.find(in: img)
            }
            let results = found
            await MainActor.run {
                scanning.remove(guideID)
                if var g = GuideStore.shared.guide(guideID) {
                    for i in g.steps.indices {
                        guard let rects = results[g.steps[i].id] else { continue }
                        for r in rects where !g.steps[i].blurs.contains(where: { $0.intersects(r) && $0.contains(CGPoint(x: r.midX, y: r.midY)) }) {
                            g.steps[i].blurs.append(r)
                        }
                        g.steps[i].autoBlurDone = true
                    }
                    GuideStore.shared.update(g)
                }
                NotificationCenter.default.post(name: .autoBlurChanged, object: nil)
            }
        }
    }
}

extension Notification.Name {
    static let autoBlurChanged = Notification.Name("PareGuideAutoBlurChanged")
}
