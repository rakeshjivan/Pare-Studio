// Pare Slides — put slides on screen at the right moments in a recorded talk.
// Drop in the recording and the slides, click Match, check the change points, and export
// a Camtasia project (or an MP4).

import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers


// MARK: - Playback

@MainActor
final class Player: ObservableObject {
    static let shared = Player()
    @Published var time: Double = 0
    @Published var playing = false
    private var player: AVPlayer?
    private var observer: Any?
    private var loaded: URL?

    func load(_ url: URL?) {
        guard url != loaded else { return }
        if let o = observer { player?.removeTimeObserver(o) }
        loaded = url
        player = url.map { AVPlayer(url: $0) }
        playing = false
        time = 0
        observer = player?.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                self?.time = t.seconds
                self?.playing = (self?.player?.rate ?? 0) > 0
            }
        }
    }

    func toggle() {
        guard let p = player else { return }
        if p.rate > 0 { p.pause() } else { p.play() }
        playing = p.rate > 0
    }

    func play(from t: Double) {
        seek(t)
        player?.play()
        playing = true
    }

    func seek(_ t: Double) {
        player?.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = t
    }
}

// MARK: - Main window

struct SlidesHome: View {
    @ObservedObject private var s = Session.shared
    @State private var confirmNew = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Spacer()
                Button { confirmNew = true } label: { Label("Start New", systemImage: "arrow.counterclockwise") }
                    .disabled(s.isEmpty || s.busy || s.exporting != nil)
                    .help("Clear the recordings and slides to start a new batch")
                    .confirmationDialog("Start a new batch?", isPresented: $confirmNew) {
                        Button("Clear Recordings and Slides", role: .destructive) {
                            Player.shared.load(nil)
                            s.reset()
                        }
                    } message: {
                        Text("This clears the recordings, the slide deck and the slide timings. Export anything you need first. Your keywords are kept.")
                    }
            }
            .padding(.horizontal, 18).padding(.top, 10)
            Divider()
            if s.hasResult { EditorView() } else { SetupView() }
        }
    }
}

// MARK: - Step 1: choose files

