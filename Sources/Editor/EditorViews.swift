// The multi-track editor's window: media bin, preview, inspector and timeline.

import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct ProjectEditorView: View {
    @ObservedObject private var m = EditorModel.shared
    @State private var dropping = false

    private var empty: Bool { m.project.media.isEmpty && m.project.tracks.allSatisfy { $0.clips.isEmpty } }

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar()
            Divider()
            if let p = m.problem { Banner(text: p, colour: .orange) { m.problem = nil } }
            if empty {
                EditorEmptyState(dropping: dropping)
            } else {
                HSplitView {
                    MediaBin().frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                    PreviewPane().frame(minWidth: 360)
                    ClipInspector().frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
                }
                .frame(minHeight: 260)
                Divider()
                MultiTimeline().frame(minHeight: 200, idealHeight: 280)
            }
        }
        .background(ProjectEditorKeys())
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for p in providers {
                    if let u = await Self.url(from: p) { urls.append(u) }
                }
                await m.add(urls)
            }
            return true
        }
        .onChange(of: m.time) { _, _ in m.timeChanged() }
    }

    static func url(from p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = p.loadObject(ofClass: URL.self) { u, _ in cont.resume(returning: u) }
        }
    }
}

// MARK: - Toolbar

struct EditorToolbar: View {
    @ObservedObject private var m = EditorModel.shared

