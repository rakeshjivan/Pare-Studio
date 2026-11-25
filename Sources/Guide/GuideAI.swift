// AI — optional step wording. Four ways to do it:
// • Claude subscription: runs the official Claude Code tool ("claude -p") that you've signed in to,
//   so it uses your Pro/Max plan rather than paid API credits. No key needed.
// • Apple Intelligence: Apple's on-device model. Free, private, offline (macOS 26 or later).
// • Anthropic or OpenAI API key, for people with API credits.

import Foundation
import AppKit
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case claudeCode = "Claude subscription (via Claude Code)"
    case apple = "Apple Intelligence (on this Mac)"
    case anthropic = "Anthropic API key"
    case openai = "OpenAI API key"
    var id: String { rawValue }
    var defaultModel: String {
        switch self {
        case .claudeCode: return "sonnet"
        case .apple: return ""
        case .anthropic: return "claude-haiku-5-5"
        case .openai: return "gpt-4.1-mini"
        }
    }
    var keyAccount: String {
        switch self {
        case .claudeCode: return "claude-code"
        case .apple: return "apple"
        case .anthropic: return "anthropic-key"
        case .openai: return "openai-key"
        }
    }
    var needsKey: Bool { self == .anthropic || self == .openai }
}

/// A step to be written, with its finished picture.
struct AIJob {
    let number: Int
    let step: Step
    let picture: CGImage
}

