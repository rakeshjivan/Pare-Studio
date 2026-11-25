// Turn a video into slides. Same steps and controls as Pare PDF's Video to Slides:
//   1 · Choose & detect   scrub the video, crop the slide area, pick sampling/sensitivity/settle options
//   2 · Review            check the captured slides against the video, add missed frames (C), pick slides
//   3 · Download          PowerPoint (speaker notes), PDF, smaller PDF, images (ZIP), Word transcript, Camtasia
// Slide finding and transcription run side by side; transcription is split across cores.

import SwiftUI
import AppKit
import AVFoundation
import PDFKit
import UniformTypeIdentifiers

/// One captured slide and every time it appears in the video.
struct Capture: Identifiable {
    let id = UUID()
    var url: URL
    var thumb: NSImage?
    var size: CGSize
    var times: [Double]
    var selected = true
    var first: Double { times.min() ?? 0 }
}

@MainActor
final class VideoSlides: ObservableObject {
    static let shared = VideoSlides()

    enum Step: Int, CaseIterable, Identifiable {
        case detect, review, download
        var id: Int { rawValue }
        var title: String {
            switch self { case .detect: return "1 · Choose & detect"; case .review: return "2 · Review"; case .download: return "3 · Download" }
        }
    }
    enum Sampling: Double, CaseIterable, Identifiable {
        case one = 1, two = 2, five = 5
        var id: Double { rawValue }
        var label: String {
            switch self { case .one: return "1 second · more detail"; case .two: return "2 seconds · balanced"; case .five: return "5 seconds · faster" }
        }
    }
    enum Detection: String, CaseIterable, Identifiable {
        case changes = "Slide changes", every = "Every sampled frame"
        var id: String { rawValue }
    }
    enum Sensitivity: String, CaseIterable, Identifiable {
        case high = "High · subtle changes", balanced = "Balanced", low = "Low · fewer slides"
        var id: String { rawValue }
        var threshold: Double {
            switch self { case .high: return 0.02; case .balanced: return 0.05; case .low: return 0.12 }
        }
    }
    enum Settle: Double, CaseIterable, Identifiable {
        case one = 1, two = 2, four = 4
        var id: Double { rawValue }
        var label: String {
            switch self { case .one: return "1 second · short slides"; case .two: return "2 seconds · webinars"; case .four: return "4 seconds · more motion filtering" }
        }
    }
    enum Output: String, CaseIterable, Identifiable {
        case pptx = "PowerPoint", pdf = "Standard PDF", smallPDF = "Compressed PDF", zip = "Slide images (ZIP)",
             word = "Word transcript", camtasia = "Camtasia project"
        var id: String { rawValue }
        var detail: String {
            switch self {
            case .pptx: return "One slide per capture. If the recording was transcribed, what was said on each slide becomes its speaker notes."
            case .pdf: return "Faithful, full-quality pages."
            case .smallPDF: return "Smaller file for emailing and sharing."
            case .zip: return "The selected slides as numbered JPG files, in the current slide order."
            case .word: return "An editable transcript, with a heading wherever the slide changes."
            case .camtasia: return "Slides on track 1 at the times they appear, the sound on track 2, every slide in the Media Bin."
            }
        }
        var ext: String {
            switch self { case .pptx: return "pptx"; case .pdf, .smallPDF: return "pdf"; case .zip: return "zip"; case .word: return "docx"; case .camtasia: return "cmproj" }
        }
    }

    // Recording
    @Published var video: URL?
    @Published var duration: Double = 0
    @Published var aspect: CGFloat = 16.0 / 9.0
    let player = AVPlayer()
    @Published var time: Double = 0
    @Published var playing = false
    private var observer: Any?

    // Settings (the same choices as Pare PDF)
    @Published var step: Step = .detect
    @Published var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var sampling: Sampling = .two
    @Published var detection: Detection = .changes
    @Published var sensitivity: Sensitivity = .balanced
    @Published var startAt = ""
    @Published var stopAt = ""
    @Published var settle: Settle = .two
    @Published var keepFirstOnly = true
    @Published var keepCompletedBuild = true
    @Published var transcribe = true

    // Results
    @Published var captures: [Capture] = []
    @Published var lines: [Line] = []
    @Published var wav: URL?
    @Published var listening: String?

    // Download
    @Published var output: Output = .pptx
    @Published var fileName = ""
    @Published var includeVideo = true

    @Published var status: String?
    @Published var progress: Double?
    @Published var problem: String?
    @Published var message: String?
    @Published var busy = false

    private(set) var work: URL = VideoSlides.newWork()
    private var task: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?

