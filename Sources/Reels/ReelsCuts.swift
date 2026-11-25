// Edit Video's timeline: trim either end, and cut parts out of the middle (the parts either side
// are joined). Saving with cuts first joins the kept parts into a temporary copy on the Mac's video
// hardware, then runs the normal save (crop, blur, speed, smaller file, GIF, framed) on that copy.

import SwiftUI
import AppKit
import AVFoundation

struct CutRange: Identifiable, Equatable {
    let id = UUID()
    var start: Double
    var end: Double
    var length: Double { end - start }
}

extension CropModel {
    /// Cuts that fall inside the kept (trimmed) part.
    var activeCuts: [CutRange] {
        cuts.filter { $0.end > trimStart + 0.05 && $0.start < trimEnd - 0.05 }.sorted { $0.start < $1.start }
    }
    var hasCuts: Bool { !activeCuts.isEmpty }

    /// What's kept: the trimmed part, minus the cuts.
    var keepSegments: [(start: Double, end: Double)] {
        var out: [(Double, Double)] = []
        var t = trimStart
        for c in activeCuts {
            let a = max(c.start, trimStart), b = min(c.end, trimEnd)
            if a - t > 0.05 { out.append((t, a)) }
            t = max(t, b)
        }
        if trimEnd - t > 0.05 { out.append((t, trimEnd)) }
        return out
    }

    var keptLength: Double { keepSegments.reduce(0) { $0 + ($1.end - $1.start) } }

    func isCutOut(_ t: Double) -> Bool {
        t < trimStart || t > trimEnd || activeCuts.contains { t >= $0.start && t <= $0.end }
    }

    /// Adds a part to cut out around the playhead (about 5 seconds), then you drag its edges.
    func addCut() {
        guard duration > 1 else { return }
        let len = min(5, max(1, duration * 0.05))
        var a = max(trimStart, time - len / 2), b = min(trimEnd, a + len)
        if b - a < 0.5 { a = max(0, b - len) }
        // Join with any cut it touches.
        var merged = CutRange(start: a, end: b)
        cuts.removeAll { c in
            if c.end >= merged.start && c.start <= merged.end {
                merged = CutRange(start: min(c.start, merged.start), end: max(c.end, merged.end))
                return true
            }
            return false
        }
        cuts.append(merged)
        cuts.sort { $0.start < $1.start }
    }

    func removeCut(_ id: UUID) { cuts.removeAll { $0.id == id } }

    func setCut(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let i = cuts.firstIndex(where: { $0.id == id }) else { return }
        if let start { cuts[i].start = min(max(0, start), cuts[i].end - 0.3) }
        if let end { cuts[i].end = max(min(duration, end), cuts[i].start + 0.3) }
    }

    func trimStartHere() { trimStart = min(time, max(0, trimEnd - 0.5)) }
    func trimEndHere() { trimEnd = max(time, min(duration, trimStart + 0.5)) }