enum AI {
    static var provider: AIProvider {
        get { AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? .claudeCode }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "aiProvider") }
    }
    static func model(_ p: AIProvider) -> String {
        let m = UserDefaults.standard.string(forKey: "aiModel-\(p.keyAccount)")?.trimmed ?? ""
        return m.isEmpty ? p.defaultModel : m
    }
    static var language: String {
        let l = UserDefaults.standard.string(forKey: "aiLanguage")?.trimmed ?? ""
        return l.isEmpty ? "English" : l
    }

    static var isReady: Bool {
        switch provider {
        case .claudeCode: return ClaudeCLI.find() != nil || AppleAI.isAvailable
        case .apple: return AppleAI.isAvailable
        case .anthropic, .openai: return !(Keychain.get(provider.keyAccount) ?? "").isEmpty
        }
    }

    static var notReadyMessage: String {
        switch provider {
        case .claudeCode: return "Click Connect Claude in Settings › AI first."
        case .apple: return "Apple Intelligence isn't available. See Settings › AI."
        case .anthropic, .openai: return "Add your API key in Settings › AI first."
        }
    }

    /// Set when the last request had to fall back to Apple Intelligence.
    @MainActor static var lastNote: String?

    // MARK: Writing steps

    /// Writes instructions for a batch of steps. Returns new text by step id.
    static func write(_ jobs: [AIJob]) async throws -> [UUID: String] {
        guard !jobs.isEmpty else { return [:] }
        await MainActor.run { lastNote = nil }
        switch provider {
        case .claudeCode:
            if ClaudeCLI.find() != nil {
                do { return try await ClaudeCLI.write(jobs) }
                catch {
                    guard AppleAI.isAvailable, !Task.isCancelled else { throw error }
                    let reason = String(error.localizedDescription.prefix(140))
                    await MainActor.run { lastNote = "Claude Code didn't answer (\(reason)), so Apple Intelligence wrote these." }
                }
            }
            return try await appleWrite(jobs)
        case .apple:
            return try await appleWrite(jobs)
        case .anthropic, .openai:
            var out: [UUID: String] = [:]
            for j in jobs {
                try Task.checkCancellation()
                out[j.step.id] = clean(try await send(prompt: singlePrompt(j), image: j.picture, maxTokens: 120))
            }
            return out
        }
    }

    private static func appleWrite(_ jobs: [AIJob]) async throws -> [UUID: String] {
        var out: [UUID: String] = [:]
        for j in jobs {
            try Task.checkCancellation()
            out[j.step.id] = clean(try await AppleAI.respond(textOnlyPrompt(j)))
        }
        return out
    }

    /// A title and one-line summary from the finished steps.
    static func titleAndSummary(_ guide: Guide) async throws -> (String, String) {
        let steps = guide.steps.enumerated().map { "\($0.offset + 1). \($0.element.text.plain)" }.joined(separator: "\n")
        let prompt = """
        These are the steps of a how-to guide for a Mac:
        \(steps)
        In \(language), reply with exactly two lines and nothing else: line 1 a short title (max 8 words, no quotes) \
        saying what the guide teaches; line 2 a one-sentence summary for the top of the guide.
        """
        let text: String
        switch provider {
        case .claudeCode:
            if ClaudeCLI.find() != nil {
                do { text = try await ClaudeCLI.ask(prompt) }
                catch {
                    guard AppleAI.isAvailable else { throw error }
                    text = try await AppleAI.respond(prompt)
                }
            } else { text = try await AppleAI.respond(prompt) }
        case .apple: text = try await AppleAI.respond(prompt)
        case .anthropic, .openai: text = try await send(prompt: prompt, image: nil, maxTokens: 150)
        }
        let lines = text.split(separator: "\n").map { String($0).trimmed }.filter { !$0.isEmpty }
        return (clean(lines.first ?? guide.title), clean(lines.dropFirst().first ?? guide.summary))
    }

    // MARK: Prompts

    static func facts(_ j: AIJob) -> String {
        let s = j.step
        var c = "action: \(actionWords(s))"
        if !s.appName.isEmpty { c += "; app: \(s.appName)" }
        if !s.windowTitle.isEmpty { c += "; window: \(s.windowTitle)" }
        if !s.label.isEmpty { c += "; item label: \"\(s.label)\"" }
        if !s.role.isEmpty { c += "; item type: \(s.role.replacingOccurrences(of: "AX", with: ""))" }
        c += "; current draft: \"\(s.text.plain)\""
        return c
    }

    static let rules = """
    Write ONE short, plain instruction (at most 20 words) a beginner can follow. Start with a verb. \
    Put on-screen labels in **double asterisks**. Keep any typed text exactly as in the draft. \
    Never include passwords or private details.
    """

    private static func singlePrompt(_ j: AIJob) -> String {
        """
        You are writing step \(j.number) of a how-to guide for a Mac. The screenshot shows the screen at this step; \
        the orange box and dot mark what the person clicked or typed into.
        Facts: \(facts(j)).
        \(rules) Write in \(language). Reply with the instruction only.
        """
    }

    private static func textOnlyPrompt(_ j: AIJob) -> String {
        """
        You are writing step \(j.number) of a how-to guide for a Mac, from what the Mac recorded.
        Facts: \(facts(j)).
        \(rules) Write in \(language). Reply with the instruction only.
        """
    }

    private static func actionWords(_ s: Step) -> String {
        switch s.kind {
        case .click: return "single click"
        case .rightClick: return "right-click"
        case .doubleClick: return "double-click"
        case .type: return "typing into a field"
        case .shortcut: return "keyboard shortcut"
        case .note: return "note"
        }
    }

    static func clean(_ s: String) -> String {
        var t = s.trimmed
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count > 1 { t = String(t.dropFirst().dropLast()) }
        for p in ["title:", "summary:", "instruction:"] where t.lowercased().hasPrefix(p) {
            t = String(t.dropFirst(p.count)).trimmed
        }
        return t
    }

    // MARK: API keys

    private static func send(prompt: String, image: CGImage?, maxTokens: Int) async throws -> String {
        let p = provider
        guard let key = Keychain.get(p.keyAccount), !key.isEmpty else {
            throw PGError("Add your \(p.rawValue) in Settings first.")
        }
        var b64: String?
        if let image {
            let small = image.width > 1400 ? (Renderer.scaled(image, width: 1400) ?? image) : image
            b64 = Renderer.jpeg(small, quality: 0.8)?.base64EncodedString()
        }
        var req: URLRequest
        var body: [String: Any]
        if p == .anthropic {
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var content: [[String: Any]] = []
            if let b64 {
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]])
            }
            content.append(["type": "text", "text": prompt])
            body = ["model": model(p), "max_tokens": maxTokens, "messages": [["role": "user", "content": content]]]
        } else {
            req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            var content: [[String: Any]] = [["type": "text", "text": prompt]]
            if let b64 {
                content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]])
            }
            body = ["model": model(p), "messages": [["role": "user", "content": content]]]
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 60
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PGError("\(p == .anthropic ? "Anthropic" : "OpenAI") said: \(msg.prefix(300))")
        }
        if p == .anthropic {
            let blocks = json?["content"] as? [[String: Any]] ?? []
            return blocks.compactMap { $0["text"] as? String }.joined()
        }
        let choices = json?["choices"] as? [[String: Any]] ?? []
        return ((choices.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
    }
}

