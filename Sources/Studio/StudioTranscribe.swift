// Transcribe a recording on this Mac: text, Word, or captions (SRT, VTT), plus keyword finds.

import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct TranscriptJob: Identifiable {
    enum State: Equatable { case waiting, working(String), done, failed(String) }
    let id = UUID()
    var file: URL
    var lines: [Line] = []
    var duration: Double = 0
    var state: State = .waiting
    var name: String { file.deletingPathExtension().lastPathComponent }
    var isDone: Bool { state == .done }
}

@MainActor
final class TranscribeModel: ObservableObject {
    static let shared = TranscribeModel()

    enum Format: String, CaseIterable, Identifiable {
        case word = "Word", text = "Text", timedText = "Text with times", srt = "Captions (SRT)", vtt = "Captions (VTT)"
        var id: String { rawValue }
        var ext: String {
            switch self { case .word: return "docx"; case .text, .timedText: return "txt"; case .srt: return "srt"; case .vtt: return "vtt" }
        }
        var suffix: String {
            switch self { case .timedText: return " (with times)"; default: return "" }
        }
    }

    @Published var jobs: [TranscriptJob] = []
    @Published var selected: UUID?
    @Published var busy = false
    @Published var problem: String?
    @Published var message: String?
    @Published var formats: Set<Format> = [.word]
    @Published var filter = ""

    private let work: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("PareStudioTx-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    var current: TranscriptJob? { jobs.first { $0.id == selected } }

    func add(_ urls: [URL]) {
        problem = nil
        for u in urls where Session.mediaTypes.contains(u.pathExtension.lowercased()) {
            guard !jobs.contains(where: { $0.file == u }) else { continue }
            jobs.append(TranscriptJob(file: u))
        }
        if jobs.isEmpty, !urls.isEmpty { problem = "Those aren't recordings Pare Studio can read (MP4, MOV, M4A, MP3, WAV)." }
        if selected == nil { selected = jobs.first?.id }
        start()
    }

    func remove(_ id: UUID) {
        guard !busy || jobs.first(where: { $0.id == id })?.isDone == true else { return }
        jobs.removeAll { $0.id == id }
        if selected == id { selected = jobs.first?.id }
    }

    func clear() {
        guard !busy else { return }
        jobs = []; selected = nil; problem = nil; message = nil
    }

    func setState(_ id: UUID, _ st: TranscriptJob.State) {
        if let i = jobs.firstIndex(where: { $0.id == id }), case .working = jobs[i].state { jobs[i].state = st }
    }

    private func update(_ id: UUID, _ f: (inout TranscriptJob) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { f(&jobs[i]) }
    }

    /// Works through the waiting files one at a time.
    func start() {
        guard !busy else { return }
        busy = true
        Task {
            while let next = jobs.first(where: { $0.state == .waiting }) {
                let id = next.id
                do {
                    update(id) { $0.state = .working("Taking the sound out…") }
                    let wav = try await Audio.extract(next.file, work: work)
                    if let f = try? AVAudioFile(forReading: wav) {
                        let d = Double(f.length) / f.processingFormat.sampleRate
                        update(id) { $0.duration = d }
                    }
                    update(id) { $0.state = .working("Listening (on this Mac)… long recordings take a while.") }
                    let lines = try await Transcriber.transcribe(wav) { f in
                        Task { @MainActor in
                            TranscribeModel.shared.setState(id, .working("Listening (on this Mac)… \(Int(f * 100))%"))
                        }
                    }
                    try? FileManager.default.removeItem(at: wav)
                    guard !lines.isEmpty else { throw PGError("No speech was found.") }
                    update(id) { $0.lines = lines; $0.state = .done }
                    if selected == nil || current?.isDone != true { selected = id }
                } catch {
                    update(id) { $0.state = .failed(error.localizedDescription) }
                }
            }
            busy = false
        }
    }

    // MARK: Output

    static func render(_ job: TranscriptJob, as format: Format) -> String {
        func srtTime(_ t: Double, sep: String) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d\(sep)%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        switch format {
        case .text:
            return job.lines.map(\.text).joined(separator: " ")
                .replacingOccurrences(of: ". ", with: ".\n\n", options: [], range: nil)
        case .timedText:
            return job.lines.map { "[\(Keywords.hms($0.start))] \($0.text)" }.joined(separator: "\n")
        case .srt:
            return job.lines.enumerated().map { i, l in
                "\(i + 1)\n\(srtTime(l.start, sep: ",")) --> \(srtTime(max(l.end, l.start + 0.5), sep: ","))\n\(l.text)\n"
            }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n" + job.lines.map { l in
                "\(srtTime(l.start, sep: ".")) --> \(srtTime(max(l.end, l.start + 0.5), sep: "."))\n\(l.text)\n"
            }.joined(separator: "\n")
        case .word:
            return ""
        }
    }

