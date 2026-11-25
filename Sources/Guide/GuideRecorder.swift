// Recorder — watches clicks and typing anywhere on the Mac and turns each one into a step.
// • A listen-only event tap sees clicks and keys (needs Accessibility permission).
// • The Accessibility API says what was clicked (button name, field, menu item) and where it is.
// • ScreenCaptureKit keeps a live copy of each screen, so every step gets the picture from just
//   BEFORE the click (menus are still open, dialogs not yet closed). Needs Screen Recording permission.

import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreImage
import CoreMedia

@MainActor
final class Recorder: ObservableObject {
    static let shared = Recorder()

    enum State: Equatable { case idle, countdown(Int), recording, paused, finishing }

    @Published private(set) var state: State = .idle
    @Published private(set) var stepCount = 0
    @Published var lastError: String?
    /// Shows the "What do you want to record?" sheet.
    @Published var showPicker = false
    @Published private(set) var target: RecordTarget = .screen
    /// For "page only": how far the web page sits inside the browser window.
    private var pageInsets: NSEdgeInsets?

    /// Called with the new guide's id when a recording ends.
    var onFinish: ((UUID) -> Void)?

    /// The guide being recorded. Always read fresh from the store and written straight back, so edits
    /// made while a recording is finishing (deleted steps, changed text) are never overwritten.
    private var guideID: UUID?
    private var guide: Guide? {
        get { guideID.flatMap { GuideStore.shared.guide($0) } }
        set {
            guideID = newValue?.id
            if let g = newValue, GuideStore.shared.guide(g.id) != nil { GuideStore.shared.update(g) }
        }
    }
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private let grabber = FrameGrabber()
    private var statusItem: NSStatusItem?
    private var pendingImages = 0
    private var typing: (id: UUID, text: String, secure: Bool)?
    private var lastClick: (id: UUID, point: CGPoint, time: Date)?
    private var axEnabledPIDs = Set<pid_t>()
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    /// When the last step was added; a recording with nothing new for 10 minutes stops by itself.
    private var lastActivity = Date()
    static let idleLimit: TimeInterval = 10 * 60

    var isBusy: Bool { state != .idle }

    // MARK: Start / stop

    /// Asks what to record (whole screen, one app or one window), then starts.
    func askWhatToRecord() {
        guard state == .idle else { return }
        NSApp.activate(ignoringOtherApps: true)
        showPicker = true
    }

    /// Whether this recording also records your voice ("Talk while you record").
    private var talk = false
    @Published var narrationStatus: String?

