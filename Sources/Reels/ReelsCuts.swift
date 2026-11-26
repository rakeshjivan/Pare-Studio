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

    var cutSummary: String {
        let n = activeCuts.count
        return n == 0 ? "" : "\(n) part\(n == 1 ? "" : "s") cut out"
    }
}

// MARK: - Timeline

/// A Camtasia-style timeline: a time ruler, the film strip with yellow trim handles and red parts cut out,
/// the sound's waveform, lanes for blurs, text and logos (each bar is when it shows), splits, the selection,
/// and a playhead you can grab and drag. Zoom with the slider above.
struct ClipTimeline: View {
    @ObservedObject var model: CropModel
    @State private var cutDrag: (id: UUID, start: Double, end: Double)?
    @State private var trimDrag: (start: Double, end: Double)?
    @State private var barDrag: (key: String, start: Double, end: Double)?
    @State private var hoverX: CGFloat?

    private let ruler: CGFloat = 18
    private let strip: CGFloat = 52
    private let wave: CGFloat = 26
    private let laneH: CGFloat = 18

    private struct Bar: Identifiable {
        let id: String
        let label: String
        let colour: Color
        let icon: String
        let range: ClosedRange<Double>?
        let set: (ClosedRange<Double>?) -> Void
        let delete: () -> Void
        let select: () -> Void
    }

    private var bars: [Bar] {
        var out: [Bar] = []
        for i in model.blurs.indices {
            out.append(Bar(id: "b\(i)", label: "Blur \(i + 1)", colour: .purple, icon: "drop.halffull",
                           range: i < model.blurTimes.count ? model.blurTimes[i] : nil,
                           set: { r in if i < model.blurTimes.count { model.blurTimes[i] = r } },
                           delete: { model.removeBlur(at: i) }, select: {}))
        }
        for t in model.texts {
            let id = t.id
            out.append(Bar(id: "t\(id)", label: t.text.isEmpty ? "Text" : t.text, colour: .teal, icon: "textformat", range: t.range,
                           set: { r in if let k = model.texts.firstIndex(where: { $0.id == id }) { model.texts[k].range = r } },
                           delete: { model.removeOverlay(id) }, select: { model.selectedOverlay = id }))
        }
        for o in model.images {
            let id = o.id
            out.append(Bar(id: "i\(id)", label: o.url.deletingPathExtension().lastPathComponent, colour: .orange, icon: "photo", range: o.range,
                           set: { r in if let k = model.images.firstIndex(where: { $0.id == id }) { model.images[k].range = r } },
                           delete: { model.removeOverlay(id) }, select: { model.selectedOverlay = id }))
        }
        return out
    }

