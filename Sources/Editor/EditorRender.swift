// Turns an EditorProject into something AVFoundation can play and export:
// an AVComposition with every clip, a custom compositor that layers the tracks,
// fits each clip to the canvas and draws the transitions, and an audio mix.

import AVFoundation
import CoreImage
import AppKit

// MARK: - The render plan the compositor follows

struct PlanTransition {
    var kind: TransitionKind
    var start: Double
    var duration: Double
    var fromNothing = false
    func progress(_ t: Double) -> Double { duration <= 0 ? 1 : min(max((t - start) / duration, 0), 1) }
}

struct Placement {
    var trackID: CMPersistentTrackID?
    var image: CIImage?
    var start: Double
    var end: Double
    var transform: CGAffineTransform = .identity
    var opacity: Double = 1
    var scale: Double = 1
    var offsetX: Double = 0
    var offsetY: Double = 0
    var transIn: PlanTransition?
    var transOut: PlanTransition?
}

struct RenderPlan: @unchecked Sendable {
    var width: Double
    var height: Double
    var layers: [[Placement]] = []       // bottom layer first
}

final class PlanInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let plan: RenderPlan
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    init(plan: RenderPlan, timeRange: CMTimeRange, tracks: [CMPersistentTrackID]) {
        self.plan = plan
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = tracks.isEmpty ? nil : tracks.map { NSNumber(value: $0) }
    }
}

// MARK: - Drawing one frame

enum PlanRenderer {
    static func frame(_ plan: RenderPlan, at t: Double, source: (CMPersistentTrackID) -> CIImage?) -> CIImage {
        let canvas = CGRect(x: 0, y: 0, width: plan.width, height: plan.height)
        var out = CIImage(color: .black).cropped(to: canvas)
        for layer in plan.layers {
            for p in layer where t >= p.start - 0.0005 && t < p.end {
                var img: CIImage
                if let i = p.image { img = i }
                else if let id = p.trackID, let f = source(id) { img = orient(f, p.transform) }
                else { continue }
                img = fit(img, p, plan)
                guard let shown = transition(img, p, at: t, plan) else { continue }
                img = shown
                if p.opacity < 0.999 { img = alpha(img, p.opacity) }
                out = img.composited(over: out)
            }
        }
        return out.cropped(to: canvas)
    }

    /// Applies a movie's rotation (phones record sideways and say so in the file).
    static func orient(_ img: CIImage, _ tf: CGAffineTransform) -> CIImage {
        let angle = atan2(tf.b, tf.a)
        if abs(angle) < 0.01 { return img }
        if abs(angle - .pi / 2) < 0.01 { return img.oriented(.right) }
        if abs(angle + .pi / 2) < 0.01 { return img.oriented(.left) }
        return img.oriented(.down)
    }

    static func fit(_ img: CIImage, _ p: Placement, _ plan: RenderPlan) -> CIImage {
        let e = img.extent
        guard e.width > 0, e.height > 0, e.width.isFinite else { return img }
        var i = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let s = min(plan.width / e.width, plan.height / e.height) * p.scale
        i = i.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let w = e.width * s, h = e.height * s
        let x = (plan.width - w) / 2 + p.offsetX * plan.width
        let y = (plan.height - h) / 2 - p.offsetY * plan.height
        return i.transformed(by: CGAffineTransform(translationX: x, y: y))
    }

    static func alpha(_ img: CIImage, _ a: Double) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, a)))])
    }

    static func darken(_ img: CIImage, _ f: Double) -> CIImage {
        let v = CGFloat(min(max(f, 0), 1))
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: v, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: v, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: v, w: 0)])
    }

    /// Returns the clip as it should look at time t, or nil if it is hidden at that moment.
    static func transition(_ img: CIImage, _ p: Placement, at t: Double, _ plan: RenderPlan) -> CIImage? {
        var img = img
        let W = plan.width, H = plan.height
        if let tr = p.transIn, t < tr.start + tr.duration {
            let k = tr.progress(t)
            switch tr.kind {
            case .none: break
            case .crossfade: img = alpha(img, k)
            case .dip:
                if tr.fromNothing { img = darken(img, k) }
                else if k < 0.5 { return nil }
                else { img = darken(img, (k - 0.5) * 2) }
            case .wipe: img = img.cropped(to: CGRect(x: 0, y: 0, width: W * k, height: H))
            case .slide: img = img.transformed(by: CGAffineTransform(translationX: W * (1 - k), y: 0))
            }
        }
        if let tr = p.transOut, t >= tr.start {
            let k = tr.progress(t)
            switch tr.kind {
            case .none, .crossfade, .wipe: break
            case .dip:
                if k >= 0.5 { return nil }
                img = darken(img, 1 - k * 2)
            case .slide: img = img.transformed(by: CGAffineTransform(translationX: -W * k, y: 0))
            }
        }
        return img
    }
}