// MARK: - Claude Code (your Claude subscription)

enum ClaudeCLI {
    private static let lock = NSLock()
    private static var cached: String??

    /// Where the `claude` tool is installed, if it is.
    static func find() -> String? {
        if let c = lock.withLock({ cached }) { return c }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude",
                          "\(home)/.volta/bin/claude"]
        var found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        if found == nil {
            // Ask a login shell, which knows the user's PATH.
            let r = run("/bin/zsh", ["-lc", "command -v claude"], cwd: nil, env: nil, timeout: 10)
            let p = r.out.trimmed
            if r.status == 0, !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) { found = p }
        }
        lock.withLock { cached = .some(found) }
        return found
    }

    /// Look again next time (after installing Claude Code).
    static func forgetLocation() { lock.withLock { cached = nil } }

    /// Environment for claude: the user's normal one, minus anything that would switch it to paid API billing.
    static var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK",
                  "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] { e[k] = nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        e["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin", e["PATH"] ?? ""].joined(separator: ":")
        return e
    }

    /// Quick check from Settings: is it installed and signed in?
    static func test() async -> String {
        forgetLocation()
        guard find() != nil else { return "Claude Code isn't installed." }
        do {
            let reply = try await ask("Reply with just the word OK.")
            return reply.uppercased().contains("OK") ? "Working. Steps will use your Claude subscription." : "Claude Code replied: \(reply.prefix(80))"
        } catch { return error.localizedDescription }
    }

    /// A text-only question.
    static func ask(_ prompt: String) async throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pareguide-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await call(prompt, in: dir, allowRead: false)
    }

    /// Writes all the steps in one go: the pictures are saved to a temporary folder and Claude reads them.
    static func write(_ jobs: [AIJob]) async throws -> [UUID: String] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pareguide-ai-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        var lines: [String] = []
        for (i, j) in jobs.enumerated() {
            let name = String(format: "step-%02d.jpg", j.number)
            let small = j.picture.width > 1400 ? (Renderer.scaled(j.picture, width: 1400) ?? j.picture) : j.picture
            try Renderer.jpeg(small, quality: 0.8)?.write(to: dir.appendingPathComponent(name))
            lines.append("\(i + 1). image file: \(name) | \(AI.facts(j))")
        }
        let prompt = """
        You are writing steps for a how-to guide for a Mac. For each step below, open its screenshot with the Read tool \
        (the files are in the current folder). The orange box and dot mark what the person clicked or typed into.
        For each step: \(AI.rules) Write in \(AI.language).
        Reply with ONLY a JSON array of \(jobs.count) strings, one per step, in the same order. No other text.

        Steps:
        \(lines.joined(separator: "\n"))
        """
        let reply = try await call(prompt, in: dir, allowRead: true)
        guard let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String], arr.count == jobs.count else {
            throw PGError("Claude's reply wasn't in the expected format. Try again.")
        }
        var out: [UUID: String] = [:]
        for (j, text) in zip(jobs, arr) where !text.trimmed.isEmpty { out[j.step.id] = AI.clean(text) }
        return out
    }

    private static func call(_ prompt: String, in dir: URL, allowRead: Bool) async throws -> String {
        guard let exe = find() else { throw PGError("Claude Code isn't installed.") }
        var args = ["-p", prompt, "--output-format", "text", "--model", AI.model(.claudeCode)]
        if allowRead { args += ["--allowedTools", "Read"] }
        let environment = env
        let r = await Task.detached(priority: .userInitiated) {
            run(exe, args, cwd: dir, env: environment, timeout: 300)
        }.value
        if r.timedOut { throw PGError("Claude Code took too long to answer.") }
        let text = r.out.trimmed
        guard r.status == 0, !text.isEmpty else {
            let detail = r.err.trimmed.isEmpty ? text : r.err.trimmed
            let lower = detail.lowercased()
            if lower.contains("login") || lower.contains("log in") || lower.contains("authenticat") || lower.contains("api key") {
                throw PGError("Claude isn't connected yet. Click Connect Claude in Settings › AI.")
            }
            if lower.contains("limit") || lower.contains("credit") || lower.contains("quota") || lower.contains("usage") {
                throw PGError("Your Claude allowance is used up for now. \(detail.prefix(160))")
            }
            throw PGError("Claude Code: \(detail.isEmpty ? "no answer" : String(detail.prefix(200)))")
        }
        return text
    }

    struct Result { var status: Int32; var out: String; var err: String; var timedOut: Bool }

    static func run(_ exe: String, _ args: [String], cwd: URL?, env: [String: String]?, timeout: TimeInterval) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let env { p.environment = env }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(status: -1, out: "", err: error.localizedDescription, timedOut: false) }
        // Read both pipes while it runs so a long reply can't block it.
        let box = PipeBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { box.set(out: outPipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        group.enter()
        DispatchQueue.global().async { box.set(err: errPipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            _ = group.wait(timeout: .now() + 5)
        }
        p.waitUntilExit()
        let (o, e) = box.get()
        return Result(status: p.terminationStatus, out: String(decoding: o, as: UTF8.self),
                      err: String(decoding: e, as: UTF8.self), timedOut: timedOut)
    }
}

// MARK: - Connect Claude (install + sign in, no Terminal)

extension ClaudeCLI {
    /// Installs Claude Code with Anthropic's official installer.
    static func install() async throws {
        let environment = env
        let r = await Task.detached {
            run("/bin/bash", ["-c", "curl -fsSL https://claude.ai/install.sh | bash"], cwd: nil, env: environment, timeout: 600)
        }.value
        forgetLocation()
        guard find() != nil else {
            let tail = (r.err.trimmed.isEmpty ? r.out : r.err).trimmed.suffix(200)
            throw PGError("Installing Claude Code didn't work. \(tail)")
        }
    }

    /// Whether Claude Code is signed in, and as whom.
    static func authStatus() async -> (loggedIn: Bool, who: String) {
        guard let exe = find() else { return (false, "") }
        let environment = env
        let r = await Task.detached { run(exe, ["auth", "status"], cwd: nil, env: environment, timeout: 20) }.value
        let text = r.out + "\n" + r.err
        let lower = text.lowercased().replacingOccurrences(of: " ", with: "")
        let loggedIn = r.status == 0 && !lower.contains("notloggedin") && !lower.contains("\"loggedin\":false")
        var who = ""
        if let re = try? NSRegularExpression(pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: .caseInsensitive),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(m.range, in: text) {
            who = String(text[range])
        }
        return (loggedIn, who)
    }
}

@MainActor
final class ClaudeConnect: ObservableObject {
    static let shared = ClaudeConnect()

    enum Phase: Equatable { case unknown, notConnected, installing, signingIn, connected(String), failed(String) }

    @Published private(set) var phase: Phase = .unknown
    @Published private(set) var signInURL: URL?

    private var process: Process?
    private var stdin: Pipe?
    private var output = ""
    private var triedWithoutFlag = false

    func refresh() async {
        guard ClaudeCLI.find() != nil else { phase = .notConnected; return }
        let s = await ClaudeCLI.authStatus()
        phase = s.loggedIn ? .connected(s.who) : .notConnected
    }

    func connect() {
        guard phase != .installing, phase != .signingIn else { return }
        Task {
            if ClaudeCLI.find() == nil {
                phase = .installing
                do { try await ClaudeCLI.install() } catch {
                    phase = .failed(error.localizedDescription)
                    return
                }
            }
            let s = await ClaudeCLI.authStatus()
            if s.loggedIn { phase = .connected(s.who); return }
            triedWithoutFlag = false
            startLogin(withFlag: true)
        }
    }

    private func startLogin(withFlag: Bool) {
        guard let exe = ClaudeCLI.find() else { phase = .failed("Claude Code isn't installed."); return }
        phase = .signingIn
        signInURL = nil
        output = ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        // --claudeai picks "Claude account with subscription" rather than paid API (Console) billing.
        p.arguments = withFlag ? ["auth", "login", "--claudeai"] : ["auth", "login"]
        p.environment = ClaudeCLI.env
        let out = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = input
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let chunk = String(decoding: d, as: UTF8.self)
            Task { @MainActor in ClaudeConnect.shared.received(chunk) }
        }
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            Task { @MainActor in ClaudeConnect.shared.finished(code, usedFlag: withFlag) }
        }
        do { try p.run() } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        process = p
        stdin = input
    }

    private func received(_ chunk: String) {
        output += chunk
        if signInURL == nil,
           let re = try? NSRegularExpression(pattern: #"https://[^\s"'<>]+"#),
           let m = re.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let r = Range(m.range, in: output) {
            signInURL = URL(string: String(output[r]))
        }
    }

    private func finished(_ code: Int32, usedFlag: Bool) {
        process?.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdin = nil
        let lower = output.lowercased()
        if code != 0, usedFlag, !triedWithoutFlag,
           lower.contains("unknown option") || lower.contains("unknown argument") || lower.contains("unexpected argument") {
            triedWithoutFlag = true
            startLogin(withFlag: false)
            return
        }
        Task {
            let s = await ClaudeCLI.authStatus()
            if s.loggedIn {
                phase = .connected(s.who)
            } else if case .signingIn = phase {
                let tail = output.trimmed.split(separator: "\n").suffix(2).joined(separator: " ")
                phase = .failed(tail.isEmpty ? "Sign-in didn't finish. Try again." : "Sign-in didn't finish: \(tail.prefix(200))")
            }
        }
    }

    /// For when the browser shows a code to paste back instead of returning by itself.
    func submitCode(_ code: String) {
        stdin?.fileHandleForWriting.write(Data((code.trimmed + "\n").utf8))
    }

    func cancel() {
        process?.terminate()
        phase = .notConnected
    }
}