struct SetupView: View {
    @ObservedObject private var s = Session.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Put the slides on screen at the right moments in recorded talks.")
                    .font(.title3).foregroundStyle(.secondary)
                HStack(spacing: 20) {
                    DropCard(title: "1. Recordings", icon: "waveform",
                             hint: "Drop one or more videos or audio files here (MP4, MOV, M4A, MP3, WAV)",
                             detail: s.jobs.isEmpty ? nil : (s.jobs.count == 1 ? "1 recording" : "\(s.jobs.count) recordings") + " · drop more to add",
                             types: [.movie, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .mpeg4Audio],
                             multiple: true) { urls in
                        s.addRecordings(urls)
                    }
                    DropCard(title: "2. Slide deck", icon: "rectangle.stack",
                             hint: "Drop the deck: a zip or folder of slide images, or a PDF. One deck can serve all the recordings.",
                             detail: s.slides.isEmpty ? nil : "\(s.slides.count) slides",
                             types: [.zip, .folder, .pdf, .image], multiple: true) { urls in
                        s.setSlides(urls)
                    }
                }
                if !s.slides.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(s.slides) { sl in
                                VStack(spacing: 3) {
                                    thumb(sl).frame(width: 96, height: 54)
                                    Text("\(sl.number)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .frame(height: 76)
                }
                KeywordBox()
                if !s.jobs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Recordings").font(.headline)
                            Spacer()
                            Text("Slide range is optional: fill it in if a recording only uses part of the deck.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(spacing: 0) {
                            ForEach(s.jobs) { job in
                                RecordingRow(job: job)
                                if job.id != s.jobs.last?.id { Divider() }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
                    }
                }
                HStack(spacing: 12) {
                    if s.waitingCount > 0 || !s.anyDone {
                        Button {
                            s.processAll()
                        } label: {
                            Label(matchTitle, systemImage: "wand.and.stars")
                                .font(.title3.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!s.ready || s.busy)
                    }
                    if s.anyDone {
                        Button {
                            if s.current?.isDone != true { s.selected = s.jobs.first { $0.isDone }?.id }
                            s.showResults = true
                        } label: {
                            Label("Check", systemImage: "checklist").padding(.horizontal, 8).padding(.vertical, 4)
                        }
                        .controlSize(.large)
                        Button { s.exportAll() } label: {
                            Label(s.jobs.filter(\.isDone).count > 1 ? "Export All \(s.jobs.filter(\.isDone).count) to Camtasia…" : "Export to Camtasia…",
                                  systemImage: "square.and.arrow.up.on.square")
                                .font(.title3.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(s.exporting != nil)
                    }
                }
                if let e = s.exporting { HStack { ProgressView().controlSize(.small); Text(e) } }
                if let m = s.exportMessage { Text(m).foregroundStyle(.secondary) }
                StatusLine()
            }
            .padding(28)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
    }

    private var matchTitle: String {
        let n = s.anyDone ? s.waitingCount : s.jobs.count
        if s.anyDone { return n == 1 ? "3. Match the New Recording" : "3. Match the \(n) New Recordings" }
        return n <= 1 ? "3. Match Slides to Recording" : "3. Match All \(n) Recordings"
    }

    @ViewBuilder func thumb(_ sl: Slide) -> some View {
        if let t = sl.thumb {
            Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
        } else {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
        }
    }
}

struct KeywordBox: View {
    @ObservedObject private var s = Session.shared
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Keywords to find (optional)", systemImage: "flag").font(.headline)
                Spacer()
                Text("Use + for words said together, e.g. six + weeks").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Add a keyword or phrase, e.g. six + weeks", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(text.trimmed.isEmpty)
            }
            if !s.searches.isEmpty {
                FlowChips(items: s.searches) { item in s.searches.removeAll { $0 == item } }
                Text("Each find becomes a marker in the Camtasia project, and a list of times (Keyword finds.csv) is saved with the export. Words joined with + count as together when they're said within about 10 seconds of each other.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    private func add() {
        s.addSearch(text)
        text = ""
    }
}

/// Removable chips that wrap onto new lines.
struct FlowChips: View {
    let items: [String]
    let remove: (String) -> Void

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 4) {
                    Text(item)
                    Button { remove(item) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.orange.opacity(0.15)))
            }
        }
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let sz = v.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += row + spacing; row = 0 }
            x += sz.width + spacing
            widest = max(widest, x - spacing)
            row = max(row, sz.height)
        }
        return CGSize(width: min(width, widest), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let sz = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            row = max(row, sz.height)
        }
    }
}

struct JobStateView: View {
    let state: Job.State
    var body: some View {
        switch state {
        case .waiting: Label("Waiting", systemImage: "clock").foregroundStyle(.secondary)
        case .working(let what): HStack(spacing: 6) { ProgressView().controlSize(.small); Text(what) }
        case .done: Label("Matched", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let why): Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
        }
    }
}

struct RecordingRow: View {
    let job: Job
    @ObservedObject private var s = Session.shared
    @State private var from = ""
    @State private var to = ""

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ["m4a", "mp3", "wav", "aif", "aiff", "aac", "caf"].contains(job.recording.pathExtension.lowercased())
                  ? "waveform" : "film")
                .foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.recording.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(job.duration > 0 ? clock(job.duration) : " ").font(.caption).foregroundStyle(.secondary)
            }
            .frame(minWidth: 200, alignment: .leading)
            Spacer()
            JobStateView(state: job.state).font(.callout).frame(maxWidth: 300, alignment: .trailing)
            HStack(spacing: 4) {
                Text("Slides").font(.callout).foregroundStyle(.secondary)
                TextField("first", text: $from).frame(width: 46).multilineTextAlignment(.center).onSubmit(apply)
                Text("to").font(.callout).foregroundStyle(.secondary)
                TextField("last", text: $to).frame(width: 46).multilineTextAlignment(.center).onSubmit(apply)
            }
            .disabled(s.busy || s.slides.isEmpty)
            .help("Optional. If this recording only uses part of the deck, enter its first and last slide numbers.")
            Button { s.removeJob(job.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).disabled(s.busy).help("Remove this recording")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .onAppear { from = job.from.map(String.init) ?? ""; to = job.to.map(String.init) ?? "" }
        .onChange(of: from) { _, _ in apply() }
        .onChange(of: to) { _, _ in apply() }
    }

    private func apply() {
        s.setRange(job.id, from: Int(from.trimmed), to: Int(to.trimmed))
    }
}