    func start(target: RecordTarget = .screen, talk: Bool = false) {
        guard state == .idle else { return }
        self.target = target
        self.talk = talk
        pageInsets = nil
        guard Permissions.accessibility, Permissions.screenRecording else {
            lastError = "Pare Studio needs Accessibility and Screen Recording permission first."
            return
        }
        let df = DateFormatter()
        df.dateFormat = "d MMM yyyy, h:mm a"
        var g = Guide(title: "New guide – \(df.string(from: Date()))")
        g.zoom = Prefs.defaultZoom
        guide = g
        GuideStore.shared.create(g)
        stepCount = 0
        typing = nil
        lastClick = nil
        lastError = nil
        showStatusItem()
        NSApp.hide(nil)
        if let pid = target.pid { NSRunningApplication(processIdentifier: pid)?.activate(options: []) }

        let seconds = Prefs.countdown ? 3 : 0
        state = .countdown(seconds)
        refreshStatusItem()
        Task {
            do { try await grabber.start() } catch {
                self.lastError = "Couldn't start screen capture: \(error.localizedDescription)"
            }
            for n in stride(from: seconds, through: 1, by: -1) {
                guard case .countdown = state else { return }
                state = .countdown(n)
                refreshStatusItem()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard case .countdown = state else { return }   // discarded during the countdown
            beginTap()
        }
    }

    private func beginTap() {
        if case .window(let id, let pid, _, true) = target, let b = WindowList.bounds(id),
           let w = WindowList.webArea(pid: pid, window: b) {
            pageInsets = NSEdgeInsets(top: w.minY - b.minY, left: w.minX - b.minX, bottom: b.maxY - w.maxY, right: b.maxX - w.maxX)
        }
        guard installTap() else {
            lastError = "Couldn't watch clicks. Check Accessibility permission in System Settings, then reopen Pare Studio."
            cancel()
            return
        }
        state = .recording
        lastActivity = Date()
        if talk { SpokenNarration.shared.start() }
        refreshStatusItem()
        watchForIdle()
    }

    /// Safety net: stop a recording that has been left running with nothing happening.
    private func watchForIdle() {
        Task {
            while state == .recording || state == .paused {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if (state == .recording || state == .paused), Date().timeIntervalSince(lastActivity) > Self.idleLimit {
                    stop()
                    lastError = "Recording stopped by itself after 10 minutes with no new steps."
                    return
                }
            }
        }
    }

    /// Coming back to Pare Studio ends the recording, so it can never keep running in the background.
    func appBecameActive() {
        switch state {
        case .countdown:
            cancel()
        case .recording, .paused:
            stop()
            lastError = "Recording stopped and saved because you came back to Pare Studio."
        case .idle, .finishing:
            break
        }
    }

    func togglePause() {
        if state == .recording { finishTyping(); state = .paused }
        else if state == .paused { state = .recording; lastActivity = Date() }
        refreshStatusItem()
    }

    func stop() {
        if state == .idle || state == .finishing { return }
        // Stop capturing immediately: no more clicks or keys are seen from this moment.
        removeTap()
        finishTyping()
        state = .finishing
        removeStatusItem()
        let gr = grabber
        Task {
            // Let screenshots that are already saving finish (at most 3 seconds).
            for _ in 0..<30 where pendingImages > 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
            // Shut down screen capture, but never wait more than 3 seconds for it.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await gr.stop() }
                group.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000) }
                await group.next()
                group.cancelAll()
            }
            finish()
        }
    }

    func cancel() {
        SpokenNarration.shared.discard()
        removeTap()
        Task { await grabber.stop() }
        if let g = guide { GuideStore.shared.delete(g.id) }
        guide = nil
        state = .idle
        removeStatusItem()
        bringBack()
    }

    private func finish() {
        removeStatusItem()
        state = .idle
        let spoken = SpokenNarration.shared.stop()
        guard let g = guide else { bringBack(); return }
        guide = nil
        if g.steps.isEmpty {
            if let sp = spoken { try? FileManager.default.removeItem(at: sp.0) }
            GuideStore.shared.delete(g.id)
            lastError = "Nothing was recorded."
            bringBack()
            return
        }
        GuideStore.shared.update(g)
        bringBack()
        onFinish?(g.id)
        if Prefs.autoBlur { AutoBlur.scan(guideID: g.id) }
        if let sp = spoken { addSpokenNarration(guideID: g.id, audio: sp.0, began: sp.1) }
    }

    /// Turns what you said while recording into each step's narration (on this Mac).
    private func addSpokenNarration(guideID: UUID, audio: URL, began: Date) {
        narrationStatus = "Turning what you said into narration…"
        Task {
            defer { try? FileManager.default.removeItem(at: audio) }
            do {
                let words = try await SpokenNarration.transcribe(audio)
                guard var g = GuideStore.shared.guide(guideID) else { narrationStatus = nil; return }
                let lines = SpokenNarration.assign(words, recordingStart: began, steps: g.steps)
                var n = 0
                for i in g.steps.indices {
                    if let l = lines[g.steps[i].id], (g.steps[i].narration ?? "").isEmpty { g.steps[i].narration = l; n += 1 }
                }
                GuideStore.shared.update(g, forceSnapshot: true)
                narrationStatus = n == 0 ? "No speech was picked up while recording."
                    : "Added what you said to \(n) step\(n == 1 ? "" : "s"). Use Write with AI › Polish My Spoken Narration to tidy it."
            } catch {
                narrationStatus = "Couldn't transcribe what you said: \(error.localizedDescription)"
            }
        }
    }

    private func bringBack() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    // MARK: Event tap

    private func installTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: mask,
                                        callback: recorderTapCallback, userInfo: me) else { return false }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        tapSource = src
        return true
    }

    private func removeTap() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        tapSource = nil
    }

    fileprivate func reenableTap() {
        guard state == .recording || state == .paused else { return }   // never restart after Stop
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
    }

    fileprivate func handle(_ e: TapEvent) {
        // Stop / pause shortcuts work even while paused.
        if e.type == .keyDown, e.flags.contains([.maskControl, .maskAlternate, .maskCommand]) {
            if e.keyCode == 1 { stop(); return }          // ⌃⌥⌘S
            if e.keyCode == 35 { togglePause(); return }  // ⌃⌥⌘P
        }
        guard state == .recording else { return }
        switch e.type {
        case .leftMouseDown: click(at: e.location, right: false, clickCount: e.clickCount)
        case .rightMouseDown: click(at: e.location, right: true, clickCount: 1)
        case .keyDown: key(e)
        default: break
        }
    }

    // MARK: Clicks

    private func click(at p: CGPoint, right: Bool, clickCount: Int) {
        let info = AX.element(at: p)
        if info.pid == ownPID { return }   // our own menu bar item / menus
        guard accepts(click: p, pid: info.pid) else { return }   // outside the chosen app or window
        finishTyping()
        enableWebAccessibility(info.pid)

        // Second click of a double-click: upgrade the step we just made.
        if clickCount >= 2, let last = lastClick, hypot(last.point.x - p.x, last.point.y - p.y) < 8,
           Date().timeIntervalSince(last.time) < 1,
           var g = guide, let i = g.steps.firstIndex(where: { $0.id == last.id }) {
            g.steps[i].kind = .doubleClick
            g.steps[i].text = StepText.click(info, kind: .doubleClick, previousApp: i > 0 ? g.steps[i - 1].appName : nil)
            guide = g
            save()
            return
        }

        let kind: StepKind = right ? .rightClick : .click
        let prev = guide?.steps.last?.appName
        var step = Step(kind: kind, text: StepText.click(info, kind: kind, previousApp: prev))
        step.appName = info.appName
        step.windowTitle = info.windowTitle
        step.role = info.role
        step.label = info.label
        addStep(step, point: p, element: info.frame)
        lastClick = (step.id, p, Date())
    }

    /// Chrome, Edge and Electron apps only expose web page buttons to the Accessibility API when asked.
    private func enableWebAccessibility(_ pid: pid_t) {
        guard pid > 0, !axEnabledPIDs.contains(pid) else { return }
        axEnabledPIDs.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: Keys

    private func key(_ e: TapEvent) {
        if let tp = target.pid, NSWorkspace.shared.frontmostApplication?.processIdentifier != tp { return }
        let hasCmd = e.flags.contains(.maskCommand) || e.flags.contains(.maskControl)
        if hasCmd {
            finishTyping()
            let info = AX.focused()
            if info.pid == ownPID { return }
            let combo = KeyNames.combo(e)
            var step = Step(kind: .shortcut, text: "Press **\(combo)**")
            step.appName = info.appName
            step.windowTitle = info.windowTitle
            step.showHighlight = false
            addStep(step, point: info.frame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocationCG, element: nil)
            return
        }
        switch e.keyCode {
        case 36, 76:   // Return / Enter
            if typing != nil { finishTyping(suffix: ", then press **Return**") }
            else { simpleKeyStep("Press **Return**") }
        case 48:       // Tab
            finishTyping()
        case 53:       // Escape
            finishTyping()
            simpleKeyStep("Press **Esc**")
        case 51:       // Delete
            if var t = typing, !t.text.isEmpty { t.text.removeLast(); typing = t }
        case 123, 124, 125, 126, 115, 116, 119, 121:   // arrows, home/end/page
            break
        default:
            guard !e.chars.isEmpty, e.chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return }
            if typing == nil { beginTyping() }
            typing?.text += e.chars
        }
    }

    private func simpleKeyStep(_ text: String) {
        let info = AX.focused()
        if info.pid == ownPID { return }
        var step = Step(kind: .shortcut, text: text)
        step.appName = info.appName
        step.windowTitle = info.windowTitle
        step.showHighlight = false
        addStep(step, point: NSEvent.mouseLocationCG, element: nil)
    }

    private func beginTyping() {
        let info = AX.focused()
        var step = Step(kind: .type, text: "Type")
        step.appName = info.appName
        step.windowTitle = info.windowTitle
        step.role = info.role
        step.label = info.label
        let point = info.frame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocationCG
        addStep(step, point: point, element: info.frame, markClick: false)
        typing = (step.id, "", info.isSecure)
    }

    private func finishTyping(suffix: String = "") {
        guard let t = typing else { return }
        typing = nil
        guard var g = guide, let i = g.steps.firstIndex(where: { $0.id == t.id }) else { return }
        if t.text.isEmpty && suffix.isEmpty {
            g.steps.remove(at: i)
            guide = g
            stepCount = g.steps.count
            save()
            return
        }
        let field = g.steps[i].label.isEmpty ? "" : " in the **\(g.steps[i].label)** field"
        let typed: String
        if t.secure { typed = "Enter your password\(field)" }
        else if t.text.isEmpty { typed = "Press **Return**" }
        else {
            let shown = Sensitive.mask(t.text)
            typed = "Type \u{201C}\(shown.count > 120 ? String(shown.prefix(120)) + "…" : shown)\u{201D}\(field)"
        }
        g.steps[i].text = typed + (t.text.isEmpty ? "" : suffix)
        guide = g
        save()
    }

    // MARK: Steps

    private func addStep(_ s: Step, point: CGPoint, element: CGRect?, markClick: Bool = true) {
        lastActivity = Date()
        guard var g = guide else { return }
        var step = s
        let index = g.steps.count + 1
        let guideID = g.id
        let folder = GuideStore.shared.imagesFolder(guideID)

        if let shot = grabber.latest(at: point) {
            place(&step, shot: shot, point: point, element: element, markClick: markClick)
            let picture = cropped(shot, step: &step)
            g.steps.append(step)
            guide = g
            stepCount = g.steps.count
            save()
            saveImage(picture, stepID: step.id, folder: folder, name: Self.fileName(index, step.id))
        } else {
            // No live frame yet (just started, or a new screen): take a one-off screenshot.
            g.steps.append(step)
            guide = g
            stepCount = g.steps.count
            save()
            let id = step.id
            pendingImages += 1
            Task {
                defer { pendingImages -= 1 }
                guard let shot = try? await FrameGrabber.oneOff(at: point) else { return }
                guard var g = guide, let i = g.steps.firstIndex(where: { $0.id == id }) else { return }
                place(&g.steps[i], shot: shot, point: point, element: element, markClick: markClick)
                let picture = cropped(shot, step: &g.steps[i])
                guide = g
                save()
                saveImage(picture, stepID: id, folder: folder, name: Self.fileName(index, id))
            }
        }
    }

    // MARK: Chosen app or window

    private func accepts(click p: CGPoint, pid: pid_t) -> Bool {
        switch target {
        case .screen:
            return true
        case .app(let tp, _):
            let owner = pid > 0 ? pid : (NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)
            return owner == tp
        case .window(let id, let tp, _, _):
            guard let b = WindowList.bounds(id), b.contains(p) else { return false }
            return pid <= 0 || pid == tp
        }
    }

    /// The part of the screenshot to keep (pixels), when recording one window.
    private func cropRect(for shot: Shot) -> CGRect? {
        guard case .window(let id, _, _, let page) = target, var b = WindowList.bounds(id) else { return nil }
        if page, let i = pageInsets {
            b = CGRect(x: b.minX + i.left, y: b.minY + i.top,
                       width: b.width - i.left - i.right, height: b.height - i.top - i.bottom)
        }
        let s = shot.scale
        let r = CGRect(x: (b.minX - shot.displayFrame.minX) * s, y: (b.minY - shot.displayFrame.minY) * s,
                       width: b.width * s, height: b.height * s).integral
            .intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
        return r.isNull || r.width < 60 || r.height < 60 ? nil : r
    }

    /// Crops the picture to the chosen window and moves the click and highlight to match.
    private func cropped(_ shot: Shot, step: inout Step) -> CGImage {
        guard let r = cropRect(for: shot), let img = shot.image.cropping(to: r) else { return shot.image }
        if let c = step.clickPoint { step.clickPoint = CGPoint(x: c.x - r.minX, y: c.y - r.minY) }
        if let h = step.highlight {
            let m = h.offsetBy(dx: -r.minX, dy: -r.minY).intersection(CGRect(origin: .zero, size: r.size))
            step.highlight = m.isNull || m.width < 2 || m.height < 2 ? nil : m
        }
        return img
    }

    private func place(_ step: inout Step, shot: Shot, point: CGPoint, element: CGRect?, markClick: Bool) {
        let s = shot.scale
        step.scale = Double(s)
        func toPixels(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - shot.displayFrame.minX) * s, y: (p.y - shot.displayFrame.minY) * s)
        }
        if markClick { step.clickPoint = toPixels(point) }
        if let r = element {
            let area = r.width * r.height
            let screenArea = shot.displayFrame.width * shot.displayFrame.height
            // Ignore "elements" that are really whole windows or page areas.
            if area > 0, area < screenArea * 0.2 {
                let o = toPixels(r.origin)
                let px = CGRect(x: o.x, y: o.y, width: r.width * s, height: r.height * s)
                    .intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
                if !px.isNull, px.width > 2, px.height > 2 { step.highlight = px }
            }
        }
    }

    private func saveImage(_ image: CGImage, stepID: UUID, folder: URL, name: String) {
        pendingImages += 1
        Task.detached(priority: .userInitiated) {
            let file = GuideStore.saveScreenshot(image, to: folder, name: name)
            await MainActor.run {
                self.pendingImages -= 1
                guard var g = self.guide, let i = g.steps.firstIndex(where: { $0.id == stepID }) else {
                    // Recording already finished: write straight into the store.
                    if let gid = self.lastGuideID, var sg = GuideStore.shared.guide(gid),
                       let j = sg.steps.firstIndex(where: { $0.id == stepID }) {
                        sg.steps[j].image = file
                        GuideStore.shared.update(sg)
                    }
                    return
                }
                g.steps[i].image = file
                self.guide = g
                self.save()
            }
        }
    }

    private var lastGuideID: UUID?

    private static func fileName(_ index: Int, _ id: UUID) -> String {
        String(format: "step-%03d-", index) + String(id.uuidString.prefix(6))
    }

    private func save() {
        guard let g = guide else { return }
        lastGuideID = g.id
        GuideStore.shared.update(g)
        refreshStatusItem()
    }

    // MARK: Menu bar item

    private func showStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        refreshStatusItem()
    }

    private func removeStatusItem() {
        if let s = statusItem { NSStatusBar.system.removeStatusItem(s) }
        statusItem = nil
    }

    private func refreshStatusItem() {
        guard let item = statusItem else { return }
        let title: String
        switch state {
        case .countdown(let n): title = n > 0 ? " Starting in \(n)…" : " Starting…"
        case .recording: title = " \(stepCount) step\(stepCount == 1 ? "" : "s")"
        case .paused: title = " Paused"
        case .finishing: title = " Saving…"
        case .idle: title = ""
        }
        item.button?.image = NSImage(systemSymbolName: state == .paused ? "pause.circle.fill" : "record.circle.fill",
                                     accessibilityDescription: "Pare Studio recording")
        item.button?.contentTintColor = state == .paused ? .systemOrange : .systemRed
        item.button?.imagePosition = .imageLeading
        item.button?.title = title

        let menu = NSMenu()
        let stopItem = NSMenuItem(title: "Stop and Edit Guide  (⌃⌥⌘S)", action: #selector(StatusTarget.stop), keyEquivalent: "")
        let pauseItem = NSMenuItem(title: state == .paused ? "Resume  (⌃⌥⌘P)" : "Pause  (⌃⌥⌘P)", action: #selector(StatusTarget.pause), keyEquivalent: "")
        let cancelItem = NSMenuItem(title: "Discard Recording", action: #selector(StatusTarget.discard), keyEquivalent: "")
        for i in [stopItem, pauseItem, cancelItem] { i.target = StatusTarget.shared }
        menu.addItem(stopItem)
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(cancelItem)
        item.menu = menu
    }
}

@MainActor
final class StatusTarget: NSObject {
    static let shared = StatusTarget()
    @objc func stop() { Recorder.shared.stop() }
    @objc func pause() { Recorder.shared.togglePause() }
    @objc func discard() { Recorder.shared.cancel() }
}

// MARK: - Event tap plumbing

struct TapEvent {
    let type: CGEventType
    let location: CGPoint
    let flags: CGEventFlags
    let keyCode: Int64
    let clickCount: Int
    let chars: String
}

private func recorderTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let recorder = Unmanaged<Recorder>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { recorder.reenableTap() }
        return Unmanaged.passUnretained(event)
    }
    var chars = ""
    if type == .keyDown {
        var len = 0
        var buf = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
        chars = String(utf16CodeUnits: buf, count: len)
    }
    let e = TapEvent(type: type, location: event.location, flags: event.flags,
                     keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                     clickCount: Int(event.getIntegerValueField(.mouseEventClickState)),
                     chars: chars)
    // The tap runs on the main run loop, so we're already on the main thread.
    MainActor.assumeIsolated { recorder.handle(e) }
    return Unmanaged.passUnretained(event)
}