private final class PipeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    func set(out d: Data) { lock.withLock { out = d } }
    func set(err d: Data) { lock.withLock { err = d } }
    func get() -> (Data, Data) { lock.withLock { (out, err) } }
}

// MARK: - Apple Intelligence (on-device)

enum AppleAI {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    static var status: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Ready on this Mac (reads the step details, not the screenshots)."
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri."
                case .modelNotReady: return "Apple Intelligence is still downloading. Try again later."
                case .deviceNotEligible: return "This Mac can't run Apple Intelligence."
                @unknown default: return "Apple Intelligence isn't available right now."
                }
            @unknown default: return "Apple Intelligence isn't available right now."
            }
        }
        #endif
        return "Needs macOS 26 or later."
    }

    static func respond(_ prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { throw PGError(status) }
            let session = LanguageModelSession(instructions: "You write short, clear instructions for how-to guides about using a Mac.")
            let r = try await session.respond(to: prompt)
            return r.content
        }
        #endif
        throw PGError("Apple Intelligence needs macOS 26 or later.")
    }
}

// MARK: - Narration script for tutorial videos

struct NarrationScript {
    var intro: String
    var steps: [UUID: String]
    var outro: String
}

extension AI {
    /// Turns the written steps into a natural spoken script: an intro, one line per step, and an outro.
    static func narration(_ guide: Guide, brand: Brand?) async throws -> NarrationScript {
        let steps = guide.steps
        guard !steps.isEmpty else { return NarrationScript(intro: "", steps: [:], outro: "") }
        let list = steps.enumerated().map { i, s -> String in
            var line = "\(i + 1). \(s.text.plain)"
            var facts: [String] = []
            if !s.appName.isEmpty { facts.append("app: \(s.appName)") }
            if !s.label.isEmpty { facts.append("clicked: \"\(s.label)\"") }
            if !facts.isEmpty { line += "  [\(facts.joined(separator: "; "))]" }
            return line
        }.joined(separator: "\n")
        let brandLine = brand.map { "The video is for \($0.name)\($0.tagline.isEmpty ? "" : " (tagline: \"\($0.tagline)\")")." } ?? ""
        let prompt = """
        You are writing the voiceover for a short tutorial video made from a recording on a Mac.
        Title: \(guide.title.plain)
        \(guide.summary.isEmpty ? "" : "Summary: \(guide.summary.plain)\n")\(brandLine)
        Steps:
        \(list)

        Write natural, friendly narration in \(language) for a narrator to read aloud while each step is shown.
        - intro: one sentence saying what the video shows (at most 20 words).
        - steps: exactly \(steps.count) short spoken sentences, one per step, in order (at most 18 words each). \
        Conversational, for example "Now click Compress PDF." No markdown, no asterisks, no step numbers. \
        Never read out passwords or private details; say "enter your password" instead.
        - outro: one short closing sentence (at most 16 words).
        Reply with ONLY this JSON and nothing else: {"intro": "...", "steps": ["...", ...], "outro": "..."}
        """
        let reply = try await askText(prompt)
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PGError("The AI's reply wasn't in the expected format. Try again.")
        }
        let lines = (obj["steps"] as? [String]) ?? []
        var map: [UUID: String] = [:]
        for (s, l) in zip(steps, lines) where !l.trimmed.isEmpty { map[s.id] = clean(l).plain }
        return NarrationScript(intro: clean((obj["intro"] as? String) ?? "").plain,
                               steps: map,
                               outro: clean((obj["outro"] as? String) ?? "").plain)
    }
}


