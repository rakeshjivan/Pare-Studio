// Narrator — reads narration aloud into sound files for videos.
// Two kinds of voice:
// • Pare Voice: cloned voices (yours, or voice artists you have permission for) made with Chatterbox,
//   using the voices saved by the Pare Voice app in ~/Documents/Pare Voice/Voices.
//   Pare Guide runs a small helper (Resources/pare_voice_engine.py) with the Chatterbox install at ~/chatterbox.
// • The Mac's built-in voices (no setup).
// Everything runs on this Mac.

import AppKit
import AVFoundation
import CryptoKit

enum NarratorKind: String, CaseIterable, Identifiable {
    case pareVoice = "Pare Voice (cloned voices)"
    case mac = "Mac voice"
    var id: String { rawValue }
}

enum PareVoiceMode: String, CaseIterable, Identifiable {
    case turbo = "Fast (Turbo)"
    case standard = "Expressive (Standard)"
    var id: String { rawValue }
    var engineName: String { self == .turbo ? "turbo" : "standard" }
}

/// Which program makes the cloned voice.
enum VoiceEngine: String, CaseIterable, Identifiable {
    case standard = "Standard (PyTorch)"
    case mlx = "Fast (MLX, beta)"
    var id: String { rawValue }
    var short: String { self == .mlx ? "mlx" : "standard" }
}