extension NSEvent {
    /// Mouse position in screen coordinates with the origin at the top-left (like CGEvent).
    static var mouseLocationCG: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}

// MARK: - Accessibility: what's under the mouse

struct AXInfo {
    var pid: pid_t = 0
    var role = ""
    var subrole = ""
    var label = ""
    var frame: CGRect?
    var appName = ""
    var windowTitle = ""
    var isSecure: Bool { subrole == "AXSecureTextField" }
}

enum AX {
    static let system: AXUIElement = {
        let s = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(s, 0.3)
        return s
    }()

    static func element(at p: CGPoint) -> AXInfo {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &el) == .success, let el else {
            return AXInfo(appName: frontAppName)
        }
        return describe(el)
    }

    static func focused() -> AXInfo {
        guard let v = attr(system, kAXFocusedUIElementAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else {
            return AXInfo(appName: frontAppName)
        }
        return describe(v as! AXUIElement)
    }

    static var frontAppName: String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "" }

    static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ name: String) -> String {
        (attr(el, name) as? String)?.trimmed ?? ""
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let pv = attr(el, kAXPositionAttribute), let sv = attr(el, kAXSizeAttribute),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pt)
        AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    static func parent(_ el: AXUIElement) -> AXUIElement? {
        guard let v = attr(el, kAXParentAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func label(_ el: AXUIElement, role: String) -> String {
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        var candidates = [string(el, kAXTitleAttribute), string(el, kAXDescriptionAttribute)]
        if !textRoles.contains(role) { candidates.append(string(el, kAXValueAttribute)) }
        candidates.append(string(el, "AXPlaceholderValue"))
        if let t = attr(el, kAXTitleUIElementAttribute), CFGetTypeID(t) == AXUIElementGetTypeID() {
            let te = t as! AXUIElement
            candidates.append(string(te, kAXValueAttribute))
            candidates.append(string(te, kAXTitleAttribute))
        }
        candidates.append(string(el, kAXHelpAttribute))
        let first = candidates.first { !$0.isEmpty } ?? ""
        let oneLine = first.components(separatedBy: .newlines).first ?? first
        return oneLine.count > 70 ? String(oneLine.prefix(70)) + "…" : oneLine
    }

    static func describe(_ start: AXUIElement) -> AXInfo {
        var info = AXInfo()
        var el = start
        AXUIElementGetPid(el, &info.pid)
        info.appName = NSRunningApplication(processIdentifier: info.pid)?.localizedName ?? frontAppName
        info.role = string(el, kAXRoleAttribute)
        info.subrole = string(el, kAXSubroleAttribute)
        info.label = label(el, role: info.role)

        // Clicked on an icon or text inside a button/link? Use the button.
        let wrapperRoles: Set<String> = ["AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXCheckBox",
                                         "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTab", "AXCell", "AXRow", "AXDockItem"]
        if ["AXImage", "AXStaticText", "AXGroup", "AXUnknown"].contains(info.role) {
            var p = parent(el)
            for _ in 0..<3 {
                guard let pp = p else { break }
                let r = string(pp, kAXRoleAttribute)
                if wrapperRoles.contains(r) {
                    let l = label(pp, role: r)
                    el = pp
                    info.role = r
                    info.subrole = string(pp, kAXSubroleAttribute)
                    if !l.isEmpty { info.label = l }
                    break
                }
                p = parent(pp)
            }
        }
        info.frame = frame(el)
        if let w = attr(el, kAXWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() {
            info.windowTitle = string(w as! AXUIElement, kAXTitleAttribute)
        }
        return info
    }
}

// MARK: - Wording for each step

enum StepText {
    static func click(_ info: AXInfo, kind: StepKind, previousApp: String?) -> String {
        let verb: String
        switch kind {
        case .rightClick: verb = "Right-click"
        case .doubleClick: verb = "Double-click"
        default: verb = "Click"
        }
        let l = info.label
        var body: String
        switch info.role {
        case "AXMenuItem" where !l.isEmpty && kind == .click:
            body = "Choose **\(l)**"
        case "AXMenuBarItem" where !l.isEmpty && kind == .click:
            body = "Open the **\(l)** menu"
        case "AXDockItem" where !l.isEmpty:
            body = "\(verb) **\(l)** in the Dock"
        default:
            let noun: String
            switch info.role {
            case "AXButton": noun = " button"
            case "AXCheckBox": noun = " checkbox"
            case "AXRadioButton": noun = info.subrole == "AXTabButton" ? " tab" : " option"
            case "AXTab": noun = " tab"
            case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField": noun = " field"
            case "AXPopUpButton", "AXMenuButton": noun = " menu"
            case "AXLink": noun = " link"
            case "AXImage": noun = " icon"
            default: noun = ""
            }
            body = l.isEmpty ? "\(verb) here" : "\(verb) the **\(l)**\(noun)"
            if noun.isEmpty && !l.isEmpty { body = "\(verb) **\(l)**" }
        }
        // Say which app when it changes.
        if !info.appName.isEmpty, info.appName != previousApp, info.role != "AXDockItem" {
            let lowered = body.prefix(1).lowercased() + body.dropFirst()
            return "In **\(info.appName)**, \(lowered)"
        }
        return body
    }
}

enum KeyNames {
    static func combo(_ e: TapEvent) -> String {
        var s = ""
        if e.flags.contains(.maskControl) { s += "⌃" }
        if e.flags.contains(.maskAlternate) { s += "⌥" }
        if e.flags.contains(.maskShift) { s += "⇧" }
        if e.flags.contains(.maskCommand) { s += "⌘" }
        return s + name(e)
    }

    static func name(_ e: TapEvent) -> String {
        let special: [Int64: String] = [36: "Return", 76: "Enter", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
                                        123: "←", 124: "→", 125: "↓", 126: "↑", 117: "⌦", 115: "Home", 119: "End",
                                        116: "Page Up", 121: "Page Down", 122: "F1", 120: "F2", 99: "F3", 118: "F4",
                                        96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let n = special[e.keyCode] { return n }
        // Name the key as printed on it (ignoring modifiers).
        if let src = CGEventSource(stateID: .hidSystemState),
           let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(e.keyCode), keyDown: true) {
            ev.flags = []
            var len = 0
            var buf = [UniChar](repeating: 0, count: 4)
            ev.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
            let s = String(utf16CodeUnits: buf, count: len).uppercased()
            if !s.trimmed.isEmpty { return s }
        }
        return e.chars.uppercased()
    }
}

// MARK: - Live screen frames

struct Shot {
    let image: CGImage
    let displayFrame: CGRect   // points, global top-left coordinates
    let scale: CGFloat         // pixels per point
}

final class FrameGrabber: NSObject, SCStreamOutput, SCStreamDelegate {
    private struct Feed {
        let stream: SCStream
        let frame: CGRect
        let scale: CGFloat
    }

    private var feeds: [ObjectIdentifier: Feed] = [:]
    private var latestBuffers: [ObjectIdentifier: CVPixelBuffer] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "au.jivan.pareguide.frames")
    private static let ci = CIContext(options: [.cacheIntermediates: false])

    func start() async throws {
        await stop()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let me = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == me }
        for d in content.displays {
            let filter = SCContentFilter(display: d, excludingApplications: own, exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            let cfg = SCStreamConfiguration()
            cfg.width = Int(CGFloat(d.width) * scale)
            cfg.height = Int(CGFloat(d.height) * scale)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = false
            cfg.queueDepth = 5
            let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            lock.withLock { feeds[ObjectIdentifier(stream)] = Feed(stream: stream, frame: d.frame, scale: scale) }
        }
    }

    func stop() async {
        let streams: [SCStream] = lock.withLock {
            let s = feeds.values.map(\.stream)
            feeds = [:]
            latestBuffers = [:]
            return s
        }
        for s in streams { try? await s.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pb = sampleBuffer.imageBuffer else { return }
        lock.lock()
        latestBuffers[ObjectIdentifier(stream)] = pb
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        feeds[ObjectIdentifier(stream)] = nil
        latestBuffers[ObjectIdentifier(stream)] = nil
        lock.unlock()
    }

    /// The newest frame of the screen containing `point`, if one has arrived.
    func latest(at point: CGPoint) -> Shot? {
        lock.lock()
        let pick = feeds.first { $0.value.frame.contains(point) } ?? feeds.first
        let pb = pick.flatMap { latestBuffers[$0.key] }
        lock.unlock()
        guard let feed = pick?.value, let pb else { return nil }
        let img = CIImage(cvPixelBuffer: pb)
        guard let cg = Self.ci.createCGImage(img, from: img.extent) else { return nil }
        return Shot(image: cg, displayFrame: feed.frame, scale: CGFloat(cg.width) / feed.frame.width)
    }

    /// A single screenshot, for when no live frame is available.
    static func oneOff(at point: CGPoint) async throws -> Shot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let d = content.displays.first(where: { $0.frame.contains(point) }) ?? content.displays.first else {
            throw PGError("No screen found")
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(display: d, excludingApplications: content.applications.filter { $0.processID == me },
                                     exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(CGFloat(d.width) * scale)
        cfg.height = Int(CGFloat(d.height) * scale)
        cfg.showsCursor = false
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return Shot(image: img, displayFrame: d.frame, scale: CGFloat(img.width) / d.frame.width)
    }
}

// MARK: - Permissions

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func askAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func askScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    private static func open(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
}