    var body: some View {
        HStack(spacing: 10) {
            Button { m.newProject() } label: { Label("New", systemImage: "doc.badge.plus") }
                .help("Start a new, empty project")
            Button { m.openProject() } label: { Label("Open…", systemImage: "folder") }
                .help("Open a Pare Studio project or a Camtasia project")
            Button { m.saveAs() } label: { Label("Save As…", systemImage: "square.and.arrow.down") }
                .help("Projects save themselves as you go. Use this to pick a name and place.")
            Divider().frame(height: 18)
            Button { m.importMedia() } label: { Label("Add Media", systemImage: "plus.rectangle.on.folder") }
                .help("Add videos, sound or pictures to the media bin")
            Button { m.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!m.canUndo).help("Undo (⌘Z)").keyboardShortcut("z", modifiers: .command)
            Button { m.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!m.canRedo).help("Redo (⇧⌘Z)").keyboardShortcut("z", modifiers: [.command, .shift])
            Picker("", selection: Binding(get: { m.project.canvas }, set: { m.project.canvas = $0; m.projectChanged() })) {
                ForEach(ProjectCanvas.presets + (ProjectCanvas.presets.contains(m.project.canvas) ? [] : [m.project.canvas]), id: \.self) { c in
                    Text(c.label).tag(c)
                }
            }
            .frame(width: 190)
            .help("The shape and size of the finished video")
            Spacer()
            if let f = m.progress {
                ProgressView(value: f).frame(width: 140)
                Text("\(Int(f * 100))%").monospacedDigit().foregroundStyle(.secondary)
            } else if let s = m.status {
                Text(s).foregroundStyle(.secondary).lineLimit(1)
            }
            Button { m.exportVideo() } label: { Label("Export Video", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
                .disabled(m.busy || m.duration <= 0)
                .keyboardShortcut("e", modifiers: .command)
                .help("Save the finished video as an MP4 (⌘E)")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

struct Banner: View {
    let text: String
    let colour: Color
    let close: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(colour)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(colour.opacity(0.12))
    }
}

// MARK: - Empty state

struct EditorEmptyState: View {
    @ObservedObject private var m = EditorModel.shared
    let dropping: Bool

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 10)
            VStack(spacing: 12) {
                Image(systemName: "film.stack").font(.system(size: 52)).foregroundStyle(.tint)
                Text("Drop videos, sound or pictures here").font(.title2.weight(.semibold))
                Text("Or drop a Camtasia project (.cmproj or .tscproj) to open it.").foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button { m.importMedia() } label: { Label("Add Media…", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button { m.openProject() } label: { Label("Open a Project…", systemImage: "folder") }
                        .controlSize(.large)
                }
            }
            .padding(40)
            .frame(maxWidth: 620)
            .background(RoundedRectangle(cornerRadius: 18).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(dropping ? Color.accentColor : Color.secondary.opacity(0.4)))

            let recent = m.recentProjects
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent projects").font(.headline)
                    ForEach(recent, id: \.self) { u in
                        Button { m.open(u) } label: {
                            Label(u.deletingPathExtension().lastPathComponent, systemImage: "film")
                        }
                        .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
            }
            Spacer(minLength: 10)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Media bin

struct MediaBin: View {
    @ObservedObject private var m = EditorModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Media").font(.headline)
                Spacer()
                Button { m.importMedia() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("Add media")
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 10) {
                    ForEach(m.project.media) { item in
                        MediaTile(item: item)
                    }
                }
                .padding(10)
            }
            Text("Drag onto the timeline, or double-click to add at the end.")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
    }
}

struct MediaTile: View {
    @ObservedObject private var m = EditorModel.shared
    let item: MediaItem

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.8))
                if let t = m.thumbs[item.id] {
                    Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: item.kind == .audio ? "waveform" : item.kind == .image ? "photo" : "film")
                        .font(.title2).foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(item.kind == .image ? "Picture" : TimingBar.fmt(item.duration)).font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { m.place(item) }
        .draggable(item.id.uuidString)
        .contextMenu {
            Button("Add to the timeline") { m.place(item) }
            Button("Add at the playhead") { m.place(item, at: m.time) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Remove from project", role: .destructive) { m.removeMedia(item.id) }
        }
        .help(item.url.lastPathComponent)
    }
}

// MARK: - Preview

struct PreviewPane: View {
    @ObservedObject private var m = EditorModel.shared

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                VideoSurface(player: m.player)
                    .aspectRatio(CGFloat(m.project.canvas.width) / CGFloat(m.project.canvas.height), contentMode: .fit)
                    .padding(10)
                    .shadow(radius: 4)
                if m.duration <= 0 {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down").font(.title)
                        Text("Drag something from Media onto the timeline below,\nor double-click it, to see it here.")
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding()
                }
            }
            Divider()
            HStack(spacing: 14) {
                Button { m.time = 0 } label: { Image(systemName: "backward.end.fill") }.help("Go to the start")
                Button { m.step(seconds: -5) } label: { Image(systemName: "gobackward.5") }.help("Back 5 seconds (J)")
                Button { m.step(frames: -1) } label: { Image(systemName: "chevron.left") }.help("Back one frame (←)")
                Button { m.togglePlay() } label: {
                    Image(systemName: m.playing ? "pause.fill" : "play.fill").font(.title2).frame(width: 30)
                }
                .help("Play or pause (Space)")
                Button { m.step(frames: 1) } label: { Image(systemName: "chevron.right") }.help("Forward one frame (→)")
                Button { m.step(seconds: 5) } label: { Image(systemName: "goforward.5") }.help("Forward 5 seconds")
                Text("\(Self.clock(m.time)) / \(Self.clock(m.duration))").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button { m.splitAtPlayhead() } label: { Label("Split", systemImage: "scissors") }.help("Cut the clip at the playhead in two (S)")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    static func clock(_ s: Double) -> String {
        guard s.isFinite else { return "0:00.0" }
        let t = max(0, s)
        return String(format: "%d:%02d.%d", Int(t) / 60, Int(t) % 60, Int((t * 10).truncatingRemainder(dividingBy: 10)))
    }
}

// MARK: - Inspector

struct ClipInspector: View {
    @ObservedObject private var m = EditorModel.shared
    @FocusState private var naming: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let c = m.selected, let item = m.project.item(c.mediaID) {
                    clipPanel(c, item)
                } else {
                    projectPanel
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: naming) { _, v in m.typing = v }
    }

    private func bind(_ get: @escaping (Clip) -> Double, _ set: @escaping (inout Clip, Double) -> Void) -> Binding<Double> {
        Binding(get: { m.selected.map(get) ?? 0 }, set: { v in m.updateSelected { set(&$0, v) } })
    }

