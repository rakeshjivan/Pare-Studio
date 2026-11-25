// Engine — loads the recording and slides, pulls out the sound, transcribes it on this Mac,
// reads each slide, and works out when each slide should appear.

import Foundation
import AppKit
import AVFoundation
import PDFKit
import Speech
import Vision

struct Slide: Identifiable {
    let id = UUID()
    let number: Int
    let url: URL
    var text = ""
    var size = CGSize(width: 1920, height: 1080)
    var thumb: NSImage?
}

/// One line of what was said, with its time in the recording.
struct Line: Identifiable, Codable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    /// Each word with the time it's said (empty if the speech engine didn't give word times).
    var words: [TimedWord] = []
}

struct TimedWord: Codable, Equatable {
    var text: String
    var start: Double
}

/// "Show slide N from this time."
struct Cue: Identifiable, Equatable {
    var id = UUID()
    var slide: Int        // index into slides
    var start: Double
}

/// One recording and its results.
struct Job: Identifiable {
    enum State: Equatable { case waiting, working(String), done, failed(String) }
    let id = UUID()
    var recording: URL
    var duration: Double = 0
    var wav: URL?
    var lines: [Line] = []
    var cues: [Cue] = []
    /// Optional slide numbers (1-based) this recording covers.
    var from: Int?
    var to: Int?
    var state: State = .waiting
    var note: String?
    var name: String { recording.deletingPathExtension().lastPathComponent }
    var isDone: Bool { state == .done }
}

@MainActor
final class Session: ObservableObject {
    static let shared = Session()

    @Published var jobs: [Job] = []
    @Published var selected: UUID?
    @Published var slides: [Slide] = []
    @Published var slidesSource: URL?
    @Published var status: String?
    @Published var problem: String?
    @Published var note: String?
    @Published var busy = false
    @Published var showResults = false
    @Published var includeVideo = false
    @Published var exporting: String?
    @Published var exportMessage: String?
    /// Keyword searches, e.g. "six + weeks". Kept between launches.
    @Published var searches: [String] = UserDefaults.standard.stringArray(forKey: "searches") ?? [] {
        didSet { UserDefaults.standard.set(searches, forKey: "searches") }
    }

    var isEmpty: Bool { jobs.isEmpty && slides.isEmpty }

    /// Clear the recordings and the deck to start a new batch. Keywords are kept.
    func reset() {
        guard !busy, exporting == nil else { return }
        jobs = []
        selected = nil
        slides = []
        slidesSource = nil
        showResults = false
        status = nil
        problem = nil
        note = nil
        exportMessage = nil
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    func addSearch(_ text: String) {
        let t = text.trimmed
        guard !t.isEmpty, !searches.contains(where: { $0.lowercased() == t.lowercased() }) else { return }
        searches.append(t)
    }

    func finds(for job: Job) -> [Find] { Keywords.find(searches, in: job.lines) }

    let work: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("PareSlides-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static let mediaTypes: Set<String> = ["mp4", "mov", "m4v", "m4a", "mp3", "wav", "aif", "aiff", "aac", "caf"]

    var ready: Bool { !jobs.isEmpty && !slides.isEmpty }
    var hasResult: Bool { showResults }
    var anyDone: Bool { jobs.contains { $0.isDone } }
    var waitingCount: Int { jobs.filter { !$0.isDone }.count }

    // The selected recording, for the editor.
    var sel: Int? { jobs.firstIndex { $0.id == selected } }
    var current: Job? { sel.map { jobs[$0] } }
    var recording: URL? { current?.recording }
    var duration: Double { current?.duration ?? 0 }
    var lines: [Line] { current?.lines ?? [] }
    var audioWAV: URL? { current?.wav }
    var cues: [Cue] {
        get { current?.cues ?? [] }
        set { if let i = sel { jobs[i].cues = newValue } }
    }

    // MARK: Inputs

    func addRecordings(_ urls: [URL]) {
        problem = nil
        var added = 0
        for u in urls where Self.mediaTypes.contains(u.pathExtension.lowercased()) {
            guard !jobs.contains(where: { $0.recording == u }) else { continue }
            let job = Job(recording: u)
            jobs.append(job)
            added += 1
            let id = job.id
            Task {
                let d = (try? await AVURLAsset(url: u).load(.duration).seconds) ?? 0
                if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].duration = d.isNaN ? 0 : d }
            }
        }
        if added == 0, !urls.isEmpty { problem = "Those files aren't recordings Pare Slides can use (MP4, MOV, M4A, MP3, WAV)." }
        if selected == nil { selected = jobs.first?.id }
    }

