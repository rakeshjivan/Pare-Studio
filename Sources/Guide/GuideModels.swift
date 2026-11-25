// Models — guides, steps, and where they live on disk.
// Each guide is a folder in ~/Library/Application Support/Pare Guide/Guides/<id>/
// holding guide.json, the original screenshots (images/) and earlier versions (history/).

import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Security

enum StepKind: String, Codable {
    case click, rightClick, doubleClick, type, shortcut, note
}

struct Step: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: StepKind
    var text: String
    /// File name inside the guide's images folder (the untouched screenshot).
    var image: String?
    /// Pixels per point of the display the screenshot came from (2 on Retina).
    var scale: Double = 2
    /// Everything below is in screenshot pixels, top-left origin.
    var clickPoint: CGPoint?
    var highlight: CGRect?
    var showHighlight = true
    var blurs: [CGRect] = []
    var crop: CGRect?
    /// This step's own zoom; nil follows the guide's setting.
    var zoomOverride: Zoom? = nil
    var autoBlurDone = false
    // What was clicked, for step wording and AI.
    var appName = ""
    var windowTitle = ""
    var role = ""
    var label = ""
    var time = Date()
    /// What the narrator says for this step in tutorial videos (nil = read the step text).
    var narration: String?
    /// Arrows, boxes, circles, text labels and numbers drawn on the picture.
    var annotations: [Annotation]?

    /// The drawings, never nil (saved as nil when empty so older guides stay readable).
    var marks: [Annotation] {
        get { annotations ?? [] }
        set { annotations = newValue.isEmpty ? nil : newValue }
    }
}

/// Something drawn on a step's picture. Points are in screenshot pixels, top-left origin.
struct Annotation: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case arrow, box, circle, text, number }
    enum Colour: String, Codable, CaseIterable, Identifiable {
        case red, orange, yellow, green, blue, purple, black, white
        var id: String { rawValue }
        var rgb: (CGFloat, CGFloat, CGFloat) {
            switch self {
            case .red: return (0.93, 0.20, 0.20)
            case .orange: return (1.0, 0.45, 0.10)
            case .yellow: return (1.0, 0.82, 0.10)
            case .green: return (0.15, 0.68, 0.33)
            case .blue: return (0.10, 0.45, 0.95)
            case .purple: return (0.55, 0.30, 0.90)
            case .black: return (0.10, 0.10, 0.12)
            case .white: return (1, 1, 1)
            }
        }
        var cg: CGColor { let c = rgb; return CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1) }
        /// Text on a filled label: dark on light colours, white otherwise.
        var onColourIsDark: Bool { self == .yellow || self == .white }
    }
    var id = UUID()
    var kind: Kind
    /// Arrow: from a (tail) to b (point). Box and circle: corners a and b. Text and number: a is the top-left / centre.
    var a: CGPoint
    var b: CGPoint
    var text: String = ""
    var colour: Colour = .red
    /// 0.7 small, 1 medium, 1.5 large.
    var size: Double = 1
}

enum Zoom: String, Codable, CaseIterable, Identifiable {
    case off = "Whole screen"
    case some = "Zoom in a little"
    case close = "Zoom in close"
    var id: String { rawValue }
    /// Width of the zoomed view as a share of the screenshot width.
    var fraction: CGFloat? {
        switch self { case .off: return nil; case .some: return 0.6; case .close: return 0.38 }
    }
}

struct Guide: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var summary = ""
    var created = Date()
    var modified = Date()
    var zoom: Zoom = .some
    var steps: [Step] = []
    /// Spoken over the intro and outro of tutorial videos.
    var introNarration: String?
    var outroNarration: String?
    /// Which intro/outro style tutorial videos use (nil = the default from Settings).
    var brandID: String?
}

struct GuideVersion: Identifiable {
    let url: URL
    let date: Date
    var id: URL { url }
}

@MainActor
final class GuideStore: ObservableObject {
    static let shared = GuideStore()

    @Published private(set) var guides: [Guide] = []

    let root: URL
    private var lastSnapshot: [UUID: Date] = [:]
    private let imageCache = NSCache<NSString, CGImageBox>()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Pare Guide/Guides", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func imagesFolder(_ id: UUID) -> URL { folder(id).appendingPathComponent("images", isDirectory: true) }
    func historyFolder(_ id: UUID) -> URL { folder(id).appendingPathComponent("history", isDirectory: true) }