    /// Thumbnails for the timeline.
    func makeFilmstrip(_ asset: AVURLAsset) {
        let n = 16
        filmstrip = Array(repeating: nil, count: n)
        guard duration > 0 else { return }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 200, height: 200)
        let tol = CMTime(seconds: max(0.5, duration / Double(n) / 2), preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        let times = (0..<n).map { NSValue(time: CMTime(seconds: duration * (Double($0) + 0.5) / Double(n), preferredTimescale: 600)) }
        let forURL = url, total = duration
        gen.generateCGImagesAsynchronously(forTimes: times) { [weak self] req, img, _, result, _ in
            guard result == .succeeded, let img else { return }
            let i = min(n - 1, max(0, Int(req.seconds / max(0.001, total) * Double(n))))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.url == forURL, i < self.filmstrip.count else { return }
                    self.filmstrip[i] = img
                }
            }
        }
    }

    /// Needs a first pass on the original video: parts cut out, or blurs for part of the time.
    var needsFirstPass: Bool { hasCuts || hasTimedBlurs }

    /// Runs a save. With cuts or timed blurs, a first pass on the original video joins the kept parts
    /// and burns in the timed blurs (at the original times); the save then runs on that copy
    /// (named after the original), and the editor is put back afterwards.
    /// `finalIfPlain`: for a plain video save with nothing else to change, the first pass is the result.
    func withFirstPass(finalIfPlain: Bool, _ save: @escaping () -> Void) {
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
        let plain = finalIfPlain && !isCropped && wholeBlurs.isEmpty && abs(speed - 1) < 0.001
        busy = true
        savedFile = nil
        progress = nil
        status = hasCuts ? "Joining the parts you're keeping…" : "Adding the timed blurs…"
        let started = Date()
        let size = videoSize
        Task {
            let hasAudio = (try? await AVURLAsset(url: src).loadTracks(withMediaType: .audio).isEmpty == false) ?? false
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PareStudioPass-\(UUID().uuidString.prefix(6))")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pass = dir.appendingPathComponent(src.deletingPathExtension().lastPathComponent + ".mp4")
            // 1. Timed blurs, on the original timeline.
            var f = "[0:v]null[v0src]"
            var cur = "v0src"
            for (k, tb) in timed.enumerated() {
                func even(_ v: CGFloat) -> Int { Int((v / 2).rounded(.down) * 2) }
                let w = max(16, even(tb.rect.width * size.width)), h = max(16, even(tb.rect.height * size.height))
                let x = even(tb.rect.minX * size.width), y = even(tb.rect.minY * size.height)
                let r = max(1, min(min(w, h) / 2 - 1, 40)), rc = max(1, min(r, min(w, h) / 4 - 1))
                f += ";[\(cur)]split[tm\(k)][ts\(k)];[ts\(k)]crop=\(w):\(h):\(x):\(y),boxblur=luma_radius=\(r):luma_power=3:chroma_radius=\(rc):chroma_power=3[tb\(k)];"
                f += String(format: "[tm%d][tb%d]overlay=%d:%d:enable='between(t,%.3f,%.3f)'[tv%d]", k, k, x, y, tb.range.lowerBound, tb.range.upperBound, k)
                cur = "tv\(k)"
            }
            // 2. The kept parts, joined.
            let n = keeps.count
            f += ";[\(cur)]split=\(n)" + (0..<n).map { "[vs\($0)]" }.joined()
            if hasAudio { f += ";[0:a]asplit=\(n)" + (0..<n).map { "[as\($0)]" }.joined() }
            for (i, k) in keeps.enumerated() {
                f += String(format: ";[vs%d]trim=start=%.3f:end=%.3f,setpts=PTS-STARTPTS[v%d]", i, k.start, k.end, i)
                if hasAudio { f += String(format: ";[as%d]atrim=start=%.3f:end=%.3f,asetpts=PTS-STARTPTS[a%d]", i, k.start, k.end, i) }
            }
            f += ";" + keeps.indices.map { hasAudio ? "[v\($0)][a\($0)]" : "[v\($0)]" }.joined()
            f += "concat=n=\(n):v=1:a=\(hasAudio ? 1 : 0)[v]" + (hasAudio ? "[a]" : "")
            var base = ["-y", "-loglevel", "error", "-i", src.path, "-filter_complex", f, "-map", "[v]"]
            if hasAudio { base += ["-map", "[a]", "-c:a", "aac", "-b:a", "192k"] }
            let tail = ["-movflags", "+faststart", pass.path]
            // Mac video hardware first; the software encoder if that fails.
            var (code, _) = await ReelTools.capture(ff.path, base + ["-c:v", "h264_videotoolbox", "-q:v", "70"] + tail)
            if code != 0 {
                (code, _) = await ReelTools.capture(ff.path, base + ["-c:v", "libx264", "-preset", "veryfast", "-crf", "18"] + tail)
            }
            guard code == 0, FileManager.default.fileExists(atPath: pass.path) else {
                busy = false
                status = "Couldn't prepare the video. See details in the Download tab's Log."
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
            let kept = (url: url, start: trimStart, end: trimEnd, duration: duration, cuts: cuts, time: time,
                        blurs: blurs, blurTimes: blurTimes)
            let length = keeps.reduce(0) { $0 + ($1.end - $1.start) }
            busy = false
            url = pass
            nameSource = src
            duration = length
            trimStart = 0
            trimEnd = length
            cuts = []
            blurs = wholeBlurs           // timed blurs are already in the copy
            blurTimes = wholeBlurs.map { _ in nil }
            save()
            while busy { try? await Task.sleep(nanoseconds: 250_000_000) }
            url = kept.url
            nameSource = nil
            duration = kept.duration
            trimStart = kept.start
            trimEnd = kept.end
            cuts = kept.cuts
            blurs = kept.blurs
            blurTimes = kept.blurTimes
            time = kept.time
            try? FileManager.default.removeItem(at: dir)
        }
    }

    var cutSummary: String {
        let n = activeCuts.count
        return n == 0 ? "" : "\(n) part\(n == 1 ? "" : "s") cut out"
    }
}