// MARK: - The compositor AVFoundation calls for every frame

final class PlanCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "pare.editor.compositor", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colour = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    private static let attrs: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()]

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.attrs }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.attrs }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [context, colour] in
            guard let ins = request.videoCompositionInstruction as? PlanInstruction,
                  let out = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "Pare Studio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No frame to draw into"]))
                return
            }
            let img = PlanRenderer.frame(ins.plan, at: request.compositionTime.seconds) { id in
                request.sourceFrame(byTrackID: id).map { CIImage(cvPixelBuffer: $0) }
            }
            let size = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(out), height: CVPixelBufferGetHeight(out))
            let scaled = size.width == ins.plan.width ? img
                : img.transformed(by: CGAffineTransform(scaleX: size.width / ins.plan.width, y: size.height / ins.plan.height))
            context.render(scaled, to: out, bounds: size, colorSpace: colour)
            request.finish(withComposedVideoFrame: out)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

// MARK: - Building the composition

struct BuiltComposition: @unchecked Sendable {
    let composition: AVMutableComposition
    let videoComposition: AVVideoComposition?
    let audioMix: AVAudioMix?
}

enum CompositionBuilder {
    /// Why the last build gave up, for the message the person sees.
    nonisolated(unsafe) static var lastProblem: String?

    static func ct(_ s: Double) -> CMTime { CMTime(seconds: max(0, s), preferredTimescale: 600) }

    /// One composition track being filled from left to right.
    final class Lane {
        let track: AVMutableCompositionTrack
        var cursor: Double = 0
        var volume: AVMutableAudioMixInputParameters?
        init(_ t: AVMutableCompositionTrack) { track = t }

        /// Puts part of a source track at a time. Returns false if it couldn't.
        @discardableResult
        func put(_ src: AVAssetTrack, from: Double, length: Double, at t: Double, stretchTo: Double? = nil) -> Bool {
            var from = from, length = length, t = t
            if t < cursor - 0.001 {
                let skip = cursor - t
                guard stretchTo == nil, skip < length - 0.02 else { return false }
                from += skip; length -= skip; t = cursor
            }
            guard length > 0.01 else { return false }
            if t > cursor + 0.001 { track.insertEmptyTimeRange(CMTimeRange(start: ct(cursor), duration: ct(t - cursor))) }
            do {
                try track.insertTimeRange(CMTimeRange(start: ct(from), duration: ct(length)), of: src, at: ct(t))
            } catch { return false }
            var placed = length
            if let s = stretchTo {
                track.scaleTimeRange(CMTimeRange(start: ct(t), duration: ct(length)), toDuration: ct(s))
                placed = s
            }
            cursor = t + placed
            return true
        }
    }

    struct Source {
        var video: AVAssetTrack?
        var audio: AVAssetTrack?
        var videoEnd: Double = 0
        var audioEnd: Double = 0
        var transform: CGAffineTransform = .identity
        var image: CIImage?
    }

