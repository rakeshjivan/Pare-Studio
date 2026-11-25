import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Shared drop screen

struct StudioDrop: View {
    let title: String
    let detail: String
    let icon: String
    let colour: Color
    let types: [UTType]
    var multiple = false
    var problem: String? = nil
    let onFile: (URL) -> Void
    var onFiles: (([URL]) -> Void)? = nil
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 46)).foregroundStyle(colour)
                Text(title).font(.title2.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                Button("Choose…") { choose() }.controlSize(.large)
            }
            .padding(40)
            .frame(maxWidth: 680)
            .background(RoundedRectangle(cornerRadius: 18).fill(targeted ? colour.opacity(0.10) : Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                .foregroundStyle(targeted ? colour : Color.secondary.opacity(0.45)))
            .dropDestination(for: URL.self) { urls, _ in
                deliver(urls)
                return !urls.isEmpty
            } isTargeted: { targeted = $0 }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deliver(_ urls: [URL]) {
        if let onFiles { onFiles(urls) } else if let u = urls.first { onFile(u) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = multiple
        if panel.runModal() == .OK { deliver(panel.urls) }
    }
}
