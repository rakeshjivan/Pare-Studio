// Editor — edit a recorded guide: titles, step wording, order, pictures (blur, crop, highlight),
// AI wording, earlier versions, and export.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct StepRef: Identifiable { let id: UUID }

struct GuideEditor: View {
    let guideID: UUID
    @ObservedObject private var store = GuideStore.shared
    @State private var editing: StepRef?
    @State private var translating = false
    @State private var busy: String?
    @State private var errorText: String?
    @State private var scanning = false
    @State private var aiTask: Task<Void, Never>?
    /// 0 Steps, 1 Grid, 2 Script.
    @AppStorage("editorLayout") private var layout = 0
    /// Script edits also change the step text, so Steps and Grid stay the same as the script.
    @AppStorage("scriptUpdatesSteps") private var scriptUpdatesSteps = true
    @AppStorage("narratorKind") private var voiceKindSetting = ""
    @AppStorage("pareVoiceName") private var voiceNameSetting = ""
    @AppStorage("pareVoiceMode") private var voiceModeSetting = ""
    @AppStorage("pareVoiceExpressiveness") private var voiceExprSetting = 0.45
    @AppStorage("pareVoicePace") private var voicePaceSetting = 0.5
    @State private var linesReady = 0
    @State private var linesTotal = 0
    @FocusState private var titleFocused: Bool
    @State private var picked = Set<UUID>()
    @State private var lastPicked: Int?
    /// Earlier states of this guide, newest last, for the Undo button.
    @State private var undoStack: [(guide: Guide, what: String)] = []
    @State private var undoNote: String?
    @ObservedObject private var brands = BrandStore.shared

    private var guide: Binding<Guide> {
        Binding(get: { store.guide(guideID) ?? Guide(title: "") },
                set: { store.update($0) })
    }

    private func text(_ kp: WritableKeyPath<Guide, String?>) -> Binding<String> {
        Binding(get: { guide.wrappedValue[keyPath: kp] ?? "" },
                set: { v in var g = guide.wrappedValue; g[keyPath: kp] = v.isEmpty ? nil : v; guide.wrappedValue = g })
    }

    private var brandChoice: Binding<String> {
        Binding(get: { guide.wrappedValue.brandID ?? "" },
                set: { v in var g = guide.wrappedValue; g.brandID = v.isEmpty ? nil : v; guide.wrappedValue = g })
    }

