// VoiceLibrary — one-click setup of Pare Voice, and the library of cloned voices.
// • Setup installs everything itself (no Terminal): uv, a Python 3.11 environment at ~/chatterbox,
//   Chatterbox, the music remover and the voice models. Safe to run again: it repairs and updates.
// • Voices live in ~/Documents/Pare Voice/Voices (shared with the Pare Voice app). Add one by recording
//   15 seconds, or from any audio or video file; move them between Macs with Export/Import Voices.

import AppKit
import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class VoiceSetup: ObservableObject {
    static let shared = VoiceSetup()

    enum Phase: Equatable { case idle, running(String), done, failed(String) }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var log = ""
    private var process: Process?

    var isRunning: Bool { if case .running = phase { return true } else { return false } }

    /// The whole install as one script, so each part runs in order without anyone typing anything.
    private static let script = #"""
    set -e
    export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    VENV="$HOME/chatterbox"
    UV="$HOME/.local/bin/uv"
    echo "STEP Getting the installer (uv)…"
    if [ ! -x "$UV" ]; then curl -LsSf https://astral.sh/uv/install.sh | sh; fi
    echo "STEP Making the voice environment…"
    if [ ! -x "$VENV/bin/python" ]; then "$UV" venv --python 3.11 "$VENV"; fi
    echo "STEP Installing Chatterbox (a few minutes)…"
    "$UV" pip install --python "$VENV/bin/python" chatterbox-tts "setuptools<81"
    echo "STEP Installing the music remover…"
    TOOLS="$HOME/pare-voice-tools"
    if [ ! -x "$TOOLS/bin/python" ]; then "$UV" venv --python 3.11 "$TOOLS"; fi
    if "$UV" pip install --python "$TOOLS/bin/python" "audio-separator[cpu]" imageio-ffmpeg; then
      FF="$("$TOOLS/bin/python" -c 'import imageio_ffmpeg;print(imageio_ffmpeg.get_ffmpeg_exe())' 2>/dev/null || true)"
      if [ -n "$FF" ]; then ln -sf "$FF" "$TOOLS/bin/ffmpeg"; fi
    else
      echo "Music remover skipped (everything else still works)"
    fi
    echo "STEP Downloading the voice models (a few GB, once only)…"
    "$VENV/bin/python" - <<'PY'
    import torch
    _load = torch.load
    torch.load = lambda *a, **k: _load(*a, **{**k, "map_location": torch.device("cpu")})
    from chatterbox.tts_turbo import ChatterboxTurboTTS
    from chatterbox.tts import ChatterboxTTS
    ChatterboxTurboTTS.from_pretrained(device="cpu")
    ChatterboxTTS.from_pretrained(device="cpu")
    print("models ready")
    PY
    mkdir -p "$HOME/Documents/Pare Voice/Voices"
    echo "STEP Done"
    """#

    func run() {
        guard !isRunning else { return }
        PareVoice.stop()
        log = ""
        phase = .running("Starting…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", Self.script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let chunk = String(decoding: d, as: UTF8.self)
            Task { @MainActor in VoiceSetup.shared.received(chunk) }
        }
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            Task { @MainActor in VoiceSetup.shared.finished(code) }
        }
        do { try p.run(); process = p } catch { phase = .failed(error.localizedDescription) }
    }

    private func received(_ chunk: String) {
        log = String((log + chunk).suffix(6000))
        for line in chunk.split(separator: "\n") where line.hasPrefix("STEP ") {
            phase = .running(String(line.dropFirst(5)))
        }
    }

    private func finished(_ code: Int32) {
        process?.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        process = nil
        if code == 0 {
            phase = .done
            Narrator.kind = .pareVoice
        } else {
            let tail = log.trimmed.split(separator: "\n").suffix(3).joined(separator: " ")
            phase = .failed("Setup stopped: \(tail.prefix(240))")
        }
        objectWillChange.send()
    }

    func cancel() { process?.terminate() }
}

// MARK: - The fast (MLX) engine

/// Installs mlx-audio in its own environment (~/pare-voice-mlx), so it can't upset the Standard engine.
@MainActor
final class MLXSetup: ObservableObject {
    static let shared = MLXSetup()

    enum Phase: Equatable { case idle, running(String), done, failed(String) }
    @Published private(set) var phase: Phase = .idle
    private var log = ""
    private var process: Process?

    var isRunning: Bool { if case .running = phase { return true } else { return false } }

    private static let script = #"""
    set -e
    export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    UV="$HOME/.local/bin/uv"
    VENV="$HOME/pare-voice-mlx"
    echo "STEP Getting the installer (uv)…"
    if [ ! -x "$UV" ]; then curl -LsSf https://astral.sh/uv/install.sh | sh; fi
    echo "STEP Making the fast voice environment…"
    if [ ! -x "$VENV/bin/python" ]; then "$UV" venv --python 3.12 "$VENV"; fi
    echo "STEP Installing MLX voice (a few minutes)…"
    "$UV" pip install --python "$VENV/bin/python" -U mlx-audio librosa soundfile scipy
    echo "STEP Downloading the fast voice models (once only)…"
    "$VENV/bin/python" - <<'PY'
    from mlx_audio.tts.utils import load_model
    for group in (["mlx-community/chatterbox-turbo-fp16", "mlx-community/chatterbox-turbo-8bit", "mlx-community/chatterbox-turbo-4bit"],
                  ["mlx-community/chatterbox-fp16", "mlx-community/chatterbox-8bit"]):
        for repo in group:
            try:
                load_model(repo)
                print("ready:", repo, flush=True)
                break
            except Exception as e:
                print("skipped:", repo, e, flush=True)
    PY
    echo "STEP Done"
    """#

    func run() {
        guard !isRunning else { return }
        log = ""
        phase = .running("Starting…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", Self.script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let chunk = String(decoding: d, as: UTF8.self)
            Task { @MainActor in MLXSetup.shared.received(chunk) }
        }
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            Task { @MainActor in MLXSetup.shared.finished(code) }
        }
        do { try p.run(); process = p } catch { phase = .failed(error.localizedDescription) }
    }

    private func received(_ chunk: String) {
        log = String((log + chunk).suffix(6000))
        for line in chunk.split(separator: "\n") where line.hasPrefix("STEP ") {
            phase = .running(String(line.dropFirst(5)))
        }
    }

    private func finished(_ code: Int32) {
        process?.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        process = nil
        if code == 0, PareVoice.mlxInstalled {
            phase = .done
            PareVoice.mlxProblem = nil
            PareVoice.stop()
        } else {
            let tail = log.trimmed.split(separator: "\n").suffix(3).joined(separator: " ")
            phase = .failed("Install stopped: \(tail.prefix(240))")
        }
    }

    func cancel() { process?.terminate() }
}

// MARK: - The library

enum VoiceLibrary {
    static var folder: URL { PareVoice.voicesFolder }

    static func url(_ name: String) -> URL { folder.appendingPathComponent(name + ".wav") }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let t = s.components(separatedBy: bad).joined().trimmed
        return t.isEmpty ? "My voice" : String(t.prefix(40))
    }

    /// Adds a voice from any audio or video file. Picks the cleanest stretch of speech and,
    /// if asked, removes background music first.
    static func add(from file: URL, name: String, removeMusic: Bool) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let audio = try await extractAudio(file, to: work)
        try await PareVoice.addVoice(src: audio, name: safeName(name), clean: removeMusic)
    }

    /// Any audio or video → a WAV file the voice tools can read.
    static func extractAudio(_ src: URL, to dir: URL) async throws -> URL {
        let m4a = dir.appendingPathComponent("audio.m4a")
        let wav = dir.appendingPathComponent("audio.wav")
        let asset = AVURLAsset(url: src)
        if let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
            export.outputURL = m4a
            export.outputFileType = .m4a
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
            if export.status == .completed,
               Tools.runQuick("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@24000", "-c", "1", m4a.path, wav.path]) == 0 {
                return wav
            }
        }
        if Tools.runQuick("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@24000", "-c", "1", src.path, wav.path]) == 0 {
            return wav
        }
        throw PGError("Couldn't read any sound from that file.")
    }

    static func rename(_ old: String, to new: String) throws {
        let n = safeName(new)
        guard n != old else { return }
        guard !FileManager.default.fileExists(atPath: url(n).path) else { throw PGError("There's already a voice called \(n).") }
        try FileManager.default.moveItem(at: url(old), to: url(n))
    }

    static func delete(_ name: String) {
        try? FileManager.default.trashItem(at: url(name), resultingItemURL: nil)
    }

    /// All voices in one file, to copy to another Mac.
    static func exportAll(to dest: URL) throws {
        try? FileManager.default.removeItem(at: dest)
        guard Tools.runQuick("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, dest.path]) == 0 else {
            throw PGError("Couldn't export the voices.")
        }
    }

    /// Adds the voices from an exported file. Voices with the same name are kept as they are.
    static func importAll(from src: URL) throws -> Int {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("voices-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        guard Tools.runQuick("/usr/bin/ditto", ["-x", "-k", src.path, tmp.path]) == 0 else { throw PGError("Couldn't open that file.") }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var added = 0
        let files = fm.enumerator(at: tmp, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for f in files where f.pathExtension.lowercased() == "wav" && !f.lastPathComponent.hasPrefix(".") {
            let dest = folder.appendingPathComponent(f.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: f, to: dest); added += 1 }
        }
        return added
    }
}

extension PareVoice {
    static func addVoice(src: URL, name: String, clean: Bool) async throws {
        try await start()
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/addvoice")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 1200   // removing music from a long file takes a while
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["src": src.path, "name": name, "clean": clean])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw PGError((json?["error"] as? String) ?? "Couldn't add that voice.")
        }
    }
}

// MARK: - Recording a voice with the microphone

@MainActor
final class VoiceRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var seconds = 0.0
    @Published var level: Float = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("pare-voice-recording.m4a")

    static let script = """
    Hi, I'm recording my voice for Pare. Today I'll show you how quick it is to shrink a large PDF. \
    Just choose your file, pick a quality level, and click compress. It takes about five seconds, \
    and nothing ever leaves your computer. Easy, right?
    """

    func start() async -> String? {
        let ok = await AVCaptureDevice.requestAccess(for: .audio)
        guard ok else { return "Pare Studio needs the microphone. Turn it on in System Settings › Privacy & Security › Microphone." }
        try? FileManager.default.removeItem(at: file)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                       AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue]
        do {
            let r = try AVAudioRecorder(url: file, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else { return "Couldn't start recording." }
            recorder = r
        } catch { return error.localizedDescription }
        recording = true
        seconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard let r = self.recorder else { return }
                r.updateMeters()
                self.seconds = r.currentTime
                self.level = max(0, min(1, (r.averagePower(forChannel: 0) + 50) / 50))
            }
        }
        return nil
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        recording = false
        level = 0
    }
}