extension AI {
    /// Sends a text-only request through whichever AI is chosen in Settings.
    static func askText(_ prompt: String, maxTokens: Int = 2000) async throws -> String {
        switch provider {
        case .claudeCode:
            if ClaudeCLI.find() != nil {
                do { return try await ClaudeCLI.ask(prompt) }
                catch {
                    guard AppleAI.isAvailable else { throw error }
                    return try await AppleAI.respond(prompt)
                }
            }
            return try await AppleAI.respond(prompt)
        case .apple: return try await AppleAI.respond(prompt)
        case .anthropic, .openai: return try await send(prompt: prompt, image: nil, maxTokens: maxTokens)
        }
    }

    /// Rewrites one narration line (shorter, friendlier, more formal…).
    static func rewriteLine(_ line: String, how: String, title: String) async throws -> String {
        let prompt = """
        This is one line of voiceover for a short tutorial video\(title.isEmpty ? "" : " called \"\(title)\"").
        Rewrite it to be \(how). Keep the meaning and any button or field names. Natural spoken \(language), \
        at most 20 words, no markdown, no quotation marks around it.
        Line: \(line.plain)
        Reply with ONLY the new line.
        """
        let out = clean(try await askText(prompt, maxTokens: 300)).plain.trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}"))
        guard !out.isEmpty else { throw PGError("The AI didn't suggest anything. Try again.") }
        return out
    }

    /// Tidies what you said while recording into clean narration, one line per step.
    static func polishSpoken(_ guide: Guide) async throws -> [UUID: String] {
        let steps = guide.steps
        guard !steps.isEmpty else { return [:] }
        let list = steps.enumerated().map { i, s in
            "\(i + 1). Action: \(s.text.plain)\n   Presenter said: \((s.narration ?? "").isEmpty ? "(nothing)" : s.narration!.plain)"
        }.joined(separator: "\n")
        let prompt = """
        These are the steps of a tutorial video\(guide.title.isEmpty ? "" : " called \"\(guide.title.plain)\"") and what \
        the presenter said during each one (from speech-to-text, so it may be messy).
        \(list)

        Rewrite each into one clean, natural spoken line in \(language) for the voiceover. Keep the presenter's meaning, \
        tone and wording where possible; fix grammar and remove false starts. Where they said nothing, write a short line \
        from the action. At most 22 words each, no markdown, no step numbers.
        Reply with ONLY this JSON: {"steps": ["...", ...]} with exactly \(steps.count) items.
        """
        let reply = try await askText(prompt)
        guard let a = reply.firstIndex(of: "{"), let b = reply.lastIndex(of: "}"), a < b,
              let data = String(reply[a...b]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = obj["steps"] as? [String] else {
            throw PGError("The AI's reply wasn't in the expected format. Try again.")
        }
        var out: [UUID: String] = [:]
        for (s, l) in zip(steps, lines) where !l.trimmed.isEmpty { out[s.id] = clean(l).plain }
        return out
    }
}