    func removeJob(_ id: UUID) {
        guard !busy else { return }
        jobs.removeAll { $0.id == id }
        if selected == id { selected = jobs.first?.id }
    }

    func setRange(_ id: UUID, from: Int?, to: Int?) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let n = max(1, slides.count)
        var f = from.map { min(max(1, $0), n) }, t = to.map { min(max(1, $0), n) }
        if let a = f, let b = t, a > b { swap(&f, &t) }
        if jobs[i].from != f || jobs[i].to != t {
            jobs[i].from = f; jobs[i].to = t
            if jobs[i].isDone { jobs[i].cues = []; jobs[i].state = .waiting }
        }
    }

    func setSlides(_ urls: [URL]) {
        problem = nil
        busy = true
        status = "Reading the slides…"
        let work = self.work
        Task {
            do {
                let files = try await Task.detached { try SlideLoader.load(urls, work: work) }.value
                guard !files.isEmpty else { throw PGError("No slide images found. Use a zip or folder of JPG/PNG images, or a PDF.") }
                var list: [Slide] = []
                for (i, f) in files.enumerated() {
                    var s = Slide(number: i + 1, url: f)
                    if let img = NSImage(contentsOf: f) {
                        if let rep = img.representations.first, rep.pixelsWide > 0 {
                            s.size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                        }
                        s.thumb = img
                    }
                    list.append(s)
                }
                slides = list
                slidesSource = urls.first
                for i in jobs.indices { jobs[i].cues = []; if jobs[i].isDone { jobs[i].state = .waiting } }
            } catch { problem = error.localizedDescription }
            busy = false
            status = nil
        }
    }

    // MARK: Processing

    /// Match every recording that hasn't been matched yet, one after another.
    func processAll() {
        guard ready, !busy else { return }
        busy = true
        problem = nil
        note = nil
        Task {
            defer { busy = false; status = nil }
            // Slide text, once for the whole deck.
            if slides.contains(where: { $0.text.isEmpty }) {
                status = "Reading the text on each slide…"
                let files = slides.map(\.url)
                let texts = await Task.detached { files.map(SlideReader.text) }.value
                for i in slides.indices where i < texts.count { slides[i].text = texts[i] }
            }
            let ids = jobs.filter { !$0.isDone }.map(\.id)
            for (n, id) in ids.enumerated() {
                status = ids.count > 1 ? "Recording \(n + 1) of \(ids.count)" : nil
                await run(id)
                if let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].isDone, !showResults {
                    selected = id
                    showResults = true
                }
            }
            if !anyDone, let f = jobs.first(where: { if case .failed = $0.state { return true }; return false }),
               case .failed(let why) = f.state {
                problem = why
            }
        }
    }

    /// Match one recording again (keeps the transcript).
    func rematch(_ id: UUID) {
        guard !busy, let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].cues = []
        jobs[i].state = .waiting
        busy = true
        Task {
            await run(id)
            busy = false
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[i]) }
    }

    private func run(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let work = self.work
        do {
            // 1. Sound
            var wav = job.wav
            if wav == nil {
                update(id) { $0.state = .working("Taking the sound out…") }
                wav = try await Audio.extract(job.recording, work: work)
                update(id) { $0.wav = wav }
            }
            guard let wav else { return }
            if job.duration <= 0, let f = try? AVAudioFile(forReading: wav) {
                let d = Double(f.length) / f.processingFormat.sampleRate
                update(id) { $0.duration = d }
            }
            // 2. Words, with times
            var lines = job.lines
            if lines.isEmpty {
                update(id) { $0.state = .working("Listening (on this Mac)… long recordings take a while.") }
                lines = try await Transcriber.transcribe(wav)
                guard !lines.isEmpty else { throw PGError("No speech was found in this recording.") }
                update(id) { $0.lines = lines }
            }
            // 3. Match, against the whole deck or the chosen range.
            let lo = (job.from ?? 1) - 1, hi = (job.to ?? slides.count) - 1
            let subset = Array(slides[max(0, lo)...min(slides.count - 1, max(lo, hi))])
            let useClaude = ClaudeCLI.find() != nil
            update(id) { $0.state = .working(useClaude ? "Claude is matching the slides…" : "Matching the slides…") }
            let dur = jobs.first(where: { $0.id == id })?.duration ?? 0
            var result: [Cue] = []
            var jobNote: String?
            if useClaude {
                do { result = try await Matcher.claude(lines: lines, slides: subset) }
                catch { jobNote = "Claude couldn't do the matching (\(error.localizedDescription.prefix(120))), so Pare Slides matched by itself. Check the change points." }
            } else {
                jobNote = "Matched without Claude. For better matching, click Connect Claude."
            }
            if result.isEmpty {
                result = await Task.detached { Matcher.local(lines: lines, slides: subset, duration: dur) }.value
            }
            let cues = Matcher.tidy(result, slideCount: slides.count, duration: dur)
            update(id) { $0.cues = cues; $0.note = jobNote; $0.state = .done }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    // MARK: Editing the selected recording

    /// The slide on screen at a given time.
    func cueIndex(at t: Double) -> Int? {
        let c = cues
        return c.lastIndex { $0.start <= t + 0.001 } ?? (c.isEmpty ? nil : 0)
    }

    func end(of i: Int) -> Double { i + 1 < cues.count ? cues[i + 1].start : duration }

    func setStart(_ id: UUID, _ t: Double) {
        var c = cues
        guard let i = c.firstIndex(where: { $0.id == id }) else { return }
        c[i].start = min(max(0, t), max(0, duration - 0.1))
        c.sort { $0.start < $1.start }
        cues = c
    }

    func insert(slide: Int, at t: Double) {
        var c = cues
        c.append(Cue(slide: slide, start: min(max(0, t), duration)))
        c.sort { $0.start < $1.start }
        cues = c
    }

    func remove(_ id: UUID) { cues.removeAll { $0.id == id } }

    /// Slide indexes for this recording's Media Bin: its range (or the whole deck) plus any slide it uses.
    func binSlides(for job: Job) -> Set<Int> {
        let lo = (job.from ?? 1) - 1, hi = (job.to ?? slides.count) - 1
        var s = Set(max(0, lo)...min(max(0, slides.count - 1), max(lo, hi)))
        for c in job.cues { s.insert(c.slide) }
        return s
    }

    /// Export every matched recording as its own Camtasia project, all into one folder.
    func exportAll() {
        guard anyDone, exporting == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder. Each matched recording becomes its own Camtasia project."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let plans = jobs.compactMap { plan(for: $0, includeRecording: includeVideo) }
        let skipped = jobs.count - plans.count
        exportMessage = nil
        Task {
            var made: [URL] = []
            var failed: [String] = []
            for (i, plan) in plans.enumerated() {
                exporting = plans.count > 1 ? "Making Camtasia project \(i + 1) of \(plans.count)…" : "Making the Camtasia project…"
                var url = folder.appendingPathComponent(plan.title + ".cmproj")
                var n = 2
                while FileManager.default.fileExists(atPath: url.path) {
                    url = folder.appendingPathComponent("\(plan.title) \(n).cmproj"); n += 1
                }
                let target = url
                do {
                    try await Task.detached { try Export.camtasia(plan, to: target) }.value
                    made.append(target)
                } catch { failed.append(plan.title) }
            }
            if !searches.isEmpty, !made.isEmpty {
                var csv = folder.appendingPathComponent("Keyword finds.csv")
                var n = 2
                while FileManager.default.fileExists(atPath: csv.path) {
                    csv = folder.appendingPathComponent("Keyword finds \(n).csv"); n += 1
                }
                let rows = plans.flatMap { p in p.finds.map { (p.title, $0) } }
                if (try? Keywords.csv(rows, searches: searches).write(to: csv, atomically: true, encoding: .utf8)) != nil {
                    made.append(csv)
                }
            }
            exporting = nil
            var msg: [String] = []
            let projects = made.filter { $0.pathExtension == "cmproj" }.count
            if projects > 0 { msg.append("Exported \(projects) Camtasia project\(projects == 1 ? "" : "s").") }
            if !searches.isEmpty, projects > 0 {
                let total = plans.reduce(0) { $0 + $1.finds.count }
                msg.append("\(total) keyword find\(total == 1 ? "" : "s") marked, and listed in Keyword finds.csv.")
            }
            if !failed.isEmpty { msg.append("Couldn't export: " + failed.joined(separator: ", ") + ".") }
            if skipped > 0 { msg.append("\(skipped) recording\(skipped == 1 ? " isn't" : "s aren't") matched yet, so \(skipped == 1 ? "it was" : "they were") left out.") }
            exportMessage = msg.joined(separator: " ")
            if !made.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(made) }
        }
    }

    func plan(for job: Job, includeRecording: Bool) -> Export.Plan? {
        guard let wav = job.wav, job.isDone else { return nil }
        return Export.Plan(slides: slides, cues: job.cues, duration: job.duration, wav: wav, recording: job.recording,
                           includeRecording: includeRecording, title: job.name, binOnly: binSlides(for: job),
                           finds: finds(for: job))
    }
}

