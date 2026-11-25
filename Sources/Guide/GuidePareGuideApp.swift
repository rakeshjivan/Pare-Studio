// Pare Guide — record any workflow on your Mac and turn it into a step-by-step guide.
// A Mac desktop take on Mimik (github.com/westpoint-io/mimik, MIT): instead of a browser
// extension it watches clicks and typing in every app, with screenshots and the clicked item boxed.

import SwiftUI
import AppKit
import UniformTypeIdentifiers


/// Settings read by the recorder (the Settings window writes the same keys).
enum Prefs {
    static var countdown: Bool { UserDefaults.standard.object(forKey: "countdown") as? Bool ?? true }
    static var autoBlur: Bool { UserDefaults.standard.object(forKey: "autoBlur") as? Bool ?? true }
    static var defaultZoom: Zoom { Zoom(rawValue: UserDefaults.standard.string(forKey: "defaultZoom") ?? "") ?? .some }
}

// MARK: - Main window

struct RootView: View {
    @ObservedObject private var store = GuideStore.shared
    @ObservedObject private var recorder = Recorder.shared
    @State private var selection: UUID?
    @State private var search = ""
    @State private var confirmDelete: UUID?

    @MainActor static var pendingSelection: UUID? {
        didSet { NotificationCenter.default.post(name: .selectGuide, object: nil) }
    }