    func load() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var out: [Guide] = []
        for d in dirs {
            let file = d.appendingPathComponent("guide.json")
            if let data = try? Data(contentsOf: file), let g = try? Self.decoder.decode(Guide.self, from: data) {
                out.append(g)
            }
        }
        guides = out.sorted { $0.modified > $1.modified }
    }

    func guide(_ id: UUID) -> Guide? { guides.first { $0.id == id } }

    /// Creates the guide's folder and returns it.
    func create(_ guide: Guide) {
        try? FileManager.default.createDirectory(at: imagesFolder(guide.id), withIntermediateDirectories: true)
        guides.insert(guide, at: 0)
        write(guide)
    }

    /// A copy of a guide with its own folder and screenshots (used for translations).
    @discardableResult
    func duplicate(_ source: Guide, as copy: Guide) -> UUID {
        var g = copy
        g.id = UUID()
        g.created = Date()
        g.modified = Date()
        let fm = FileManager.default
        try? fm.createDirectory(at: folder(g.id), withIntermediateDirectories: true)
        if fm.fileExists(atPath: imagesFolder(source.id).path) {
            try? fm.copyItem(at: imagesFolder(source.id), to: imagesFolder(g.id))
        }
        create(g)
        return g.id
    }

    /// Saves changes. Keeps an earlier version at most every 30 seconds so you can roll back.
    func update(_ guide: Guide, forceSnapshot: Bool = false) {
        guard let i = guides.firstIndex(where: { $0.id == guide.id }) else { return }
        let old = guides[i]
        guard old != guide || forceSnapshot else { return }
        let now = Date()
        if forceSnapshot || now.timeIntervalSince(lastSnapshot[guide.id] ?? .distantPast) > 30 {
            snapshot(old)
            lastSnapshot[guide.id] = now
        }
        var g = guide
        g.modified = now
        guides[i] = g
        write(g)
    }

    func delete(_ id: UUID) {
        pendingWrites[id]?.cancel()
        pendingWrites[id] = nil
        guides.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: folder(id))
    }

    /// Saving waits until typing pauses, then writes in the background, so editing never stutters.
    private var pendingWrites: [UUID: Task<Void, Never>] = [:]

    private func write(_ g: Guide) {
        pendingWrites[g.id]?.cancel()
        pendingWrites[g.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingWrites[g.id] = nil
            self.writeNow(g, background: true)
        }
    }

    private func writeNow(_ g: Guide, background: Bool) {
        guard let data = try? Self.encoder.encode(g) else { return }
        let url = folder(g.id).appendingPathComponent("guide.json")
        if background {
            Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Saves anything still waiting (called when the app quits).
    func flush() {
        for (id, t) in pendingWrites {
            t.cancel()
            if let g = guide(id) { writeNow(g, background: false) }
        }
        pendingWrites = [:]
    }

    private func snapshot(_ g: Guide) {
        let dir = historyFolder(g.id)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970)).json"
        if let data = try? Self.encoder.encode(g) { try? data.write(to: dir.appendingPathComponent(name)) }
        // Keep the 40 newest.
        let files = versions(g.id)
        for v in files.dropFirst(40) { try? fm.removeItem(at: v.url) }
    }

    func versions(_ id: UUID) -> [GuideVersion] {
        let files = (try? FileManager.default.contentsOfDirectory(at: historyFolder(id), includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            guard let t = Double(url.deletingPathExtension().lastPathComponent) else { return nil }
            return GuideVersion(url: url, date: Date(timeIntervalSince1970: t))
        }.sorted { $0.date > $1.date }
    }

    func restore(_ version: GuideVersion, into id: UUID) {
        guard let data = try? Data(contentsOf: version.url),
              var g = try? Self.decoder.decode(Guide.self, from: data) else { return }
        g.id = id
        update(g, forceSnapshot: true)
    }

    // MARK: Images

    func imageURL(_ guideID: UUID, _ name: String) -> URL { imagesFolder(guideID).appendingPathComponent(name) }

    func baseImage(_ guideID: UUID, _ step: Step) -> CGImage? {
        guard let name = step.image else { return nil }
        let key = "\(guideID.uuidString)/\(name)" as NSString
        if let hit = imageCache.object(forKey: key) { return hit.image }
        let url = imageURL(guideID, name)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        imageCache.setObject(CGImageBox(img), forKey: key)
        return img
    }

    /// Off the main thread: same as baseImage but without the cache.
    nonisolated static func loadImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Saves a screenshot (HEIC, falling back to PNG). Runs in the background.
    nonisolated static func saveScreenshot(_ image: CGImage, to folder: URL, name: String) -> String? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let heic = folder.appendingPathComponent(name + ".heic")
        if let dest = CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            if CGImageDestinationFinalize(dest) { return heic.lastPathComponent }
        }
        let png = folder.appendingPathComponent(name + ".png")
        guard let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? png.lastPathComponent : nil
    }

    // MARK: Import a shared .pareguide file

    func importBundle(_ url: URL) throws -> UUID {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        guard Tools.runQuick("/usr/bin/ditto", ["-x", "-k", url.path, tmp.path]) == 0 else { throw PGError("Couldn't open that file.") }
        // The guide.json may sit at the top or one folder down.
        var dir = tmp
        if !fm.fileExists(atPath: tmp.appendingPathComponent("guide.json").path),
           let sub = try fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .first(where: { fm.fileExists(atPath: $0.appendingPathComponent("guide.json").path) }) {
            dir = sub
        }
        let data = try Data(contentsOf: dir.appendingPathComponent("guide.json"))
        var g = try Self.decoder.decode(Guide.self, from: data)
        g.id = UUID()
        g.modified = Date()
        try fm.createDirectory(at: folder(g.id), withIntermediateDirectories: true)
        let images = dir.appendingPathComponent("images")
        if fm.fileExists(atPath: images.path) {
            try fm.copyItem(at: images, to: imagesFolder(g.id))
        } else {
            try fm.createDirectory(at: imagesFolder(g.id), withIntermediateDirectories: true)
        }
        guides.insert(g, at: 0)
        write(g)
        return g.id
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

final class CGImageBox {
    let image: CGImage
    init(_ i: CGImage) { image = i }
}

struct PGError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - Keychain (API keys)

enum Keychain {
    private static let service = "au.jivan.pareguide"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Small helpers

enum Tools {
    @discardableResult
    static func runQuick(_ path: String, _ args: [String], cwd: URL? = nil) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func download(_ url: String, to dest: URL) async throws {
        guard let u = URL(string: url) else { throw PGError("Bad address") }
        let (tmp, resp) = try await URLSession.shared.download(from: u)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw PGError("Download failed") }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Removes **bold** markers.
    var plain: String { replacingOccurrences(of: "**", with: "") }
    /// Splits "Click **Save** now" into plain and bold pieces. An unclosed ** stays plain.
    var boldParts: [(text: String, bold: Bool)] {
        let parts = components(separatedBy: "**")
        return parts.enumerated().map { i, p in
            (p, i % 2 == 1 && (parts.count % 2 == 1 || i < parts.count - 1))
        }
    }
}