    @ViewBuilder
    private func clipPanel(_ c: Clip, _ item: MediaItem) -> some View {
        let onSoundTrack = m.location(of: c.id).map { m.project.tracks[$0.track].isAudio } ?? false
        Text(item.name).font(.headline).lineLimit(2)
        Text("Starts \(PreviewPane.clock(c.start)) · lasts \(PreviewPane.clock(c.duration))")
            .font(.callout).foregroundStyle(.secondary)

        GroupBox("Transition in") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Type", selection: Binding(get: { m.selected?.transition ?? .none },
                                                  set: { v in m.updateSelected { $0.transition = v } })) {
                    ForEach(TransitionKind.allCases) { Text($0.rawValue).tag($0) }
                }
                if c.transition != .none {
                    slider("Length", bind({ $0.transitionDuration }, { $0.transitionDuration = $1 }), 0.2...3, unit: "s")
                    Text("Plays from the clip before it on this track (or from black if there isn't one).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }

        if c.videoOnly == true && !onSoundTrack {
            GroupBox("Sound") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This video's sound is its own clip on a sound track. Click it there to change its volume.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            }
        } else if item.hasAudio || item.kind == .audio {
            GroupBox("Sound") {
                VStack(alignment: .leading, spacing: 8) {
                    slider("Volume", bind({ $0.volume }, { $0.volume = $1 }), 0...2, percent: true)
                    Toggle("Mute this clip", isOn: Binding(get: { m.selected?.muted ?? false }, set: { v in m.updateSelected { $0.muted = v } }))
                }
                .padding(4)
            }
        }

        if c.linkID != nil {
            Button { m.unlinkSelected() } label: { Label("Unlink picture and sound", systemImage: "link.badge.plus") }
                .help("Linked clips move, trim and split together. Unlink to move them separately.")
        } else if !onSoundTrack, c.videoOnly != true, item.hasAudio {
            Button { m.separateSound(c.id) } label: { Label("Separate the sound", systemImage: "waveform.badge.plus") }
        }

        if item.kind != .audio && !onSoundTrack {
            GroupBox("Picture") {
                VStack(alignment: .leading, spacing: 8) {
                    slider("Opacity", bind({ $0.opacity }, { $0.opacity = $1 }), 0...1, percent: true)
                    slider("Size", bind({ $0.scale }, { $0.scale = $1 }), 0.1...3, percent: true)
                    slider("Left / right", bind({ $0.offsetX }, { $0.offsetX = $1 }), -1...1, percent: true)
                    slider("Up / down", bind({ $0.offsetY }, { $0.offsetY = $1 }), -1...1, percent: true)
                    HStack {
                        Button("Fill the frame") { m.updateSelected { $0.scale = 1; $0.offsetX = 0; $0.offsetY = 0 } }
                        Button("Corner bubble") { m.updateSelected { $0.scale = 0.3; $0.offsetX = 0.33; $0.offsetY = 0.32 } }
                            .help("Small, bottom right: handy for a webcam over a screen recording")
                    }
                }
                .padding(4)
            }
        }

        HStack {
            Button { m.splitAtPlayhead() } label: { Label("Split", systemImage: "scissors") }
            Button(role: .destructive) { m.deleteSelected() } label: { Label("Delete", systemImage: "trash") }
        }
        Button("Done") { m.selectedClip = nil }.buttonStyle(.link)
    }

    @ViewBuilder
    private var projectPanel: some View {
        Text("Project").font(.headline)
        TextField("Name", text: Binding(get: { m.project.name }, set: { m.project.name = $0; m.projectChanged() }))
            .textFieldStyle(.roundedBorder)
            .focused($naming)
        Text("\(m.project.canvas.label) · \(PreviewPane.clock(m.duration)) long").font(.callout).foregroundStyle(.secondary)

        GroupBox("Tracks") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(m.project.tracks) { t in
                    HStack {
                        Image(systemName: t.isAudio ? "waveform" : "film").foregroundStyle(.secondary)
                        Text(t.name).lineLimit(1)
                        Spacer()
                        Text("\(t.clips.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                HStack {
                    Button("+ Video track") { m.addTrack(audio: false) }
                    Button("+ Sound track") { m.addTrack(audio: true) }
                }
                .padding(.top, 4)
            }
            .padding(4)
        }

        GroupBox("How it works") {
            VStack(alignment: .leading, spacing: 6) {
                tip("Click a clip to change it. Drag to move it, drag its edges to trim.")
                tip("Higher tracks show on top of lower ones.")
                tip("S splits at the playhead. Delete removes the selected clip.")
                tip("Space plays. ← → move one frame.")
                tip("Your project saves itself as you work.")
            }
            .font(.callout)
            .padding(4)
        }
    }

    private func tip(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) { Text("•"); Text(s).fixedSize(horizontal: false, vertical: true) }
    }

    private func slider(_ name: String, _ b: Binding<Double>, _ r: ClosedRange<Double>, unit: String = "", percent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name)
                Spacer()
                Text(percent ? "\(Int((b.wrappedValue * 100).rounded()))%" : String(format: "%.1f%@", b.wrappedValue, unit))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: b, in: r)
        }
    }
}