// MARK: - Timeline

/// A Camtasia-style timeline: a time ruler, the film strip with yellow trim handles and red parts cut out,
/// a lane for blurs (each bar is when that blur shows), and a playhead you can grab and drag.
struct ClipTimeline: View {
    @ObservedObject var model: CropModel
    @State private var cutDrag: (id: UUID, start: Double, end: Double)?
    @State private var trimDrag: (start: Double, end: Double)?
    @State private var blurDrag: (index: Int, start: Double, end: Double)?
    @State private var hoverX: CGFloat?

    private let ruler: CGFloat = 18
    private let strip: CGFloat = 56
    private let laneH: CGFloat = 18

    private var lanes: CGFloat { model.blurs.isEmpty ? 0 : CGFloat(model.blurs.count) * (laneH + 3) + 4 }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let d = max(model.duration, 0.001)
            let x = { (t: Double) -> CGFloat in CGFloat(t / d) * w }
            let t = { (px: CGFloat) -> Double in min(max(0, Double(px / w) * d), d) }
            ZStack(alignment: .topLeading) {
                // Ruler: click or drag to scrub.
                Ruler(duration: d, width: w)
                    .frame(width: w, height: ruler)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in model.time = t(v.location.x) })

                Group {
                    // Film strip: click or drag to scrub.
                    HStack(spacing: 0) {
                        ForEach(model.filmstrip.indices, id: \.self) { i in
                            Group {
                                if let img = model.filmstrip[i] {
                                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Rectangle().fill(Color.secondary.opacity(0.25))
                                }
                            }
                            .frame(width: w / CGFloat(max(1, model.filmstrip.count)), height: strip)
                            .clipped()
                        }
                    }
                    .frame(width: w, height: strip)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in model.time = t(v.location.x) })
                    .onContinuousHover { phase in
                        if case .active(let p) = phase { hoverX = p.x } else { hoverX = nil }
                    }

                    // Trimmed-off ends.
                    Rectangle().fill(Color.black.opacity(0.65))
                        .frame(width: max(0, x(model.trimStart)), height: strip)
                        .allowsHitTesting(false)
                    Rectangle().fill(Color.black.opacity(0.65))
                        .frame(width: max(0, w - x(model.trimEnd)), height: strip)
                        .offset(x: x(model.trimEnd))
                        .allowsHitTesting(false)

                    // Parts cut out of the middle.
                    ForEach(model.cuts) { c in cutView(c, x: x, w: w, d: d) }

                    // The kept part and its trim handles.
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.yellow, lineWidth: 3)
                        .frame(width: max(8, x(model.trimEnd) - x(model.trimStart)), height: strip)
                        .offset(x: x(model.trimStart))
                        .allowsHitTesting(false)
                    trimHandle(at: x(model.trimStart), leading: true)
                        .gesture(DragGesture().onChanged { v in
                            let s = trimDrag ?? (model.trimStart, model.trimEnd)
                            trimDrag = s
                            model.trimStart = min(max(0, s.start + Double(v.translation.width / w) * d), model.trimEnd - 0.5)
                            model.time = model.trimStart
                        }.onEnded { _ in trimDrag = nil })
                        .help("Drag to choose where the video starts")
                    trimHandle(at: x(model.trimEnd), leading: false)
                        .gesture(DragGesture().onChanged { v in
                            let s = trimDrag ?? (model.trimStart, model.trimEnd)
                            trimDrag = s
                            model.trimEnd = max(min(d, s.end + Double(v.translation.width / w) * d), model.trimStart + 0.5)
                            model.time = model.trimEnd
                        }.onEnded { _ in trimDrag = nil })
                        .help("Drag to choose where the video ends")

                    // Hover time.
                    if let hx = hoverX {
                        Text(TimingBar.fmt(t(hx)))
                            .font(.caption2.monospacedDigit()).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(.black.opacity(0.7))).foregroundStyle(.white)
                            .offset(x: min(max(0, hx - 18), w - 40), y: strip - 16)
                            .allowsHitTesting(false)
                    }
                }
                .offset(y: ruler)

                // Blur lane: one bar per blur, showing when it's on.
                ForEach(model.blurs.indices, id: \.self) { i in
                    blurBar(i, x: x, w: w, d: d)
                        .offset(y: ruler + strip + 6 + CGFloat(i) * (laneH + 3))
                }

                // Playhead, with a knob to grab.
                Playhead(height: ruler + strip + lanes + 4)
                    .offset(x: x(min(model.time, d)) - 7)
                    .gesture(DragGesture().onChanged { v in model.time = t(x(model.time) + v.translation.width) })
            }
            .frame(width: w, height: ruler + strip + lanes + 4, alignment: .topLeading)
        }
        .frame(height: ruler + strip + lanes + 4)
        .padding(.top, 2)
    }

    private func trimHandle(at px: CGFloat, leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .frame(width: 12, height: strip)
            .overlay(Image(systemName: leading ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.black.opacity(0.7)))
            .offset(x: px - 6)
            .shadow(color: .black.opacity(0.3), radius: 1)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    @ViewBuilder
    private func cutView(_ c: CutRange, x: (Double) -> CGFloat, w: CGFloat, d: Double) -> some View {
        let width = max(10, x(c.end) - x(c.start))
        ZStack(alignment: .top) {
            Rectangle().fill(Color.red.opacity(0.55))
            Stripes().stroke(Color.white.opacity(0.35), lineWidth: 1.5).clipped()
            Button { model.removeCut(c.id) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 15)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
            }
            .buttonStyle(.borderless)
            .help("Put this part back")
            .padding(.top, 3)
        }
        .frame(width: width, height: strip)
        .overlay(alignment: .leading) { cutEdge(c, start: true, w: w, d: d) }
        .overlay(alignment: .trailing) { cutEdge(c, start: false, w: w, d: d) }
        .offset(x: x(c.start))
        .help("This part is cut out and the parts either side are joined. Drag its edges, or × to put it back.")
    }

    private func cutEdge(_ c: CutRange, start: Bool, w: CGFloat, d: Double) -> some View {
        Rectangle().fill(Color.red)
            .frame(width: 6, height: strip)
            .contentShape(Rectangle().inset(by: -4))
            .gesture(DragGesture().onChanged { v in
                let s = (cutDrag?.id == c.id ? cutDrag : nil) ?? (c.id, c.start, c.end)
                cutDrag = s
                let dt = Double(v.translation.width / w) * d
                if start { model.setCut(c.id, start: s.start + dt); model.time = max(0, s.start + dt) }
                else { model.setCut(c.id, end: s.end + dt); model.time = min(d, s.end + dt) }
            }.onEnded { _ in cutDrag = nil })
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    /// A blur's bar: drag the middle to move it in time, the ends to change when it starts and stops.
    @ViewBuilder
    private func blurBar(_ i: Int, x: (Double) -> CGFloat, w: CGFloat, d: Double) -> some View {
        let range = i < model.blurTimes.count ? model.blurTimes[i] : nil
        let a = range?.lowerBound ?? 0, b = range?.upperBound ?? d
        let colour = Color.purple
        HStack(spacing: 4) {
            Image(systemName: "drop.halffull").font(.system(size: 10))
            Text(range == nil ? "Blur \(i + 1) · whole video" : "Blur \(i + 1) · \(TimingBar.fmt(a))–\(TimingBar.fmt(b))")
                .font(.caption2.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(width: max(24, x(b) - x(a)), height: laneH)
        .background(RoundedRectangle(cornerRadius: 4).fill(colour.opacity(range == nil ? 0.45 : 0.85)))
        .overlay(alignment: .leading) { blurEdge(i, start: true, w: w, d: d) }
        .overlay(alignment: .trailing) { blurEdge(i, start: false, w: w, d: d) }
        .offset(x: x(a))
        .gesture(DragGesture(minimumDistance: 2).onChanged { v in
            let s = (blurDrag?.index == i ? blurDrag : nil) ?? (i, a, b)
            blurDrag = s
            let len = s.end - s.start
            var na = s.start + Double(v.translation.width / w) * d
            na = min(max(0, na), d - len)
            setBlur(i, na...(na + len))
            model.time = na
        }.onEnded { _ in blurDrag = nil })
        .contextMenu {
            Button("Show for the whole video") { setBlur(i, nil) }
            Button("Show from the playhead for 5 seconds") {
                let s = min(model.time, max(0, d - 1)); setBlur(i, s...min(d, s + 5))
            }
            Divider()
            Button("Delete this blur", role: .destructive) { model.removeBlur(at: i) }
        }
        .help("When this blur shows. Drag the ends to change when it starts and stops; drag the middle to move it. Right-click for more.")
    }

    private func blurEdge(_ i: Int, start: Bool, w: CGFloat, d: Double) -> some View {
        Rectangle().fill(Color.white.opacity(0.85))
            .frame(width: 4, height: laneH - 4)
            .padding(.horizontal, 1)
            .contentShape(Rectangle().inset(by: -4))
            .gesture(DragGesture().onChanged { v in
                let range = i < model.blurTimes.count ? model.blurTimes[i] : nil
                let s = (blurDrag?.index == i ? blurDrag : nil) ?? (i, range?.lowerBound ?? 0, range?.upperBound ?? d)
                blurDrag = s
                let dt = Double(v.translation.width / w) * d
                if start {
                    let na = min(max(0, s.start + dt), s.end - 0.3)
                    setBlur(i, na...s.end); model.time = na
                } else {
                    let nb = max(min(d, s.end + dt), s.start + 0.3)
                    setBlur(i, s.start...nb); model.time = nb
                }
            }.onEnded { _ in blurDrag = nil })
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    private func setBlur(_ i: Int, _ r: ClosedRange<Double>?) {
        guard i < model.blurTimes.count else { return }
        // A range covering the whole video is the same as "whole video".
        if let r, r.lowerBound <= 0.05, r.upperBound >= model.duration - 0.05 { model.blurTimes[i] = nil } else { model.blurTimes[i] = r }
    }
}

/// Time marks along the top of the timeline.
struct Ruler: View {
    let duration: Double
    let width: CGFloat

    var body: some View {
        let step = Self.step(duration, width)
        Canvas { ctx, size in
            var t = 0.0
            var i = 0
            while t <= duration + 0.001 {
                let x = CGFloat(t / duration) * size.width
                let major = i % 5 == 0
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x, y: size.height - (major ? 8 : 4)))
                ctx.stroke(p, with: .color(.secondary.opacity(major ? 0.8 : 0.45)), lineWidth: 1)
                if major, x < size.width - 24 {
                    ctx.draw(Text(TimingBar.fmt(t)).font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary),
                             at: CGPoint(x: x + 2, y: 5), anchor: .leading)
                }
                t += step / 5
                i += 1
            }
        }
    }

    /// A tidy spacing for labelled marks, about every 90 points.
    static func step(_ d: Double, _ w: CGFloat) -> Double {
        let target = d * 90 / Double(max(1, w))
        for s in [1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600] where s >= target { return s }
        return 3600
    }
}