    static func newWork() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("PareStudioVS-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    var name: String { video?.deletingPathExtension().lastPathComponent ?? "Slides" }
    var selected: [Capture] { captures.filter(\.selected) }

    // MARK: Recording and playback

    func open(_ url: URL) {
        guard !busy else { return }
        reset()
        Task {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
                problem = "That file has no picture. Use a video of the talk (MP4, MOV or M4V)."
                return
            }
            video = url
            fileName = url.deletingPathExtension().lastPathComponent
            let d = (try? await asset.load(.duration).seconds) ?? 0
            duration = d.isFinite ? d : 0
            if let size = try? await track.load(.naturalSize), let tf = try? await track.load(.preferredTransform) {
                let s = size.applying(tf)
                if abs(s.height) > 0 { aspect = abs(s.width) / abs(s.height) }
            }
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            if observer == nil {
                observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if t.seconds.isFinite { self.time = t.seconds }
                        self.playing = self.player.rate > 0
                    }
                }
            }
            seek(min(5, duration * 0.1))
        }
    }

    func reset() {
        task?.cancel(); audioTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        video = nil; duration = 0; time = 0; aspect = 16.0 / 9.0
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        startAt = ""; stopAt = ""
        captures = []; lines = []; wav = nil; listening = nil
        status = nil; progress = nil; problem = nil; message = nil; busy = false
        step = .detect
        try? FileManager.default.removeItem(at: work)
        work = VideoSlides.newWork()
    }

    func seek(_ t: Double, exact: Bool = true) {
        let c = CMTime(seconds: max(0, min(duration, t)), preferredTimescale: 600)
        let tol = exact ? CMTime.zero : CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: c, toleranceBefore: tol, toleranceAfter: tol)
        time = c.seconds
    }

    func togglePlay() {
        if player.rate > 0 { player.pause() } else { player.play() }
        playing = player.rate > 0
    }

    func nudge(_ by: Double) { player.pause(); seek(time + by) }

    // MARK: Crop presets

    func fullFrame() { crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
    func presenterLeft() { crop = CGRect(x: 0.25, y: 0, width: 0.75, height: 1) }
    func presenterRight() { crop = CGRect(x: 0, y: 0, width: 0.75, height: 1) }

    /// Edges as percentages, for the precise crop fields.
    func edge(_ e: Edge) -> Int {
        switch e {
        case .leading: return Int((crop.minX * 100).rounded())
        case .top: return Int((crop.minY * 100).rounded())
        case .trailing: return Int(((1 - crop.maxX) * 100).rounded())
        case .bottom: return Int(((1 - crop.maxY) * 100).rounded())
        }
    }

    func setEdge(_ e: Edge, _ pct: Int) {
        let v = CGFloat(min(95, max(0, pct))) / 100
        var l = crop.minX, t = crop.minY, r = 1 - crop.maxX, b = 1 - crop.maxY
        switch e { case .leading: l = v; case .top: t = v; case .trailing: r = v; case .bottom: b = v }
        guard 1 - l - r > 0.05, 1 - t - b > 0.05 else { return }
        crop = CGRect(x: l, y: t, width: 1 - l - r, height: 1 - t - b)
    }

    // MARK: Finding slides

    func findSlides() {
        guard let video, !busy else { return }
        busy = true
        problem = nil
        message = nil
        player.pause()
        let crop = self.crop, work = self.work, duration = self.duration
        let opts = SlideFinder.Options(step: sampling.rawValue, threshold: sensitivity.threshold, everyFrame: detection == .every,
                                       settle: settle.rawValue, keepFirstOnly: keepFirstOnly, keepCompletedBuild: keepCompletedBuild,
                                       from: Double(startAt.trimmed).map { max(0, $0) } ?? 0,
                                       to: Double(stopAt.trimmed).map { min(duration, $0) } ?? duration)
        // The sound (and, if asked, the transcript) are worked out at the same time.
        startAudio()
        task = Task {
            defer { busy = false; status = nil; progress = nil }
            do {
                status = "Looking for slides…"
                let found = try await SlideFinder.scan(video, crop: crop, options: opts, duration: duration) { f in
                    Task { @MainActor in VideoSlides.shared.progress = f }
                }
                try Task.checkCancellation()
                guard !found.captureTimes.isEmpty else { throw PGError("No slides were found. Try High sensitivity, or Every sampled frame.") }
                status = "Saving each slide in full quality…"
                progress = nil
                let files = try await SlideFinder.capture(video, crop: crop, times: found.captureTimes, work: work)
                var list: [Capture] = []
                for (i, f) in files.enumerated() {
                    let img = NSImage(contentsOf: f)
                    let rep = img?.representations.first
                    let size = rep.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? CGSize(width: 1920, height: 1080)
                    let times = found.spans.filter { $0.slide == i }.map(\.start)
                    list.append(Capture(url: f, thumb: img, size: size, times: times.isEmpty ? [found.captureTimes[i]] : times))
                }
                captures = list.sorted { $0.first < $1.first }
                let n = captures.count
                message = "Found \(n) slide\(n == 1 ? "" : "s"). Check them against the video and add any that were missed."
                step = .review
            } catch is CancellationError {
                message = "Stopped."
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    func stop() { task?.cancel() }

    private func startAudio() {
        guard let video, wav == nil || (transcribe && lines.isEmpty), audioTask == nil else { return }
        let work = self.work, wantWords = transcribe
        audioTask = Task {
            defer { audioTask = nil }
            if wav == nil {
                listening = "Taking the sound out…"
                wav = try? await Audio.extract(video, work: work)
            }
            if wantWords, lines.isEmpty, let w = wav {
                listening = "Transcribing on this Mac…"
                lines = (try? await Transcriber.transcribe(w) { f in
                    Task { @MainActor in VideoSlides.shared.listening = "Transcribing on this Mac… \(Int(f * 100))%" }
                }) ?? []
            }
            listening = nil
        }
    }

    /// Transcribes without finding slides (for the Word transcript).
    func transcribeOnly() {
        transcribe = true
        startAudio()
    }

    // MARK: Review

    /// Captures the frame under the playhead as a slide (key C).
    func addFrameAtPlayhead() {
        guard let video else { return }
        let t = time, crop = self.crop, work = self.work
        Task {
            do {
                let files = try await SlideFinder.capture(video, crop: crop, times: [t], work: work)
                guard let f = files.first else { return }
                let img = NSImage(contentsOf: f)
                let size = img?.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? CGSize(width: 1920, height: 1080)
                captures.append(Capture(url: f, thumb: img, size: size, times: [t]))
                captures.sort { $0.first < $1.first }
                message = "Added the frame at \(Keywords.hms(t))."
                if step == .detect { step = .review }
            } catch { problem = error.localizedDescription }
        }
    }

    func keepAll() { for i in captures.indices { captures[i].selected = true } }
    func clearSelection() { for i in captures.indices { captures[i].selected = false } }
    func toggle(_ id: UUID) { if let i = captures.firstIndex(where: { $0.id == id }) { captures[i].selected.toggle() } }
    func delete(_ id: UUID) { captures.removeAll { $0.id == id } }
    func move(_ id: UUID, by d: Int) {
        guard let i = captures.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard captures.indices.contains(j) else { return }
        captures.swapAt(i, j)
    }

    /// When each selected slide is on screen: (start, end, index into `selected`).
    func timeline() -> [(start: Double, end: Double, slide: Int)] {
        let sel = selected
        var marks: [(Double, Int)] = []
        for (i, c) in sel.enumerated() { for t in c.times { marks.append((t, i)) } }
        marks.sort { $0.0 < $1.0 }
        return marks.enumerated().map { k, m in (m.0, k + 1 < marks.count ? marks[k + 1].0 : duration, m.1) }
    }

    /// What was said while each selected slide was on screen. Notes follow the video's timings.
    func notes() -> [[String]] {
        let tl = timeline()
        return selected.indices.map { i in
            let mine = tl.filter { $0.slide == i }
            return lines.filter { l in mine.contains { l.start >= $0.start - 0.2 && l.start < $0.end } }
                .map { "[\(Keywords.hms($0.start))] \($0.text)" }
        }
    }

    // MARK: Download

    func download() {
        let sel = selected
        guard output == .word || !sel.isEmpty else { problem = "Select at least one slide."; return }
        if output == .word && lines.isEmpty {
            problem = listening != nil ? "The transcript isn't ready yet: \(listening ?? "")" : "Transcribe the recording first (button below)."
            return
        }
        let base = fileName.trimmed.isEmpty ? name : fileName.trimmed
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = base + (output == .smallPDF ? " (small)" : "") + "." + output.ext
        if output != .camtasia { panel.allowedContentTypes = [UTType(filenameExtension: output.ext) ?? .data] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        problem = nil
        let out = output
        switch out {
        case .pptx:
            let notes = notes()
            run("Making the PowerPoint…") { try Office.pptx(images: sel.map(\.url), notes: notes, to: url); return url }
        case .pdf, .smallPDF:
            run("Making the PDF…") { try SlideFinder.pdf(sel.map(\.url), small: out == .smallPDF, to: url); return url }
        case .zip:
            run("Saving the slide images…") { try SlideFinder.zip(sel.map(\.url), to: url); return url }
        case .word:
            let tl = timeline(), lines = self.lines
            run("Making the transcript…") {
                var paras: [(time: String?, text: String)] = []
                var last = -1
                for l in lines {
                    let s = tl.last { $0.start <= l.start + 0.2 }?.slide ?? 0
                    if !tl.isEmpty, s != last { paras.append((nil, "— Slide \(s + 1) —")); last = s }
                    paras.append((Keywords.hms(l.start), l.text))
                }
                try Office.docx(title: base, paragraphs: paras, to: url)
                return url
            }
        case .camtasia:
            guard let wav, let video else { problem = wav == nil && listening != nil ? "The sound is still being prepared. Try again in a moment." : "This video has no sound."; return }
            let slides = sel.enumerated().map { i, c -> Slide in
                var s = Slide(number: i + 1, url: c.url)
                s.size = c.size
                return s
            }
            let cues = Matcher.tidy(timeline().map { Cue(slide: $0.slide, start: $0.start) }, slideCount: slides.count, duration: duration)
            let plan = Export.Plan(slides: slides, cues: cues, duration: duration, wav: wav, recording: video,
                                   includeRecording: includeVideo, title: base,
                                   finds: Keywords.find(Session.shared.searches, in: lines))
            run("Making the Camtasia project…") {
                try Export.camtasia(plan, to: url)
                return url.pathExtension.lowercased() == "cmproj" ? url : url.appendingPathExtension("cmproj")
            }
        }
    }

    private func run(_ what: String, _ job: @escaping @Sendable () throws -> URL) {
        busy = true
        status = what
        Task {
            do {
                let made = try await Task.detached(priority: .userInitiated) { try job() }.value
                NSWorkspace.shared.activateFileViewerSelecting([made])
                message = "Saved \(made.lastPathComponent)."
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
    struct Options {
        var step: Double
        var threshold: Double
        var everyFrame: Bool
        var settle: Double
        var keepFirstOnly: Bool
        var keepCompletedBuild: Bool
        var from: Double
        var to: Double
    }

    struct Result {
        var spans: [SlideSpan]
        var captureTimes: [Double]      // one per captured slide
    }

    struct SlideSpan { var start: Double; var end: Double; var slide: Int }

    static let sigW = 64, sigH = 36

    /// A tiny grey picture of the slide area, for comparing frames.
    static func signature(_ img: CGImage, crop: CGRect) -> [UInt8] {
        let part = cropped(img, crop)
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

    static func cropped(_ img: CGImage, _ crop: CGRect) -> CGImage {
        let r = CGRect(x: crop.minX * CGFloat(img.width), y: crop.minY * CGFloat(img.height),
                       width: crop.width * CGFloat(img.width), height: crop.height * CGFloat(img.height)).integral
        return img.cropping(to: r) ?? img
    }

    /// Share of the picture that changed noticeably (0–1).
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var n = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 28 { n += 1 }
        return Double(n) / Double(a.count)
    }

    /// True when the new frame looks like the old one with more content added (an animation build):
    /// most changed pixels were plain background before, and the rest of the slide stayed put.
    static func isBuild(from a: [UInt8], to b: [UInt8]) -> Bool {
        var hist = [Int](repeating: 0, count: 16)
        for v in a { hist[Int(v) >> 4] += 1 }
        let bg = ((hist.indices.max { hist[$0] < hist[$1] } ?? 0) << 4) + 8
        var changed = 0, wasBackground = 0
        for i in 0..<min(a.count, b.count) where abs(Int(a[i]) - Int(b[i])) > 28 {
            changed += 1
            if abs(Int(a[i]) - bg) <= 24 { wasBackground += 1 }
        }
        guard changed > 0 else { return true }
        return Double(changed) / Double(a.count) < 0.35 && Double(wasBackground) / Double(changed) >= 0.7
    }

    /// Frames at the given times, fast: the generator may use the nearest key frame within the tolerance.
    static func frames(_ url: URL, times: [Double], maxSize: CGSize?, tolerance: Double,
                       each: @escaping @Sendable (Int, Double, CGImage?) -> Void) async {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        if let maxSize { gen.maximumSize = maxSize }
        let tol = CMTime(seconds: tolerance, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        let values = times.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
        let done = Counter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                guard !values.isEmpty else { c.resume(); return }
                gen.generateCGImagesAsynchronously(forTimes: values) { requested, image, _, result, _ in
                    let n = done.add()
                    let i = times.firstIndex { abs($0 - requested.seconds) < 0.001 } ?? (n - 1)
                    each(i, requested.seconds, result == .succeeded ? image : nil)
                    if n == values.count { c.resume() }
                }
            }
        } onCancel: {
            gen.cancelAllCGImageGeneration()
        }
    }

    static func scan(_ url: URL, crop: CGRect, options o: Options, duration: Double,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        let start = max(0, o.from), stop = max(start + 0.5, min(duration, o.to))
        var times: [Double] = []
        var t = start
        while t < stop { times.append(t); t += o.step }
        guard !times.isEmpty else { return Result(spans: [], captureTimes: []) }

        // Small frames, snapped to key frames: much less decoding work.
        let store = SigStore(count: times.count)
        await frames(url, times: times, maxSize: CGSize(width: 480, height: 480), tolerance: o.step / 2) { i, _, img in
            if let img { store.set(i, signature(img, crop: crop)) }
            progress(store.progress)
        }
        try Task.checkCancellation()
        let samples: [(t: Double, sig: [UInt8])] = times.indices.compactMap { i in store.get(i).map { (times[i], $0) } }
        guard !samples.isEmpty else { return Result(spans: [], captureTimes: []) }

        struct Seg { var start: Double; var end: Double; var lastT: Double; var lastSig: [UInt8] }
        var segs: [Seg] = []
        if o.everyFrame {
            for s in samples {
                if let last = segs.last, difference(last.lastSig, s.sig) < 0.005 {
                    segs[segs.count - 1].end = s.t + o.step
                    segs[segs.count - 1].lastT = s.t
                    segs[segs.count - 1].lastSig = s.sig
                } else {
                    segs.append(Seg(start: s.t, end: s.t + o.step, lastT: s.t, lastSig: s.sig))
                }
            }
        } else {
            // Stretches of near-identical frames; animation builds can stay on one slide.
            var ref = samples[0].sig
            segs = [Seg(start: samples[0].t, end: samples[0].t, lastT: samples[0].t, lastSig: samples[0].sig)]
            for s in samples.dropFirst() {
                let d = difference(s.sig, ref)
                if d > o.threshold && !(o.keepCompletedBuild && isBuild(from: ref, to: s.sig)) {
                    segs[segs.count - 1].end = s.t
                    segs.append(Seg(start: s.t, end: s.t, lastT: s.t, lastSig: s.sig))
                } else {
                    // Same slide: keep the latest settled picture (so a finished build is what's saved).
                    segs[segs.count - 1].end = s.t
                    segs[segs.count - 1].lastT = s.t
                    segs[segs.count - 1].lastSig = s.sig
                }
                if d > o.threshold { ref = s.sig }
            }
            segs[segs.count - 1].end = stop
            // A slide must stay still for the settle time; shorter stretches are transitions or motion.
            var kept: [Seg] = []
            var carry: Double?
            for (i, seg) in segs.enumerated() {
                var s = seg
                if let c = carry { s.start = c; carry = nil }
                if s.end - s.start < o.settle && i < segs.count - 1 { carry = s.start; continue }
                kept.append(s)
            }
            if kept.isEmpty, let l = segs.last { kept = [l] }
            segs = kept
        }

        // Repeated slides reuse their first picture (if chosen).
        var unique: [[UInt8]] = []
        var captureTimes: [Double] = []
        var spans: [SlideSpan] = []
        for s in segs {
            var idx: Int?
            if o.keepFirstOnly { idx = unique.firstIndex { difference($0, s.lastSig) < max(0.01, o.threshold * 0.6) } }
            if idx == nil {
                unique.append(s.lastSig)
                captureTimes.append(s.lastT)
                idx = unique.count - 1
            }
            if let last = spans.last, last.slide == idx! { spans[spans.count - 1].end = s.end }
            else { spans.append(SlideSpan(start: s.start, end: s.end, slide: idx!)) }
        }
        if !spans.isEmpty { spans[0].start = min(spans[0].start, start) }
        return Result(spans: spans, captureTimes: captureTimes)
    }

    /// Full-quality pictures of each slide, cropped to the slide area.
    static func capture(_ url: URL, crop: CGRect, times: [Double], work: URL) async throws -> [URL] {
        let dir = work.appendingPathComponent("slides-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = URLStore(count: times.count)
        await frames(url, times: times, maxSize: nil, tolerance: 0.05) { i, _, img in
            guard let img else { return }
            let rep = NSBitmapImageRep(cgImage: cropped(img, crop))
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            let f = dir.appendingPathComponent(String(format: "Slide %03d.png", i + 1))
            if (try? png.write(to: f)) != nil { out.set(i, f) }
        }
        try Task.checkCancellation()
        let files = (0..<times.count).compactMap { out.get($0) }
        guard files.count == times.count else { throw PGError("Couldn't read some of the video frames.") }
        return files
    }

    /// A PDF, one slide per page. Small: JPEG pictures at up to 1600 px wide.
    static func pdf(_ images: [URL], small: Bool, to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else { throw PGError("Couldn't save the PDF.") }
        var box = CGRect(x: 0, y: 0, width: 1280, height: 720)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw PGError("Couldn't save the PDF.") }
        for f in images {
            guard let src = CGImageSourceCreateWithURL(f as CFURL, nil), var img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            if small {
                let scale = min(1, 1600 / CGFloat(img.width))
                let w = Int(CGFloat(img.width) * scale), h = Int(CGFloat(img.height) * scale)
                if let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                    c.interpolationQuality = .high
                    c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                    if let shrunk = c.makeImage(),
                       let jpg = NSBitmapImageRep(cgImage: shrunk).representation(using: .jpeg, properties: [.compressionFactor: 0.72]),
                       let prov = CGDataProvider(data: jpg as CFData),
                       let j = CGImage(jpegDataProviderSource: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                        img = j
                    }
                }
            }
            var page = CGRect(x: 0, y: 0, width: CGFloat(img.width), height: CGFloat(img.height))
            let pageInfo = [kCGPDFContextMediaBox as String: NSData(bytes: &page, length: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(pageInfo)
            ctx.draw(img, in: page)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// The slides as numbered JPG files in a ZIP.
    static func zip(_ images: [URL], to url: URL) throws {
        let d = try Office.tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        for (i, f) in images.enumerated() {
            guard let img = NSImage(contentsOf: f), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { continue }
            try jpg.write(to: d.appendingPathComponent(String(format: "Slide %02d.jpg", i + 1)))
        }
        try Office.zip(d, to: url)
    }
}

/// Thread-safe slots for results that arrive out of order.
final class SigStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[UInt8]?]
    private var filled = 0
    init(count: Int) { items = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ v: [UInt8]) { lock.withLock { if i < items.count, items[i] == nil { items[i] = v; filled += 1 } } }
    func get(_ i: Int) -> [UInt8]? { lock.withLock { i < items.count ? items[i] : nil } }
    var progress: Double { lock.withLock { Double(filled) / Double(max(1, items.count)) } }
}

final class URLStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL?]
    init(count: Int) { items = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ v: URL) { lock.withLock { if i < items.count { items[i] = v } } }
    func get(_ i: Int) -> URL? { lock.withLock { i < items.count ? items[i] : nil } }
}

// MARK: - Screens

struct VideoSlidesView: View {
    @ObservedObject private var m = VideoSlides.shared

    var body: some View {
        if m.video == nil {
            StudioDrop(title: "Choose a video of a talk or webinar",
                       detail: "MP4, MOV or M4V. Pare Studio finds each slide, then saves a PowerPoint, a PDF, the images, a Word transcript or a Camtasia project. Your recording stays on this Mac.",
                       icon: "rectangle.stack.badge.play.fill", colour: Screen.videoSlides.colour,
                       types: [.movie, .mpeg4Movie, .quickTimeMovie], problem: m.problem) { m.open($0) }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(VideoSlides.Step.allCases) { s in
                        Button { m.step = s } label: {
                            Text(s.title).font(.callout.weight(m.step == s ? .semibold : .regular))
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Capsule().fill(m.step == s ? Screen.videoSlides.colour.opacity(0.18) : Color.clear))
                        }
                        .buttonStyle(.plain)
                        .disabled(s != .detect && m.captures.isEmpty && !(s == .download && !m.lines.isEmpty))
                    }
                    Spacer()
                    if let l = m.listening { HStack(spacing: 6) { ProgressView().controlSize(.small); Text(l).font(.caption).foregroundStyle(.secondary) } }
                    Button("Different Video") { m.reset() }.disabled(m.busy)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
                switch m.step {
                case .detect: DetectStep()
                case .review: ReviewStep()
                case .download: DownloadStep()
                }
            }
        }
    }
}

/// The video, a scrubber and (in step 1) the crop box.
struct PlayerPanel: View {
    @ObservedObject private var m = VideoSlides.shared
    let showCrop: Bool
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let size = fit(geo.size)
                ZStack {
                    VideoSurface(player: m.player)
                        .frame(width: size.width, height: size.height)
                    if showCrop {
                        CropEditor(crop: $m.crop, size: size).frame(width: size.width, height: size.height)
                    } else if m.crop != CGRect(x: 0, y: 0, width: 1, height: 1) {
                        ZStack(alignment: .topLeading) {
                            Rectangle().strokeBorder(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                .frame(width: m.crop.width * size.width, height: m.crop.height * size.height)
                                .offset(x: m.crop.minX * size.width, y: m.crop.minY * size.height)
                        }
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .allowsHitTesting(false)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            HStack(spacing: 8) {
                Button { m.togglePlay() } label: { Image(systemName: m.playing ? "pause.fill" : "play.fill").frame(width: 18) }
                    .keyboardShortcut(.space, modifiers: [])
                Button { m.nudge(-5) } label: { Image(systemName: "gobackward.5") }.help("Back 5 seconds")
                Button { m.nudge(-1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: []).help("Back 1 second (←)")
                Button { m.nudge(1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: []).help("Forward 1 second (→)")
                Button { m.nudge(5) } label: { Image(systemName: "goforward.5") }.help("Forward 5 seconds")
                Slider(value: Binding(get: { m.time }, set: { m.player.pause(); m.seek($0, exact: false) }),
                       in: 0...max(1, m.duration)) { editing in
                    if !editing { m.seek(m.time, exact: true) }
                }
                Text("\(label) · \(Keywords.hms(m.time)) / \(Keywords.hms(m.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            }
            .buttonStyle(.borderless)
        }
    }

    private func fit(_ box: CGSize) -> CGSize {
        let w = min(box.width, box.height * m.aspect)
        return CGSize(width: max(1, w), height: max(1, w / m.aspect))
    }
}

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        return v
    }
    func updateNSView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// Crop box with handles on every corner and edge; drag inside to move it.
struct CropEditor: View {
    @Binding var crop: CGRect
    let size: CGSize
    @State private var startCrop: CGRect?

    enum Grip: CaseIterable { case tl, t, tr, r, br, b, bl, l }

    var body: some View {
        let r = CGRect(x: crop.minX * size.width, y: crop.minY * size.height, width: crop.width * size.width, height: crop.height * size.height)
        ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 2))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .gesture(DragGesture()
                    .onChanged { g in
                        let s = startCrop ?? crop
                        startCrop = s
                        var x = s.minX + g.translation.width / size.width
                        var y = s.minY + g.translation.height / size.height
                        x = min(max(0, x), 1 - s.width); y = min(max(0, y), 1 - s.height)
                        crop = CGRect(x: x, y: y, width: s.width, height: s.height)
                    }
                    .onEnded { _ in startCrop = nil })
            ForEach(Grip.allCases, id: \.self) { g in
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .position(point(g, r))
                    .gesture(DragGesture()
                        .onChanged { v in
                            let s = startCrop ?? crop
                            startCrop = s
                            crop = resized(s, g, dx: v.translation.width / size.width, dy: v.translation.height / size.height)
                        }
                        .onEnded { _ in startCrop = nil })
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func point(_ g: Grip, _ r: CGRect) -> CGPoint {
        switch g {
        case .tl: return CGPoint(x: r.minX, y: r.minY)
        case .t: return CGPoint(x: r.midX, y: r.minY)
        case .tr: return CGPoint(x: r.maxX, y: r.minY)
        case .r: return CGPoint(x: r.maxX, y: r.midY)
        case .br: return CGPoint(x: r.maxX, y: r.maxY)
        case .b: return CGPoint(x: r.midX, y: r.maxY)
        case .bl: return CGPoint(x: r.minX, y: r.maxY)
        case .l: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    private func resized(_ s: CGRect, _ g: Grip, dx: CGFloat, dy: CGFloat) -> CGRect {
        var l = s.minX, t = s.minY, r = s.maxX, b = s.maxY
        let minSide: CGFloat = 0.05
        if [Grip.tl, .l, .bl].contains(g) { l = min(max(0, l + dx), r - minSide) }
        if [Grip.tr, .r, .br].contains(g) { r = max(min(1, r + dx), l + minSide) }
        if [Grip.tl, .t, .tr].contains(g) { t = min(max(0, t + dy), b - minSide) }
        if [Grip.bl, .b, .br].contains(g) { b = max(min(1, b + dy), t + minSide) }
        return CGRect(x: l, y: t, width: r - l, height: b - t)
    }
}

struct DetectStep: View {
    @ObservedObject private var m = VideoSlides.shared

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Crop the slide area").font(.headline)
                Text("Use the playhead to find a clear slide, then drag the crop handles. Drag inside to move the selection. The crop is used to find slides and in everything you save.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                PlayerPanel(showCrop: true, label: "Crop playhead")
                HStack(spacing: 10) {
                    Button("Full frame") { m.fullFrame() }
                    Button("Presenter on the left") { m.presenterLeft() }
                    Button("Presenter on the right") { m.presenterRight() }
                    Spacer()
                    Button { m.addFrameAtPlayhead() } label: { Label("Add frame at playhead", systemImage: "plus.rectangle.on.rectangle") }
                        .keyboardShortcut("c", modifiers: [])
                        .help("Saves the frame under the playhead as a slide (C)")
                }
                HStack(spacing: 10) {
                    Text("Precise crop · percentages").font(.caption).foregroundStyle(.secondary)
                    PercentField(label: "Left %", edge: .leading)
                    PercentField(label: "Top %", edge: .top)
                    PercentField(label: "Right %", edge: .trailing)
                    PercentField(label: "Bottom %", edge: .bottom)
                }
            }
            .frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledPicker("Sample every", selection: $m.sampling, options: VideoSlides.Sampling.allCases) { $0.label }
                    LabeledPicker("Detection", selection: $m.detection, options: VideoSlides.Detection.allCases) { $0.rawValue }
                    LabeledPicker("Sensitivity", selection: $m.sensitivity, options: VideoSlides.Sensitivity.allCases) { $0.rawValue }
                    LabeledPicker("Wait for a slide to settle", selection: $m.settle, options: VideoSlides.Settle.allCases) { $0.label }
                        .disabled(m.detection == .every)
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Start at (seconds)").font(.caption)
                            HStack(spacing: 4) {
                                TextField("0", text: $m.startAt).frame(width: 70)
                                Button { m.startAt = String(Int(m.time)) } label: { Image(systemName: "scope") }
                                    .buttonStyle(.borderless).help("Use the playhead")
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Stop at (seconds)").font(.caption)
                            HStack(spacing: 4) {
                                TextField(String(Int(m.duration)), text: $m.stopAt).frame(width: 70)
                                Button { m.stopAt = String(Int(m.time)) } label: { Image(systemName: "scope") }
                                    .buttonStyle(.borderless).help("Use the playhead")
                            }
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    Toggle("Repeated slides: keep first occurrence only", isOn: $m.keepFirstOnly)
                    Toggle("Animation builds: keep the completed build", isOn: $m.keepCompletedBuild)
                        .disabled(m.detection == .every)
                    Toggle(isOn: $m.transcribe) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Also transcribe what's said")
                            Text("For speaker notes, the Word transcript and Camtasia keyword markers. Runs at the same time as finding slides.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                    if let st = m.status {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(st).font(.callout)
                            if let p = m.progress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
                        }
                    }
                    if let p = m.problem { Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    if let msg = m.message { Text(msg).font(.callout).foregroundStyle(.secondary) }
                    HStack {
                        if m.busy { Button("Stop analysis") { m.stop() } }
                        Spacer()
                        Button { m.findSlides() } label: {
                            Label("Find slides", systemImage: "wand.and.stars").padding(.horizontal, 8).padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(m.busy)
                    }
                    Text("Settled-frame detection skips moving scenes and slides shown too briefly. Animation grouping and duplicate filtering are estimates: review the results and add any missed frame from the video.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.trailing, 6)
            }
            .frame(width: 330)
        }
        .padding(16)
    }
}

struct PercentField: View {
    @ObservedObject private var m = VideoSlides.shared
    let label: String
    let edge: Edge
    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", value: Binding(get: { m.edge(edge) }, set: { m.setEdge(edge, $0) }), format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 44)
        }
    }
}

struct LabeledPicker<T: Hashable & Identifiable>: View {
    let title: String
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    init(_ title: String, selection: Binding<T>, options: [T], label: @escaping (T) -> String) {
        self.title = title; self._selection = selection; self.options = options; self.label = label
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium))
            Picker(title, selection: $selection) {
                ForEach(options) { Text(label($0)).tag($0) }
            }
            .labelsHidden()
        }
    }
}

struct ReviewStep: View {
    @ObservedObject private var m = VideoSlides.shared
    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12)]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recording preview").font(.headline)
                Text("Drag to a missed slide, then choose Add frame at playhead (or press C). Click a slide on the right to jump to it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                PlayerPanel(showCrop: false, label: "Video playhead")
                HStack {
                    Button { m.addFrameAtPlayhead() } label: { Label("Add frame at playhead", systemImage: "plus.rectangle.on.rectangle") }
                        .keyboardShortcut("c", modifiers: [])
                    Spacer()
                    Button("Change crop or settings") { m.step = .detect }
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Review your slides").font(.headline)
                    Text("\(m.selected.count) of \(m.captures.count) selected").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Keep all") { m.keepAll() }
                    Button("Clear selection") { m.clearSelection() }
                }
                if let msg = m.message { Text(msg).font(.caption).foregroundStyle(.secondary) }
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(m.captures.enumerated()), id: \.element.id) { i, c in
                            CaptureCard(capture: c, number: i + 1, current: currentID == c.id)
                        }
                    }
                    .padding(2)
                }
                HStack {
                    Spacer()
                    Button { m.step = .download } label: { Label("Continue to download", systemImage: "arrow.right").padding(.horizontal, 6) }
                        .buttonStyle(.borderedProminent).disabled(m.selected.isEmpty)
                }
            }
            .frame(width: 460)
        }
        .padding(16)
    }

    /// The slide showing at the playhead.
    private var currentID: UUID? {
        let tl = m.captures.flatMap { cap in cap.times.map { (t: $0, id: cap.id) } }.sorted { $0.t < $1.t }
        return tl.last { $0.t <= m.time + 0.05 }?.id
    }
}