// MARK: - Translation

extension AI {
    static let translationLanguages = [
        "English", "Chinese (Simplified)", "Chinese (Traditional)", "Japanese", "Korean", "Vietnamese", "Thai",
        "Indonesian", "Malay", "Filipino", "Hindi", "Arabic", "Spanish", "French", "German", "Italian", "Portuguese",
        "Dutch", "Greek", "Turkish", "Polish", "Russian",
    ]

    /// Translates a list of strings, keeping **bold** markers. Returns the same number of strings.
    static func translate(_ texts: [String], to language: String, keepLabels: Bool, title: String,
                          progress: @escaping (Int, Int) -> Void) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        // Apple's on-device model has a small memory, so it gets smaller batches.
        let usesApple = provider == .apple || (provider == .claudeCode && ClaudeCLI.find() == nil)
        let chunk = usesApple ? 8 : 30
        var out: [String] = []
        var start = 0
        while start < texts.count {
            try Task.checkCancellation()
            let part = Array(texts[start..<min(start + chunk, texts.count)])
            progress(start, texts.count)
            let list = part.enumerated().map { i, t in "\(i + 1). \(jsonString(t))" }.joined(separator: "\n")
            let labelRule = keepLabels
                ? "Words inside **double asterisks** are on-screen labels: copy them EXACTLY as written, untranslated, because the screenshots show them in the original language. Keep the asterisks."
                : "Words inside **double asterisks** are on-screen labels: translate them too, and keep the asterisks around them."
            let prompt = """
            Translate these strings from a how-to guide\(title.isEmpty ? "" : " called \"\(title)\"") into \(language).
            Rules:
            - \(labelRule)
            - Keep anything the person typed (in quotation marks), keyboard shortcuts like ⌘C, app names, file names and web addresses unchanged.
            - Natural, clear \(language) for a beginner. Same meaning, no extra words.
            - An empty string stays empty.
            Strings (JSON-escaped):
            \(list)
            Reply with ONLY a JSON array of exactly \(part.count) strings, in the same order. No other text.
            """
            let reply = try await askText(prompt, maxTokens: 4000)
            guard let a = reply.firstIndex(of: "["), let b = reply.lastIndex(of: "]"), a < b,
                  let data = String(reply[a...b]).data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [String], arr.count == part.count else {
                throw PGError("The translation came back in the wrong shape. Try again.")
            }
            out += zip(part, arr).map { orig, new in orig.trimmed.isEmpty ? orig : new.trimmed }
            start += chunk
        }
        progress(texts.count, texts.count)
        return out
    }

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// A translated copy of a guide (same screenshots, drawings and settings).
    static func translatedCopy(of g: Guide, to language: String, keepLabels: Bool,
                               progress: @escaping (Int, Int) -> Void) async throws -> Guide {
        // Gather every piece of text, remembering where it goes back.
        enum Slot { case title, summary, intro, outro, step(Int), narration(Int), mark(Int, Int) }
        var slots: [Slot] = []
        var texts: [String] = []
        func add(_ slot: Slot, _ t: String?) {
            guard let t, !t.trimmed.isEmpty else { return }
            slots.append(slot); texts.append(t)
        }
        add(.title, g.title)
        add(.summary, g.summary)
        add(.intro, g.introNarration)
        add(.outro, g.outroNarration)
        for (i, s) in g.steps.enumerated() {
            add(.step(i), s.text)
            add(.narration(i), s.narration)
            for (j, m) in s.marks.enumerated() where m.kind == .text { add(.mark(i, j), m.text) }
        }
        let done = try await translate(texts, to: language, keepLabels: keepLabels, title: g.title.plain, progress: progress)
        var c = g
        for (slot, t) in zip(slots, done) {
            switch slot {
            case .title: c.title = t
            case .summary: c.summary = t
            case .intro: c.introNarration = t.plain
            case .outro: c.outroNarration = t.plain
            case .step(let i): c.steps[i].text = t
            case .narration(let i): c.steps[i].narration = t.plain
            case .mark(let i, let j): c.steps[i].marks[j].text = t.plain
            }
        }
        return c
    }
}