    private var filtered: [Guide] {
        let q = search.trimmed.lowercased()
        guard !q.isEmpty else { return store.guides }
        return store.guides.filter { g in
            g.title.lowercased().contains(q) || g.steps.contains { $0.text.lowercased().contains(q) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(filtered) { g in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(g.title).lineLimit(2)
                        Text("\(g.steps.count) step\(g.steps.count == 1 ? "" : "s") · \(g.modified.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(g.id)
                    .contextMenu {
                        Button("Delete Guide…", role: .destructive) { confirmDelete = g.id }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search guides")
            .navigationSplitViewColumnWidth(min: 220, ideal: 270)
            .safeAreaInset(edge: .bottom) {
                Button {
                    recorder.askWhatToRecord()
                } label: {
                    Label("New Recording", systemImage: "record.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(recorder.isBusy || !Permissions.accessibility || !Permissions.screenRecording)
                .padding(12)
            }
            .overlay {
                if store.guides.isEmpty {
                    Text("Your guides will appear here.").foregroundStyle(.secondary).font(.callout)
                }
            }
        } detail: {
            VStack(spacing: 0) {
                if let note = recorder.narrationStatus {
                    HStack {
                        if note.hasSuffix("…") { ProgressView().controlSize(.small) }
                        else { Image(systemName: "waveform").foregroundStyle(.secondary) }
                        Text(note).font(.callout)
                        Spacer()
                        Button { recorder.narrationStatus = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                    .padding(.horizontal, 12).padding(.top, 8)
                }
                if recorder.state == .recording || recorder.state == .paused {
                    HStack {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        Text("A recording is still running and is saving every click and keystroke.")
                        Spacer()
                        Button("Stop Recording") { recorder.stop() }.buttonStyle(.borderedProminent).tint(.red)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
                    .padding(.horizontal, 12).padding(.top, 8)
                }
                if let id = selection, store.guide(id) != nil {
                    GuideEditor(guideID: id).id(id)
                } else {
                    HomeView()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { Self.importGuide() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Open a .pareguide file someone shared with you")
            }
        }
        .onAppear {
            recorder.onFinish = { id in selection = id }
            if let p = Self.pendingSelection { selection = p }
        }
        .sheet(isPresented: $recorder.showPicker) { RecordPicker() }
        .onReceive(NotificationCenter.default.publisher(for: .selectGuide)) { _ in
            if let p = Self.pendingSelection { selection = p }
        }
        .confirmationDialog("Delete this guide?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = confirmDelete {
                    if selection == id { selection = nil }
                    store.delete(id)
                }
                confirmDelete = nil
            }
        } message: {
            Text("Its steps and screenshots are removed from this Mac.")
        }
    }

    @MainActor
    static func importGuide() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pareguide") ?? .zip, .zip]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for u in panel.urls {
            do { pendingSelection = try GuideStore.shared.importBundle(u) }
            catch { NSAlert(error: error).runModal() }
        }
    }
}

extension Notification.Name {
    static let selectGuide = Notification.Name("PareGuideSelect")
}

// MARK: - Home (no guide selected)

struct HomeView: View {
    @ObservedObject private var recorder = Recorder.shared
    @State private var ax = Permissions.accessibility
    @State private var screen = Permissions.screenRecording
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pare Guide").font(.system(size: 34, weight: .bold))
                    Text("Do a task once on your Mac. Pare Guide turns every click and entry into a step-by-step guide with screenshots, then exports it as a PDF, Word file, web page or GIF — or a narrated tutorial video in your own voice.")
                        .font(.title3).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !ax || !screen {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Two permissions first").font(.headline)
                            PermissionRow(done: ax, title: "Accessibility",
                                          detail: "Lets Pare Studio see where you click, what you clicked on, and what you type.",
                                          action: Permissions.askAccessibility)
                            PermissionRow(done: screen, title: "Screen Recording",
                                          detail: "Lets Pare Studio take a screenshot for each step.",
                                          action: Permissions.askScreenRecording)
                            HStack {
                                Text("Already switched them on? macOS needs the app to reopen.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Quit & Reopen") { relaunch() }.controlSize(.small)
                            }
                            HStack {
                                Text("Switched on but still asked? macOS is remembering an older copy of the app.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Reset & Reopen") { resetPermissions() }.controlSize(.small)
                                    .help("Clears Pare Studio's old permission entries, then reopens. Switch both on again afterwards.")
                            }
                        }
                        .padding(8)
                    }
                }

                Button {
                    recorder.askWhatToRecord()
                } label: {
                    Label("Start Recording", systemImage: "record.circle.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(!ax || !screen || recorder.isBusy)

                if let e = recorder.lastError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        tip("record.circle", "The window hides and recording starts after a 3-second countdown. A red dot in the menu bar shows the step count.")
                        tip("stop.circle", "Stop with **⌃⌥⌘S** or the menu bar dot. Pause with **⌃⌥⌘P**.")
                        tip("eye.slash", "Emails, phone and card numbers in screenshots are blurred automatically. Passwords are never recorded.")
                        tip("sparkles", "**Write with AI** rewords steps using your Claude subscription (through Claude Code) or Apple Intelligence. No API key needed.")
                    }
                    .padding(6)
                }
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .onReceive(timer) { _ in
            ax = Permissions.accessibility
            screen = Permissions.screenRecording
        }
    }

    private func tip(_ icon: String, _ text: LocalizedStringKey) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon).foregroundStyle(.secondary) }
    }

    /// Clears stale permission entries (left by an earlier, differently signed copy), then reopens.
    private func resetPermissions() {
        let id = Bundle.main.bundleIdentifier ?? "au.jivan.pareguide"
        Tools.runQuick("/usr/bin/tccutil", ["reset", "Accessibility", id])
        Tools.runQuick("/usr/bin/tccutil", ["reset", "ScreenCapture", id])
        relaunch()
    }

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"$APP\""]
        p.environment = ["APP": Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

struct PermissionRow: View {
    let done: Bool
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !done { Button("Allow…", action: action) }
        }
    }
}

// MARK: - Connect Claude