    private func stepBinding(_ id: UUID) -> Binding<Step> {
        Binding(get: { guide.wrappedValue.steps.first { $0.id == id } ?? Step(kind: .note, text: "") },
                set: { new in
                    var g = guide.wrappedValue
                    if let i = g.steps.firstIndex(where: { $0.id == id }) { g.steps[i] = new; guide.wrappedValue = g }
                })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch layout {
            case 1: gridView
            case 2: scriptView
            default: listView
            }
            if let note = undoNote {
                HStack {
                    Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
                    Text(note)
                    Spacer()
                    if !undoStack.isEmpty && !note.hasPrefix("Undid") { Button("Undo") { undo() }.buttonStyle(.borderedProminent) }
                    Button { undoNote = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .font(.callout)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
                .task(id: note) {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if undoNote == note { undoNote = nil }
                }
            }
            if busy != nil || errorText != nil || scanning { statusBar }
        }
        .toolbar { toolbar }
        .sheet(item: $editing) { ref in
            StepPictureEditor(guideID: guideID, step: stepBinding(ref.id))
        }
        .sheet(isPresented: $translating) {
            TranslateSheet(guide: guide.wrappedValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoBlurChanged)) { _ in
            scanning = AutoBlur.scanning.contains(guideID)
        }
        .onAppear {
            scanning = AutoBlur.scanning.contains(guideID)
            PareVoice.warmUp()   // so playing a line or making a video starts quickly
        }
        .onDisappear { aiTask?.cancel() }
    }

    // MARK: Grid: see every step at once and delete several together

    private var gridView: some View {
        let steps = guide.wrappedValue.steps
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(picked.isEmpty ? "Click steps to select them (Shift-click for a range)" : "\(picked.count) selected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(picked.count == steps.count && !steps.isEmpty ? "Select None" : "Select All") {
                    picked = picked.count == steps.count ? [] : Set(steps.map(\.id))
                }
                Button { duplicatePicked() } label: {
                    Label(picked.count > 1 ? "Duplicate \(picked.count) Steps" : "Duplicate", systemImage: "plus.square.on.square")
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(picked.isEmpty)
                Button(role: .destructive) { deletePicked() } label: {
                    Label(picked.count > 1 ? "Delete \(picked.count) Steps" : "Delete Step", systemImage: "trash")
                }
                .disabled(picked.isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                        StepTile(guideID: guideID, step: step, number: i + 1, zoom: guide.wrappedValue.zoom,
                                 selected: picked.contains(step.id))
                            .onTapGesture { pick(i, steps) }
                            .overlay(alignment: .topTrailing) {
                                if step.image != nil {
                                    StepZoomMenu(step: stepBinding(step.id), guideZoom: guide.wrappedValue.zoom).padding(6)
                                }
                            }
                            .contextMenu {
                                Picker("Zoom This Picture", selection: stepBinding(step.id).zoomOverride) {
                                    Text("Same as guide").tag(Zoom?.none)
                                    ForEach(Zoom.allCases) { Text($0.rawValue).tag(Zoom?.some($0)) }
                                }
                                Button("Duplicate Step") { duplicate(step.id) }
                                Button("Delete Step", role: .destructive) { picked = [step.id]; deletePicked() }
                            }
                    }
                }
                .padding(16)
            }
            .onDeleteCommand { deletePicked() }
        }
        .onChange(of: steps.map(\.id)) { _, ids in picked.formIntersection(ids) }
    }

    /// Call before a change so Undo can bring the guide back.
    private func remember(_ what: String) {
        undoStack.append((guide.wrappedValue, what))
        if undoStack.count > 40 { undoStack.removeFirst() }
    }

    private func undo() {
        guard let last = undoStack.popLast() else { return }
        var g = last.guide
        g.id = guideID
        store.update(g, forceSnapshot: true)
        undoNote = "Undid: \(last.what)"
        picked = []
    }

    private func pick(_ i: Int, _ steps: [Step]) {
        let id = steps[i].id
        if NSEvent.modifierFlags.contains(.shift), let a = lastPicked, a < steps.count {
            for j in min(a, i)...max(a, i) { picked.insert(steps[j].id) }
        } else if picked.contains(id) {
            picked.remove(id)
        } else {
            picked.insert(id)
        }
        lastPicked = i
    }

    private func deletePicked() {
        guard !picked.isEmpty else { return }
        let n = picked.count
        remember(n == 1 ? "delete step" : "delete \(n) steps")
        undoNote = n == 1 ? "Deleted 1 step" : "Deleted \(n) steps"
        var g = guide.wrappedValue
        g.steps.removeAll { picked.contains($0.id) }
        store.update(g, forceSnapshot: true)   // Versions can bring them back
        picked = []
        lastPicked = nil
    }

    private var listView: some View {
            List {
                ForEach(Array(guide.wrappedValue.steps.enumerated()), id: \.element.id) { i, step in
                    StepRow(guideID: guideID, step: stepBinding(step.id), number: i + 1, zoom: guide.wrappedValue.zoom,
                            showNarration: false,
                            onEditPicture: { editing = StepRef(id: step.id) },
                            onDelete: { delete(step.id) },
                            onAI: { writeWithAI(only: step.id) },
                            onDuplicate: { duplicate(step.id) })
                        .listRowSeparator(.hidden)
                        .padding(.vertical, 6)
                }
                .onMove { from, to in
                    remember("move step")
                    var g = guide.wrappedValue
                    g.steps.move(fromOffsets: from, toOffset: to)
                    store.update(g, forceSnapshot: true)
                }
                Button {
                    var g = guide.wrappedValue
                    g.steps.append(Step(kind: .note, text: "Add a note or tip here."))
                    guide.wrappedValue = g
                } label: { Label("Add a text-only step", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 8)
            }
            .listStyle(.inset)
    }

    private var isUnnamed: Bool {
        let t = guide.wrappedValue.title.trimmed
        return t.isEmpty || t.hasPrefix("New guide")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Guide title", text: guide.title)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .bold))
                .focused($titleFocused)
            if isUnnamed {
                HStack(spacing: 10) {
                    Image(systemName: "pencil.line").foregroundStyle(Color(cgColor: Renderer.accent))
                    Text("Give this guide a name. It's the title of the guide and is read out in the video intro.")
                    Spacer()
                    Button("Type a Name") {
                        var g = guide.wrappedValue; g.title = ""; guide.wrappedValue = g
                        titleFocused = true
                    }
                    Button("Suggest a Name") { writeTitle() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy != nil)
                }
                .font(.callout)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(cgColor: Renderer.accent).opacity(0.1)))
            }
            TextField("Add a one-line summary (optional)", text: guide.summary, axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
            if layout != 2 {
                HStack {
                    Picker("All pictures", selection: guide.zoom) {
                        ForEach(Zoom.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                    Spacer()
                    Text("\(guide.wrappedValue.steps.count) steps · change one picture with its 🔍 button")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if busy != nil || scanning { ProgressView().controlSize(.small) }
            if let b = busy { Text(b) } else if scanning { Text("Checking screenshots for private details…") }
            if let e = errorText {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(e).lineLimit(2)
            }
            Spacer()
            if aiTask != nil { Button("Stop") { aiTask?.cancel() } }
            if errorText != nil { Button("Dismiss") { errorText = nil } }
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("Layout", selection: $layout) {
                Text("Steps").tag(0)
                Text("Grid").tag(1)
                Text("Script").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
            .help("Steps: edit each step · Grid: see them all and delete several · Script: write and hear the voiceover")
        }
        ToolbarItem {
            Button { undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .labelStyle(.titleAndIcon)
                .disabled(undoStack.isEmpty)
                .help(undoStack.last.map { "Undo \($0.what)" } ?? "Nothing to undo")
        }
        ToolbarItemGroup {
            Group {
            Menu {
                Button("Write Every Step") { writeWithAI(only: nil) }
                Button("Write Title and Summary") { writeTitle() }
                Button("Write Narration Script") { writeNarration() }
                Button("Polish My Spoken Narration") { polishSpoken() }
                    .help("Tidies what you said while recording into clean voiceover lines")
                Divider()
                Button("Translate Guide…") { translating = true }
                    .help("Make a copy of this guide in another language")
                Divider()
                SettingsLink { Text("AI Settings…") }
            } label: { Label("Write with AI", systemImage: "sparkles") }
                .disabled(busy != nil)
                .help("Uses your Claude subscription, Apple Intelligence or an API key (Settings › AI)")

            Button { AutoBlur.scan(guideID: guideID, force: true) } label: {
                Label("Blur", systemImage: "eye.slash")
            }
            .help("Find emails, phone and card numbers in every screenshot and blur them")

            Menu {
                let versions = store.versions(guideID)
                if versions.isEmpty { Text("No earlier versions yet") }
                ForEach(versions.prefix(25)) { v in
                    Button(v.date.formatted(date: .abbreviated, time: .standard)) { store.restore(v, into: guideID) }
                }
            } label: { Label("Versions", systemImage: "clock.arrow.circlepath") }
                .help("Roll back to an earlier version of this guide")

            Menu {
                Button("Tutorial Video (.mp4)") { export(.tutorial, narrate: true) }
                Button("Camtasia Project (to edit, with narration)") { export(.camtasia, narrate: true) }
                CaptionsMenu()
                Divider()
                ForEach(ExportFormat.allCases.filter { $0 != .tutorial && $0 != .camtasia }) { f in
                    Button(f.rawValue) { export(f, narrate: false) }
                    if f == .mp4 { Button("Simple slideshow with Mac narration (.mp4)") { export(.mp4, narrate: true) } }
                }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
            }
            .labelStyle(.titleAndIcon)
                .disabled(busy != nil || guide.wrappedValue.steps.isEmpty)
        }
    }

    // MARK: Actions

    /// Copies a step (picture, drawings, blurs, crop, zoom, wording and narration) and puts the copy right after it.
    private func duplicate(_ id: UUID) {
        var g = guide.wrappedValue
        guard let i = g.steps.firstIndex(where: { $0.id == id }) else { return }
        remember("duplicate step")
        undoNote = "Duplicated step \(i + 1)"
        var copy = g.steps[i]
        copy.id = UUID()
        copy.time = Date()
        copy.annotations = copy.annotations?.map { var m = $0; m.id = UUID(); return m }
        g.steps.insert(copy, at: i + 1)
        store.update(g, forceSnapshot: true)
        picked = [copy.id]
    }

    /// Duplicates every selected step, each copy right after its original (⌘D in Grid).
    private func duplicatePicked() {
        var g = guide.wrappedValue
        let ids = g.steps.map(\.id).filter { picked.contains($0) }
        guard !ids.isEmpty else { return }
        if ids.count == 1 { duplicate(ids[0]); return }
        remember("duplicate steps")
        undoNote = "Duplicated \(ids.count) steps"
        var copies = Set<UUID>()
        for id in ids.reversed() {
            guard let i = g.steps.firstIndex(where: { $0.id == id }) else { continue }
            var copy = g.steps[i]
            copy.id = UUID()
            copy.time = Date()
            copy.annotations = copy.annotations?.map { var m = $0; m.id = UUID(); return m }
            g.steps.insert(copy, at: i + 1)
            copies.insert(copy.id)
        }
        store.update(g, forceSnapshot: true)
        picked = copies
    }

    private func delete(_ id: UUID) {
        remember("delete step")
        undoNote = "Deleted 1 step"
        var g = guide.wrappedValue
        g.steps.removeAll { $0.id == id }
        store.update(g, forceSnapshot: true)
    }

    private func writeWithAI(only: UUID?) {
        guard AI.isReady else { errorText = AI.notReadyMessage; return }
        let g = guide.wrappedValue
        remember("AI step wording")
        store.update(g, forceSnapshot: true)
        let targets = g.steps.enumerated().filter { (only == nil || $0.element.id == only) && $0.element.image != nil }
        guard !targets.isEmpty else { return }
        errorText = nil
        aiTask = Task {
            defer { busy = nil; aiTask = nil }
            // Claude Code reads several screenshots per request; the others go one at a time.
            let chunk = AI.provider == .claudeCode ? 8 : 1
            var i = 0
            while i < targets.count {
                if Task.isCancelled { return }
                let slice = Array(targets[i..<min(i + chunk, targets.count)])
                busy = targets.count == 1 ? "Writing step \(slice[0].offset + 1)…"
                    : "Writing steps \(i + 1)–\(i + slice.count) of \(targets.count)…"
                let zoom = g.zoom
                let inputs = slice.map { ($0.offset + 1, $0.element, $0.element.image.map { store.imageURL(guideID, $0) }) }
                let jobs: [AIJob] = await Task.detached {
                    inputs.compactMap { n, s, url -> AIJob? in
                        guard let pic = url.flatMap(GuideStore.loadImage)
                            .flatMap({ Renderer.render(s, base: $0, zoom: zoom, maxWidth: 1600) }) else { return nil }
                        return AIJob(number: n, step: s, picture: pic)
                    }
                }.value
                do {
                    let texts = try await AI.write(jobs)
                    for (id, t) in texts where !t.isEmpty {
                        let b = stepBinding(id)
                        b.wrappedValue.text = t
                    }
                    if let note = AI.lastNote { errorText = note }
                } catch {
                    if !Task.isCancelled { errorText = error.localizedDescription }
                    return
                }
                i += chunk
            }
        }
    }

    private func writeTitle() {
        guard AI.isReady else { errorText = AI.notReadyMessage; return }
        remember("AI title")
        busy = "Writing title…"
        errorText = nil
        Task {
            defer { busy = nil }
            do {
                let (t, s) = try await AI.titleAndSummary(guide.wrappedValue)
                var g = guide.wrappedValue
                g.title = t
                g.summary = s
                store.update(g, forceSnapshot: true)
            } catch { errorText = error.localizedDescription }
        }
    }

    private func writeNarration() {
        guard AI.isReady else { errorText = AI.notReadyMessage; return }
        busy = "Writing the narration script…"
        errorText = nil
        let g = guide.wrappedValue
        remember("AI narration")
        store.update(g, forceSnapshot: true)
        let brand = brands.brand(g.brandID)
        aiTask = Task {
            defer { busy = nil; aiTask = nil }
            do {
                let script = try await AI.narration(g, brand: brand)
                var now = guide.wrappedValue
                if !script.intro.isEmpty { now.introNarration = script.intro }
                if !script.outro.isEmpty { now.outroNarration = script.outro }
                for i in now.steps.indices { if let l = script.steps[now.steps[i].id] { now.steps[i].narration = l } }
                store.update(now, forceSnapshot: true)
                layout = 2
            } catch {
                if !Task.isCancelled { errorText = error.localizedDescription }
            }
        }
    }

    private func polishSpoken() {
        guard AI.isReady else { errorText = AI.notReadyMessage; return }
        busy = "Polishing your narration…"
        errorText = nil
        let g = guide.wrappedValue
        remember("AI narration polish")
        aiTask = Task {
            defer { busy = nil; aiTask = nil }
            do {
                let lines = try await AI.polishSpoken(g)
                var now = guide.wrappedValue
                for i in now.steps.indices { if let l = lines[now.steps[i].id] { now.steps[i].narration = l } }
                store.update(now, forceSnapshot: true)
                layout = 2
            } catch {
                if !Task.isCancelled { errorText = error.localizedDescription }
            }
        }
    }

    // MARK: Script: the whole voiceover in one place

    private var scriptView: some View {
        let g = guide.wrappedValue
        let total = Narrator.estimate(g.introNarration ?? g.title)
            + g.steps.reduce(0) { $0 + Narrator.estimate(($1.narration ?? "").isEmpty ? $1.text : $1.narration!) }
            + Narrator.estimate(g.outroNarration ?? "")
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                VoiceQuickPicker()
                CaptionsMenu().fixedSize()
                Picker("Intro & outro", selection: brandChoice) {
                    let def = brands.brand(nil)?.name ?? "None"
                    Text("Intro & outro: \(def)").tag("")
                    ForEach(brands.all) { Text("Intro & outro: \($0.name)").tag($0.id) }
                    Text("No intro or outro").tag(Brand.noneID)
                }
                .labelsHidden()
                .fixedSize()
                Toggle("Edits update the steps", isOn: $scriptUpdatesSteps)
                    .toggleStyle(.checkbox)
                    .help("On: changing a line here also changes that step's text in Steps and Grid. Off: the narrator can say something different from the written step.")
                Spacer()
                Button { export(.camtasia, narrate: true) } label: {
                    Label("Camtasia Project", systemImage: "square.and.arrow.up.on.square")
                }
                .controlSize(.large)
                .disabled(busy != nil)
                .help("Export as a Camtasia project with separate clips, narration and clicks, so you can add transitions and edit")
                Button { export(.tutorial, narrate: true) } label: {
                    Label("Make Video", systemImage: "film")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy != nil)
                .help("Export this guide as a narrated tutorial video (.mp4)")
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            HStack(spacing: 8) {
                Text("About \(Self.duration(total)) of speaking").foregroundStyle(.secondary)
                if linesTotal > 0 {
                    Text("·").foregroundStyle(.secondary)
                    if linesReady < linesTotal {
                        ProgressView().controlSize(.mini)
                        Text("Preparing the voice: \(linesReady) of \(linesTotal) lines ready").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Voice ready — the video will be quick to make").foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("▶ Play hears a line. A blank line reads the step text.").foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 20).padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if hasIntro {
                    scriptRow(badge: "Intro", picture: nil) {
                        NarrationField(label: nil, text: text(\.introNarration),
                                       placeholder: g.title.plain.isEmpty ? "Spoken over the intro" : g.title.plain,
                                       context: g.title.plain, full: true,
                                       linkedDefault: !g.title.plain.isEmpty,
                                       beforeRewrite: { remember("rewrite"); undoNote = "Line rewritten" })
                    }
                    }
                    ForEach(Array(g.steps.enumerated()), id: \.element.id) { i, step in
                        scriptRow(badge: "\(i + 1)", picture: step) {
                            VStack(alignment: .leading, spacing: 4) {
                                if !(step.narration ?? "").trimmed.isEmpty {
                                    Text("Step: " + step.text.plain)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                } else {
                                    Text(scriptUpdatesSteps ? "Click to edit — changes the step text too" : "Same as the step text — click to edit what's said")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                NarrationField(label: nil,
                                               text: Binding(get: { stepBinding(step.id).wrappedValue.narration ?? "" },
                                                             set: { v in
                                                                 let b = stepBinding(step.id)
                                                                 if scriptUpdatesSteps, !v.trimmed.isEmpty {
                                                                     // Keep one wording everywhere: the step text becomes the script line.
                                                                     var st = b.wrappedValue
                                                                     st.text = Self.rebold(old: st.text, new: v)
                                                                     st.narration = nil
                                                                     b.wrappedValue = st
                                                                 } else {
                                                                     b.wrappedValue.narration = v.isEmpty ? nil : v
                                                                 }
                                                             }),
                                               placeholder: step.text.plain.isEmpty ? "What the narrator says" : step.text.plain,
                                               context: g.title.plain, full: true,
                                               linkedDefault: !step.text.plain.isEmpty,
                                       beforeRewrite: { remember("rewrite"); undoNote = "Line rewritten" },
                                       onDelete: { delete(step.id) },
                                       onDuplicate: { duplicate(step.id) })
                            }
                        }
                    }
if hasIntro {
                    scriptRow(badge: "Outro", picture: nil) {
                        NarrationField(label: nil, text: text(\.outroNarration),
                                       placeholder: "Spoken over the closing card (optional)",
                                       context: g.title.plain, full: true,
                                       beforeRewrite: { remember("rewrite"); undoNote = "Line rewritten" })
                    }
                    }
                }
                .padding(20)
            }
        }
        .onDisappear { NarrationPlayer.shared.stop() }
        .task(id: prefetchKey) { await prepareVoice() }
    }

    // MARK: Make the voice in the background, so Make Video is quick

    /// Every line the video will say, in order.
    private var spokenLines: [String] {
        let g = guide.wrappedValue
        var out: [String] = []
        if brands.brand(g.brandID) != nil { out.append((g.introNarration ?? "").trimmed.isEmpty ? g.title : g.introNarration!) }
        for st in g.steps {
            let c = (st.narration ?? "").trimmed
            out.append(c.isEmpty ? st.text.plain : c)
        }
        if let o = g.outroNarration, !o.trimmed.isEmpty { out.append(o) }
        return out.filter { !$0.trimmed.isEmpty }
    }

    private var prefetchKey: String {
        [voiceKindSetting, voiceNameSetting, voiceModeSetting, "\(voiceExprSetting)", "\(voicePaceSetting)",
         busy == nil ? "idle" : "busy"].joined(separator: "|") + "\n" + spokenLines.joined(separator: "\n")
    }

    private func prepareVoice() async {
        let lines = spokenLines
        guard Narrator.effectiveKind == .pareVoice else { linesTotal = 0; return }
        linesTotal = lines.count
        linesReady = lines.filter { Narrator.isReady($0) }.count
        guard busy == nil, linesReady < linesTotal else { return }
        // Wait until typing pauses, then make the missing lines one at a time.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let tmp = FileManager.default.temporaryDirectory
        for line in lines where !Narrator.isReady(line) {
            if Task.isCancelled { return }
            _ = try? await Narrator.record(line, name: "prefetch", in: tmp)
            if Task.isCancelled { return }
            linesReady = lines.filter { Narrator.isReady($0) }.count
        }
    }

    private var hasIntro: Bool { brands.brand(guide.wrappedValue.brandID) != nil }

    private func scriptRow<C: View>(badge: String, picture: Step?, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .topLeading) {
                if let step = picture, step.image != nil {
                    StepPicture(guideID: guideID, step: step, zoom: .close, maxWidth: 400)
                        .aspectRatio(16 / 10, contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .overlay(Image(systemName: picture == nil ? "film" : "text.alignleft").foregroundStyle(.secondary))
                }
                Text(badge)
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                    .background(Capsule().fill(Color(cgColor: Renderer.accent)))
                    .padding(5)
            }
            .frame(width: 150)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Puts **bold** back around on-screen labels that are still in the new wording.
    static func rebold(old: String, new: String) -> String {
        var out = new
        for part in old.boldParts where part.bold {
            let label = part.text.trimmed
            guard !label.isEmpty, !out.contains("**\(label)**"), let r = out.range(of: label) else { continue }
            out.replaceSubrange(r, with: "**\(label)**")
        }
        return out
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t < 60 ? "\(t) sec" : "\(t / 60) min \(t % 60) sec"
    }

    private func export(_ format: ExportFormat, narrate: Bool) {
        let g = guide.wrappedValue
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        if format == .markdown {
            panel.nameFieldStringValue = Exporter.safeName(g.title)
            panel.message = "Pare Studio makes a folder with the Markdown file and its images."
        } else if format == .camtasia {
            panel.nameFieldStringValue = Exporter.safeName(g.title) + ".cmproj"
            panel.message = "Makes a Camtasia project, plus a captions file (.srt) beside it."
        } else {
            panel.nameFieldStringValue = Exporter.safeName(g.title) + "." + format.ext
            panel.allowedContentTypes = [UTType(filenameExtension: format.ext) ?? .data]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = "Exporting…"
        errorText = nil
        Task {
            defer { busy = nil }
            do {
                try await Exporter.run(format, guide: g, to: url, narrate: narrate) { msg in
                    Task { @MainActor in if busy != nil { busy = msg } }
                }
                let shown = format == .markdown ? url.deletingPathExtension() : url
                NSWorkspace.shared.activateFileViewerSelecting([shown])
            } catch {
                errorText = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - One step in the list

struct StepRow: View {
    let guideID: UUID
    @Binding var step: Step
    let number: Int
    let zoom: Zoom
    var showNarration = false
    let onEditPicture: () -> Void
    let onDelete: () -> Void
    let onAI: () -> Void
    var onDuplicate: (() -> Void)? = nil
    @State private var hovering = false
    @State private var isEditing = false
    @FocusState private var focused: Bool

    /// The step text with **bold** shown as bold.
    private var rendered: AttributedString {
        guard !step.text.trimmed.isEmpty else {
            var a = AttributedString("Describe this step")
            a.foregroundColor = .secondary
            return a
        }
        var out = AttributedString()
        for part in step.text.boldParts {
            var a = AttributedString(part.text)
            if part.bold { a.font = .system(size: 15, weight: .semibold) }
            out += a
        }
        return out
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color(cgColor: Renderer.accent)))
            VStack(alignment: .leading, spacing: 8) {
                if isEditing {
                    TextField("Describe this step", text: $step.text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onSubmit { isEditing = false }
                        .onChange(of: focused) { _, now in if !now { isEditing = false } }
                } else {
                    Text(rendered)
                        .font(.system(size: 15))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isEditing = true
                            DispatchQueue.main.async { focused = true }
                        }
                        .help("Click to edit. Put **double asterisks** around words to make them bold.")
                }
                if showNarration {
                    NarrationField(label: nil,
                                   text: Binding(get: { step.narration ?? "" },
                                                 set: { step.narration = $0.isEmpty ? nil : $0 }),
                                   placeholder: step.text.plain.isEmpty ? "What the narrator says" : step.text.plain,
                                   linkedDefault: !step.text.plain.isEmpty)
                }
                if !step.appName.isEmpty {
                    Text([step.appName, step.windowTitle].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if step.image != nil {
                    StepPicture(guideID: guideID, step: step, zoom: zoom, maxWidth: 1100)
                        .frame(maxWidth: 520, alignment: .leading)
                        .overlay(alignment: .topTrailing) { StepZoomMenu(step: $step, guideZoom: zoom).padding(6) }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                        .onTapGesture(perform: onEditPicture)
                        .help("Click to blur, crop or move the highlight")
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                if step.image != nil {
                    Button(action: onEditPicture) { Image(systemName: "crop") }.help("Edit picture")
                    Button(action: onAI) { Image(systemName: "sparkles") }.help("Write this step with AI")
                }
                if let onDuplicate {
                    Button(action: onDuplicate) { Image(systemName: "plus.square.on.square") }.help("Duplicate step")
                }
                Button(action: onDelete) { Image(systemName: "trash") }.help("Delete step")
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0.35)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// The finished picture for a step, rendered in the background.
struct StepPicture: View {
    let guideID: UUID
    let step: Step
    let zoom: Zoom
    var maxWidth = 1100
    @State private var image: NSImage?

    /// Finished pictures kept in memory, so scrolling and switching views never re-draws them.
    static let cache: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.totalCostLimit = 400_000_000; return c }()

    init(guideID: UUID, step: Step, zoom: Zoom, maxWidth: Int = 1100) {
        self.guideID = guideID
        self.step = step
        self.zoom = zoom
        self.maxWidth = maxWidth
        _image = State(initialValue: Self.cache.object(forKey: Self.key(guideID, step, zoom, maxWidth) as NSString))
    }

    private static func key(_ g: UUID, _ step: Step, _ zoom: Zoom, _ w: Int) -> String {
        "\(g)|\(step.image ?? "")|\(step.blurs)|\(String(describing: step.crop))|\(String(describing: step.highlight))|\(step.showHighlight)|\(zoom.rawValue)|\(step.zoomOverride?.rawValue ?? "-")|\(step.annotations ?? [])|\(w)"
    }
    private var key: String { Self.key(guideID, step, zoom, maxWidth) }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary).aspectRatio(16 / 10, contentMode: .fit)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: key) {
            if let hit = Self.cache.object(forKey: key as NSString) { image = hit; return }
            guard let name = step.image else { return }
            let url = GuideStore.shared.imageURL(guideID, name)
            let s = step, z = zoom, m = maxWidth
            let cg = await Task.detached(priority: .userInitiated) {
                GuideStore.loadImage(url).flatMap { Renderer.render(s, base: $0, zoom: z, maxWidth: m) }
            }.value
            if let cg {
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                Self.cache.setObject(img, forKey: key as NSString, cost: cg.width * cg.height * 4)
                image = img
            }
        }
    }
}

// MARK: - Picture editor (blur, crop, highlight)

struct StepPictureEditor: View {
    let guideID: UUID
    @Binding var step: Step
    @Environment(\.dismiss) private var dismiss

    enum Tool: String, CaseIterable, Identifiable {
        case blur = "Blur", crop = "Crop", highlight = "Highlight"
        case arrow = "Arrow", box = "Box", circle = "Circle", text = "Text", number = "Number"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .blur: return "eye.slash"
            case .crop: return "crop"
            case .highlight: return "cursorarrow.rays"
            case .arrow: return "arrow.up.right"
            case .box: return "rectangle"
            case .circle: return "circle"
            case .text: return "textformat"
            case .number: return "1.circle"
            }
        }
        var kind: Annotation.Kind? {
            switch self {
            case .arrow: return .arrow
            case .box: return .box
            case .circle: return .circle
            case .text: return .text
            case .number: return .number
            default: return nil
            }
        }
        var help: String {
            switch self {
            case .blur: return "Drag over anything private. Click a blur box to remove it."
            case .crop: return "Drag the handles to crop, or drag inside the box to move it."
            case .highlight: return "Drag a box around the thing to click."
            case .arrow: return "Drag from where the arrow starts to where it points."
            case .box: return "Drag to draw a box."
            case .circle: return "Drag to draw a circle."
            case .text: return "Click where the label goes, then type its words below."
            case .number: return "Click to drop numbered markers: 1, 2, 3…"
            }
        }
    }

    @State private var draft = Step(kind: .note, text: "")
    @State private var tool: Tool = .blur
    @State private var preview: NSImage?
    @State private var pixelSize = CGSize(width: 16, height: 10)
    @State private var dragStart: CGPoint?
    @State private var dragNow: CGPoint?
    @State private var detecting = false
    @State private var selectedMark: UUID?
    /// What the current crop drag is doing: moving a handle (0–7), moving the whole box, or drawing a new one.
    private enum CropAction { case handle(Int), move, new }
    @State private var cropAction: CropAction?
    @State private var cropAtStart = CGRect.zero
    @AppStorage("annotationColour") private var markColourRaw = Annotation.Colour.red.rawValue
    @AppStorage("annotationSize") private var markSize = 1.0
    @FocusState private var labelFocused: Bool

    private var markColour: Annotation.Colour { Annotation.Colour(rawValue: markColourRaw) ?? .red }
    private var selectedIndex: Int? { selectedMark.flatMap { id in draft.marks.firstIndex { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("Tool", selection: $tool) {
                    ForEach(Tool.allCases) { t in Label(t.rawValue, systemImage: t.icon).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(tool.help).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
            if tool.kind != nil || selectedIndex != nil { markBar }

            GeometryReader { geo in
                let fit = fitted(pixelSize, in: geo.size)
                let s = fit.width > 0 ? pixelSize.width / fit.width : 1
                ZStack(alignment: .topLeading) {
                    if let preview {
                        Image(nsImage: preview).resizable().frame(width: fit.width, height: fit.height)
                    } else {
                        Rectangle().fill(.quaternary).frame(width: fit.width, height: fit.height).overlay(ProgressView())
                    }
                    // Crop: dim everything outside, with handles to drag while the Crop tool is on.
                    if draft.crop != nil || tool == .crop {
                        let r = view(draft.crop ?? CGRect(origin: .zero, size: pixelSize), s)
                        if draft.crop != nil {
                            Path { p in
                                p.addRect(CGRect(origin: .zero, size: fit))
                                p.addRect(r)
                            }
                            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                        }
                        Rectangle().strokeBorder(Color.white, lineWidth: 2)
                            .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                            .shadow(color: .black.opacity(0.4), radius: 1)
                        if tool == .crop {
                            // Rule-of-thirds guides
                            Path { p in
                                for k in 1...2 {
                                    let x = r.minX + r.width * CGFloat(k) / 3, y = r.minY + r.height * CGFloat(k) / 3
                                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                                }
                            }
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                            ForEach(0..<8, id: \.self) { h in
                                let pt = Self.handlePoint(h, in: r)
                                let corner = h % 2 == 0
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.white)
                                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
                                    .frame(width: corner ? 14 : (h == 1 || h == 5 ? 26 : 8), height: corner ? 14 : (h == 1 || h == 5 ? 8 : 26))
                                    .position(pt)
                            }
                        }
                    }
                    ForEach(Array(draft.blurs.enumerated()), id: \.offset) { _, b in
                        let r = view(b, s)
                        Rectangle().strokeBorder(Color.blue, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    }
                    AnnotationOverlay(marks: draft.marks, pixelsPerPoint: s, unit: CGFloat(draft.scale), selected: selectedMark)
                        .frame(width: fit.width, height: fit.height)
                        .allowsHitTesting(false)
                    if let a = dragStart, let b = dragNow, tool == .arrow {
                        Path { p in p.move(to: a); p.addLine(to: b) }
                            .stroke(Color(cgColor: markColour.cg), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 3]))
                    } else if let a = dragStart, let b = dragNow, tool.kind != .text, tool.kind != .number {
                        let r = rect(a, b)
                        Rectangle().strokeBorder(tool == .blur ? Color.blue : tool == .crop ? Color.white : Color(cgColor: Renderer.accent),
                                                 style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                            .background(Color.white.opacity(0.08))
                            .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    }
                }
                .frame(width: fit.width, height: fit.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if tool == .crop { cropDrag(v, fit: fit, scale: s); return }
                            dragStart = clamp(v.startLocation, fit)
                            dragNow = clamp(v.location, fit)
                        }
                        .onEnded { v in
                            if tool == .crop { cropDrag(v, fit: fit, scale: s); cropAction = nil; return }
                            let a = clamp(v.startLocation, fit), b = clamp(v.location, fit)
                            dragStart = nil
                            dragNow = nil
                            finishDrag(a, b, scale: s)
                        }
                )
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .padding(.horizontal, 12)

            HStack {
                Picker("Zoom", selection: $draft.zoomOverride) {
                    Text("Same as guide").tag(Zoom?.none)
                    ForEach(Zoom.allCases) { Text($0.rawValue).tag(Zoom?.some($0)) }
                }
                .fixedSize()
                .help("Zoom for this picture only")
                Toggle("Show highlight", isOn: $draft.showHighlight)
                Button("Remove all blurs") { draft.blurs = [] }.disabled(draft.blurs.isEmpty)
                Button("Find private details") { detect() }.disabled(detecting)
                if detecting { ProgressView().controlSize(.small) }
                Button("Reset crop") { draft.crop = nil }.disabled(draft.crop == nil)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { step = draft; dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 1100, idealWidth: 1240, minHeight: 700, idealHeight: 840)
        .onAppear { draft = step }
        .task(id: previewKey) { await renderPreview() }
    }

    private var previewKey: String { "\(draft.blurs)|\(String(describing: draft.highlight))|\(draft.showHighlight)|\(draft.image ?? "")" }

    private func renderPreview() async {
        guard let name = draft.image else { return }
        let url = GuideStore.shared.imageURL(guideID, name)
        var s = draft
        s.crop = nil
        s.zoomOverride = nil
        s.annotations = nil   // drawn live on top while editing
        let st = s
        let result = await Task.detached(priority: .userInitiated) { () -> (CGImage, CGSize)? in
            guard let base = GuideStore.loadImage(url),
                  let out = Renderer.render(st, base: base, zoom: .off, maxWidth: 2400) else { return nil }
            return (out, CGSize(width: base.width, height: base.height))
        }.value
        if let r = result {
            pixelSize = r.1
            preview = NSImage(cgImage: r.0, size: NSSize(width: r.0.width, height: r.0.height))
        }
    }

    private func detect() {
        guard let name = draft.image else { return }
        let url = GuideStore.shared.imageURL(guideID, name)
        detecting = true
        Task {
            let found = await Task.detached { GuideStore.loadImage(url).map(Sensitive.find) ?? [] }.value
            for r in found where !draft.blurs.contains(where: { $0.contains(CGPoint(x: r.midX, y: r.midY)) }) {
                draft.blurs.append(r)
            }
            detecting = false
        }
    }

    private func finishDrag(_ a: CGPoint, _ b: CGPoint, scale s: CGFloat) {
        let r = rect(a, b)
        let px = CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s)
        let isClick = r.width < 4 && r.height < 4
        if let kind = tool.kind {
            let pa = CGPoint(x: a.x * s, y: a.y * s), pb = CGPoint(x: b.x * s, y: b.y * s)
            let u = CGFloat(draft.scale)
            // Clicking on a drawing selects it.
            if isClick, let hit = draft.marks.last(where: { Renderer.bounds($0, unit: u).contains(pa) }) {
                selectedMark = hit.id
                return
            }
            var m = Annotation(kind: kind, a: pa, b: pb, colour: markColour, size: markSize)
            switch kind {
            case .arrow, .box, .circle:
                guard !isClick else { selectedMark = nil; return }
            case .text:
                m.b = pa
                m.text = "Label"
            case .number:
                m.b = pa
                let used = draft.marks.filter { $0.kind == .number }.compactMap { Int($0.text) }
                m.text = "\((used.max() ?? 0) + 1)"
            }
            draft.marks.append(m)
            selectedMark = m.id
            if kind == .text { DispatchQueue.main.async { labelFocused = true } }
            return
        }
        switch tool {
        case .blur:
            if isClick {
                let p = CGPoint(x: a.x * s, y: a.y * s)
                if let i = draft.blurs.lastIndex(where: { $0.contains(p) }) { draft.blurs.remove(at: i) }
            } else { draft.blurs.append(px) }
        case .crop:
            if !isClick { draft.crop = px }
        case .highlight:
            if isClick {
                draft.clickPoint = CGPoint(x: a.x * s, y: a.y * s)
            } else {
                draft.highlight = px
                draft.clickPoint = CGPoint(x: px.midX, y: px.midY)
            }
            draft.showHighlight = true
        default: break
        }
    }

    // MARK: Crop handles

    /// Handles go clockwise from the top-left corner: 0 TL, 1 top, 2 TR, 3 right, 4 BR, 5 bottom, 6 BL, 7 left.
    static func handlePoint(_ h: Int, in r: CGRect) -> CGPoint {
        switch h {
        case 0: return CGPoint(x: r.minX, y: r.minY)
        case 1: return CGPoint(x: r.midX, y: r.minY)
        case 2: return CGPoint(x: r.maxX, y: r.minY)
        case 3: return CGPoint(x: r.maxX, y: r.midY)
        case 4: return CGPoint(x: r.maxX, y: r.maxY)
        case 5: return CGPoint(x: r.midX, y: r.maxY)
        case 6: return CGPoint(x: r.minX, y: r.maxY)
        default: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    private func cropDrag(_ v: DragGesture.Value, fit: CGSize, scale s: CGFloat) {
        let full = CGRect(origin: .zero, size: pixelSize)
        let current = draft.crop ?? full
        let viewRect = view(current, s)
        if cropAction == nil {
            cropAtStart = current
            let p = v.startLocation
            if let h = (0..<8).first(where: { hypot(Self.handlePoint($0, in: viewRect).x - p.x, Self.handlePoint($0, in: viewRect).y - p.y) < 14 }) {
                cropAction = .handle(h)
            } else if viewRect.insetBy(dx: 4, dy: 4).contains(p), draft.crop != nil {
                cropAction = .move
            } else {
                cropAction = .new
            }
        }
        let dx = (v.location.x - v.startLocation.x) * s, dy = (v.location.y - v.startLocation.y) * s
        let minSide: CGFloat = 60
        var r = cropAtStart
        switch cropAction {
        case .handle(let h):
            var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
            if [0, 6, 7].contains(h) { minX = min(max(0, minX + dx), maxX - minSide) }
            if [2, 3, 4].contains(h) { maxX = max(min(full.maxX, maxX + dx), minX + minSide) }
            if [0, 1, 2].contains(h) { minY = min(max(0, minY + dy), maxY - minSide) }
            if [4, 5, 6].contains(h) { maxY = max(min(full.maxY, maxY + dy), minY + minSide) }
            r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .move:
            r.origin.x = min(max(0, r.minX + dx), full.width - r.width)
            r.origin.y = min(max(0, r.minY + dy), full.height - r.height)
        case .new, .none:
            let a = clamp(v.startLocation, fit), b = clamp(v.location, fit)
            let vr = rect(a, b)
            guard vr.width * s >= minSide, vr.height * s >= minSide else { return }
            r = CGRect(x: vr.minX * s, y: vr.minY * s, width: vr.width * s, height: vr.height * s)
        }
        // Covering the whole picture means no crop.
        draft.crop = r.insetBy(dx: -2, dy: -2).contains(full) ? nil : r
    }

    // MARK: Drawing options

    private var markBar: some View {
        HStack(spacing: 12) {
            Text(selectedIndex != nil ? "Selected:" : "New drawings:").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                ForEach(Annotation.Colour.allCases) { c in
                    Button {
                        markColourRaw = c.rawValue
                        if let i = selectedIndex { draft.marks[i].colour = c }
                    } label: {
                        Circle().fill(Color(cgColor: c.cg))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).padding(-4)
                                .opacity((selectedIndex.map { draft.marks[$0].colour } ?? markColour) == c ? 1 : 0))
                    }
                    .buttonStyle(.plain)
                    .help(c.rawValue.capitalized)
                }
            }
            Picker("Size", selection: Binding(get: { selectedIndex.map { draft.marks[$0].size } ?? markSize },
                                             set: { v in markSize = v; if let i = selectedIndex { draft.marks[i].size = v } })) {
                Text("S").tag(0.7)
                Text("M").tag(1.0)
                Text("L").tag(1.5)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if let i = selectedIndex, draft.marks[i].kind == .text || draft.marks[i].kind == .number {
                TextField(draft.marks[i].kind == .text ? "Label text" : "Number", text: $draft.marks[i].text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: draft.marks[i].kind == .text ? 260 : 60)
                    .focused($labelFocused)
            }
            if let i = selectedIndex {
                Button(role: .destructive) {
                    draft.marks.remove(at: i)
                    selectedMark = nil
                } label: { Label("Delete", systemImage: "trash") }
                Button("Deselect") { selectedMark = nil }
            }
            Spacer()
            if !draft.marks.isEmpty {
                Button("Remove all drawings") { draft.marks = []; selectedMark = nil }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let k = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * k, height: size.height * k)
    }

    private func view(_ r: CGRect, _ s: CGFloat) -> CGRect {
        CGRect(x: r.minX / s, y: r.minY / s, width: r.width / s, height: r.height / s)
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func clamp(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, p.x), size.width), y: min(max(0, p.y), size.height))
    }
}


/// One line of narration: what the narrator says. Blank uses the placeholder (the step text).
/// `full` (Script view) adds the length, ▶ Play and Rewrite; otherwise just a compact ▶ Play.
struct NarrationField: View {
    let label: String?
    @Binding var text: String
    let placeholder: String
    var context: String = ""
    var full = false
    /// The placeholder is the real default line (the step text). When set, it's shown as ordinary,
    /// editable text: you can click into it, select part of it, copy and paste. Until you change it,
    /// the line stays linked to the step text.
    var linkedDefault = false
    /// Called just before a rewrite replaces the line, so Undo can bring it back.
    var beforeRewrite: () -> Void = {}
    /// When set, a bin button next to Rewrite deletes the step.
    var onDelete: (() -> Void)? = nil
    /// When set, a copy button next to the bin duplicates the step.
    var onDuplicate: (() -> Void)? = nil
    @ObservedObject private var player = NarrationPlayer.shared
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var rewriting = false
    @State private var problem: String?

    private var spoken: String { text.trimmed.isEmpty ? placeholder : text }
    private var seconds: Double { Narrator.estimate(spoken) }

    var body: some View {
        Group { if full { big } else { compact } }
            .onAppear { if linkedDefault { draft = text.isEmpty ? placeholder : text } }
            .onChange(of: draft) { _, v in
                guard linkedDefault else { return }
                let new = stored(from: v)
                if new != text { text = new }
            }
            .onChange(of: text) { _, v in
                // Changed from outside (Rewrite, Undo, Write with AI): show it.
                guard linkedDefault, stored(from: draft) != v else { return }
                draft = v.isEmpty ? placeholder : v
            }
            .onChange(of: placeholder) { _, p in
                if linkedDefault, text.isEmpty, !focused { draft = p }
            }
            .onChange(of: focused) { _, now in
                if linkedDefault, !now, draft.trimmed.isEmpty { draft = placeholder }
            }
    }

    /// What gets saved: nothing while the line still matches the step text.
    private func stored(from d: String) -> String {
        d.trimmed == placeholder.trimmed ? "" : d
    }

    private var field: Binding<String> { linkedDefault ? $draft : $text }

    private var compact: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "waveform").foregroundStyle(Color(cgColor: Renderer.accent)).font(.caption)
            if let label { Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading) }
            TextField(placeholder, text: field, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .focused($focused)
            playButton(small: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .help("What the narrator says in tutorial videos. Leave blank to read the step text.")
    }

    private var big: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(placeholder, text: field, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(2...6)
                .focused($focused)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            HStack(spacing: 10) {
                playButton(small: false)
                Menu {
                    Button("Shorter") { rewrite("shorter and punchier") }
                    Button("Friendlier") { rewrite("warmer and friendlier") }
                    Button("More formal") { rewrite("more formal and professional") }
                    Button("Fix wording") { rewrite("clearer, with grammar and wording fixed") }
                } label: { Label("Rewrite", systemImage: "sparkles") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(rewriting || spoken.trimmed.isEmpty)
                    .help("Ask the AI to rewrite this line")
                if let onDuplicate {
                    Button(action: onDuplicate) { Image(systemName: "plus.square.on.square") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Duplicate this step")
                }
                if let onDelete {
                    Button(action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Delete this step (Undo brings it back)")
                }
                if rewriting { ProgressView().controlSize(.small); Text("Rewriting…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if seconds > 0 {
                    Label("\(Int(seconds.rounded())) sec", systemImage: seconds > 12 ? "exclamationmark.triangle.fill" : "clock")
                        .font(.caption)
                        .foregroundStyle(seconds > 12 ? Color.orange : Color.secondary)
                        .help(seconds > 12 ? "A long line — the step will stay on screen a while. Try Rewrite › Shorter."
                                           : "About how long this line takes to say")
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private func playButton(small: Bool) -> some View {
        let busy = player.preparing == spoken
        let on = player.playing == spoken
        Button {
            problem = nil
            let line = spoken
            Task {
                do { try await player.toggle(line) }
                catch { problem = "Couldn't play: \(error.localizedDescription)" }
            }
        } label: {
            if small {
                Image(systemName: busy ? "hourglass" : on ? "stop.fill" : "play.fill")
            } else {
                Label(busy ? "Preparing…" : on ? "Stop" : "Play",
                      systemImage: busy ? "hourglass" : on ? "stop.fill" : "play.fill")
            }
        }
        .buttonStyle(small ? AnyButtonStyle(.borderless) : AnyButtonStyle(.bordered))
        .disabled(spoken.trimmed.isEmpty)
        .help(on ? "Stop" : "Hear this line in your chosen voice")
    }

    private func rewrite(_ how: String) {
        guard AI.isReady else { problem = AI.notReadyMessage; return }
        problem = nil
        rewriting = true
        let line = spoken
        Task {
            defer { rewriting = false }
            do {
                let new = try await AI.rewriteLine(line, how: how, title: context)
                beforeRewrite()
                text = new
            }
            catch { problem = error.localizedDescription }
        }
    }
}

/// Lets one button switch between borderless and bordered.
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}


/// Makes a translated copy of a guide.
struct TranslateSheet: View {
    let guide: Guide
    @Environment(\.dismiss) private var dismiss
    @AppStorage("translateLanguage") private var language = "Chinese (Simplified)"
    @State private var other = ""
    @State private var keepLabels = true
    @State private var working: String?
    @State private var problem: String?
    @State private var task: Task<Void, Never>?

    private var target: String { language == "Other" ? other.trimmed : language }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Translate “\(guide.title.plain)”").font(.title3.weight(.semibold))
            Text("Makes a copy of this guide in another language: the title, steps, narration script and text labels. Screenshots, blurs and drawings stay the same. The original isn't changed.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Language", selection: $language) {
                ForEach(AI.translationLanguages, id: \.self) { Text($0).tag($0) }
                Divider()
                Text("Other…").tag("Other")
            }
            if language == "Other" {
                TextField("Language, for example Tamil or Brazilian Portuguese", text: $other)
            }
            Toggle("Keep on-screen labels (the bold words) as they appear in the screenshots", isOn: $keepLabels)
                .help("Turn off if the app in the screenshots is also in the new language")
            Text("For a narrated video, choose a voice that speaks this language in Settings › Voice.")
                .font(.caption).foregroundStyle(.secondary)
            if let w = working { HStack { ProgressView().controlSize(.small); Text(w).font(.callout) } }
            if let p = problem { Text(p).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Translate") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working != nil || target.isEmpty || !AI.isReady)
            }
            if !AI.isReady { Text(AI.notReadyMessage).font(.caption).foregroundStyle(.orange) }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func start() {
        let lang = target
        problem = nil
        working = "Translating…"
        task = Task {
            do {
                let copy = try await AI.translatedCopy(of: guide, to: lang, keepLabels: keepLabels) { done, total in
                    Task { @MainActor in working = "Translating… \(min(done, total)) of \(total) pieces of text" }
                }
                if Task.isCancelled { return }
                let id = GuideStore.shared.duplicate(guide, as: copy)
                RootView.pendingSelection = id
                dismiss()
            } catch {
                if !Task.isCancelled { problem = error.localizedDescription }
                working = nil
            }
        }
    }
}

/// Live drawings in the picture editor (the finished picture is drawn by Renderer).
struct AnnotationOverlay: View {
    let marks: [Annotation]
    /// Screenshot pixels per point on screen.
    let pixelsPerPoint: CGFloat
    let unit: CGFloat
    let selected: UUID?

    var body: some View {
        Canvas { ctx, _ in
            let k = 1 / max(0.0001, pixelsPerPoint)
            for m in marks {
                let colour = Color(cgColor: m.colour.cg)
                let edge = Color(white: m.colour == .white ? 0.15 : 1)
                let mt = Renderer.metrics(m, unit: unit)
                let line = mt.line * k
                let a = CGPoint(x: m.a.x * k, y: m.a.y * k), b = CGPoint(x: m.b.x * k, y: m.b.y * k)
                switch m.kind {
                case .arrow:
                    let dx = b.x - a.x, dy = b.y - a.y, len = max(1, hypot(dx, dy))
                    let ux = dx / len, uy = dy / len
                    let head = min(mt.head * 1.4 * k, len * 0.6), wing = head * 0.6
                    let base = CGPoint(x: b.x - ux * head * 0.8, y: b.y - uy * head * 0.8)
                    var shaft = Path(); shaft.move(to: a); shaft.addLine(to: base)
                    var tip = Path()
                    tip.move(to: b)
                    tip.addLine(to: CGPoint(x: b.x - ux * head - uy * wing, y: b.y - uy * head + ux * wing))
                    tip.addLine(to: CGPoint(x: b.x - ux * head + uy * wing, y: b.y - uy * head - ux * wing))
                    tip.closeSubpath()
                    ctx.stroke(shaft, with: .color(edge), style: StrokeStyle(lineWidth: line * 1.9, lineCap: .round))
                    ctx.stroke(tip, with: .color(edge), style: StrokeStyle(lineWidth: line * 0.9, lineJoin: .round))
                    ctx.stroke(shaft, with: .color(colour), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    ctx.fill(tip, with: .color(colour))
                case .box, .circle:
                    let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    let p = m.kind == .box ? Path(roundedRect: r, cornerRadius: min(10 * unit * k, r.width / 2, r.height / 2))
                                           : Path(ellipseIn: r)
                    ctx.stroke(p, with: .color(edge), style: StrokeStyle(lineWidth: line * 1.9))
                    ctx.stroke(p, with: .color(colour), style: StrokeStyle(lineWidth: line))
                case .text, .number:
                    let br = Renderer.bounds(m, unit: unit)
                    let r = CGRect(x: br.minX * k, y: br.minY * k, width: br.width * k, height: br.height * k)
                    let p = m.kind == .number ? Path(ellipseIn: r) : Path(roundedRect: r, cornerRadius: mt.font * 0.4 * k)
                    ctx.fill(p, with: .color(colour))
                    ctx.stroke(p, with: .color(edge), lineWidth: 1.5)
                    let label = Text(m.kind == .number ? (m.text.isEmpty ? "1" : m.text) : m.text)
                        .font(.system(size: max(6, mt.font * k * (m.kind == .number ? 1.05 : 1)), weight: .semibold))
                        .foregroundColor(m.colour.onColourIsDark ? .black : .white)
                    if m.kind == .number {
                        ctx.draw(label, at: CGPoint(x: r.midX, y: r.midY), anchor: .center)
                    } else {
                        let pad = mt.font * 0.55 * k
                        ctx.draw(label, in: r.insetBy(dx: pad, dy: pad * 0.7))
                    }
                }
                if m.id == selected {
                    let br = Renderer.bounds(m, unit: unit)
                    let r = CGRect(x: br.minX * k, y: br.minY * k, width: br.width * k, height: br.height * k).insetBy(dx: -4, dy: -4)
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(.accentColor),
                               style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
            }
        }
    }
}

/// Per-picture zoom: whole screen, a little, close, or the guide's setting.
struct StepZoomMenu: View {
    @Binding var step: Step
    let guideZoom: Zoom

    var body: some View {
        Menu {
            Picker("Zoom", selection: $step.zoomOverride) {
                Text("Same as guide (\(guideZoom.rawValue.lowercased()))").tag(Zoom?.none)
                ForEach(Zoom.allCases) { Text($0.rawValue).tag(Zoom?.some($0)) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: step.zoomOverride == nil ? "plus.magnifyingglass" : "plus.magnifyingglass.fill")
                .padding(5)
                .background(Circle().fill(.regularMaterial))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(step.zoomOverride == nil ? "Zoom this picture only" : "This picture: \(step.zoomOverride!.rawValue.lowercased())")
    }
}

/// One step as a thumbnail in the grid.
struct StepTile: View {
    let guideID: UUID
    let step: Step
    let number: Int
    let zoom: Zoom
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if step.image != nil {
                    StepPicture(guideID: guideID, step: step, zoom: zoom, maxWidth: 520)
                        .aspectRatio(16 / 10, contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary).aspectRatio(16 / 10, contentMode: .fit)
                        .overlay(Image(systemName: "text.alignleft").foregroundStyle(.secondary))
                }
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color(cgColor: Renderer.accent)))
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? Color.accentColor : Color.white)
                    .shadow(radius: 2)
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(step.text.plain.isEmpty ? "(no text)" : step.text.plain)
                .font(.callout).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !step.appName.isEmpty {
                Text(step.appName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}


// MARK: - Choose the voice without opening Settings

/// The voice button in the guide header: voice, Fast or Expressive, and the sliders, in a popover.
struct VoiceQuickPicker: View {
    @AppStorage("narratorKind") private var kindRaw = ""
    @AppStorage("pareVoiceName") private var voiceName = ""
    @AppStorage("pareVoiceMode") private var modeRaw = PareVoiceMode.turbo.rawValue
    @AppStorage("pareVoiceExpressiveness") private var expressiveness = 0.45
    @AppStorage("pareVoicePace") private var pace = 0.5
    @AppStorage("voiceID") private var macVoiceID = ""
    @ObservedObject private var player = NarrationPlayer.shared
    @State private var open = false
    @State private var voices: [String] = []
    @State private var problem: String?

    private var kind: NarratorKind {
        NarratorKind(rawValue: kindRaw) ?? (PareVoice.isInstalled ? .pareVoice : .mac)
    }
    private var standard: Bool { modeRaw == PareVoiceMode.standard.rawValue }
    private var title: String {
        guard kind == .pareVoice else { return "Mac voice" }
        let v = voiceName.isEmpty ? (PareVoice.selectedVoice ?? "Choose a voice") : voiceName
        return "\(v) · \(standard ? "Expressive" : "Fast")"
    }
    private let sample = "Here's how this voice sounds in your tutorial."

    var body: some View {
        Button { voices = PareVoice.voices; open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                Text(title)
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Change the narrator's voice")
        .popover(isPresented: $open, arrowEdge: .bottom) { panel.onDisappear { player.stop() } }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Narrator voice").font(.headline)
            Picker("Narrator", selection: Binding(get: { kind.rawValue }, set: { kindRaw = $0 })) {
                ForEach(NarratorKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if kind == .pareVoice {
                if !PareVoice.isInstalled {
                    Text("Pare Voice isn't set up on this Mac yet.").foregroundStyle(.secondary)
                } else {
                    Picker("Voice", selection: Binding(get: { voiceName.isEmpty ? (PareVoice.selectedVoice ?? "") : voiceName },
                                                       set: { voiceName = $0 })) {
                        ForEach(voices, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(voices.isEmpty)

                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Mode", selection: $modeRaw) {
                            Text("Fast").tag(PareVoiceMode.turbo.rawValue)
                            Text("Expressive (slower)").tag(PareVoiceMode.standard.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(standard ? "Richer delivery, but several times slower to make."
                                      : "Quickest to make. Good for drafts and most videos.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if standard {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text("Expressiveness"); Spacer(); Text("calm ← → lively").font(.caption).foregroundStyle(.secondary) }
                            Slider(value: $expressiveness, in: 0.25...1.0)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text("Pace"); Spacer(); Text("slower ← → quicker").font(.caption).foregroundStyle(.secondary) }
                            Slider(value: $pace, in: 0.0...0.8)
                        }
                        Button("Reset sliders") { expressiveness = 0.45; pace = 0.5 }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            } else {
                Picker("Mac voice", selection: $macVoiceID) {
                    Text("System default").tag("")
                    ForEach(Speech.voices, id: \.identifier) { v in Text("\(v.name) (\(v.language))").tag(v.identifier) }
                }
            }

            Divider()
            HStack {
                let busy = player.preparing == sample, on = player.playing == sample
                Button {
                    problem = nil
                    Task {
                        do { try await player.toggle(sample) }
                        catch { problem = error.localizedDescription }
                    }
                } label: {
                    Label(busy ? "Preparing…" : on ? "Stop" : "Play a Sample",
                          systemImage: busy ? "hourglass" : on ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                SettingsLink { Text("More voice settings…") }.buttonStyle(.link)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .padding(18)
        .frame(width: 360)
    }
}


/// Caption size, position, short captions or none, for tutorial videos.
struct CaptionsMenu: View {
    @AppStorage("captionsOn") private var on = true
    @AppStorage("captionSize") private var size = 1
    @AppStorage("captionPosition") private var position = "auto"
    @AppStorage("captionShort") private var short = false

    var body: some View {
        Menu {
            Toggle("Show Captions", isOn: $on)
            Divider()
            Picker("Size", selection: $size) {
                Text("Small").tag(0); Text("Medium").tag(1); Text("Large").tag(2)
            }
            Picker("Position", selection: $position) {
                Text("Auto (moves away from the click)").tag("auto")
                Text("Bottom").tag("bottom")
                Text("Top").tag("top")
            }
            Toggle("Short Captions (one line)", isOn: $short)
        } label: {
            Label(on ? "Captions: \(["Small", "Medium", "Large"][min(2, max(0, size))])" : "Captions: Off",
                  systemImage: "captions.bubble")
        }
        .help("Caption size and position in the video")
    }
}