// MARK: - Slides from a zip, folder, PDF or images

enum SlideLoader {
    static let imageTypes: Set<String> = ["jpg", "jpeg", "png", "heic", "tif", "tiff", "gif", "bmp", "webp"]

    static func load(_ urls: [URL], work: URL) throws -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for u in urls {
            let ext = u.pathExtension.lowercased()
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                found += images(in: u)
            } else if ext == "zip" {
                let dest = work.appendingPathComponent("slides-\(UUID().uuidString.prefix(6))")
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                guard Tools.runQuick("/usr/bin/ditto", ["-x", "-k", u.path, dest.path]) == 0 else {
                    throw PGError("Couldn't open \(u.lastPathComponent).")
                }
                found += images(in: dest)
            } else if ext == "pdf" {
                found += try pdfPages(u, work: work)
            } else if imageTypes.contains(ext) {
                found.append(u)
            }
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func images(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let f as URL in en {
            if f.path.contains("__MACOSX") { continue }
            if imageTypes.contains(f.pathExtension.lowercased()) { out.append(f) }
        }
        return out
    }

    /// Each PDF page as a 1920-pixel-wide PNG.
    static func pdfPages(_ url: URL, work: URL) throws -> [URL] {
        guard let doc = PDFDocument(url: url) else { throw PGError("Couldn't open \(url.lastPathComponent).") }
        let dir = work.appendingPathComponent("pdf-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let w: CGFloat = 1920, h = (w * box.height / max(1, box.width)).rounded()
            guard let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: w / box.width, y: h / box.height)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: ctx)
            guard let img = ctx.makeImage(),
                  let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { continue }
            let f = dir.appendingPathComponent(String(format: "Slide %03d.png", i + 1))
            try png.write(to: f)
            out.append(f)
        }
        return out
    }
}

