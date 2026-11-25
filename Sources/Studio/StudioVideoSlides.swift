// Turn a video into slides: finds each slide change in a recorded talk or webinar, then saves a
// PowerPoint (with what was said as speaker notes), a PDF, the slide images, or a Camtasia project
// with the slides timed to the sound.

import SwiftUI
import AppKit
import AVFoundation
import PDFKit
import UniformTypeIdentifiers

/// One stretch of the video showing one slide.
struct SlideSpan: Identifiable, Equatable {
    let id = UUID()
    var start: Double
    var end: Double
    var slide: Int          // index into VideoSlides.slides
}

@MainActor
final class VideoSlides: ObservableObject {
    static let shared = VideoSlides()

    enum Sensitivity: String, CaseIterable, Identifiable {
        case low = "Fewer slides", normal = "Normal", high = "Every change"
        var id: String { rawValue }
        var threshold: Double {
            switch self { case .low: return 0.12; case .normal: return 0.05; case .high: return 0.02 }
        }
        var help: String {
            switch self {
            case .low: return "Only big changes count. Use this if the presenter's video or animations make extra slides."
            case .normal: return "Works for most talks and webinars."
            case .high: return "Every animation step becomes its own slide."
            }
        }
    }

    @Published var video: URL?
    @Published var duration: Double = 0
    @Published var preview: NSImage?
    /// The part of the frame that holds the slides (0–1, top-left origin). Whole frame by default.
    @Published var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var sensitivity: Sensitivity = .normal
    @Published var transcribe = true
    @Published var slides: [Slide] = []
    @Published var spans: [SlideSpan] = []
    @Published var lines: [Line] = []
    @Published var wav: URL?
    @Published var status: String?
    @Published var progress: Double?
    @Published var problem: String?
    @Published var busy = false
    @Published var message: String?
    @Published var includeVideo = true

    private(set) var work: URL = VideoSlides.newWork()
    private var task: Task<Void, Never>?

    static func newWork() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("PareStudioVS-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    var name: String { video?.deletingPathExtension().lastPathComponent ?? "Slides" }
    var hasResult: Bool { !slides.isEmpty }

    func open(_ url: URL) {
        guard !busy else { return }
        reset()
        video = url
        Task {
            let asset = AVURLAsset(url: url)
            guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else {
                problem = "That file has no picture. Use a video of the talk (MP4, MOV or M4V)."
                video = nil
                return
            }
            let d = (try? await asset.load(.duration).seconds) ?? 0
            duration = d.isFinite ? d : 0
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 1280, height: 1280)
            let at = CMTime(seconds: min(max(5, duration * 0.15), max(0, duration - 1)), preferredTimescale: 600)
            if let img = try? await gen.image(at: at).image {
                preview = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            }
        }
    }