// MARK: - Timeline

private let laneHeight: CGFloat = 58
private let rulerHeight: CGFloat = 26
private let headerWidth: CGFloat = 132

struct MultiTimeline: View {
    @ObservedObject private var m = EditorModel.shared

    private var length: Double { max(m.duration + 20, 60) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { m.addTrack(audio: false) } label: { Label("Video track", systemImage: "plus") }
                Button { m.addTrack(audio: true) } label: { Label("Sound track", systemImage: "plus") }
                Button { m.closeGaps() } label: { Label("Close gaps", systemImage: "arrow.left.to.line") }
                    .help("Slide clips left so there are no empty spaces")
                Toggle("Snap", isOn: $m.snapping).toggleStyle(.checkbox).help("Clips snap to each other and to the playhead")
                Spacer()
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $m.zoom, in: 4...400).frame(width: 160).help("Zoom the timeline")
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Button("Fit") { fitZoom() }.help("Show the whole project")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: rulerHeight)
                        ForEach(m.project.tracks) { t in TrackHeader(track: t) }
                    }
                    .frame(width: headerWidth)
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            ZStack(alignment: .topLeading) {
                                VStack(alignment: .leading, spacing: 0) {
                                    TimeRuler(length: length)
                                    ForEach(Array(m.project.tracks.enumerated()), id: \.element.id) { i, t in
                                        TrackLane(track: t, index: i, length: length)
                                    }
                                }
                                PlayheadLine()
                                    .offset(x: m.time * m.zoom - 1)
                                    .allowsHitTesting(false)
                                Color.clear.frame(width: 1, height: 1).id("playhead").offset(x: m.time * m.zoom)
                            }
                            .frame(width: length * m.zoom, alignment: .leading)
                        }
                        .onChange(of: m.playing) { _, p in if p { proxy.scrollTo("playhead", anchor: .center) } }
                    }
                }
            }
        }
        .onAppear { if m.duration > 0 { fitZoom() } }
    }

    private func fitZoom() {
        let width = (NSApp.keyWindow?.frame.width ?? 1200) - headerWidth - 60
        m.zoom = min(max(width / max(m.duration, 5), 4), 400)
    }
}

struct PlayheadLine: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 11)).foregroundStyle(.red).offset(x: 1)
            Rectangle().fill(Color.red).frame(width: 2)
        }
        .frame(width: 12)
        .offset(x: -5)
    }
}

struct TimeRuler: View {
    @ObservedObject private var m = EditorModel.shared
    let length: Double

    var body: some View {
        Canvas { ctx, size in
            let z = m.zoom
            let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
            let step = steps.first { $0 * z >= 70 } ?? 600
            var t = 0.0
            while t <= length {
                let x = t * z
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: size.height - 9)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(.secondary), lineWidth: 1)
                ctx.draw(Text(TimingBar.fmt(t)).font(.caption2).foregroundColor(.secondary), at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                let minor = step / 5
                for k in 1..<5 {
                    let mx = (t + Double(k) * minor) * z
                    ctx.stroke(Path { $0.move(to: CGPoint(x: mx, y: size.height - 4)); $0.addLine(to: CGPoint(x: mx, y: size.height)) },
                               with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                }
                t += step
            }
        }
        .frame(width: length * m.zoom, height: rulerHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            m.pause()
            m.time = min(max(0, g.location.x / m.zoom), m.duration)
        })
        .help("Click or drag to move the playhead")
    }
}

struct TrackHeader: View {
    @ObservedObject private var m = EditorModel.shared
    let track: Track