struct ClaudeConnectView: View {
    @ObservedObject private var connect = ClaudeConnect.shared
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch connect.phase {
            case .unknown:
                ProgressView().controlSize(.small)
            case .connected(let who):
                Label(who.isEmpty ? "Connected to your Claude account" : "Connected as \(who)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .installing:
                HStack { ProgressView().controlSize(.small); Text("Installing Claude Code (about a minute)…") }
            case .signingIn:
                HStack { ProgressView().controlSize(.small); Text("Finish in your browser: **Continue with Google**, then **Authorize**.") }
                if let url = connect.signInURL {
                    Link("Browser didn't open? Click here to sign in", destination: url).font(.callout)
                }
                HStack {
                    TextField("If the page shows a code, paste it here", text: $code)
                    Button("Submit") { connect.submitCode(code); code = "" }.disabled(code.trimmed.isEmpty)
                }
                Button("Cancel") { connect.cancel() }.controlSize(.small)
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { connect.connect() }
            case .notConnected:
                Button {
                    connect.connect()
                } label: {
                    Label("Connect Claude", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
                Text("Installs Claude Code if needed, then opens claude.ai in your browser so you can sign in (Google works). One time per Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await connect.refresh() }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("countdown") private var countdown = true
    @AppStorage("autoBlur") private var autoBlur = true
    @AppStorage("defaultZoom") private var defaultZoom = Zoom.some.rawValue
    @AppStorage("aiProvider") private var providerRaw = AIProvider.claudeCode.rawValue
    @AppStorage("aiLanguage") private var language = ""
    @AppStorage("voiceID") private var voiceID = ""
    @State private var key = ""
    @State private var model = ""
    @State private var saved = false

    @State private var testing = false
    @State private var testResult: String?

    private var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .claudeCode }

    var body: some View {
        TabView {
            Form {
                Toggle("3-second countdown before recording starts", isOn: $countdown)
                Toggle("Blur emails, phone and card numbers automatically", isOn: $autoBlur)
                Picker("New guides", selection: $defaultZoom) {
                    ForEach(Zoom.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            VoiceSettings()
                .tabItem { Label("Voice", systemImage: "waveform") }

            BrandSettings()
                .tabItem { Label("Intros & Outros", systemImage: "rectangle.on.rectangle") }

            Form {
                Picker("Write steps with", selection: $providerRaw) {
                    ForEach(AIProvider.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                switch provider {
                case .claudeCode:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Uses the Claude Code app signed in to your Claude Pro or Max plan, so there's nothing extra to pay. Screenshots are sent to Claude with their blurs applied.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ClaudeConnectView()
                        HStack {
                            Button(testing ? "Testing…" : "Test") {
                                testing = true
                                testResult = nil
                                Task {
                                    testResult = await ClaudeCLI.test()
                                    testing = false
                                }
                            }
                            .disabled(testing)
                            if let r = testResult { Text(r).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
                        }
                    }
                    TextField("Model", text: $model, prompt: Text("sonnet"))
                    Text("sonnet is a good balance. haiku uses less of your allowance; opus is the most capable. If Claude Code isn't available or your allowance runs out, Apple Intelligence takes over when it's switched on.")
                        .font(.caption).foregroundStyle(.secondary)
                case .apple:
                    Text(AppleAI.status).font(.callout)
                    Text("Free and private: runs on your Mac and works offline. It works from what was clicked (button names, app, window) rather than the screenshots, so wording is simpler than Claude's.")
                        .font(.caption).foregroundStyle(.secondary)
                case .anthropic, .openai:
                    SecureField("API key", text: $key)
                    TextField("Model", text: $model, prompt: Text(provider.defaultModel))
                    Text("Needs API credits, which are billed separately from a Claude or ChatGPT subscription. The key stays in your Mac's Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("Write steps in", text: $language, prompt: Text("English"))
                HStack {
                    Button("Save") {
                        if provider.needsKey { Keychain.set(key.trimmed, for: provider.keyAccount) }
                        UserDefaults.standard.set(model.trimmed, forKey: "aiModel-\(provider.keyAccount)")
                        saved = true
                    }
                    if saved { Text("Saved").foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("AI", systemImage: "sparkles") }
            .onAppear(perform: loadKey)
            .onChange(of: providerRaw) { _, _ in loadKey() }

            Form {
                LabeledContent("Version", value: "Build \(Updater.shared.currentBuild)")
                UpdateButton(busy: false)
                Text("Based on the idea of Mimik by Westpoint (MIT licence), rebuilt as a native Mac app that works in every app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 680, height: 640)
    }

    private func loadKey() {
        key = provider.needsKey ? (Keychain.get(provider.keyAccount) ?? "") : ""
        testResult = nil
        model = UserDefaults.standard.string(forKey: "aiModel-\(provider.keyAccount)") ?? ""
        saved = false
    }
}