    func reset() {
        task?.cancel()
        video = nil; duration = 0; preview = nil
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        slides = []; spans = []; lines = []; wav = nil
        status = nil; progress = nil; problem = nil; message = nil; busy = false
        try? FileManager.default.removeItem(at: work)
        work = VideoSlides.newWork()
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: Finding the slides

    func findSlides() {
        guard let video, !busy else { return }
        busy = true
        problem = nil
        message = nil
        slides = []; spans = []
        let crop = self.crop, threshold = sensitivity.threshold, duration = self.duration
        let work = self.work, wantWords = transcribe
        task = Task {
            defer { busy = false; status = nil; progress = nil }
            do {
                // 1. Watch the video for slide changes.
                status = "Looking for slide changes…"
                let found = try await Task.detached(priority: .userInitiated) {
                    try await SlideFinder.scan(video, crop: crop, threshold: threshold, duration: duration) { f in
                        Task { @MainActor in VideoSlides.shared.progress = f }
                    }
                }.value
                try Task.checkCancellation()
                guard !found.spans.isEmpty else { throw PGError("No slides were found in this video.") }
                // 2. Save a sharp picture of each slide.
                status = "Saving each slide…"
                progress = nil
                let files = try await Task.detached(priority: .userInitiated) {
                    try await SlideFinder.capture(video, crop: crop, times: found.captureTimes, work: work)
                }.value
                var list: [Slide] = []
                for (i, f) in files.enumerated() {
                    var s = Slide(number: i + 1, url: f)
                    if let img = NSImage(contentsOf: f) {
                        s.thumb = img
                        if let rep = img.representations.first, rep.pixelsWide > 0 {
                            s.size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                        }
                    }
                    list.append(s)
                }
                slides = list
                spans = found.spans
                // 3. The sound (for Camtasia) and, if asked, what was said.
                status = "Taking the sound out…"
                if let w = try? await Audio.extract(video, work: work) {
                    wav = w
                    if wantWords {
                        status = "Listening to what's said (on this Mac)… long videos take a while."
                        lines = (try? await Transcriber.transcribe(w)) ?? []
                    }
                }
                try Task.checkCancellation()
                let n = slides.count
                message = "Found \(n) slide\(n == 1 ? "" : "s")" + (spans.count > n ? ", shown \(spans.count) times (some came back)." : ".")
            } catch is CancellationError {
                message = "Stopped."
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    // MARK: Editing

    /// Removes a slide: its time goes to the slide before it (or the next one, if it was first).
    func remove(slide index: Int) {
        guard index < slides.count, slides.count > 1 else { return }
        slides.remove(at: index)
        let gone = Int.max
        var out: [SlideSpan] = []
        for var sp in spans {
            if sp.slide == index {
                if !out.isEmpty { out[out.count - 1].end = sp.end; continue }
                sp.slide = gone
            } else if sp.slide > index {
                sp.slide -= 1
            }
            out.append(sp)
        }
        if let f = out.first, f.slide == gone {
            if out.count > 1 { out[1].start = f.start; out.removeFirst() } else { out[0].slide = 0 }
        }
        var joined: [SlideSpan] = []
        for sp in out {
            if let last = joined.last, last.slide == sp.slide { joined[joined.count - 1].end = sp.end } else { joined.append(sp) }
        }
        spans = joined
        renumber()
    }

    private func renumber() {
        slides = slides.enumerated().map { i, s in
            var n = Slide(number: i + 1, url: s.url)
            n.thumb = s.thumb; n.size = s.size; n.text = s.text
            return n
        }
    }

    func firstTime(of slide: Int) -> Double { spans.first { $0.slide == slide }?.start ?? 0 }

    /// What was said while each slide was on screen, for speaker notes.
    func notes() -> [[String]] {
        slides.indices.map { i in
            let mine = spans.filter { $0.slide == i }
            return lines.filter { l in mine.contains { l.start >= $0.start - 0.2 && l.start < $0.end } }
                .map { "[\(clock($0.start))] \($0.text)" }
        }
    }

    // MARK: Saving

    func savePowerPoint() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + ".pptx"
        panel.allowedContentTypes = [UTType(filenameExtension: "pptx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("Making the PowerPoint…") { [slides, notes = notes()] in
            try Office.pptx(images: slides.map(\.url), notes: notes, to: url)
            return [url]
        }
    }

    func savePDF() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + " slides.pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("Making the PDF…") { [slides] in
            let doc = PDFDocument()
            for s in slides {
                if let img = NSImage(contentsOf: s.url), let page = PDFPage(image: img) { doc.insert(page, at: doc.pageCount) }
            }
            guard doc.write(to: url) else { throw PGError("Couldn't save the PDF.") }
            return [url]
        }
    }

    func saveImages() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose a folder for the slide images."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        run("Saving the slide images…") { [slides, name] in
            let fm = FileManager.default
            let dir = folder.appendingPathComponent(name + " slides")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for s in slides {
                let dest = dir.appendingPathComponent(String(format: "Slide %02d.png", s.number))
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: s.url, to: dest)
            }
            return [dir]
        }
    }

    func saveTranscript() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + " transcript.docx"
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("Making the transcript…") { [lines, spans, name] in
            var paras: [(time: String?, text: String)] = []
            var lastSlide = -1
            for l in lines {
                let s = spans.last { $0.start <= l.start + 0.2 }?.slide ?? 0
                if s != lastSlide { paras.append((nil, "— Slide \(s + 1) —")); lastSlide = s }
                paras.append((Keywords.hms(l.start), l.text))
            }
            try Office.docx(title: name, paragraphs: paras, to: url)
            return [url]
        }
    }

    func saveCamtasia() {
        guard let wav, let video else {
            problem = "This video has no sound, so there's nothing to put on the audio track."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + ".cmproj"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let cues = spans.map { Cue(slide: $0.slide, start: $0.start) }
        let finds = Keywords.find(Session.shared.searches, in: lines)
        let plan = Export.Plan(slides: slides, cues: Matcher.tidy(cues, slideCount: slides.count, duration: duration),
                               duration: duration, wav: wav, recording: video, includeRecording: includeVideo,
                               title: name, finds: finds)
        run("Making the Camtasia project…") {
            try Export.camtasia(plan, to: url)
            return [url.pathExtension.lowercased() == "cmproj" ? url : url.appendingPathExtension("cmproj")]
        }
    }

    private func run(_ what: String, _ job: @escaping @Sendable () throws -> [URL]) {
        busy = true
        status = what
        problem = nil
        Task {
            do {
                let made = try await Task.detached(priority: .userInitiated) { try job() }.value
                NSWorkspace.shared.activateFileViewerSelecting(made)
                message = "Saved \(made.first?.lastPathComponent ?? "")."
            } catch {
                problem = error.localizedDescription
            }
            busy = false
            status = nil
        }
    }
}

