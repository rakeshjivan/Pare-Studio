// Pare Studio — one Mac app for video, guides, slides and transcripts.
// The home screen asks what you want to do, then opens that tool:
//   Download a video (Pare Reels) · Make a how-to guide (Pare Guide) · Turn a video into slides ·
//   Put slides to a recording (Pare Slides) · Transcribe a recording.

import SwiftUI
import AppKit

@main
struct PareStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Pare Studio") {
            StudioRoot()
                .frame(minWidth: 1080, minHeight: 700)
                .task { await Updater.shared.check() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Home") { Nav.shared.screen = .home }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Button("New Guide Recording") {
                    Nav.shared.screen = .guide
                    Recorder.shared.askWhatToRecord()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Import Guide…") {
                    Nav.shared.screen = .guide
                    RootView.importGuide()
                }
                .keyboardShortcut("o")
            }
        }
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { Recorder.shared.appBecameActive() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ReelTools.stopBackgroundJobs()   // never leave ffmpeg/yt-dlp running after the app closes
        MainActor.assumeIsolated { GuideStore.shared.flush() }
        PareVoice.stop()
        MainActor.assumeIsolated { Updater.shared.install(relaunch: false) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for u in urls where u.pathExtension.lowercased() == "pareguide" {
                if let id = try? GuideStore.shared.importBundle(u) {
                    RootView.pendingSelection = id
                    Nav.shared.screen = .guide
                }
            }
        }
    }
}

// MARK: - Where we are

enum Screen: String, CaseIterable, Identifiable {
    case home, download, guide, videoSlides, fitSlides, transcribe
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Pare Studio"
        case .download: return "Download a Video"
        case .guide: return "Make a How-To Guide"
        case .videoSlides: return "Turn a Video into Slides"
        case .fitSlides: return "Put Slides to a Recording"
        case .transcribe: return "Transcribe a Recording"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .download: return "arrow.down.circle.fill"
        case .guide: return "list.number"
        case .videoSlides: return "rectangle.stack.badge.play.fill"
        case .fitSlides: return "rectangle.on.rectangle.angled"
        case .transcribe: return "text.bubble.fill"
        }
    }

    var colour: Color {
        switch self {
        case .home: return .accentColor
        case .download: return Color(red: 0.16, green: 0.52, blue: 0.86)
        case .guide: return Color(red: 0.86, green: 0.30, blue: 0.32)
        case .videoSlides: return Color(red: 0.55, green: 0.36, blue: 0.84)
        case .fitSlides: return Color(red: 0.11, green: 0.62, blue: 0.58)
        case .transcribe: return Color(red: 0.93, green: 0.56, blue: 0.16)
        }
    }

    var question: String {
        switch self {
        case .home: return ""
        case .download: return "Save a video from a website"
        case .guide: return "Show someone how to do something on a Mac"
        case .videoSlides: return "Get the slides out of a recorded talk"
        case .fitSlides: return "I have a recording and the slide deck"
        case .transcribe: return "Turn what's said into text"
        }
    }

    var detail: String {
        switch self {
        case .home: return ""
        case .download:
            return "Download from YouTube, Vimeo, webinars, Zoom and more. Then crop, trim, compress or make a GIF."
        case .guide:
            return "Record yourself doing a task in any app. Get a step-by-step guide (PDF, Word, web page), a narrated tutorial video, or a Camtasia project."
        case .videoSlides:
            return "Pare Studio finds every slide in a video. Get a PowerPoint (with what was said as speaker notes), a PDF, or a Camtasia project with the slides timed to the sound."
        case .fitSlides:
            return "Pare Studio listens to the recording and puts each slide on screen at the right moment. Exports a Camtasia project or an MP4. Works on a batch of recordings."
        case .transcribe:
            return "On this Mac, nothing uploaded. Save as text, a Word document, or captions (SRT, VTT). Find keywords with their times."
        }
    }
}

@MainActor
final class Nav: ObservableObject {
    static let shared = Nav()
    @Published var screen: Screen = .home
}

// MARK: - Window

struct StudioRoot: View {
    @ObservedObject private var nav = Nav.shared
    @ObservedObject private var recorder = Recorder.shared
    @ObservedObject private var slides = Session.shared
    @ObservedObject private var reels = ReelsHome.model

    private var busy: Bool { recorder.isBusy || slides.busy || reels.isRunning || VideoSlides.shared.busy || TranscribeModel.shared.busy }

    var body: some View {
        VStack(spacing: 0) {
            if nav.screen != .home { TopBar(screen: nav.screen) }
            UpdateBanner(busy: busy).padding(.horizontal, 16)
            if nav.screen != .home { Divider() }
            Group {
                switch nav.screen {
                case .home: StudioHomeView()
                case .download: ReelsHome()
                case .guide: RootView()
                case .videoSlides: VideoSlidesView()
                case .fitSlides: SlidesHome()
                case .transcribe: TranscribeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct TopBar: View {
    let screen: Screen
    var body: some View {
        HStack(spacing: 12) {
            Button { Nav.shared.screen = .home } label: {
                Label("Home", systemImage: "chevron.left")
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .help("Back to the home screen (⇧⌘H)")
            Divider().frame(height: 18)
            Image(systemName: screen.icon).foregroundStyle(screen.colour)
            Text(screen.title).font(.headline)
            Spacer()
            ClaudeChip()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
}

/// Shows whether Claude is connected; click to connect (Google sign-in, through Claude Code).
struct ClaudeChip: View {
    @ObservedObject private var connect = ClaudeConnect.shared
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            if case .connected = connect.phase {
                Label("Claude connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("Connect Claude", systemImage: "link")
            }
        }
        .help("Claude writes guide steps, matches slides and more, using your Claude subscription")
        .popover(isPresented: $show) { ClaudeConnectView().padding(16).frame(width: 380) }
        .task { await connect.refresh() }
    }
}

// MARK: - Home

struct StudioHomeView: View {
    private let tools: [Screen] = [.download, .guide, .videoSlides, .fitSlides, .transcribe]
    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                VStack(spacing: 8) {
                    Text("What would you like to do?")
                        .font(.system(size: 30, weight: .bold))
                    Text("Pick one. Everything happens on this Mac.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                .padding(.top, 34)

                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(tools) { t in ToolCard(screen: t) }
                }
                .frame(maxWidth: 1320)

                HStack(spacing: 14) {
                    ClaudeChip()
                    UpdateButton(busy: false)
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
    }
}

struct ToolCard: View {
    let screen: Screen
    @State private var hover = false

    var body: some View {
        Button { Nav.shared.screen = screen } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: screen.icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .background(RoundedRectangle(cornerRadius: 12).fill(screen.colour.gradient))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(screen.title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                        Text(screen.question).font(.callout).foregroundStyle(screen.colour)
                    }
                    Spacer(minLength: 0)
                }
                Text(screen.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Text("Start").font(.callout.weight(.semibold)).foregroundStyle(screen.colour)
                    Image(systemName: "arrow.right").font(.callout.weight(.semibold)).foregroundStyle(screen.colour)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(hover ? 0.16 : 0.07), radius: hover ? 12 : 5, y: hover ? 4 : 2)
            )
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(hover ? screen.colour.opacity(0.7) : Color.secondary.opacity(0.18),
                                                                     lineWidth: hover ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}
