// Brands — the intro and outro used in tutorial videos.
// • "Pare PDF" is built in (warm paper background, Pare PDF™ wordmark, peach and green accents).
// • Add your own: either a designed style (name, colours, optional logo, tagline, website),
//   or your own intro and/or outro video clips.
// • "None" makes videos start and end on the steps.
// Saved in ~/Library/Application Support/Pare Guide/Brands (brands.json plus logos and clips).

import AppKit
import SwiftUI

struct Brand: Codable, Identifiable, Equatable, Hashable {
    var id = UUID().uuidString
    var name: String
    /// Shown big on the intro (the guide title goes underneath).
    var wordmark: String
    var tagline = ""
    var website = ""
    var background = "#FAF7F4"
    var text = "#1E2326"
    var accent = "#B07058"
    var highlight = "#628034"
    /// File names inside the Brands folder.
    var logo: String?
    var introVideo: String?
    var outroVideo: String?
    var builtIn = false

    static let noneID = "none"

    /// Your own intro and outro: a slide (JPG/PNG) or a video (MP4/MOV) each.
    var introFile: String? { get { introVideo } set { introVideo = newValue } }
    var outroFile: String? { get { outroVideo } set { outroVideo = newValue } }
    static func isImage(_ name: String?) -> Bool {
        guard let ext = name?.split(separator: ".").last?.lowercased() else { return false }
        return ["jpg", "jpeg", "png", "heic", "tif", "tiff"].contains(ext)
    }
    static let pare = Brand(id: "pare", name: "Pare PDF", wordmark: "Pare PDF\u{2122}",
                            tagline: "Your files stay on your device.", website: "parepdf.app", builtIn: true)
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

@MainActor
final class BrandStore: ObservableObject {
    static let shared = BrandStore()
    @Published private(set) var custom: [Brand] = []

    let folder: URL
    private var file: URL { folder.appendingPathComponent("brands.json") }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("Pare Guide/Brands", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: file), let b = try? JSONDecoder().decode([Brand].self, from: d) { custom = b }
    }

    var all: [Brand] { [Brand.pare] + custom }

    func brand(_ id: String?) -> Brand? {
        let wanted = id ?? defaultID
        if wanted == Brand.noneID { return nil }
        return all.first { $0.id == wanted } ?? Brand.pare
    }

    var defaultID: String {
        get { UserDefaults.standard.string(forKey: "defaultBrand") ?? Brand.pare.id }
        set { UserDefaults.standard.set(newValue, forKey: "defaultBrand"); objectWillChange.send() }
    }

    func save(_ b: Brand) {
        if let i = custom.firstIndex(where: { $0.id == b.id }) { custom[i] = b } else { custom.append(b) }
        persist()
    }

    func delete(_ id: String) {
        guard let b = custom.first(where: { $0.id == id }) else { return }
        for f in [b.logo, b.introFile, b.outroFile].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(f))
        }
        custom.removeAll { $0.id == id }
        if defaultID == id { defaultID = Brand.pare.id }
        persist()
    }

    /// Copies a logo or clip into the Brands folder and returns its new file name.
    func importFile(_ url: URL, for brandID: String, kind: String) throws -> String {
        let name = "\(brandID)-\(kind).\(url.pathExtension.lowercased())"
        let dest = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)
        return name
    }

    func fileURL(_ name: String?) -> URL? {
        guard let name else { return nil }
        let u = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private func persist() {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(custom) { try? d.write(to: file, options: .atomic) }
    }
}