enum SlideReader {
    /// The words on a slide (Apple's on-device text recognition).
    static func text(_ url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "" }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}

// MARK: - Sound

enum Audio {
    /// Takes the sound out of a video or audio file as 44.1 kHz 16-bit stereo WAV.
    static func extract(_ url: URL, work: URL) async throws -> URL {
        let fm = FileManager.default
        let m4a = work.appendingPathComponent("voice-\(UUID().uuidString.prefix(6)).m4a")
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw PGError("That file has no sound.")
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw PGError("Couldn't read the sound.")
        }
        export.outputURL = m4a
        export.outputFileType = .m4a
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        guard export.status == .completed else { throw export.error ?? PGError("Couldn't read the sound.") }
        let wav = work.appendingPathComponent(url.deletingPathExtension().lastPathComponent + " voice.wav")
        try? fm.removeItem(at: wav)
        let status = await Task.detached {
            Tools.runQuick("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@44100", "-c", "2", m4a.path, wav.path])
        }.value
        try? fm.removeItem(at: m4a)
        guard status == 0 else { throw PGError("Couldn't convert the sound.") }
        return wav
    }
}

// MARK: - Speech to text (on this Mac)

enum Transcriber {
    static func transcribe(_ url: URL) async throws -> [Line] {
        if #available(macOS 26.0, *) {
            do {
                let l = try await modern(url)
                if !l.isEmpty { return l }
            } catch {
                // fall back to the older engine below
            }
        }
        return try await legacy(url)
    }

    /// macOS 26's speech engine: handles long recordings well.
    @available(macOS 26.0, *)
    static func modern(_ url: URL) async throws -> [Line] {
        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-AU"))
        if locale == nil { locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) }
        if locale == nil { locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let locale else { throw PGError("English speech recognition isn't available on this Mac.") }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let collect = Task { () -> [Line] in
            var words: [(String, Double, Double)] = []
            var out: [Line] = []
            for try await r in transcriber.results {
                // Word timings where available, so long results can be split into short lines.
                var got = false
                for run in r.text.runs {
                    guard let tr = run.audioTimeRange else { continue }
                    let w = String(r.text[run.range].characters)
                    if w.trimmed.isEmpty { continue }
                    words.append((w, tr.start.seconds, tr.end.seconds))
                    got = true
                }
                if !got {
                    let t = String(r.text.characters).trimmed
                    if !t.isEmpty { out.append(Line(start: r.range.start.seconds, end: r.range.end.seconds, text: t)) }
                }
            }
            return out + Transcriber.group(words)
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value.sorted { $0.start < $1.start }
    }

    /// The older engine (macOS 14–15), on-device where possible.
    static func legacy(_ url: URL) async throws -> [Line] {
        let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard auth == .authorized else {
            throw PGError("Pare Slides needs Speech Recognition permission: System Settings › Privacy & Security › Speech Recognition.")
        }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-AU")) ?? SFSpeechRecognizer(), rec.isAvailable else {
            throw PGError("Speech recognition isn't available right now.")
        }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        let once = Once()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[Line], Error>) in
            rec.recognitionTask(with: req) { result, error in
                if let result, result.isFinal {
                    let words = result.bestTranscription.segments.map { ($0.substring, $0.timestamp, $0.timestamp + $0.duration) }
                    if once.claim() { c.resume(returning: Transcriber.group(words)) }
                } else if let error {
                    if once.claim() { c.resume(throwing: error) }
                }
            }
        }
    }

    /// Words → short lines (about 12 words, or a new line after a pause or a full stop).
    static func group(_ words: [(String, Double, Double)]) -> [Line] {
        var out: [Line] = []
        var cur: [String] = []
        var tw: [TimedWord] = []
        var s = 0.0, e = 0.0
        for (w, ws, we) in words.sorted(by: { $0.1 < $1.1 }) {
            let pause = !cur.isEmpty && ws - e > 0.8
            if pause || cur.count >= 12 {
                out.append(Line(start: s, end: e, text: cur.joined(separator: " "), words: tw))
                cur = []; tw = []
            }
            if cur.isEmpty { s = ws }
            cur.append(w.trimmed)
            tw.append(TimedWord(text: w.trimmed, start: ws))
            e = we
            if let last = w.trimmed.last, ".?!".contains(last), cur.count >= 4 {
                out.append(Line(start: s, end: e, text: cur.joined(separator: " "), words: tw))
                cur = []; tw = []
            }
        }
        if !cur.isEmpty { out.append(Line(start: s, end: e, text: cur.joined(separator: " "), words: tw)) }
        return out
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

// MARK: - Matching what's said to the slides

enum Matcher {
    /// Claude reads the transcript and the slides and decides when each slide starts.
    static func claude(lines: [Line], slides: [Slide]) async throws -> [Cue] {
        let transcript = lines.map { String(format: "[%.1f] ", $0.start) + $0.text }.joined(separator: "\n")
        let deck = slides.map { "Slide \($0.number): \($0.text.isEmpty ? "(picture only, no text)" : String($0.text.prefix(700)))" }
            .joined(separator: "\n")
        let prompt = """
        You are syncing a slide deck to a recording of the presenter talking through it. Below are the \
        transcript lines with their start times in seconds, and the text on each slide.
        Decide when each slide should appear on screen.
        Rules:
        - The recording may cover only PART of the deck. It can start at any slide and end at any slide. \
        Include only the slides this recording actually talks about.
        - Slides usually go forward in order. A slide the presenter doesn't talk about is skipped. \
        Going back to an earlier slide is rare but allowed when the talk clearly returns to it.
        - The first slide shown starts at 0 (use whichever slide the recording opens on).
        - Put each change at the start time of the transcript line where the presenter starts talking about \
        that slide's content (or says things like "next", "moving on", "let's look at").
        - A slide with no text (a picture) usually sits between the slides around it; include it if the talk moves through it.
        - Use only start times that appear in the transcript (or 0).
        Reply with ONLY a JSON array in time order, like [{"slide":1,"start":0},{"slide":3,"start":34.3}]. No other text.

        SLIDES
        \(deck)

        TRANSCRIPT
        \(transcript)
        """
        let reply = try await ClaudeCLI.ask(prompt)
        guard let a = reply.firstIndex(of: "["), let b = reply.lastIndex(of: "]"), a < b,
              let data = String(reply[a...b]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PGError("Claude's answer wasn't in the expected format.")
        }
        var cues: [Cue] = []
        for item in arr {
            guard let n = (item["slide"] as? NSNumber)?.intValue,
                  let t = (item["start"] as? NSNumber)?.doubleValue, slides.contains(where: { $0.number == n }) else { continue }
            cues.append(Cue(slide: n - 1, start: t))
        }
        guard !cues.isEmpty else { throw PGError("Claude didn't place any slides.") }
        return cues
    }

    /// Without Claude: match words in each line to words on the slides, keeping the slides in order.
    static func local(lines: [Line], slides: [Slide], duration: Double) -> [Cue] {
        guard !lines.isEmpty, !slides.isEmpty else { return [Cue(slide: max(0, (slides.first?.number ?? 1) - 1), start: 0)] }
        let stop: Set<String> = Set("""
        the a an and or of to in on for with is are be that this it i you your we our my me so as at by from have has was were \
        will can not but do just there what how they their them about also very really lots some here then than when which who
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
                .filter { $0.count > 2 && !stop.contains($0) }
        }
        let slideWords = slides.map { Set(words($0.text)) }
        var df: [String: Int] = [:]
        for s in slideWords { for w in s { df[w, default: 0] += 1 } }
        let n = Double(slides.count)
        func idf(_ w: String) -> Double { log((n + 1) / (Double(df[w] ?? 0) + 0.5)) }
        // Score of every line against every slide.
        let S: [[Double]] = lines.map { l in
            let ws = words(l.text)
            return slideWords.map { sw in
                ws.filter { sw.contains($0) }.reduce(0) { $0 + idf($1) } / sqrt(Double(1 + ws.count))
            }
        }
        // Best path through the slides: it can start on any slide, moves forward with a small cost per
        // change and per slide skipped, and can go back to an earlier slide at a higher cost.
        let change = 0.8, skip = 0.2, goBack = 2.5
        let L = lines.count, K = slides.count
        var best = Array(repeating: Array(repeating: -Double.infinity, count: K), count: L)
        var back = Array(repeating: Array(repeating: 0, count: K), count: L)
        for k in 0..<K { best[0][k] = S[0][k] }
        for i in 1..<L {
            for k in 0..<K {
                var bestPrev = best[i - 1][k], arg = k
                for j in 0..<K where j != k {
                    let cost = j < k ? change + Double(k - j - 1) * skip : goBack
                    let v = best[i - 1][j] - cost
                    if v > bestPrev { bestPrev = v; arg = j }
                }
                best[i][k] = bestPrev + S[i][k]
                back[i][k] = arg
            }
        }
        var k = (0..<K).max { best[L - 1][$0] < best[L - 1][$1] } ?? 0
        var path = [Int](repeating: 0, count: L)
        for i in stride(from: L - 1, through: 0, by: -1) {
            path[i] = k
            if i > 0 { k = back[i][k] }
        }
        var cues: [Cue] = []
        for (i, k) in path.enumerated() where cues.last?.slide != slides[k].number - 1 {
            cues.append(Cue(slide: slides[k].number - 1, start: i == 0 ? 0 : lines[i].start))
        }
        return cues
    }

    /// Sorted, starting at 0, no two cues on top of each other.
    static func tidy(_ cues: [Cue], slideCount: Int, duration: Double) -> [Cue] {
        var c = cues.filter { $0.slide >= 0 && $0.slide < slideCount }.sorted { $0.start < $1.start }
        guard !c.isEmpty else { return [Cue(slide: 0, start: 0)] }
        c[0].start = 0
        var out: [Cue] = []
        for cue in c {
            if let last = out.last, cue.start - last.start < 0.5 { out[out.count - 1] = Cue(slide: cue.slide, start: last.start); continue }
            if duration > 0, cue.start >= duration { continue }
            out.append(cue)
        }
        return out
    }
}


// MARK: - Keyword finds

/// One place a keyword search turns up in a recording.
struct Find: Identifiable, Equatable {
    let id = UUID()
    var search: String
    var start: Double
    var end: Double
    var context: String
}

enum Keywords {
    /// Words are counted as "together" when they're said within this many seconds of each other.
    static let window = 10.0

    private static let numbers: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
        "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20",
        "thirty": "30", "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
        "hundred": "100", "first": "1st", "second": "2nd", "third": "3rd",
    ]

    /// Lowercase pieces, punctuation removed, number words as digits ("Six-week" → ["6", "week"]).
    static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { piece -> String in
                var w = String(piece)
                if w.hasSuffix("'s") { w.removeLast(2) }
                w = w.replacingOccurrences(of: "'", with: "")
                return numbers[w] ?? w
            }
            .filter { !$0.isEmpty }
    }

    /// "week" finds "weeks" and the other way round.
    static func same(_ a: String, _ b: String) -> Bool {
        a == b || a + "s" == b || b + "s" == a || a + "es" == b || b + "es" == a
    }

    /// The parts of a search: "six + weeks" → [["6"], ["weeks"]]; "nervous system" → [["nervous", "system"]].
    static func parts(_ search: String) -> [[String]] {
        search.split(separator: "+").map { tokens(String($0)) }.filter { !$0.isEmpty }
    }

    static func find(_ searches: [String], in lines: [Line]) -> [Find] {
        // Every word in the recording, with a time.
        var stream: [(word: String, time: Double, line: Int)] = []
        for (li, line) in lines.enumerated() {
            if !line.words.isEmpty {
                for w in line.words { for t in tokens(w.text) { stream.append((t, w.start, li)) } }
            } else {
                let ts = tokens(line.text)
                for (i, t) in ts.enumerated() {
                    let f = ts.count > 1 ? Double(i) / Double(ts.count - 1) : 0
                    stream.append((t, line.start + f * (line.end - line.start), li))
                }
            }
        }
        guard !stream.isEmpty else { return [] }

        func occurrences(_ phrase: [String]) -> [(time: Double, line: Int)] {
            guard !phrase.isEmpty, stream.count >= phrase.count else { return [] }
            var out: [(Double, Int)] = []
            for i in 0...(stream.count - phrase.count) {
                var ok = true
                for (k, p) in phrase.enumerated() where !same(stream[i + k].word, p) { ok = false; break }
                if ok { out.append((stream[i].time, stream[i].line)) }
            }
            return out
        }

        var finds: [Find] = []
        for search in searches {
            let ps = parts(search)
            guard !ps.isEmpty else { continue }
            let occ = ps.map(occurrences)
            guard occ.allSatisfy({ !$0.isEmpty }) else { continue }
            let anchor = occ.indices.min { occ[$0].count < occ[$1].count } ?? 0
            var hits: [(start: Double, end: Double, first: Int, last: Int)] = []
            for a in occ[anchor] {
                var lo = a.time, hi = a.time, l0 = a.line, l1 = a.line
                var ok = true
                for (pi, list) in occ.enumerated() where pi != anchor {
                    guard let near = list.min(by: { abs($0.time - a.time) < abs($1.time - a.time) }),
                          abs(near.time - a.time) <= window else { ok = false; break }
                    lo = min(lo, near.time); hi = max(hi, near.time)
                    l0 = min(l0, near.line); l1 = max(l1, near.line)
                }
                guard ok else { continue }
                if let last = hits.last, lo - last.start <= window { continue }   // same moment, already found
                hits.append((lo, hi, l0, l1))
            }
            for h in hits {
                let context = lines[h.first...h.last].map(\.text).joined(separator: " ")
                finds.append(Find(search: search, start: h.start, end: h.end, context: context))
            }
        }
        return finds.sorted { $0.start < $1.start }
    }

    static func hms(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    /// A spreadsheet (CSV, opens in Excel or Numbers) of every find.
    static func csv(_ rows: [(recording: String, find: Find)], searches: [String]) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var out = "\u{FEFF}Recording,Time,Seconds,Search,What was said\n"
        for r in rows {
            out += [q(r.recording), hms(r.find.start), String(format: "%.1f", r.find.start), q(r.find.search), q(r.find.context)]
                .joined(separator: ",") + "\n"
        }
        if rows.isEmpty {
            out += q("No finds") + ",,," + q(searches.joined(separator: "; ")) + ",\n"
        }
        return out
    }
}