    static func load(_ m: MediaItem) async -> Source {
        var s = Source()
        if m.kind == .image {
            s.image = CIImage(contentsOf: m.url, options: [.applyOrientationProperty: true])
            return s
        }
        let asset = AVURLAsset(url: m.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        if let v = try? await asset.loadTracks(withMediaType: .video).first {
            s.video = v
            s.transform = (try? await v.load(.preferredTransform)) ?? .identity
            if let r = try? await v.load(.timeRange) { s.videoEnd = r.end.seconds }
        }
        if let a = try? await asset.loadTracks(withMediaType: .audio).first {
            s.audio = a
            if let r = try? await a.load(.timeRange) { s.audioEnd = r.end.seconds }
        }
        return s
    }

    static func build(_ p: EditorProject, thumbs: Bool = false) async -> BuiltComposition? {
        let total = p.duration
        guard total > 0.05 else { return nil }
        let comp = AVMutableComposition()
        var plan = RenderPlan(width: Double(p.canvas.width), height: Double(p.canvas.height))
        var sources: [UUID: Source] = [:]
        for m in p.media where p.tracks.contains(where: { $0.clips.contains { $0.mediaID == m.id } }) {
            sources[m.id] = await load(m)
        }
        var audioLanes: [Lane] = []

        func newLane(_ type: AVMediaType) -> Lane? {
            comp.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid).map(Lane.init)
        }

        // Bottom track first (index 0 in the project is the top layer).
        for track in p.tracks.reversed() {
            let clips = track.clips.sorted { $0.start < $1.start }
            guard !clips.isEmpty else { continue }
            let showVideo = !track.isAudio && !track.hidden
            var vLanes: [Lane] = []
            if showVideo, clips.contains(where: { sources[$0.mediaID]?.video != nil }) {
                vLanes = [newLane(.video), newLane(.video)].compactMap { $0 }
            }
            var aLanes: [Lane] = []
            if clips.contains(where: { sources[$0.mediaID]?.audio != nil }) {
                aLanes = [newLane(.audio), newLane(.audio)].compactMap { $0 }
                for l in aLanes { l.volume = AVMutableAudioMixInputParameters(track: l.track); l.volume?.setVolume(0, at: .zero) }
                audioLanes += aLanes
            }
            var layer: [Placement] = []
            var placementFor: [UUID: Int] = [:]

            for (k, c) in clips.enumerated() {
                guard let src = sources[c.mediaID], let m = p.item(c.mediaID) else { continue }
                let lane = k % 2
                let vol = (c.muted || track.muted) ? 0 : Float(c.volume)

                // The transition into this clip, and whether the clip before it needs to run on underneath.
                var tin: PlanTransition?
                var tail: (prev: Clip, length: Double)?
                if c.transition != .none {
                    let d = min(max(0.1, c.transitionDuration), c.duration * 0.9)
                    let prev = k > 0 ? clips[k - 1] : nil
                    if let prev, prev.end > c.start - 0.1 {
                        tin = PlanTransition(kind: c.transition, start: c.start, duration: d)
                        let need = c.start + d - prev.end
                        if need > 0.01 { tail = (prev, need) }
                        if let i = placementFor[prev.id] {
                            layer[i].transOut = PlanTransition(kind: c.transition, start: c.start, duration: d)
                            layer[i].end = max(layer[i].end, c.start + d)
                        }
                    } else {
                        tin = PlanTransition(kind: c.transition, start: c.start, duration: d, fromNothing: true)
                    }
                }

                // Extend the previous clip under the transition: more of its media if there is some, else its last frame held.
                if let (prev, need) = tail, let ps = sources[prev.mediaID] {
                    let other = vLanes.indices.contains(1 - lane) ? vLanes[1 - lane] : nil
                    let out = prev.inPoint + prev.duration
                    if let v = ps.video, let other {
                        if ps.videoEnd - out >= need { other.put(v, from: out, length: need, at: prev.end) }
                        else { other.put(v, from: max(0, out - 1.0 / 30), length: 1.0 / 30, at: prev.end, stretchTo: need) }
                    }
                    if let a = ps.audio, aLanes.indices.contains(1 - lane), ps.audioEnd - out >= need {
                        let al = aLanes[1 - lane]
                        let pv = (prev.muted || track.muted) ? 0 : Float(prev.volume)
                        if al.put(a, from: out, length: need, at: prev.end) {
                            al.volume?.setVolumeRamp(fromStartVolume: pv, toEndVolume: 0,
                                                     timeRange: CMTimeRange(start: ct(prev.end), duration: ct(need)))
                            al.volume?.setVolume(0, at: ct(prev.end + need))
                        }
                    }
                }

                // The clip's picture.
                if showVideo {
                    var pl = Placement(start: c.start, end: c.end, opacity: c.opacity, scale: c.scale,
                                       offsetX: c.offsetX, offsetY: c.offsetY, transIn: tin)
                    if m.kind == .image, let img = src.image {
                        pl.image = img
                    } else if let v = src.video, vLanes.indices.contains(lane) {
                        let len = min(c.duration, src.videoEnd - c.inPoint)
                        if len > 0.01, vLanes[lane].put(v, from: c.inPoint, length: len, at: c.start) {
                            pl.trackID = vLanes[lane].track.trackID
                            pl.transform = src.transform
                            pl.end = c.start + len
                        } else { pl.trackID = nil }
                    }
                    if pl.image != nil || pl.trackID != nil {
                        placementFor[c.id] = layer.count
                        layer.append(pl)
                    }
                }

                // The clip's sound.
                if let a = src.audio, aLanes.indices.contains(lane) {
                    let al = aLanes[lane]
                    let len = min(c.duration, src.audioEnd - c.inPoint)
                    if len > 0.01, al.put(a, from: c.inPoint, length: len, at: c.start) {
                        if let tin, tin.duration > 0 {
                            al.volume?.setVolumeRamp(fromStartVolume: 0, toEndVolume: vol,
                                                     timeRange: CMTimeRange(start: ct(c.start), duration: ct(tin.duration)))
                            al.volume?.setVolume(vol, at: ct(c.start + tin.duration))
                        } else {
                            al.volume?.setVolume(vol, at: ct(c.start))
                        }
                        al.volume?.setVolume(0, at: ct(c.start + len))
                    }
                }
            }
            if !layer.isEmpty { plan.layers.append(layer) }
        }

        // A black picture under everything for the whole length, so there is always a frame.
        guard let blackURL = await blackClip(),
              let black = try? await AVURLAsset(url: blackURL).loadTracks(withMediaType: .video).first,
              let spacer = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            lastProblem = "couldn't make the black background clip"; return nil
        }
        do {
            try spacer.insertTimeRange(CMTimeRange(start: .zero, duration: ct(1)), of: black, at: .zero)
            spacer.scaleTimeRange(CMTimeRange(start: .zero, duration: ct(1)), toDuration: ct(total))
        } catch { lastProblem = "background clip: \(error.localizedDescription)"; return nil }