    var body: some View {
        let lanes = bars
        let total = ruler + strip + (model.waveform.isEmpty ? 0 : wave + 2) + (lanes.isEmpty ? 0 : CGFloat(lanes.count) * (laneH + 3) + 4) + 4
        GeometryReader { outer in
            let w = max(outer.size.width, outer.size.width * CGFloat(model.zoom))
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: model.zoom > 1.01) {
                    content(w: w, lanes: lanes, total: total)
                        .frame(width: w, height: total, alignment: .topLeading)
                }
                .onChange(of: model.time) { _, t in
                    guard model.zoom > 1.01, model.playing else { return }
                    proxy.scrollTo("playhead-\(Int(t))", anchor: .center)
                }
            }
        }
        .frame(height: total)
    }

    @ViewBuilder
    private func content(w: CGFloat, lanes: [Bar], total: CGFloat) -> some View {
        let d = max(model.duration, 0.001)
        let x = { (t: Double) -> CGFloat in CGFloat(t / d) * w }
        let t = { (px: CGFloat) -> Double in min(max(0, Double(px / w) * d), d) }
        let waveTop = ruler + strip + 2
        let lanesTop = waveTop + (model.waveform.isEmpty ? 0 : wave + 2) + 4
        ZStack(alignment: .topLeading) {
            // Scroll anchors so the view can follow the playhead while playing.
            ForEach(0..<max(1, Int(d) + 1), id: \.self) { s in
                Color.clear.frame(width: 1, height: 1).offset(x: x(Double(s))).id("playhead-\(s)")
            }
            Ruler(duration: d, width: w)
                .frame(width: w, height: ruler)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in model.pause(); model.time = t(v.location.x) })

            Group {
                // Film strip: click to move the playhead (and select the part between splits); drag to scrub.
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
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in model.pause(); model.time = t(v.location.x) }
                    .onEnded { v in
                        if abs(v.translation.width) < 3 {
                            if model.splits.isEmpty { model.clearSelection() } else { model.selectSegment(at: t(v.location.x)) }
                        }
                    })
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

                // Selection.
                if let a = model.markIn, let b = model.markOut, b > a {
                    Rectangle().fill(Color.accentColor.opacity(0.32))
                        .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 2))
                        .frame(width: max(2, x(b) - x(a)), height: strip)
                        .offset(x: x(a))
                        .allowsHitTesting(false)
                } else if let a = model.markIn ?? model.markOut {
                    Rectangle().fill(Color.accentColor).frame(width: 2, height: strip).offset(x: x(a) - 1).allowsHitTesting(false)
                }

                // Splits.
                ForEach(model.splits, id: \.self) { s in
                    Rectangle().fill(Color.white).frame(width: 2, height: strip)
                        .overlay(alignment: .top) {
                            Image(systemName: "scissors").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .padding(2).background(Circle().fill(Color.black.opacity(0.7))).offset(y: -2)
                        }
                        .offset(x: x(s) - 1)
                        .contextMenu { Button("Remove this split") { model.splits.removeAll { $0 == s } } }
                }

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
                        model.pause()
                        model.trimStart = min(max(0, s.start + Double(v.translation.width / w) * d), model.trimEnd - 0.5)
                        model.time = model.trimStart
                    }.onEnded { _ in trimDrag = nil })
                    .help("Drag to choose where the video starts")
                trimHandle(at: x(model.trimEnd), leading: false)
                    .gesture(DragGesture().onChanged { v in
                        let s = trimDrag ?? (model.trimStart, model.trimEnd)
                        trimDrag = s
                        model.pause()
                        model.trimEnd = max(min(d, s.end + Double(v.translation.width / w) * d), model.trimStart + 0.5)
                        model.time = model.trimEnd
                    }.onEnded { _ in trimDrag = nil })
                    .help("Drag to choose where the video ends")

                if let hx = hoverX {
                    Text(TimingBar.fmt(t(hx)))
                        .font(.caption2.monospacedDigit()).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(.black.opacity(0.7))).foregroundStyle(.white)
                        .offset(x: min(max(0, hx - 18), w - 40), y: strip - 16)
                        .allowsHitTesting(false)
                }
            }
            .offset(y: ruler)

            // Waveform.
            if !model.waveform.isEmpty {
                Waveform(peaks: model.waveform, muted: model.audioFX.mute)
                    .frame(width: w, height: wave)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)))
                    .offset(y: waveTop)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in model.pause(); model.time = t(v.location.x) })
                    .help("The sound. Quiet gaps are easy to spot and cut out.")
            }

            // Lanes: blurs, text, logos.
            ForEach(Array(lanes.enumerated()), id: \.element.id) { k, bar in
                laneBar(bar, x: x, w: w, d: d)
                    .offset(y: lanesTop + CGFloat(k) * (laneH + 3))
            }

            // Playhead, with a knob to grab.
            Playhead(height: total - 2)
                .offset(x: x(min(model.time, d)) - 7)
                .gesture(DragGesture().onChanged { v in model.pause(); model.time = t(x(model.time) + v.translation.width) })
        }
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
                model.pause()
                let dt = Double(v.translation.width / w) * d
                if start { model.setCut(c.id, start: s.start + dt); model.time = max(0, s.start + dt) }
                else { model.setCut(c.id, end: s.end + dt); model.time = min(d, s.end + dt) }
            }.onEnded { _ in cutDrag = nil })
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    /// A blur, text or logo bar: drag the middle to move it in time, the ends to change when it starts and stops.
    @ViewBuilder
    private func laneBar(_ bar: Bar, x: (Double) -> CGFloat, w: CGFloat, d: Double) -> some View {
        let a = bar.range?.lowerBound ?? 0, b = bar.range?.upperBound ?? d
        HStack(spacing: 4) {
            Image(systemName: bar.icon).font(.system(size: 10))
            Text(bar.range == nil ? "\(bar.label) · whole video" : "\(bar.label) · \(TimingBar.fmt(a))–\(TimingBar.fmt(b))")
                .font(.caption2.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(width: max(24, x(b) - x(a)), height: laneH)
        .background(RoundedRectangle(cornerRadius: 4).fill(bar.colour.opacity(bar.range == nil ? 0.5 : 0.9)))
        .overlay(alignment: .leading) { barEdge(bar, start: true, w: w, d: d) }
        .overlay(alignment: .trailing) { barEdge(bar, start: false, w: w, d: d) }
        .offset(x: x(a))
        .onTapGesture { bar.select() }
        .gesture(DragGesture(minimumDistance: 2).onChanged { v in
            let s = (barDrag?.key == bar.id ? barDrag : nil) ?? (bar.id, a, b)
            barDrag = s
            model.pause()
            let len = s.end - s.start
            let na = min(max(0, s.start + Double(v.translation.width / w) * d), d - len)
            set(bar, na...(na + len))
            model.time = na
        }.onEnded { _ in barDrag = nil })
        .contextMenu {
            Button("Show for the whole video") { bar.set(nil) }
            Button("Show from the playhead for 5 seconds") { let s = min(model.time, max(0, d - 1)); set(bar, s...min(d, s + 5)) }
            if model.hasSelection, let i = model.markIn, let o = model.markOut { Button("Show during the selection") { set(bar, i...o) } }
            Divider()
            Button("Delete", role: .destructive) { bar.delete() }
        }
        .help("When this shows. Drag the ends to change when it starts and stops; drag the middle to move it. Right-click for more.")
    }

    private func barEdge(_ bar: Bar, start: Bool, w: CGFloat, d: Double) -> some View {
        Rectangle().fill(Color.white.opacity(0.85))
            .frame(width: 4, height: laneH - 4)
            .padding(.horizontal, 1)
            .contentShape(Rectangle().inset(by: -4))
            .gesture(DragGesture().onChanged { v in
                let s = (barDrag?.key == bar.id ? barDrag : nil) ?? (bar.id, bar.range?.lowerBound ?? 0, bar.range?.upperBound ?? d)
                barDrag = s
                model.pause()
                let dt = Double(v.translation.width / w) * d
                if start { let na = min(max(0, s.start + dt), s.end - 0.3); set(bar, na...s.end); model.time = na }
                else { let nb = max(min(d, s.end + dt), s.start + 0.3); set(bar, s.start...nb); model.time = nb }
            }.onEnded { _ in barDrag = nil })
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    private func set(_ bar: Bar, _ r: ClosedRange<Double>?) {
        // A range covering the whole video is the same as "whole video".
        if let r, r.lowerBound <= 0.05, r.upperBound >= model.duration - 0.05 { bar.set(nil) } else { bar.set(r) }
    }
}

/// The sound's loudness over time.
struct Waveform: View {
    let peaks: [Float]
    var muted = false
    var body: some View {
        Canvas { ctx, size in
            let n = peaks.count
            guard n > 0 else { return }
            let step = size.width / CGFloat(n)
            var p = Path()
            for (i, v) in peaks.enumerated() {
                let h = max(1, CGFloat(v) * (size.height - 2))
                p.addRect(CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2, width: max(0.8, step * 0.8), height: h))
            }
            ctx.fill(p, with: .color(muted ? Color.secondary.opacity(0.3) : Color.green.opacity(0.75)))
        }
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