struct StatusLine: View {
    @ObservedObject private var s = Session.shared
    var body: some View {
        VStack(spacing: 6) {
            if let st = s.status { HStack { ProgressView().controlSize(.small); Text(st) } }
            if let p = s.problem { Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            if let n = s.note, s.status == nil { Text(n).font(.callout).foregroundStyle(.secondary) }
        }
        .multilineTextAlignment(.center)
    }
}

struct DropCard: View {
    let title: String
    let icon: String
    let hint: String
    let detail: String?
    let types: [UTType]
    var multiple = false
    let onFiles: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: detail == nil ? icon : "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(detail == nil ? Color.secondary : Color.green)
            Text(title).font(.headline)
            Text(detail ?? hint).font(.callout).foregroundStyle(detail == nil ? .secondary : .primary)
                .multilineTextAlignment(.center).lineLimit(3)
            Button(detail == nil ? "Choose…" : "Change…") { choose() }
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(targeted ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5)))
        .dropDestination(for: URL.self) { urls, _ in
            onFiles(urls)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.canChooseDirectories = types.contains(.folder)
        panel.allowsMultipleSelection = multiple
        if panel.runModal() == .OK { onFiles(panel.urls) }
    }
}

// MARK: - Step 2: check and export

struct EditorView: View {
    @ObservedObject private var s = Session.shared
    @ObservedObject private var player = Player.shared
    @State private var exporting: String?
    @State private var exportError: String?

