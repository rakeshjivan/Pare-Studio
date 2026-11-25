// Settings › Voice and Settings › Intros & Outros.

import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Voice

struct VoiceSettings: View {
    @AppStorage("narratorKind") private var kindRaw = ""
    @AppStorage("pareVoiceName") private var voiceName = ""
    @AppStorage("pareVoiceMode") private var modeRaw = PareVoiceMode.turbo.rawValue
    @AppStorage("pareVoiceExpressiveness") private var expressiveness = 0.45
    @AppStorage("pareVoicePace") private var pace = 0.5
    @AppStorage("voiceID") private var macVoiceID = ""
    @ObservedObject private var setup = VoiceSetup.shared

    @State private var voices: [String] = PareVoice.voices
    @State private var message: String?
    @State private var working: String?
    @State private var preview: AVAudioPlayer?
    @State private var showRecorder = false
    @State private var renaming: String?
    @State private var newName = ""
    @State private var removeMusic = false

    private var kind: NarratorKind {
        NarratorKind(rawValue: kindRaw) ?? (PareVoice.isInstalled ? .pareVoice : .mac)
    }

    var body: some View {
        Form {
            Section {
                Picker("Narrator", selection: Binding(get: { kind.rawValue }, set: { kindRaw = $0 })) {
                    ForEach(NarratorKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                if kind == .mac {
                    Picker("Mac voice", selection: $macVoiceID) {
                        Text("System default").tag("")
                        ForEach(Speech.voices, id: \.identifier) { v in Text("\(v.name) (\(v.language))").tag(v.identifier) }
                    }
                    Text("Better Mac voices: System Settings › Accessibility › Spoken Content › System Voice › Manage Voices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if kind == .pareVoice {
                Section("Pare Voice") {
                    setupRow
                    if PareVoice.isInstalled {
                        Picker("Voice", selection: Binding(get: { PareVoice.selectedVoice ?? "" }, set: { voiceName = $0 })) {
                            ForEach(voices, id: \.self) { Text($0).tag($0) }
                        }
                        .disabled(voices.isEmpty)
                        Picker("Mode", selection: $modeRaw) {
                            ForEach(PareVoiceMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        if modeRaw == PareVoiceMode.standard.rawValue {
                            LabeledContent("Expressiveness") {
                                HStack(spacing: 8) {
                                    Text("Calm").font(.caption).foregroundStyle(.secondary)
                                    Slider(value: $expressiveness, in: 0.25...1.0) { EmptyView() }
                                    Text("Lively").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            LabeledContent("Pace") {
                                HStack(spacing: 8) {
                                    Text("Slower").font(.caption).foregroundStyle(.secondary)
                                    Slider(value: $pace, in: 0.0...0.8) { EmptyView() }
                                    Text("Quicker").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                Text("More lively tends to speak faster, so if lines rush, move Pace towards Slower. All the way to Slower is also quickest to make.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button("Reset") { expressiveness = 0.45; pace = 0.5 }.controlSize(.small)
                            }
                        } else {
                            Text("Fast is several times quicker. You can type tags like [laugh] or [sigh] in narration lines.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        VoiceEngineRow()
                        HStack {
                            Button("Play a Sample") { playSample() }.disabled(working != nil || voices.isEmpty)
                            if let w = working { ProgressView().controlSize(.small); Text(w).font(.caption) }
                        }
                    }
                }

                if PareVoice.isInstalled {
                    Section("Voice library") {
                        if voices.isEmpty {
                            Text("No voices yet. Record one, or add one from an audio or video file.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(voices, id: \.self) { v in voiceRow(v) }
                        HStack {
                            Button("Record a Voice…") { showRecorder = true }
                            Button("Add from File…") { addFromFile() }
                            Spacer()
                            Menu("More") {
                                Button("Import Voices…") { importVoices() }
                                Button("Export Voices…") { exportVoices() }.disabled(voices.isEmpty)
                                Button("Show in Finder") {
                                    try? FileManager.default.createDirectory(at: VoiceLibrary.folder, withIntermediateDirectories: true)
                                    NSWorkspace.shared.open(VoiceLibrary.folder)
                                }
                            }
                            .fixedSize()
                        }
                        Toggle("Remove background music when adding from a file", isOn: $removeMusic)
                        Text("Only clone voices you have permission to use. A clean 10–20 second sample of one person speaking works best.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            PronunciationSection()

            if let m = message {
                Section { Text(m).font(.callout) }
            }
        }
        .formStyle(.grouped)
        .onAppear { voices = PareVoice.voices }
        .onChange(of: setup.phase) { _, _ in voices = PareVoice.voices }
        .sheet(isPresented: $showRecorder) {
            RecordVoiceSheet { voices = PareVoice.voices; message = $0 }
        }
        .alert("Rename voice", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let old = renaming {
                    do { try VoiceLibrary.rename(old, to: newName); if voiceName == old { voiceName = VoiceLibrary.safeName(newName) } }
                    catch { message = error.localizedDescription }
                    voices = PareVoice.voices
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    @ViewBuilder private var setupRow: some View {
        switch setup.phase {
        case .running(let step):
            HStack { ProgressView().controlSize(.small); Text(step); Spacer(); Button("Stop") { setup.cancel() } }
            Text("Setup downloads and installs everything by itself. It can take 10–20 minutes the first time.")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let why):
            Text(why).font(.callout).foregroundStyle(.orange)
            Button("Try Again") { setup.run() }
        case .done:
            Label("Pare Voice is set up.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .idle:
            if PareVoice.isInstalled {
                HStack {
                    Label("Ready on this Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Repair or Update") { setup.run() }.controlSize(.small)
                }
            } else {
                Text("Pare Voice narrates videos in cloned voices, entirely on this Mac. One click installs everything it needs (a few GB).")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Set Up Pare Voice") { setup.run() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func voiceRow(_ v: String) -> some View {
        HStack {
            Image(systemName: v == PareVoice.selectedVoice ? "person.wave.2.fill" : "person.wave.2")
                .foregroundStyle(v == PareVoice.selectedVoice ? Color(cgColor: Renderer.accent) : .secondary)
            Text(v)
            Spacer()
            Button { play(VoiceLibrary.url(v)) } label: { Image(systemName: "play.circle") }.help("Play the sample")
            Button { newName = v; renaming = v } label: { Image(systemName: "pencil") }.help("Rename")
            Button { VoiceLibrary.delete(v); voices = PareVoice.voices } label: { Image(systemName: "trash") }.help("Move to Bin")
        }
        .buttonStyle(.borderless)
    }

    private func play(_ url: URL) {
        preview?.stop()
        preview = try? AVAudioPlayer(contentsOf: url)
        preview?.play()
    }

    private func playSample() {
        guard let v = PareVoice.selectedVoice else { return }
        working = "Speaking (the first time loads the voice model)…"
        message = nil
        Task {
            defer { working = nil }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pare-voice-sample.wav")
            do {
                let started = Date()
                let secs = try await PareVoice.say("Here's how to shrink a large PDF with Pare. It only takes a few seconds.", voice: v, to: url)
                let took = Date().timeIntervalSince(started)
                play(url)
                message = String(format: "Made %.1f s of speech in %.1f s with the %@ engine. (Play it twice: the first time also loads the model.)",
                                 secs, took, PareVoice.activeEngine == .mlx ? "Fast (MLX)" : "Standard")
                if let p = PareVoice.mlxProblem, PareVoice.engineSetting == .mlx {
                    message! += "\nThe fast engine didn't work, so Standard was used: \(p.prefix(160))"
                }
            } catch { message = error.localizedDescription }
        }
    }

    private func addFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav]
        panel.message = "Choose a recording of one person speaking (audio or video)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        working = removeMusic ? "Removing music and adding the voice (a minute or two)…" : "Adding the voice…"
        message = nil
        let clean = removeMusic
        Task {
            defer { working = nil }
            do {
                try await VoiceLibrary.add(from: url, name: name, removeMusic: clean)
                voices = PareVoice.voices
                message = "Added \(VoiceLibrary.safeName(name)). Click ▶ to check it, and the pencil to rename it."
            } catch { message = error.localizedDescription }
        }
    }

    private func exportVoices() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pare Voices.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try VoiceLibrary.exportAll(to: url); NSWorkspace.shared.activateFileViewerSelecting([url]) }
        catch { message = error.localizedDescription }
    }

    private func importVoices() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let n = try VoiceLibrary.importAll(from: url)
            voices = PareVoice.voices
            message = n == 0 ? "No new voices in that file." : "Added \(n) voice\(n == 1 ? "" : "s")."
        } catch { message = error.localizedDescription }
    }
}

/// Record a new voice with the microphone, reading a short script.
struct RecordVoiceSheet: View {
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var rec = VoiceRecorder()
    @State private var name = "My voice"
    @State private var error: String?
    @State private var saving = false
    @State private var hasTake = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Record a voice").font(.title2.bold())
            Text("In a quiet room, read this in the voice you want for your videos. Start straight away and keep the same energy.")
                .foregroundStyle(.secondary)
            Text(VoiceRecorder.script)
                .font(.system(size: 18))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
            HStack(spacing: 12) {
                Button(rec.recording ? "Stop" : (hasTake ? "Record Again" : "Start Recording")) {
                    if rec.recording { rec.stop(); hasTake = true }
                    else { Task { error = await rec.start() } }
                }
                .buttonStyle(.borderedProminent)
                .tint(rec.recording ? Color.red : nil)
                ProgressView(value: Double(rec.level)).frame(width: 140)
                Text(String(format: "%.0f s", rec.seconds)).monospacedDigit().foregroundStyle(.secondary)
                if hasTake && !rec.recording {
                    Button("Play") { NSSound(contentsOf: rec.file, byReference: true)?.play() }
                }
            }
            if rec.seconds > 0 && rec.seconds < 10 && hasTake {
                Text("Aim for 12–20 seconds.").font(.caption).foregroundStyle(.orange)
            }
            TextField("Name this voice", text: $name)
            if let e = error { Text(e).foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { rec.stop(); dismiss() }
                Button(saving ? "Saving…" : "Save Voice") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasTake || rec.recording || saving)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await VoiceLibrary.add(from: rec.file, name: name, removeMusic: false)
                onDone("Saved \(VoiceLibrary.safeName(name)).")
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Intros & Outros

struct BrandSettings: View {
    @ObservedObject private var store = BrandStore.shared
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Picker("Use by default", selection: Binding(get: { store.defaultID }, set: { store.defaultID = $0 })) {
                    ForEach(store.all) { Text($0.name).tag($0.id) }
                    Text("None").tag(Brand.noneID)
                }
                Text("Each guide can choose its own in the editor (Narration › Intro & outro).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Pare PDF (built in)") {
                HStack(spacing: 10) {
                    Thumb(image: designed(intro: true), label: "Intro")
                    Thumb(image: designed(intro: false), label: "Outro")
                }
            }

            ForEach(store.custom) { b in
                Section {
                    HStack {
                        TextField("Name", text: Binding(get: { b.name }, set: { var c = b; c.name = $0; store.save(c) }))
                            .font(.headline)
                        Spacer()
                        Button("Delete", role: .destructive) { store.delete(b.id) }
                    }
                    HStack(alignment: .top, spacing: 10) {
                        slot(b, intro: true)
                        slot(b, intro: false)
                    }
                }
            }

            Section {
                Button("Add Your Own Intro & Outro") {
                    store.save(Brand(name: "My intro & outro \(store.custom.count + 1)", wordmark: ""))
                }
                Text("Choose a slide (JPG or PNG) or a video (MP4 or MOV) for the intro and for the outro. Slides show for a few seconds with the intro or outro narration over them; videos play with their own sound (up to 30 seconds). 16:9 at 1920×1080 looks best.")
                    .font(.caption).foregroundStyle(.secondary)
                if let e = error { Text(e).foregroundStyle(.orange).font(.caption) }
            }
        }
        .formStyle(.grouped)
    }

    private func slot(_ b: Brand, intro: Bool) -> some View {
        let name = intro ? b.introFile : b.outroFile
        return VStack(spacing: 6) {
            Thumb(image: preview(name), label: intro ? "Intro" : "Outro", empty: name == nil)
            HStack(spacing: 6) {
                Button(name == nil ? "Choose…" : "Change…") { choose(b, intro: intro) }
                if name != nil {
                    Button("Remove") {
                        var c = b
                        if let f = store.fileURL(name) { try? FileManager.default.removeItem(at: f) }
                        if intro { c.introFile = nil } else { c.outroFile = nil }
                        store.save(c)
                    }
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
    }

    private func choose(_ b: Brand, intro: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .mpeg4Movie, .quickTimeMovie, .movie]
        panel.message = "Choose a slide (JPG, PNG) or a video (MP4, MOV) for the \(intro ? "intro" : "outro")."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var c = b
        let old = intro ? c.introFile : c.outroFile
        do {
            let kind = (intro ? "intro-" : "outro-") + String(UUID().uuidString.prefix(6))
            let saved = try store.importFile(url, for: c.id, kind: kind)
            if let o = store.fileURL(old) { try? FileManager.default.removeItem(at: o) }
            if intro { c.introFile = saved } else { c.outroFile = saved }
            store.save(c)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func designed(intro: Bool) -> NSImage? {
        let size = CGSize(width: 640, height: 360)
        return TutorialVideo.cardPreview(brand: .pare, logo: nil, intro: intro, title: "How to compress a PDF", size: size)
            .map { NSImage(cgImage: $0, size: size) }
    }

    private func preview(_ name: String?) -> NSImage? {
        guard let url = store.fileURL(name) else { return nil }
        if Brand.isImage(name) { return NSImage(contentsOf: url) }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 360)
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// A 16:9 preview with a label underneath.
private struct Thumb: View {
    let image: NSImage?
    let label: String
    var empty = false

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).background(Color.black) }
                else {
                    Rectangle().fill(.quaternary)
                        .overlay(Text(empty ? "None" : "").font(.caption).foregroundStyle(.secondary))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}


/// Words the narrator should say differently, e.g. Pare → Pair.
struct PronunciationSection: View {
    @State private var list = Pronunciations.all
    @ObservedObject private var player = NarrationPlayer.shared

    var body: some View {
        Section {
            ForEach($list) { $p in
                HStack(spacing: 8) {
                    TextField("Word", text: $p.word).frame(maxWidth: 160)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Say it as", text: $p.sayAs)
                    Button {
                        let line = "This is how \(p.word) sounds."
                        Task { try? await player.toggle(line) }
                    } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless)
                        .disabled(p.word.trimmed.isEmpty || p.sayAs.trimmed.isEmpty)
                        .help("Hear it")
                    Button(role: .destructive) { list.removeAll { $0.id == p.id } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remove")
                }
            }
            Button { list.append(Pronunciation(word: "", sayAs: "")) } label: { Label("Add a Word", systemImage: "plus") }
        } header: {
            Text("Pronunciation")
        } footer: {
            Text("If the narrator says a word wrongly, type how it sounds — for example Pare → Pair, or GC → G C.")
        }
        .onChange(of: list) { _, now in Pronunciations.all = now }
    }
}


/// Settings › Voice › Engine: Standard (PyTorch) or Fast (MLX).
struct VoiceEngineRow: View {
    @AppStorage("pareVoiceEngine") private var engineRaw = VoiceEngine.standard.rawValue
    @ObservedObject private var setup = MLXSetup.shared
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Engine", selection: $engineRaw) {
                ForEach(VoiceEngine.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .onChange(of: engineRaw) { _, _ in
                PareVoice.mlxProblem = nil
                PareVoice.stop()
                PareVoice.warmUp()
            }
            if engineRaw == VoiceEngine.mlx.rawValue {
                switch setup.phase {
                case .running(let step):
                    HStack { ProgressView().controlSize(.small); Text(step).font(.callout); Spacer(); Button("Stop") { setup.cancel() } }
                case .failed(let why):
                    Text(why).font(.callout).foregroundStyle(.orange)
                    Button("Try Again") { setup.run() }
                default:
                    if PareVoice.mlxInstalled {
                        Text("Uses Apple's MLX framework, built for M-series chips. Usually faster, and may sound slightly different. If it ever fails, Pare Studio switches back to Standard by itself.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let p = PareVoice.mlxProblem {
                            Text("The fast engine had a problem, so Standard is being used: \(p.prefix(160))")
                                .font(.caption).foregroundStyle(.orange)
                            Button("Try the Fast Engine Again") { PareVoice.mlxProblem = nil; PareVoice.stop(); refresh += 1 }
                                .controlSize(.small)
                        }
                        Button("Repair or Update Fast Engine") { setup.run() }.controlSize(.small)
                    } else {
                        Text("The fast engine isn't installed yet. It installs separately (about 2 GB), so Standard keeps working either way.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Install Fast Engine") { setup.run() }.buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Text("The original engine. Switch to Fast (MLX) to try Apple's faster version; your voices work with both.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .id(refresh)
    }
}