struct CaptureCard: View {
    @ObservedObject private var m = VideoSlides.shared
    let capture: Capture
    let number: Int
    let current: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let t = capture.thumb { Image(nsImage: t).resizable().aspectRatio(contentMode: .fit) }
                    else { Rectangle().fill(.quaternary).aspectRatio(16.0 / 9.0, contentMode: .fit) }
                }
                .opacity(capture.selected ? 1 : 0.4)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(current ? Screen.videoSlides.colour : Color.secondary.opacity(0.3),
                                                                       lineWidth: current ? 3 : 1))
                .onTapGesture { m.player.pause(); m.seek(capture.first) }
                Toggle("", isOn: Binding(get: { capture.selected }, set: { _ in m.toggle(capture.id) }))
                    .toggleStyle(.checkbox).labelsHidden().padding(6)
            }
            HStack(spacing: 4) {
                Text("Slide \(number)").font(.caption.weight(.semibold))
                Spacer()
                Text(capture.times.sorted().prefix(2).map { Keywords.hms($0) }.joined(separator: ", ") + (capture.times.count > 2 ? "…" : ""))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contextMenu {
            Button("Move earlier in the deck") { m.move(capture.id, by: -1) }
            Button("Move later in the deck") { m.move(capture.id, by: 1) }
            Divider()
            Button("Delete", role: .destructive) { m.delete(capture.id) }
        }
    }
}