    private var current: Int? { s.cueIndex(at: player.time) }
    private var findStarts: [Find] { s.current.map { s.finds(for: $0) } ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if let job = s.current, job.isDone {
                HStack(spacing: 0) {
                    cueList.frame(width: 330)
                    Divider()
                    VStack(spacing: 12) {
                        preview
                        transport
                        Divider()
                        exportBar
                    }
                    .padding(16)
                    Divider()
                    transcript.frame(width: 360)
                }
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    if let job = s.current { JobStateView(state: job.state).font(.title3) }
                    Text("This recording isn't matched yet. Pick another from the menu, or wait for it to finish.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: s.audioWAV) { player.load(s.current?.isDone == true ? s.audioWAV : nil) }
        .onChange(of: s.current?.isDone) { _, done in if done == true { player.load(s.audioWAV) } }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { player.load(nil); s.showResults = false } label: { Label("Files", systemImage: "chevron.left") }
            if s.jobs.count > 1 {
                Picker("Recording", selection: $s.selected) {
                    ForEach(s.jobs) { j in
                        Text(j.name + (j.isDone ? "" : "  (not matched yet)")).tag(Optional(j.id))
                    }
                }
                .frame(maxWidth: 420)
                Text("\(s.jobs.filter(\.isDone).count) of \(s.jobs.count) matched").font(.callout).foregroundStyle(.secondary)
            } else if let j = s.current {
                Text(j.recording.lastPathComponent).font(.headline)
            }
            if let st = s.status, s.busy { HStack(spacing: 6) { ProgressView().controlSize(.small); Text(st).foregroundStyle(.secondary) } }
            Spacer()
            if s.jobs.count > 1 {
                Button { s.exportAll() } label: {
                    Label("Export All (\(s.jobs.filter(\.isDone).count)) to Camtasia…", systemImage: "square.and.arrow.up.on.square")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!s.anyDone || s.exporting != nil)
                .help("Save every matched recording as its own Camtasia project, all into one folder")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // Slides with their start times
    private var cueList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Slide changes").font(.headline)
                Spacer()
                Menu {
                    ForEach(s.slides.indices, id: \.self) { i in
                        Button("Slide \(s.slides[i].number)") { s.insert(slide: i, at: player.time) }
                    }
                } label: { Label("Add at \(clock(player.time))", systemImage: "plus") }
                    .fixedSize()
            }
            .padding(12)
            List {
                ForEach(s.cues) { c in
                    CueRow(cue: c, isCurrent: s.cues.firstIndex(of: c) == current)
                }
            }
            .listStyle(.inset)
            HStack {
                Spacer()
                Button("Match Again") { if let id = s.selected { s.rematch(id) } }.disabled(s.busy)
                    .help("Throw away these change points and match this recording again")
            }
            .padding(12)
        }
    }

    private var preview: some View {
        Group {
            if let i = current, i < s.cues.count, let img = s.slides[s.cues[i].slide].thumb {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 6, y: 2)
                    .overlay(alignment: .topLeading) {
                        Text("Slide \(s.slides[s.cues[i].slide].number)")
                            .font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(.ultraThinMaterial)).padding(8)
                    }
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 22) }
                .keyboardShortcut(.space, modifiers: [])
            Slider(value: Binding(get: { player.time }, set: { player.seek($0) }), in: 0...max(1, s.duration))
            Text("\(clock(player.time)) / \(clock(s.duration))").monospacedDigit().foregroundStyle(.secondary)
            if !s.searches.isEmpty, let job = s.current {
                let finds = s.finds(for: job)
                Menu {
                    if finds.isEmpty { Text("No keyword finds in this recording") }
                    ForEach(finds) { f in
                        Button("\(clock(f.start))   \(f.search)   “\(f.context.prefix(60))…”") { player.play(from: max(0, f.start - 1)) }
                    }
                } label: {
                    Label("\(finds.count) find\(finds.count == 1 ? "" : "s")", systemImage: "flag.fill")
                }
                .fixedSize()
                .help("Keyword finds in this recording. Each one becomes a marker in the Camtasia project.")
            }
        }
    }

    private var exportBar: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle("Also put the original video in the Media Bin", isOn: $s.includeVideo)
                    .disabled(!["mp4", "mov", "m4v"].contains(s.recording?.pathExtension.lowercased() ?? ""))
                Spacer()
                Button { export(mp4: true) } label: { Label("Export MP4…", systemImage: "film") }
                    .disabled(exporting != nil)
                Button { export(mp4: false) } label: {
                    Label(s.jobs.count > 1 ? "Export This One to Camtasia…" : "Export Camtasia Project…", systemImage: "square.and.arrow.up").padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(s.jobs.count > 1 ? .secondary : .accentColor)
                .disabled(exporting != nil || s.exporting != nil)
            }
            if let e = exporting ?? s.exporting { HStack { ProgressView().controlSize(.small); Text(e) } }
            if let m = s.exportMessage { Text(m).foregroundStyle(.secondary) }
            if let e = exportError { Text(e).foregroundStyle(.orange) }
            if let n = s.current?.note { Text(n).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's said").font(.headline).padding(12)
            ScrollViewReader { proxy in
                List(s.lines) { line in
                    LineRow(line: line, isNow: player.time >= line.start && player.time < line.end,
                            find: findStarts.first { $0.start >= line.start - 0.05 && $0.start <= line.end + 0.05 }?.search)
                        .id(line.id)
                }
                .listStyle(.inset)
                .onChange(of: player.time) { _, t in
                    if player.playing, let l = s.lines.last(where: { $0.start <= t }) { proxy.scrollTo(l.id, anchor: .center) }
                }
            }
        }
    }

    private func export(mp4: Bool) {
        guard let job = s.current, let plan = s.plan(for: job, includeRecording: s.includeVideo) else { return }
        let base = job.name
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = base + (mp4 ? " with slides.mp4" : ".cmproj")
        if mp4 { panel.allowedContentTypes = [.mpeg4Movie] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportError = nil
        exporting = mp4 ? "Making the video…" : "Making the Camtasia project…"
        Task {
            do {
                if mp4 {
                    try await Export.mp4(plan, to: url) { f in
                        Task { @MainActor in exporting = "Making the video… \(Int(f * 100))%" }
                    }
                } else {
                    try await Task.detached { try Export.camtasia(plan, to: url) }.value
                }
                let shown = mp4 || url.pathExtension.lowercased() == "cmproj" ? url : url.appendingPathExtension("cmproj")
                var files = [shown]
                if !mp4, !s.searches.isEmpty {
                    let csv = shown.deletingLastPathComponent().appendingPathComponent(base + " keyword finds.csv")
                    let rows = plan.finds.map { (base, $0) }
                    if (try? Keywords.csv(rows, searches: s.searches).write(to: csv, atomically: true, encoding: .utf8)) != nil {
                        files.append(csv)
                    }
                }
                NSWorkspace.shared.activateFileViewerSelecting(files)
            } catch {
                exportError = "Export failed: \(error.localizedDescription)"
            }
            exporting = nil
        }
    }
}