    private var index: Int? { m.project.tracks.firstIndex { $0.id == track.id } }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: track.isAudio ? "waveform" : "film").foregroundStyle(.secondary)
            Text(track.name).font(.callout).lineLimit(1)
            Spacer(minLength: 0)
            if !track.isAudio {
                Button { toggle { $0.hidden.toggle() } } label: { Image(systemName: track.hidden ? "eye.slash" : "eye") }
                    .help(track.hidden ? "Show this track" : "Hide this track")
            }
            Button { toggle { $0.muted.toggle() } } label: { Image(systemName: track.muted ? "speaker.slash" : "speaker.wave.2") }
                .help(track.muted ? "Turn this track's sound on" : "Mute this track")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(height: laneHeight)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .contextMenu {
            Button("Rename…") { rename() }
            Button("Remove track", role: .destructive) { m.removeTrack(track.id) }.disabled(m.project.tracks.count <= 1)
        }
    }

    private func toggle(_ f: (inout Track) -> Void) {
        guard let i = index else { return }
        f(&m.project.tracks[i])
        m.projectChanged()
    }

    private func rename() {
        let alert = NSAlert()
        alert.messageText = "Rename track"
        let field = NSTextField(string: track.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty { toggle { $0.name = field.stringValue } }
    }
}

struct TrackLane: View {
    @ObservedObject private var m = EditorModel.shared
    let track: Track
    let index: Int
    let length: Double
    @State private var targeted = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(index % 2 == 0 ? Color.primary.opacity(0.035) : Color.primary.opacity(0.06))
                .contentShape(Rectangle())
                .onTapGesture { m.selectedClip = nil }
            if targeted { Rectangle().fill(Color.accentColor.opacity(0.12)) }
            ForEach(track.clips) { c in
                ClipBlock(clip: c, track: track, trackIndex: index)
            }
        }
        .frame(width: length * m.zoom, height: laneHeight, alignment: .topLeading)
        .opacity(track.hidden ? 0.45 : 1)
        .overlay(alignment: .bottom) { Divider() }
        .dropDestination(for: String.self) { ids, loc in
            var ok = false
            for s in ids {
                if let id = UUID(uuidString: s), let item = m.project.item(id) {
                    m.place(item, onTrack: track.id, at: max(0, loc.x / m.zoom)); ok = true
                }
            }
            return ok
        } isTargeted: { targeted = $0 }
    }
}

struct ClipBlock: View {
    @ObservedObject private var m = EditorModel.shared
    let clip: Clip
    let track: Track
    let trackIndex: Int
    @State private var dragStart: Double?
    @State private var trimStart: (start: Double, end: Double)?

    private var item: MediaItem? { m.project.item(clip.mediaID) }
    private var selected: Bool { m.selectedClip == clip.id }
    private var partnerSelected: Bool {
        guard let link = clip.linkID, let s = m.selected, s.id != clip.id else { return false }
        return s.linkID == link
    }
    private var colour: Color {
        if track.isAudio { return Color(red: 0.18, green: 0.62, blue: 0.45) }
        switch item?.kind {
        case .audio: return Color(red: 0.18, green: 0.62, blue: 0.45)
        case .image: return Color(red: 0.80, green: 0.52, blue: 0.18)
        default: return Color(red: 0.25, green: 0.47, blue: 0.85)
        }
    }