struct DownloadStep: View {
    @ObservedObject private var m = VideoSlides.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Download your deck").font(.title3.weight(.semibold))
                Text("\(m.selected.count) selected slide\(m.selected.count == 1 ? "" : "s"), in the current slide order. Speaker notes and the transcript follow the original video timings.")
                    .foregroundStyle(.secondary)
                HStack {
                    Text("File name")
                    TextField(m.name, text: $m.fileName).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(VideoSlides.Output.allCases) { o in
                        Button { m.output = o } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: m.output == o ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(m.output == o ? Screen.videoSlides.colour : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(o.rawValue).font(.body.weight(.medium))
                                    Text(o.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
                if m.output == .camtasia {
                    Toggle("Also put the original video in the Media Bin", isOn: $m.includeVideo)
                }
                if (m.output == .word || m.output == .pptx) && m.lines.isEmpty {
                    HStack {
                        if let l = m.listening {
                            ProgressView().controlSize(.small)
                            Text(l).foregroundStyle(.secondary)
                        } else {
                            Text(m.output == .word ? "The recording hasn't been transcribed yet." : "No speaker notes yet: the recording hasn't been transcribed.")
                                .foregroundStyle(.secondary)
                            Button("Transcribe on this Mac") { m.transcribeOnly() }
                        }
                    }
                }
                HStack {
                    if let st = m.status { ProgressView().controlSize(.small); Text(st) }
                    if let p = m.problem { Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    if let msg = m.message, m.status == nil, m.problem == nil { Text(msg).foregroundStyle(.secondary) }
                    Spacer()
                    Button { m.download() } label: {
                        Label("Download \(m.output.rawValue)", systemImage: "arrow.down.circle.fill").padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(m.busy)
                }
                Text("Your video and slides stay on this Mac. Captured slides are pictures of the original slides, not the original editable artwork.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