/// The playhead: a knob on top and a line down through the timeline.
struct Playhead: View {
    let height: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.white)
                .shadow(color: .black.opacity(0.6), radius: 1)
            Rectangle().fill(Color.white).frame(width: 2, height: max(0, height - 12))
                .shadow(color: .black.opacity(0.6), radius: 1)
        }
        .frame(width: 14, height: height, alignment: .top)
        .contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
        .help("Drag to scrub")
    }
}

/// Diagonal lines for the parts that are cut out.
struct Stripes: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        var x = -r.height
        while x < r.width {
            p.move(to: CGPoint(x: x, y: r.height))
            p.addLine(to: CGPoint(x: x + r.height, y: 0))
            x += 9
        }
        return p
    }
}

/// The controls under the timeline.
struct TimingBar: View {
    @ObservedObject var model: CropModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Group {
                    Button { step(-5) } label: { Image(systemName: "gobackward.5") }
                        .keyboardShortcut(.leftArrow, modifiers: [.shift]).help("Back 5 seconds (⇧←)")
                    Button { step(-1) } label: { Image(systemName: "backward.frame.fill") }
                        .keyboardShortcut(.leftArrow, modifiers: []).help("Back 1 second (←)")
                    Button { step(1) } label: { Image(systemName: "forward.frame.fill") }
                        .keyboardShortcut(.rightArrow, modifiers: []).help("Forward 1 second (→)")
                    Button { step(5) } label: { Image(systemName: "goforward.5") }
                        .keyboardShortcut(.rightArrow, modifiers: [.shift]).help("Forward 5 seconds (⇧→)")
                }
                .buttonStyle(.borderless)
                Text(TimingBar.fmt(model.time)).font(.body.monospacedDigit().weight(.semibold)).frame(minWidth: 48, alignment: .leading)
                Divider().frame(height: 16)
                Button { model.trimStartHere() } label: { Label("Start here", systemImage: "arrow.right.to.line") }
                    .help("The video starts at the playhead (or drag the yellow handle on the left)")
                Button { model.trimEndHere() } label: { Label("End here", systemImage: "arrow.left.to.line") }
                    .help("The video ends at the playhead (or drag the yellow handle on the right)")
                Button { model.addCut() } label: { Label("Cut out a part", systemImage: "scissors") }
                    .help("Marks a part around the playhead to remove; the parts either side are joined. Drag its red edges to fit.")
                    .disabled(model.isGIF)
                if model.isTrimmed || !model.cuts.isEmpty {
                    Button("Reset timing") { model.resetTiming() }
                }
                Spacer()
                Text("Keeping \(TimingBar.fmt(model.keptLength)) of \(TimingBar.fmt(model.duration))")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .disabled(model.busy)
            Text(hint).font(.caption).foregroundStyle(model.isCutOut(model.time) ? .red : .secondary)
        }
    }

    private func step(_ s: Double) { model.time = min(max(0, model.time + s), model.duration) }

    private var hint: String {
        if model.isCutOut(model.time) { return "The playhead is in a part that won't be in the saved video." }
        if !model.cuts.isEmpty { return "Red parts are cut out and the parts either side are joined. Drag the red edges to adjust, or × to put a part back." }
        return "Click or drag the timeline to scrub. Drag the yellow handles to trim. To remove a part in the middle, move the playhead there and click Cut out a part."
    }

    static func fmt(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let t = Int(s.rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}
