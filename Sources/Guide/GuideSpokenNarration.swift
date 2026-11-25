// SpokenNarration — "Talk while you record".
// The microphone records while you work. When you stop, your words are transcribed on this Mac
// (Apple's speech recognition) and each sentence goes to the step you were doing when you said it.
// Your narration is then read in the chosen voice (for example your cloned Pare Voice).

import AVFoundation
import Speech

@MainActor
final class SpokenNarration {
    static let shared = SpokenNarration()
    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var file: URL?

    /// Asks for the microphone and speech recognition. Returns a message if either is refused.
    static func requestAccess() async -> String? {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            return "Talking while you record needs the microphone. Turn it on in System Settings › Privacy & Security › Microphone."
        }
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else {
            return "Talking while you record needs Speech Recognition. Turn it on in System Settings › Privacy & Security › Speech Recognition."
        }
        return nil
    }

    func start() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pare-guide-talk-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                                       AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        guard let r = try? AVAudioRecorder(url: url, settings: settings), r.record() else { return }
        recorder = r
        file = url
        startedAt = Date()
    }

    var isRecording: Bool { recorder != nil }

    /// Stops the microphone; returns the recording and when it started.
    func stop() -> (URL, Date)? {
        recorder?.stop()
        defer { recorder = nil; file = nil; startedAt = nil }
        guard let f = file, let s = startedAt else { return nil }
        return (f, s)
    }

    func discard() {
        if let r = stop() { try? FileManager.default.removeItem(at: r.0) }
    }

    // MARK: Turning speech into step narration

    /// Words with the time (seconds from the start of the recording) each was said.
    static func transcribe(_ url: URL) async throws -> [(word: String, at: TimeInterval)] {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-AU")) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else { throw PGError("Speech recognition isn't available on this Mac right now.") }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }   // stays on this Mac
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { c in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true
                    c.resume(returning: result.bestTranscription.segments.map { ($0.substring, $0.timestamp) })
                } else if let error {
                    done = true
                    let ns = error as NSError
                    // "No speech detected" just means nothing was said.
                    if ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110 { c.resume(returning: []) }
                    else { c.resume(throwing: error) }
                }
            }
        }
    }

    /// Gives each step the words said before its click (and just after it), up to the previous step.
    static func assign(_ words: [(word: String, at: TimeInterval)], recordingStart: Date, steps: [Step]) -> [UUID: String] {
        guard !steps.isEmpty, !words.isEmpty else { return [:] }
        let lag = 1.2   // people often finish the sentence just after clicking
        let times = steps.map { $0.time.timeIntervalSince(recordingStart) + lag }
        var buckets = Array(repeating: [String](), count: steps.count)
        for w in words {
            let i = times.firstIndex { w.at <= $0 } ?? steps.count - 1
            buckets[i].append(w.word)
        }
        var out: [UUID: String] = [:]
        for (i, b) in buckets.enumerated() {
            let t = tidy(b.joined(separator: " "))
            if !t.isEmpty { out[steps[i].id] = t }
        }
        return out
    }

    /// Removes "um", "uh" and repeated words, and finishes the sentence neatly.
    static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"(?i)\b(um+|uh+|erm+|er|ah+|hmm+)\b[,.]?\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)\b(\w+)( \1\b)+"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
        guard let first = t.first else { return "" }
        t = first.uppercased() + t.dropFirst()
        if let last = t.last, !".!?".contains(last) { t += "." }
        return t
    }
}