enum Narrator {
    static var kind: NarratorKind {
        get { NarratorKind(rawValue: UserDefaults.standard.string(forKey: "narratorKind") ?? "") ?? (PareVoice.isInstalled ? .pareVoice : .mac) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "narratorKind") }
    }

    /// Which narrator will actually be used (falls back to the Mac voice if Pare Voice isn't set up).
    static var effectiveKind: NarratorKind {
        kind == .pareVoice && PareVoice.isInstalled && PareVoice.selectedVoice != nil ? .pareVoice : .mac
    }

    /// Reads `text` into a sound file and returns the file and its length in seconds.
    /// Lines already read in the same voice and settings are reused, so re-exporting is quick.
    static func record(_ text: String, name: String, in folder: URL) async throws -> (URL, Double)? {
        let t = Pronunciations.apply(text.plain.trimmed)
        guard !t.isEmpty else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        if effectiveKind == .pareVoice, let voice = PareVoice.selectedVoice {
            let cached = pareCacheURL(t, voice: voice)
            if let secs = duration(cached) { touch(cached); return (cached, secs) }
            // If this line is already being made (by the background preparation or another export),
            // wait for that instead of making it twice. Each line is written to a temporary file and
            // moved into place when complete, so nothing ever reads a half-written line.
            let secs = try await NarrationJobs.shared.run(key: cached.path) {
                let tmp = cached.deletingLastPathComponent().appendingPathComponent(".making-\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: tmp) }
                let secs = try await PareVoice.say(t, voice: voice, to: tmp)
                try? FileManager.default.removeItem(at: cached)
                try FileManager.default.moveItem(at: tmp, to: cached)
                return secs
            }
            prune()
            return (cached, secs)
        }
        let voiceID = UserDefaults.standard.string(forKey: "voiceID") ?? ""
        let cached = cacheFolder.appendingPathComponent(hash("mac|\(voiceID)|\(t)") + ".caf")
        if let secs = duration(cached) { touch(cached); return (cached, secs) }
        let secs = try await Speech.write(t, to: cached)
        return secs > 0 ? (cached, secs) : nil
    }

    // MARK: Narration cache (~/Library/Caches/Pare Guide/Narration)

    private static func pareCacheURL(_ t: String, voice: String) -> URL {
        let sample = VoiceLibrary.url(voice)
        let stamp = (try? FileManager.default.attributesOfItem(atPath: sample.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = hash("pv|\(PareVoice.activeEngine.short)|\(voice)|\(stamp)|\(PareVoice.mode.engineName)|\(PareVoice.exaggeration)|\(PareVoice.cfg)|\(t)")
        return cacheFolder.appendingPathComponent(key + ".wav")
    }

    /// True when this line has already been made in the current Pare Voice and settings.
    static func isReady(_ text: String) -> Bool {
        let t = Pronunciations.apply(text.plain.trimmed)
        guard !t.isEmpty else { return true }
        guard effectiveKind == .pareVoice, let voice = PareVoice.selectedVoice else { return true }
        return FileManager.default.fileExists(atPath: pareCacheURL(t, voice: voice).path)
    }

    static var cacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pare Guide/Narration", isDirectory: true)
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func duration(_ url: URL) -> Double? {
        guard FileManager.default.fileExists(atPath: url.path), let f = try? AVAudioFile(forReading: url) else { return nil }
        let secs = Double(f.length) / f.processingFormat.sampleRate
        return secs > 0.1 ? secs : nil
    }

    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Keeps the 600 most recently used lines.
    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheFolder, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > 650 else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for f in sorted.dropFirst(600) { try? fm.removeItem(at: f) }
    }

    static var summary: String {
        switch effectiveKind {
        case .pareVoice: return "Pare Voice: \(PareVoice.selectedVoice ?? "")\(PareVoice.activeEngine == .mlx ? ", fast engine" : "")"
        case .mac: return "Mac voice"
        }
    }
}

// MARK: - Pare Voice engine

enum PareVoice {
    private static let lock = NSLock()
    private static var process: Process?
    private static var processEngine: VoiceEngine?

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var standardPython: URL { home.appendingPathComponent("chatterbox/bin/python") }
    static var mlxPython: URL { home.appendingPathComponent("pare-voice-mlx/bin/python") }
    static var standardInstalled: Bool { FileManager.default.isExecutableFile(atPath: standardPython.path) }
    static var mlxInstalled: Bool { FileManager.default.isExecutableFile(atPath: mlxPython.path) }

    /// The engine chosen in Settings › Voice.
    static var engineSetting: VoiceEngine {
        get { VoiceEngine(rawValue: UserDefaults.standard.string(forKey: "pareVoiceEngine") ?? "") ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "pareVoiceEngine") }
    }

    /// Set when the MLX engine failed this session; Pare Guide then uses Standard until it's reopened.
    static var mlxProblem: String?

    /// The engine that will actually run.
    static var activeEngine: VoiceEngine {
        if engineSetting == .mlx, mlxProblem == nil, mlxInstalled { return .mlx }
        if standardInstalled { return .standard }
        return mlxInstalled ? .mlx : .standard
    }

    static var port: Int { activeEngine == .mlx ? 7867 : 7866 }
    static var python: URL { activeEngine == .mlx ? mlxPython : standardPython }
    static var voicesFolder: URL { home.appendingPathComponent("Documents/Pare Voice/Voices", isDirectory: true) }
    static var script: URL? { Bundle.main.url(forResource: "pare_voice_engine", withExtension: "py") }

    /// Chatterbox is installed (the same setup Pare Voice uses).
    static var isInstalled: Bool { (standardInstalled || mlxInstalled) && script != nil }

    static var voices: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: voicesFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "wav" && !$0.lastPathComponent.hasPrefix(".") }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    static var selectedVoice: String? {
        let all = voices
        if let v = UserDefaults.standard.string(forKey: "pareVoiceName"), all.contains(v) { return v }
        return all.contains("Rakesh") ? "Rakesh" : all.first
    }

    static var mode: PareVoiceMode {
        PareVoiceMode(rawValue: UserDefaults.standard.string(forKey: "pareVoiceMode") ?? "") ?? .turbo
    }

    static var exaggeration: Double { UserDefaults.standard.object(forKey: "pareVoiceExpressiveness") as? Double ?? 0.45 }
    static var cfg: Double { UserDefaults.standard.object(forKey: "pareVoicePace") as? Double ?? 0.5 }

    private static var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private static func healthy() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Starts the helper if it isn't already running.
    static func start() async throws {
        let engine = activeEngine
        if processEngine == engine, await healthy() { return }
        if processEngine == nil, await healthy() { return }
        stop()   // only one engine in memory at a time
        guard isInstalled, let script else {
            throw PGError("Pare Voice isn't set up on this Mac (Chatterbox should be at ~/chatterbox).")
        }
        let p = Process()
        p.executableURL = python
        p.arguments = [script.path, String(port), engine.short]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = [python.deletingLastPathComponent().path, "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                       env["PATH"] ?? ""].joined(separator: ":")
        p.environment = env
        let log = home.appendingPathComponent("Library/Logs/Pare Guide voice.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
        try p.run()
        lock.withLock { process = p; processEngine = engine }
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if await healthy() { return }
            if !p.isRunning { break }
        }
        throw PGError("The Pare Voice helper didn't start. See ~/Library/Logs/Pare Guide voice.log.")
    }

    /// Loads the voice model in the background so the first narration starts straight away.
    static func warmUp() {
        guard Narrator.effectiveKind == .pareVoice else { return }
        Task.detached(priority: .utility) {
            guard (try? await PareVoice.start()) != nil else { return }
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(PareVoice.port)/warm")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 10
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["mode": PareVoice.mode.engineName])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    /// Stops the helper (when Pare Guide quits).
    static func stop() {
        lock.withLock {
            process?.terminate()
            process = nil
            processEngine = nil
        }
    }

    /// Speaks `text` in a Pare Voice voice into `url` (WAV). Returns the length in seconds.
    static func say(_ text: String, voice: String, to url: URL) async throws -> Double {
        do {
            return try await sayOnce(text, voice: voice, to: url)
        } catch {
            // If the fast engine fails, carry on with Standard for the rest of this session.
            guard activeEngine == .mlx, standardInstalled else { throw error }
            mlxProblem = error.localizedDescription
            stop()
            return try await sayOnce(text, voice: voice, to: url)
        }
    }

    private static func sayOnce(_ text: String, voice: String, to url: URL) async throws -> Double {
        try await start()
        var req = URLRequest(url: base.appendingPathComponent("say"))
        req.httpMethod = "POST"
        req.timeoutInterval = 900   // the first line also loads the voice model
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text, "voice": voice, "mode": mode.engineName,
            "exaggeration": exaggeration, "cfg": cfg, "out": url.path,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let secs = json?["seconds"] as? Double else {
            throw PGError("Pare Voice: \((json?["error"] as? String) ?? "no answer")")
        }
        return secs
    }
}

// MARK: - One job per line

/// Makes sure each narration line is only made once at a time, even when the background
/// preparation and Make Video ask for it together.
actor NarrationJobs {
    static let shared = NarrationJobs()
    private var running: [String: Task<Double, Error>] = [:]

    func run(key: String, _ make: @escaping @Sendable () async throws -> Double) async throws -> Double {
        if let job = running[key] { return try await job.value }
        // A separate task, so the line still finishes (and is kept) if whoever asked first stops waiting.
        let job = Task { try await make() }
        running[key] = job
        defer { running[key] = nil }
        return try await job.value
    }
}

// MARK: - Pronunciation list

/// How a word should be said, e.g. "Pare" → "Pair". Applied to every line before it's spoken.
struct Pronunciation: Codable, Identifiable, Hashable {
    var id = UUID()
    var word: String
    var sayAs: String
}

enum Pronunciations {
    static var all: [Pronunciation] {
        get {
            guard let d = UserDefaults.standard.data(forKey: "pronunciations"),
                  let list = try? JSONDecoder().decode([Pronunciation].self, from: d) else {
                return [Pronunciation(word: "Pare", sayAs: "Pair")]
            }
            return list
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "pronunciations") }
    }

    static func apply(_ s: String) -> String {
        var out = s
        for p in all where !p.word.trimmed.isEmpty && !p.sayAs.trimmed.isEmpty {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: p.word.trimmed) + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: p.sayAs.trimmed))
        }
        return out
    }
}

extension Narrator {
    /// Roughly how long a line takes to say (about 155 words a minute).
    static func estimate(_ s: String) -> Double {
        let words = s.plain.split { $0.isWhitespace }.count
        return words == 0 ? 0 : Double(words) / 2.6 + 0.3
    }
}

// MARK: - Hearing a line

@MainActor
final class NarrationPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = NarrationPlayer()
    @Published private(set) var playing: String?
    @Published private(set) var preparing: String?
    private var player: AVAudioPlayer?

    /// Plays a line in the chosen voice (or stops it if it's already playing).
    func toggle(_ text: String) async throws {
        if playing == text || preparing == text { stop(); return }
        stop()
        preparing = text
        defer { if preparing == text { preparing = nil } }
        let tmp = FileManager.default.temporaryDirectory
        guard let r = try await Narrator.record(text, name: "preview", in: tmp) else { return }
        guard preparing == text else { return }   // stopped while it was being made
        let p = try AVAudioPlayer(contentsOf: r.0)
        p.delegate = self
        p.play()
        player = p
        preparing = nil
        playing = text
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
        preparing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = nil }
    }
}