// MARK: - The slide finder

enum SlideFinder {
    struct Result {
        var spans: [SlideSpan]
        var captureTimes: [Double]      // one per unique slide
    }

    /// A tiny grey picture of the slide area, for comparing frames.
    static let sigW = 64, sigH = 36

    static func signature(_ img: CGImage, crop: CGRect) -> [UInt8] {
        let r = CGRect(x: crop.minX * CGFloat(img.width), y: crop.minY * CGFloat(img.height),
                       width: crop.width * CGFloat(img.width), height: crop.height * CGFloat(img.height)).integral
        let part = img.cropping(to: r) ?? img
        var px = [UInt8](repeating: 0, count: sigW * sigH)
        px.withUnsafeMutableBytes { buf in
            if let ctx = CGContext(data: buf.baseAddress, width: sigW, height: sigH, bitsPerComponent: 8, bytesPerRow: sigW,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.interpolationQuality = .medium
                ctx.draw(part, in: CGRect(x: 0, y: 0, width: sigW, height: sigH))
            }
        }
        return px
    }

    /// Share of the picture that changed noticeably (0–1).
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var n = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 28 { n += 1 }
        return Double(n) / Double(a.count)
    }

    static func scan(_ url: URL, crop: CGRect, threshold: Double, duration: Double,
                     progress: @escaping (Double) -> Void) async throws -> Result {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        let step = duration > 2 * 3600 ? 2.0 : (duration > 20 * 60 ? 1.0 : 0.5)
        var samples: [(t: Double, sig: [UInt8])] = []
        var t = 0.0
        while t < max(duration, 0.1) {
            try Task.checkCancellation()
            if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                samples.append((t, signature(img, crop: crop)))
            }
            progress(min(1, t / max(1, duration)))
            t += step
        }
        guard !samples.isEmpty else { return Result(spans: [], captureTimes: []) }

        // Stretches of near-identical frames.
        struct Seg { var start: Double; var end: Double; var samples: [(t: Double, sig: [UInt8])] }
        var segs: [Seg] = [Seg(start: 0, end: samples[0].t, samples: [samples[0]])]
        var ref = samples[0].sig
        for s in samples.dropFirst() {
            if difference(s.sig, ref) > threshold {
                segs[segs.count - 1].end = s.t
                segs.append(Seg(start: s.t, end: s.t, samples: [s]))
                ref = s.sig
            } else {
                segs[segs.count - 1].samples.append(s)
                segs[segs.count - 1].end = s.t
            }
        }
        segs[segs.count - 1].end = max(duration, segs[segs.count - 1].end)

        // Very short stretches are transitions or fades: fold them into the next slide.
        let minLength = max(1.5, step * 2.5)
        var kept: [Seg] = []
        var carry: Double?
        for (i, seg) in segs.enumerated() {
            var s = seg
            if let c = carry { s.start = c; carry = nil }
            if s.end - s.start < minLength && i < segs.count - 1 {
                carry = s.start
                continue
            }
            kept.append(s)
        }
        if kept.isEmpty, let last = segs.last { kept = [last] }
        kept[0].start = 0

        // The picture to keep for each stretch: near its end, once any builds have finished.
        func best(_ s: Seg) -> (t: Double, sig: [UInt8]) {
            let target = max(s.start + 0.5, s.end - 1.0)
            return s.samples.min { abs($0.t - target) < abs($1.t - target) } ?? s.samples[0]
        }

        // Slides that come back reuse their first picture.
        var uniqueSigs: [[UInt8]] = []
        var captureTimes: [Double] = []
        var spans: [SlideSpan] = []
        for s in kept {
            let b = best(s)
            var idx = uniqueSigs.firstIndex { difference($0, b.sig) < threshold * 0.6 }
            if idx == nil {
                uniqueSigs.append(b.sig)
                captureTimes.append(b.t)
                idx = uniqueSigs.count - 1
            }
            if let last = spans.last, last.slide == idx! {
                spans[spans.count - 1].end = s.end
            } else {
                spans.append(SlideSpan(start: s.start, end: s.end, slide: idx!))
            }
        }
        return Result(spans: spans, captureTimes: captureTimes)
    }

    /// Full-quality pictures of each slide, cropped to the slide area.
    static func capture(_ url: URL, crop: CGRect, times: [Double], work: URL) async throws -> [URL] {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let dir = work.appendingPathComponent("slides-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        for (i, t) in times.enumerated() {
            try Task.checkCancellation()
            let img = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            let r = CGRect(x: crop.minX * CGFloat(img.width), y: crop.minY * CGFloat(img.height),
                           width: crop.width * CGFloat(img.width), height: crop.height * CGFloat(img.height)).integral
            let part = img.cropping(to: r) ?? img
            let rep = NSBitmapImageRep(cgImage: part)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let f = dir.appendingPathComponent(String(format: "Slide %03d.png", i + 1))
            try png.write(to: f)
            out.append(f)
        }
        return out
    }
}