    var body: some View {
        let w = max(6, clip.duration * m.zoom)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6).fill(colour.gradient)
            HStack(spacing: 6) {
                if track.isAudio, w > 40 {
                    Image(systemName: "waveform").foregroundStyle(.white.opacity(0.85))
                } else if let item, let t = m.thumbs[item.id], w > 70 {
                    Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: laneHeight - 14).clipped().cornerRadius(4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item?.name ?? "Missing").font(.caption.weight(.semibold)).lineLimit(1)
                    Text(PreviewPane.clock(clip.duration)).font(.caption2).opacity(0.8)
                }
                .foregroundStyle(.white)
                Spacer(minLength: 0)
                if clip.linkID != nil { Image(systemName: "link").font(.caption2).foregroundStyle(.white.opacity(0.8)) }
                if clip.muted { Image(systemName: "speaker.slash.fill").font(.caption).foregroundStyle(.white) }
            }
            .padding(.horizontal, 7)
            if clip.transition != .none {
                LinearGradient(colors: [.white.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: min(w, max(10, clip.transitionDuration * m.zoom)))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        Image(systemName: "rectangle.2.swap").font(.caption2).foregroundStyle(.black.opacity(0.7)).padding(3)
                    }
                    .allowsHitTesting(false)
                    .help("\(clip.transition.rawValue), \(String(format: "%.1f", clip.transitionDuration)) s")
            }
        }
        .frame(width: w, height: laneHeight - 8)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.white : partnerSelected ? Color.white.opacity(0.6) : Color.black.opacity(0.25),
                                                                lineWidth: selected ? 2.5 : partnerSelected ? 1.5 : 1))
        .overlay(alignment: .leading) { handle(leading: true) }
        .overlay(alignment: .trailing) { handle(leading: false) }
        .offset(x: clip.start * m.zoom, y: 4)
        .onTapGesture { m.selectedClip = clip.id }
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { g in
                if dragStart == nil { dragStart = clip.start; m.selectedClip = clip.id; m.pause() }
                let rows = Int((g.translation.height / laneHeight).rounded())
                m.move(clip.id, to: (dragStart ?? clip.start) + g.translation.width / m.zoom, track: trackIndex + rows)
            }
            .onEnded { _ in dragStart = nil })
        .contextMenu {
            Button("Split at the playhead") { m.selectedClip = clip.id; m.splitAtPlayhead() }
            Menu("Transition in") {
                ForEach(TransitionKind.allCases) { k in
                    Button(k.rawValue) { m.selectedClip = clip.id; m.updateSelected { $0.transition = k } }
                }
            }
            Button(clip.muted ? "Unmute" : "Mute") { m.selectedClip = clip.id; m.updateSelected { $0.muted.toggle() } }
            if clip.linkID != nil {
                Button("Unlink picture and sound") { m.selectedClip = clip.id; m.unlinkSelected() }
            } else if !track.isAudio, clip.videoOnly != true, item?.hasAudio == true {
                Button("Separate the sound onto a sound track") { m.separateSound(clip.id) }
            }
            Divider()
            Button("Delete", role: .destructive) { m.selectedClip = clip.id; m.deleteSelected() }
        }
    }

    private func handle(leading: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(selected ? 0.55 : 0.001))
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .highPriorityGesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    if trimStart == nil { trimStart = (clip.start, clip.end); m.selectedClip = clip.id; m.pause() }
                    guard let s = trimStart else { return }
                    let base = leading ? s.start : s.end
                    m.trim(clip.id, edge: leading, to: base + g.translation.width / m.zoom)
                }
                .onEnded { _ in trimStart = nil })
    }
}

// MARK: - Keys

struct ProjectEditorKeys: View {
    @ObservedObject private var m = EditorModel.shared
    var body: some View {
        ZStack {
            Button("") { m.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("") { m.step(seconds: -5) }.keyboardShortcut("j", modifiers: [])
            Button("") { m.pause() }.keyboardShortcut("k", modifiers: [])
            Button("") { m.play(rate: m.playing ? 2 : 1) }.keyboardShortcut("l", modifiers: [])
            Button("") { m.step(frames: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { m.step(frames: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { m.step(seconds: -1) }.keyboardShortcut(.leftArrow, modifiers: [.shift])
            Button("") { m.step(seconds: 1) }.keyboardShortcut(.rightArrow, modifiers: [.shift])
            Button("") { m.splitAtPlayhead() }.keyboardShortcut("s", modifiers: [])
            Button("") { m.deleteSelected() }.keyboardShortcut(.delete, modifiers: [])
            Button("") { m.selectedClip = nil }.keyboardShortcut(.escape, modifiers: [])
            Button("") { m.pause(); m.time = 0 }.keyboardShortcut(.home, modifiers: [])
            Button("") { m.pause(); m.time = m.duration }.keyboardShortcut(.end, modifiers: [])
            Button("") { m.zoom = min(400, m.zoom * 1.4) }.keyboardShortcut("=", modifiers: .command)
            Button("") { m.zoom = max(4, m.zoom / 1.4) }.keyboardShortcut("-", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .disabled(m.typing || m.busy)
        .allowsHitTesting(false)
    }
}