        // Drop tracks nothing went into.
        for t in comp.tracks where t.segments.isEmpty { comp.removeTrack(t) }
        let used = Set(comp.tracks.map(\.trackID))
        audioLanes.removeAll { !used.contains($0.track.trackID) }

        let videoIDs = comp.tracks(withMediaType: .video).map(\.trackID)
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = PlanCompositor.self
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.renderSize = CGSize(width: p.canvas.width, height: p.canvas.height)
        vc.instructions = [PlanInstruction(plan: plan, timeRange: CMTimeRange(start: .zero, duration: comp.duration), tracks: videoIDs)]

        let mix = AVMutableAudioMix()
        mix.inputParameters = audioLanes.compactMap(\.volume)
        return BuiltComposition(composition: comp, videoComposition: vc, audioMix: mix)
    }

    /// A one-second black movie, made once and kept.
    static func blackClip() async -> URL? {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pare Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("black-v1.mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let tmp = folder.appendingPathComponent("black-\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: tmp, fileType: .mov) else { return nil }
        let w = 160, h = 90
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) { memset(base, 0, CVPixelBufferGetDataSize(pb)) }
        CVPixelBufferUnlockBaseAddress(pb, [])
        for i in 0...30 {
            var waited = 0
            while !input.isReadyForMoreMediaData && waited < 2000 { usleep(1000); waited += 1 }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { try? FileManager.default.removeItem(at: tmp); return nil }
        try? FileManager.default.moveItem(at: tmp, to: url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Export

    struct ExportFailed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func export(_ p: EditorProject, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let built = await build(p) else { throw ExportFailed(message: "There's nothing to export yet.") }
        try? FileManager.default.removeItem(at: url)
        let big = p.canvas.width * p.canvas.height > 1920 * 1080
        let preset = big ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset) else {
            throw ExportFailed(message: "This Mac can't export with that setting.")
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        let box = SessionBox(session)
        let poll = Task {
            while !Task.isCancelled {
                progress(Double(box.session.progress))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { poll.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            box.session.exportAsynchronously {
                switch box.session.status {
                case .completed: cont.resume()
                case .cancelled: cont.resume(throwing: ExportFailed(message: "Export was stopped."))
                default: cont.resume(throwing: box.session.error ?? ExportFailed(message: "Export didn't finish."))
                }
            }
        }
        progress(1)
    }

    final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ s: AVAssetExportSession) { session = s }
    }
}