// MARK: - Screen

struct VideoSlidesView: View {
    @ObservedObject private var m = VideoSlides.shared

    var body: some View {
        if m.video == nil {
            StudioDrop(title: "Drop a video of a talk or webinar",
                       detail: "Pare Studio finds each slide, then saves a PowerPoint, a PDF, the images, or a Camtasia project with the slides timed to the sound.",
                       icon: "rectangle.stack.badge.play.fill", colour: Screen.videoSlides.colour,
                       types: [.movie, .mpeg4Movie, .quickTimeMovie], problem: m.problem) { m.open($0) }
        } else if m.hasResult {
            VideoSlidesResult()
        } else {
            VideoSlidesSetup()
        }
    }
}

struct VideoSlidesSetup: View {
    @ObservedObject private var m = VideoSlides.shared

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("1. Where are the slides?").font(.headline)
                Text("If the video also shows the presenter or a webinar frame, drag a box around just the slide. Otherwise leave it as the whole picture.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                CropPicker(image: m.preview, crop: $m.crop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Button("Use Whole Picture") { m.crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
                    Spacer()
                    Text(m.video?.lastPathComponent ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(clock(m.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 16) {
                Text("2. Options").font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    Text("How many slides?").font(.callout.weight(.medium))
                    Picker("", selection: $m.sensitivity) {
                        ForEach(VideoSlides.Sensitivity.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text(m.sensitivity.help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $m.transcribe) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also transcribe what's said")
                        Text("Adds speaker notes to the PowerPoint, keyword markers to Camtasia, and a transcript. Takes longer.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if let st = m.status {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(st).font(.callout)
                        if let p = m.progress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
                        Button("Stop") { m.cancel() }
                    }
                }
                if let p = m.problem { Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                HStack {
                    Button("Different Video") { m.reset() }.disabled(m.busy)
                    Spacer()
                    Button { m.findSlides() } label: {
                        Label("3. Find the Slides", systemImage: "wand.and.stars").padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(m.busy)
                }
            }
            .frame(width: 330)
        }
        .padding(20)
    }
}

/// Shows a frame of the video; drag to draw the slide area.
struct CropPicker: View {
    let image: NSImage?
    @Binding var crop: CGRect
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let size = fitted(geo.size)
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                } else {
                    Rectangle().fill(.quaternary).frame(width: size.width, height: size.height)
                        .overlay(ProgressView())
                }
                // Dim outside the slide area.
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    p.addRect(rect(in: size))
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .frame(width: rect(in: size).width, height: rect(in: size).height)
                    .offset(x: rect(in: size).minX, y: rect(in: size).minY)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { g in
                    let a = dragStart ?? g.startLocation
                    dragStart = a
                    let b = g.location
                    let x0 = min(max(0, min(a.x, b.x)), size.width), x1 = min(max(0, max(a.x, b.x)), size.width)
                    let y0 = min(max(0, min(a.y, b.y)), size.height), y1 = min(max(0, max(a.y, b.y)), size.height)
                    guard x1 - x0 > 10, y1 - y0 > 10 else { return }
                    crop = CGRect(x: x0 / size.width, y: y0 / size.height, width: (x1 - x0) / size.width, height: (y1 - y0) / size.height)
                }
                .onEnded { _ in dragStart = nil })
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func fitted(_ box: CGSize) -> CGSize {
        let ar = image.map { $0.size.width / max(1, $0.size.height) } ?? 16.0 / 9.0
        let w = min(box.width, box.height * ar)
        return CGSize(width: w, height: w / ar)
    }

    private func rect(in size: CGSize) -> CGRect {
        CGRect(x: crop.minX * size.width, y: crop.minY * size.height, width: crop.width * size.width, height: crop.height * size.height)
    }
}

struct VideoSlidesResult: View {
    @ObservedObject private var m = VideoSlides.shared
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.message ?? "\(m.slides.count) slides").font(.headline)
                    Text("Remove any slide that isn't one (for example a frozen frame). Its time goes to the slide before it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start Again") { m.slides = []; m.spans = [] }.disabled(m.busy)
                Button("Different Video") { m.reset() }.disabled(m.busy)
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(m.slides.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 4) {
                            ZStack(alignment: .topTrailing) {
                                if let t = m.slides[i].thumb {
                                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                                }
                                Button { m.remove(slide: i) } label: {
                                    Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.borderless).padding(6).help("Remove this slide")
                                .disabled(m.busy || m.slides.count < 2)
                            }
                            HStack {
                                Text("Slide \(i + 1)").font(.callout.weight(.semibold))
                                Spacer()
                                Text(clock(m.firstTime(of: i))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button { m.savePowerPoint() } label: { Label("PowerPoint…", systemImage: "rectangle.on.rectangle") }
                    Button { m.savePDF() } label: { Label("PDF…", systemImage: "doc.richtext") }
                    Button { m.saveImages() } label: { Label("Images…", systemImage: "photo.on.rectangle") }
                    if !m.lines.isEmpty {
                        Button { m.saveTranscript() } label: { Label("Transcript…", systemImage: "text.alignleft") }
                    }
                    Spacer()
                    Toggle("Put the original video in the Media Bin", isOn: $m.includeVideo).toggleStyle(.checkbox)
                    Button { m.saveCamtasia() } label: {
                        Label("Camtasia Project…", systemImage: "square.and.arrow.up").padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(m.wav == nil)
                    .help(m.wav == nil ? "This video has no sound." : "Slides on track 1, timed to the video; the sound on track 2")
                }
                .disabled(m.busy)
                if let st = m.status { HStack { ProgressView().controlSize(.small); Text(st) } }
                if let p = m.problem { Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if !Session.shared.searches.isEmpty, !m.lines.isEmpty {
                    Text("Your keywords (\(Session.shared.searches.joined(separator: ", "))) are added as markers in the Camtasia project.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Shared drop screen

struct StudioDrop: View {
    let title: String
    let detail: String
    let icon: String
    let colour: Color
    let types: [UTType]
    var multiple = false
    var problem: String? = nil
    let onFile: (URL) -> Void
    var onFiles: (([URL]) -> Void)? = nil
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 46)).foregroundStyle(colour)
                Text(title).font(.title2.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                Button("Choose…") { choose() }.controlSize(.large)
            }
            .padding(40)
            .frame(maxWidth: 680)
            .background(RoundedRectangle(cornerRadius: 18).fill(targeted ? colour.opacity(0.10) : Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                .foregroundStyle(targeted ? colour : Color.secondary.opacity(0.45)))
            .dropDestination(for: URL.self) { urls, _ in
                deliver(urls)
                return !urls.isEmpty
            } isTargeted: { targeted = $0 }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deliver(_ urls: [URL]) {
        if let onFiles { onFiles(urls) } else if let u = urls.first { onFile(u) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = multiple
        if panel.runModal() == .OK { deliver(panel.urls) }
    }
}