struct CueRow: View {
    let cue: Cue
    let isCurrent: Bool
    @ObservedObject private var s = Session.shared
    @State private var text = ""

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if cue.slide < s.slides.count, let t = s.slides[cue.slide].thumb {
                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                } else { Rectangle().fill(.quaternary) }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isCurrent ? Color.accentColor : Color.secondary.opacity(0.3),
                                                                    lineWidth: isCurrent ? 2.5 : 1))
            VStack(alignment: .leading, spacing: 4) {
                Menu("Slide \(cue.slide < s.slides.count ? s.slides[cue.slide].number : 0)") {
                    ForEach(s.slides.indices, id: \.self) { i in
                        Button("Slide \(s.slides[i].number)") {
                            if let k = s.cues.firstIndex(where: { $0.id == cue.id }) { s.cues[k].slide = i }
                        }
                    }
                }
                .fixedSize()
                HStack(spacing: 4) {
                    Button { s.setStart(cue.id, cue.start - 0.5) } label: { Image(systemName: "minus") }
                        .help("Half a second earlier")
                    TextField("0:00.0", text: $text)
                        .frame(width: 64)
                        .multilineTextAlignment(.center)
                        .onSubmit { if let t = parseClock(text) { s.setStart(cue.id, t) } else { text = clock(cue.start) } }
                    Button { s.setStart(cue.id, cue.start + 0.5) } label: { Image(systemName: "plus") }
                        .help("Half a second later")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            Spacer()
            VStack(spacing: 6) {
                Button { Player.shared.play(from: max(0, cue.start - 1.5)) } label: { Image(systemName: "play.circle") }
                    .help("Play from just before this change")
                Button { s.remove(cue.id) } label: { Image(systemName: "trash") }
                    .help("Remove this slide change")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .onAppear { text = clock(cue.start) }
        .onChange(of: cue.start) { _, v in text = clock(v) }
    }
}

struct LineRow: View {
    let line: Line
    let isNow: Bool
    var find: String? = nil
    @ObservedObject private var s = Session.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(clock(line.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let find {
                    Label(find, systemImage: "flag.fill").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                }
                Text(line.text).font(.callout).fontWeight(isNow ? .semibold : .regular)
            }
            Spacer(minLength: 0)
            Menu {
                ForEach(s.slides.indices, id: \.self) { i in
                    Button("Slide \(s.slides[i].number)") { s.insert(slide: i, at: line.start) }
                }
            } label: { Image(systemName: "rectangle.badge.plus") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Change to a slide here")
        }
        .contentShape(Rectangle())
        .onTapGesture { Player.shared.play(from: line.start) }
        .listRowBackground(isNow ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

