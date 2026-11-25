// RecordTarget — what a recording captures: the whole screen, one app, or one window
// (optionally just the web page inside a browser window, without its toolbar).
// • One app: only clicks and typing in that app become steps (its menus and pop-ups included).
// • One window: the same, and each picture is cropped to that window, so the menu bar, Dock
//   and other apps never appear.

import AppKit
import SwiftUI

enum RecordTarget: Equatable {
    case screen
    case app(pid: pid_t, name: String)
    case window(id: CGWindowID, pid: pid_t, name: String, pageOnly: Bool)

    var pid: pid_t? {
        switch self {
        case .screen: return nil
        case .app(let p, _), .window(_, let p, _, _): return p
        }
    }

    var summary: String {
        switch self {
        case .screen: return "Whole screen"
        case .app(_, let n): return n
        case .window(_, _, let n, let page): return page ? "\(n) (page only)" : n
        }
    }
}

/// Open windows, from the window server.
enum WindowList {
    struct Item: Identifiable, Hashable {
        let id: CGWindowID
        let pid: pid_t
        let app: String
        let title: String
        let bounds: CGRect
        var label: String { title.isEmpty ? app : "\(app) — \(title)" }
    }

    static let browsers: Set<String> = ["Safari", "Google Chrome", "Microsoft Edge", "Arc", "Firefox", "Brave Browser",
                                        "Opera", "Vivaldi", "Chromium", "Safari Technology Preview"]

    static func list() -> [Item] {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let arr = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return arr.compactMap { d -> Item? in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.width > 160, r.height > 100
            else { return nil }
            return Item(id: id, pid: pid, app: d[kCGWindowOwnerName as String] as? String ?? "",
                        title: d[kCGWindowName as String] as? String ?? "", bounds: r)
        }
    }

    /// Where a window is now (global points, top-left origin), or nil if it has closed.
    static func bounds(_ id: CGWindowID) -> CGRect? {
        guard let arr = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let d = arr.first, let b = d[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
        if let onScreen = d[kCGWindowIsOnscreen as String] as? Bool, !onScreen { return nil }
        return r
    }

    /// The web page area inside a browser window (without tabs, toolbar and bookmarks bar).
    static func webArea(pid: pid_t, window: CGRect) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let ws = AX.attr(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        for w in ws {
            guard let f = AX.frame(w), abs(f.minX - window.minX) < 6, abs(f.minY - window.minY) < 6 else { continue }
            var queue = [w]
            var seen = 0
            while !queue.isEmpty, seen < 600 {
                let el = queue.removeFirst()
                seen += 1
                if AX.string(el, kAXRoleAttribute) == "AXWebArea", let r = AX.frame(el), r.width > 200, r.height > 150 {
                    return r.intersection(window)
                }
                if let kids = AX.attr(el, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
            }
        }
        return nil
    }
}

// MARK: - Choosing what to record

struct RecordPicker: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("recordMode") private var mode = 0          // 0 screen, 1 app, 2 window
    @AppStorage("recordPageOnly") private var pageOnly = true
    @AppStorage("talkWhileRecording") private var talk = false
    @State private var problem: String?
    @State private var windows: [WindowList.Item] = []
    @State private var chosenWindow: CGWindowID?
    @State private var chosenApp: pid_t?

    struct AppItem: Identifiable, Hashable { let id: pid_t; let name: String }

    private var apps: [AppItem] {
        var seen = Set<pid_t>()
        return windows.compactMap { w in seen.insert(w.pid).inserted ? AppItem(id: w.pid, name: w.app) : nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var window: WindowList.Item? { windows.first { $0.id == chosenWindow } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What do you want to record?").font(.title2.bold())
            Picker("", selection: $mode) {
                Text("Whole screen").tag(0)
                Text("One app").tag(1)
                Text("One window").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case 1:
                Text("Only clicks and typing in this app become steps, including its menus. Pictures show the whole screen.")
                    .font(.callout).foregroundStyle(.secondary)
                List(apps, selection: $chosenApp) { a in Text(a.name).tag(a.id) }
                    .frame(height: 220)
            case 2:
                Text("Only this window is recorded: each picture is cropped to it, and clicks anywhere else are ignored.")
                    .font(.callout).foregroundStyle(.secondary)
                List(windows, selection: $chosenWindow) { w in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.title.isEmpty ? w.app : w.title).lineLimit(1)
                        Text(w.app).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(w.id)
                }
                .frame(height: 220)
                if let w = window, WindowList.browsers.contains(w.app) {
                    Toggle("Page only: leave out the browser's tabs, address bar and bookmarks", isOn: $pageOnly)
                }
            default:
                Text("Everything on the screen is recorded, in every app.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Divider()
            Toggle(isOn: $talk) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Talk while you record")
                    Text("Explain each step out loud as you go. Your words become the narration, transcribed on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let p = problem { Text(p).font(.callout).foregroundStyle(.orange) }

            HStack {
                Button("Refresh List") { load() }.disabled(mode == 0)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Recording") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled((mode == 1 && chosenApp == nil) || (mode == 2 && window == nil))
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear(perform: load)
    }

    private func load() {
        windows = WindowList.list()
        if let w = chosenWindow, !windows.contains(where: { $0.id == w }) { chosenWindow = nil }
        if chosenWindow == nil { chosenWindow = windows.first?.id }
        if chosenApp == nil { chosenApp = windows.first?.pid }
    }

    private func start() {
        let target: RecordTarget
        switch mode {
        case 1:
            guard let p = chosenApp, let a = apps.first(where: { $0.id == p }) else { return }
            target = .app(pid: p, name: a.name)
        case 2:
            guard let w = window else { return }
            target = .window(id: w.id, pid: w.pid, name: w.label, pageOnly: pageOnly && WindowList.browsers.contains(w.app))
        default:
            target = .screen
        }
        let withVoice = talk
        Task {
            if withVoice, let msg = await SpokenNarration.requestAccess() { problem = msg; return }
            dismiss()
            try? await Task.sleep(nanoseconds: 250_000_000)
            Recorder.shared.start(target: target, talk: withVoice)
        }
    }
}