    static func write(_ job: TranscriptJob, as format: Format, to url: URL) throws {
        if format == .word {
            // Paragraphs of a few lines each, with the time they start.
            var paras: [(time: String?, text: String)] = []
            var buf: [String] = []
            var start = 0.0
            for (i, l) in job.lines.enumerated() {
                if buf.isEmpty { start = l.start }
                buf.append(l.text)
                let pause = i + 1 < job.lines.count ? job.lines[i + 1].start - l.end : 99
                if buf.count >= 5 || pause > 2.0 || i == job.lines.count - 1 {
                    paras.append((Keywords.hms(start), buf.joined(separator: " ")))
                    buf = []
                }
            }
            try Office.docx(title: job.name, paragraphs: paras, to: url)
        } else {
            try render(job, as: format).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Saves the selected recording in one format.
    func save(_ format: Format) {
        guard let job = current, job.isDone else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = job.name + format.suffix + "." + format.ext
        panel.allowedContentTypes = [UTType(filenameExtension: format.ext) ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.write(job, as: format, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            message = "Saved \(url.lastPathComponent)."
        } catch { problem = error.localizedDescription }
    }

    /// Saves every finished recording, in every ticked format, into one folder.
    func saveAll() {
        let done = jobs.filter(\.isDone)
        guard !done.isEmpty, !formats.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose a folder for the transcripts."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var made: [URL] = []
        var failed: [String] = []
        for job in done {
            for f in Format.allCases where formats.contains(f) {
                let url = folder.appendingPathComponent(job.name + f.suffix + "." + f.ext)
                do { try Self.write(job, as: f, to: url); made.append(url) } catch { failed.append(url.lastPathComponent) }
            }
        }
        let searches = Session.shared.searches
        if !searches.isEmpty {
            let rows = done.flatMap { j in Keywords.find(searches, in: j.lines).map { (j.name, $0) } }
            let csv = folder.appendingPathComponent("Keyword finds.csv")
            if (try? Keywords.csv(rows, searches: searches).write(to: csv, atomically: true, encoding: .utf8)) != nil { made.append(csv) }
        }
        message = "Saved \(made.count) file\(made.count == 1 ? "" : "s")." + (failed.isEmpty ? "" : " Couldn't save: " + failed.joined(separator: ", "))
        if !made.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(made) }
    }
}

// MARK: - Screen

struct TranscribeView: View {
    @ObservedObject private var m = TranscribeModel.shared

    var body: some View {
        if m.jobs.isEmpty {
            StudioDrop(title: "Drop one or more recordings",
                       detail: "Video or audio (MP4, MOV, M4A, MP3, WAV). Transcribed on this Mac with Apple's speech engine; nothing is uploaded.",
                       icon: "text.bubble.fill", colour: Screen.transcribe.colour,
                       types: [.movie, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .mpeg4Audio],
                       multiple: true, problem: m.problem, onFile: { m.add([$0]) }, onFiles: { m.add($0) })
        } else {
            HStack(spacing: 0) {
                fileList.frame(width: 300)
                Divider()
                transcript
            }
            .dropDestination(for: URL.self) { urls, _ in m.add(urls); return !urls.isEmpty }
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recordings").font(.headline)
                Spacer()
                Button("Add…") {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.movie, .audio]
                    p.allowsMultipleSelection = true
                    if p.runModal() == .OK { m.add(p.urls) }
                }
                Button("Clear") { m.clear() }.disabled(m.busy)
            }
            .padding(12)
            List(selection: $m.selected) {
                ForEach(m.jobs) { j in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(j.file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Group {
                            switch j.state {
                            case .waiting: Text("Waiting").foregroundStyle(.secondary)
                            case .working(let w): HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(w).lineLimit(1) }
                            case .done: Text("Done · \(clock(j.duration))").foregroundStyle(.green)
                            case .failed(let why): Text(why).foregroundStyle(.orange).lineLimit(2)
                            }
                        }
                        .font(.caption)
                    }
                    .tag(j.id)
                    .contextMenu { Button("Remove") { m.remove(j.id) } }
                }
            }
            .listStyle(.inset)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Save all as").font(.callout.weight(.medium))
                ForEach(TranscribeModel.Format.allCases) { f in
                    Toggle(f.rawValue, isOn: Binding(get: { m.formats.contains(f) },
                                                     set: { if $0 { m.formats.insert(f) } else { m.formats.remove(f) } }))
                        .toggleStyle(.checkbox)
                }
                Button { m.saveAll() } label: { Label("Save All…", systemImage: "square.and.arrow.down.on.square").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!m.jobs.contains(where: \.isDone) || m.formats.isEmpty)
                if !Session.shared.searches.isEmpty {
                    Text("Your keywords are listed in Keyword finds.csv.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            if let job = m.current {
                HStack(spacing: 10) {
                    Text(job.name).font(.headline).lineLimit(1)
                    Spacer()
                    TextField("Search", text: $m.filter).textFieldStyle(.roundedBorder).frame(width: 200)
                    Menu {
                        ForEach(TranscribeModel.Format.allCases) { f in Button(f.rawValue + "…") { m.save(f) } }
                    } label: { Label("Save As", systemImage: "square.and.arrow.down") }
                        .fixedSize()
                        .disabled(!job.isDone)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(TranscribeModel.render(job, as: .text), forType: .string)
                        m.message = "Copied the transcript."
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .disabled(!job.isDone)
                }
                .padding(12)
                Divider()
                if job.isDone {
                    let shown = m.filter.trimmed.isEmpty ? job.lines
                        : job.lines.filter { $0.text.localizedCaseInsensitiveContains(m.filter.trimmed) }
                    List(shown) { l in
                        HStack(alignment: .top, spacing: 10) {
                            Text(Keywords.hms(l.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                            Text(l.text).textSelection(.enabled)
                        }
                    }
                    .listStyle(.inset)
                } else {
                    VStack(spacing: 10) {
                        Spacer()
                        if case .failed(let why) = job.state {
                            Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        } else {
                            ProgressView()
                            Text("Transcribing… you can add more recordings meanwhile.").foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
                if let msg = m.message { Text(msg).font(.caption).foregroundStyle(.secondary).padding(8) }
            } else {
                Text("Pick a recording").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
