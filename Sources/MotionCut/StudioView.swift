import AVKit
import AppKit
import SwiftUI

private enum StudioStyle {
    static let field = Color(red: 8/255, green: 11/255, blue: 13/255)
    static let surface = Color(red: 17/255, green: 25/255, blue: 27/255)
    static let raised = Color(red: 22/255, green: 33/255, blue: 36/255)
    static let line = Color(red: 53/255, green: 73/255, blue: 74/255)
    static let text = Color(red: 234/255, green: 243/255, blue: 238/255)
    static let secondary = Color(red: 170/255, green: 189/255, blue: 182/255)
    static let muted = Color(red: 130/255, green: 155/255, blue: 146/255)
    static let mint = Color(red: 85/255, green: 233/255, blue: 176/255)
    static let amber = Color(red: 1, green: 184/255, blue: 77/255)
    static let blue = Color(red: 106/255, green: 171/255, blue: 1)
    static let violet = Color(red: 193/255, green: 138/255, blue: 1)
}

private struct StudioButton: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(primary ? StudioStyle.field : StudioStyle.text)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(primary ? StudioStyle.mint : StudioStyle.raised)
            .overlay(Rectangle().stroke(primary ? StudioStyle.mint : StudioStyle.line))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct StudioPanel<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .background(StudioStyle.surface)
            .overlay(alignment: .topLeading) {
                StudioStyle.amber.frame(width: 30, height: 1).padding(.leading, 14)
            }
            .overlay(Rectangle().stroke(StudioStyle.line))
    }
}

private struct StudioHeading: View {
    let number: String
    let title: String
    var body: some View {
        HStack(spacing: 7) {
            Text(number).foregroundStyle(StudioStyle.amber)
            StudioStyle.amber.frame(width: 15, height: 1)
            Text(title).foregroundStyle(StudioStyle.secondary)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .tracking(1.2)
    }
}

private struct ProgramPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

private enum BrowserTab: String, CaseIterable { case media = "Media", audio = "Audio", luts = "LUTs" }

struct StudioView: View {
    @EnvironmentObject private var editor: StudioModel
    @State private var browser = BrowserTab.media
    @State private var search = ""
    @State private var audioCategory = "All"
    @State private var timelineZoom = 66.0
    @State private var titleDraft = ""
    @State private var startDraft = ""
    @State private var endDraft = ""
    @State private var sourceDraft = ""
    @State private var speedDraft = ""
    @State private var nameDraft = ""
    @State private var bladeMode = false
    @State private var draggingClipID: UUID?
    @State private var dragOffset = CGSize.zero
    @State private var cutDrag: (Double, Double)?
    @FocusState private var timelineFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 12) {
                browserPanel.frame(width: 250)
                programPanel.frame(maxWidth: .infinity)
                inspectorPanel.frame(width: 265)
            }
            .frame(maxHeight: .infinity)
            .padding(12)
            timelinePanel.frame(height: 310).padding(.horizontal, 12)
            statusBar
        }
        .background(StudioStyle.field)
        .foregroundStyle(StudioStyle.text)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1120, minHeight: 760)
        .alert("MotionCut", isPresented: Binding(
            get: { editor.errorMessage != nil },
            set: { if !$0 { editor.errorMessage = nil } }
        )) {
            Button("OK") { editor.errorMessage = nil }
        } message: { Text(editor.errorMessage ?? "") }
        .onChange(of: editor.selectedClipID) { _, _ in syncInspector() }
        .onChange(of: editor.project) { _, _ in syncInspector() }
        .onChange(of: editor.project.name) { _, value in nameDraft = value }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in await editor.importMedia([url]) } }
                }
            }
            return !providers.isEmpty
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("◢").font(.system(size: 29, weight: .thin)).foregroundStyle(StudioStyle.mint)
            VStack(alignment: .leading, spacing: 2) {
                Text("MOTIONCUT").font(.system(size: 15, weight: .heavy, design: .monospaced)).tracking(1.4)
                Text("NATIVE VIDEO STUDIO").font(.system(size: 9, design: .monospaced))
                    .tracking(1).foregroundStyle(StudioStyle.muted)
            }
            StudioStyle.line.frame(width: 1, height: 26).padding(.horizontal, 5)
            TextField("Project name", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: 260)
                .onSubmit { editor.project.name = nameDraft }
                .onAppear { nameDraft = editor.project.name }
            Spacer()
            Button("New") { editor.newProject() }.buttonStyle(StudioButton())
            Button("Open") { editor.openProjectPanel() }.buttonStyle(StudioButton())
            Button("Save") { editor.project.name = nameDraft; editor.saveProject() }.buttonStyle(StudioButton())
            Button { editor.importMediaPanel() } label: { Label("Import", systemImage: "plus") }
                .buttonStyle(StudioButton())
            Button { editor.exportPanel() } label: {
                Label(editor.isExporting ? "Exporting…" : "Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(StudioButton(primary: true))
            .disabled(!editor.canExport)
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .background(Color(red: 11/255, green: 17/255, blue: 19/255))
        .overlay(alignment: .bottom) { StudioStyle.line.frame(height: 1) }
    }

    private var browserPanel: some View {
        StudioPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack { StudioHeading(number: "01", title: "LIBRARY"); Spacer() }
                    .padding(.horizontal, 14).frame(height: 42)
                HStack(spacing: 0) {
                    ForEach(BrowserTab.allCases, id: \.self) { tab in
                        Button(tab.rawValue) { browser = tab; search = "" }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: browser == tab ? .bold : .regular))
                            .foregroundStyle(browser == tab ? StudioStyle.mint : StudioStyle.secondary)
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .background(browser == tab ? StudioStyle.raised : StudioStyle.surface)
                            .overlay(alignment: .bottom) {
                                if browser == tab { StudioStyle.mint.frame(height: 2) }
                            }
                    }
                }
                Divider().overlay(StudioStyle.line)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(StudioStyle.muted)
                    TextField("Search \(browser.rawValue.lowercased())", text: $search)
                        .textFieldStyle(.plain).font(.system(size: 11))
                }
                .padding(9).background(StudioStyle.field).padding(10)
                if browser == .audio {
                    Picker("Category", selection: $audioCategory) {
                        ForEach(["All", "Music", "Ambience", "Effects"], id: \.self) { Text($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small).padding(.horizontal, 10)
                }
                ScrollView { browserContents.padding(.horizontal, 10).padding(.bottom, 12) }
                Spacer(minLength: 0)
                Divider().overlay(StudioStyle.line)
                HStack {
                    if browser == .media {
                        Button("Import media") { editor.importMediaPanel() }
                            .buttonStyle(StudioButton(primary: true))
                    } else if browser == .audio {
                        Button("Import your audio") { editor.importAudioPanel() }
                            .buttonStyle(StudioButton())
                    } else {
                        Button("Import .cube") { editor.importLUTPanel() }
                            .buttonStyle(StudioButton(primary: true))
                    }
                    Spacer()
                }.padding(10)
            }
        }
    }

    @ViewBuilder private var browserContents: some View {
        if browser == .media {
            LazyVStack(spacing: 6) {
                ForEach(editor.project.media.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { media in
                    HStack(spacing: 9) {
                        Image(systemName: media.kind == .audio ? "waveform" : media.kind == .image ? "photo" : "film")
                            .foregroundStyle(media.kind == .audio ? StudioStyle.violet : StudioStyle.blue)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(media.name).lineLimit(1).font(.system(size: 11, weight: .medium))
                            Text("\(media.kind.rawValue.uppercased()) · \(editor.timecode(media.duration))")
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(StudioStyle.muted)
                        }
                        Spacer(minLength: 0)
                        Button { editor.addMediaToTimeline(media.id) } label: { Image(systemName: "plus.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(StudioStyle.mint)
                            .help("Add at playhead")
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(StudioStyle.raised)
                    .overlay(Rectangle().stroke(StudioStyle.line))
                    .onTapGesture { editor.selectedMediaID = media.id }
                    .onDrag { NSItemProvider(object: media.id.uuidString as NSString) }
                }
                if editor.project.media.isEmpty { emptyMessage("Drop files here or import media") }
            }
        } else if browser == .audio {
            LazyVStack(spacing: 6) {
                let ownSounds = editor.project.media.filter { media in
                    media.kind == .audio &&
                    (search.isEmpty || media.name.localizedCaseInsensitiveContains(search))
                }
                if !ownSounds.isEmpty {
                    Text("YOUR AUDIO").font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(StudioStyle.amber)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    ForEach(ownSounds) { media in
                        HStack(spacing: 7) {
                            Image(systemName: "waveform").foregroundStyle(StudioStyle.violet)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(media.name).lineLimit(1).font(.system(size: 11, weight: .medium))
                                Text(editor.timecode(media.duration))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(StudioStyle.muted)
                            }
                            Spacer(minLength: 0)
                            Button { editor.previewImportedAudio(media) } label: {
                                Image(systemName: "play.circle")
                            }.buttonStyle(.plain).help("Preview sound")
                            Button { editor.addMediaToTimeline(media.id) } label: {
                                Image(systemName: "plus.circle.fill")
                            }.buttonStyle(.plain).foregroundStyle(StudioStyle.mint)
                                .help("Add at playhead")
                        }
                        .padding(8).background(StudioStyle.raised)
                        .overlay(Rectangle().stroke(StudioStyle.line))
                        .onDrag { NSItemProvider(object: media.id.uuidString as NSString) }
                    }
                }
                Text("STARTER SOUNDS").font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(StudioStyle.amber)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                ForEach(LibrarySound.all.filter {
                    (audioCategory == "All" || $0.category == audioCategory) &&
                    (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
                }) { sound in
                    HStack(spacing: 7) {
                        Image(systemName: sound.category == "Effects" ? "speaker.wave.2" : "waveform")
                            .foregroundStyle(StudioStyle.violet).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sound.title).font(.system(size: 11, weight: .medium))
                            Text("\(sound.category) · \(editor.timecode(sound.duration))")
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(StudioStyle.muted)
                        }
                        Spacer(minLength: 0)
                        Button { editor.previewLibrarySound(sound) } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.plain).help("Preview sound")
                        Button { editor.addLibrarySound(sound) } label: { Image(systemName: "plus.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(StudioStyle.mint).help("Add at playhead")
                    }
                    .padding(8).background(StudioStyle.raised)
                    .overlay(Rectangle().stroke(StudioStyle.line))
                }
            }
        } else {
            LazyVStack(spacing: 6) {
                ForEach(editor.project.luts.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { lut in
                    HStack {
                        Image(systemName: "circle.lefthalf.filled").foregroundStyle(StudioStyle.amber)
                        Text(lut.name).lineLimit(1).font(.system(size: 11))
                        Spacer(minLength: 0)
                        Button { editor.updateSelectedClip { $0.lutID = lut.id } } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(StudioStyle.mint)
                        .disabled(editor.selectedClip == nil)
                        .help("Apply to selected clip")
                    }.padding(8).background(StudioStyle.raised)
                        .overlay(Rectangle().stroke(StudioStyle.line))
                }
                if editor.project.luts.isEmpty { emptyMessage("Import a 3D or 1D .cube LUT") }
            }
        }
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(StudioStyle.muted)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(20)
    }

    private var programPanel: some View {
        StudioPanel {
            VStack(spacing: 0) {
                HStack {
                    StudioHeading(number: "02", title: "PROGRAM MONITOR")
                    Spacer()
                    if editor.isBuilding { ProgressView().controlSize(.small); Text("BUILDING") }
                    else if !editor.analyzingMedia.isEmpty { Text("ANALYZING \(editor.analyzingMedia.count) CLIP") }
                    else { Text("\(editor.project.canvasWidth) × \(editor.project.canvasHeight)") }
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(StudioStyle.muted)
                .padding(.horizontal, 14).frame(height: 42)
                Divider().overlay(StudioStyle.line)
                ZStack {
                    StudioStyle.field
                    if editor.duration > 0 {
                        ProgramPlayer(player: editor.player).aspectRatio(contentMode: .fit)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "film.stack").font(.system(size: 44, weight: .ultraLight))
                                .foregroundStyle(StudioStyle.mint)
                            Text("READY TO CREATE").font(.system(size: 15, weight: .bold, design: .monospaced))
                            Text("Import a video, then edit on the timeline below.")
                                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                            Button("Import media") { editor.importMediaPanel() }
                                .buttonStyle(StudioButton(primary: true))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) {
                    Text("PROGRAM / \(editor.timecode(editor.currentTime))")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(StudioStyle.mint)
                        .padding(7).background(StudioStyle.field.opacity(0.85)).padding(10)
                }
                Divider().overlay(StudioStyle.line)
                HStack(spacing: 12) {
                    Button { editor.togglePlayback() } label: {
                        Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 18)
                    }
                    .buttonStyle(StudioButton()).disabled(editor.duration <= 0)
                    Text("\(editor.timecode(editor.currentTime)) / \(editor.timecode(editor.duration))")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioStyle.secondary)
                    Slider(value: Binding(get: { editor.currentTime }, set: { editor.seek(to: $0) }),
                           in: 0...max(0.1, editor.duration)).tint(StudioStyle.mint)
                    Text("\(Int(editor.project.frameRate)) FPS")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(StudioStyle.muted)
                }.padding(10)
            }
        }
    }

    private var inspectorPanel: some View {
        StudioPanel {
            VStack(alignment: .leading, spacing: 0) {
                StudioHeading(number: "03", title: "INSPECTOR").padding(.horizontal, 14).frame(height: 42)
                Divider().overlay(StudioStyle.line)
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        if let clip = editor.selectedClip {
                            Text(clip.title ?? editor.project.media(for: clip)?.name ?? "Clip")
                                .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            if clip.isTitle {
                                inspectorField("TEXT", value: $titleDraft) {
                                    editor.updateSelectedClip { $0.title = titleDraft }
                                }
                            }
                            inspectorField("START", value: $startDraft) {
                                if let value = Double(startDraft), let track = editor.selectedTrack {
                                    editor.moveClip(clip.id, to: value, on: track.id)
                                }
                            }
                            inspectorField("IN / SOURCE", value: $sourceDraft) {
                                if let value = Double(sourceDraft) {
                                    editor.trimSelected(leading: clip.start +
                                        (value - clip.sourceStart) / clip.speed)
                                }
                            }
                            inspectorField("END", value: $endDraft) {
                                if let value = Double(endDraft) { editor.trimSelected(trailing: value) }
                            }
                            Text("DURATION  \(editor.timecode(clip.duration))")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(StudioStyle.secondary)
                            if !clip.isTitle {
                                inspectorField("SPEED ×", value: $speedDraft) {
                                    if let value = Double(speedDraft) { editor.setSelectedSpeed(value) }
                                }
                            }
                            if let currentTrack = editor.selectedTrack {
                                Picker("Track", selection: Binding(get: { currentTrack.id }, set: { id in
                                    editor.moveClip(clip.id, to: clip.start, on: id)
                                })) {
                                    ForEach(editor.project.tracks.filter { $0.kind == currentTrack.kind }) { track in
                                        Text(track.name).tag(track.id)
                                    }
                                }.controlSize(.small)
                            }
                            if editor.selectedTrack?.kind == .video && !clip.isTitle {
                                HStack {
                                    Text("OPACITY")
                                    Text("\(Int(clip.opacity * 100))%")
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }.font(.system(size: 9, design: .monospaced)).foregroundStyle(StudioStyle.muted)
                                Slider(value: Binding(get: { clip.opacity }, set: { value in
                                    editor.updateSelectedClip { $0.opacity = value }
                                }), in: 0...1).tint(StudioStyle.mint)
                            }
                            if editor.selectedTrack?.kind == .video {
                                inspectorSlider("SCALE", value: clip.scale, range: 0.5...3,
                                                tint: StudioStyle.mint) { value in
                                    editor.updateSelectedClip { $0.scale = value }
                                }
                                inspectorSlider("X POSITION", value: clip.positionX, range: -1...1,
                                                tint: StudioStyle.mint) { value in
                                    editor.updateSelectedClip { $0.positionX = value }
                                }
                                inspectorSlider("Y POSITION", value: clip.positionY, range: -1...1,
                                                tint: StudioStyle.mint) { value in
                                    editor.updateSelectedClip { $0.positionY = value }
                                }
                            }
                            if editor.selectedTrack?.kind == .audio || editor.project.media(for: clip)?.kind == .video {
                                HStack {
                                    Text("VOLUME")
                                    Text("\(Int(clip.volume * 100))%")
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }.font(.system(size: 9, design: .monospaced)).foregroundStyle(StudioStyle.muted)
                                Slider(value: Binding(get: { clip.volume }, set: { value in
                                    editor.updateSelectedClip { $0.volume = value }
                                }), in: 0...2).tint(StudioStyle.violet)
                            }
                            if editor.selectedTrack?.kind == .video && !clip.isTitle {
                                Divider().overlay(StudioStyle.line)
                                Text("COLOR").font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(StudioStyle.amber)
                                inspectorSlider("BRIGHTNESS", value: clip.brightness,
                                                range: -0.5...0.5, tint: StudioStyle.amber) { value in
                                    editor.updateSelectedClip { $0.brightness = value }
                                }
                                inspectorSlider("CONTRAST", value: clip.contrast,
                                                range: 0.5...2, tint: StudioStyle.amber) { value in
                                    editor.updateSelectedClip { $0.contrast = value }
                                }
                                inspectorSlider("SATURATION", value: clip.saturation,
                                                range: 0...2, tint: StudioStyle.amber) { value in
                                    editor.updateSelectedClip { $0.saturation = value }
                                }
                                Picker("LUT", selection: Binding<UUID?>(get: { clip.lutID }, set: { id in
                                    editor.updateSelectedClip { $0.lutID = id }
                                })) {
                                    Text("None").tag(nil as UUID?)
                                    ForEach(editor.project.luts) { lut in
                                        Text(lut.name).tag(Optional(lut.id))
                                    }
                                }.controlSize(.small)
                                Button("Import .cube LUT") { editor.importLUTPanel() }
                                    .buttonStyle(StudioButton())
                            }
                            Divider().overlay(StudioStyle.line)
                            Text("FADES").font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(StudioStyle.amber)
                            inspectorSlider("FADE IN", value: clip.fadeIn,
                                            range: 0...max(0.1, clip.duration / 2),
                                            tint: StudioStyle.violet) { value in
                                editor.updateSelectedClip { $0.fadeIn = value }
                            }
                            inspectorSlider("FADE OUT", value: clip.fadeOut,
                                            range: 0...max(0.1, clip.duration / 2),
                                            tint: StudioStyle.violet) { value in
                                editor.updateSelectedClip { $0.fadeOut = value }
                            }
                            if editor.selectedTrack?.kind == .video &&
                                editor.project.media(for: clip)?.kind == .video {
                                Divider().overlay(StudioStyle.line)
                                Toggle("Recorded audio", isOn: Binding(
                                    get: { clip.sourceAudioEnabled }, set: { value in
                                        editor.updateSelectedClip { $0.sourceAudioEnabled = value }
                                    }
                                )).toggleStyle(.switch).controlSize(.small)
                                Button("Detach audio to A1") { editor.detachSelectedAudio() }
                                    .buttonStyle(StudioButton())
                                    .disabled(!clip.sourceAudioEnabled)
                                Divider().overlay(StudioStyle.line)
                                Text("STABILIZATION").font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(StudioStyle.amber)
                                Toggle("Stabilize clip", isOn: Binding(get: { clip.stabilized }, set: { value in
                                    editor.updateSelectedClip { $0.stabilized = value }
                                })).toggleStyle(.switch).controlSize(.small)
                                Picker("Mode", selection: Binding(get: { editor.stabilizationMode }, set: {
                                    editor.setMode($0)
                                })) {
                                    Text("Balanced").tag(StabilizationMode.balanced)
                                    Text("Crop + steady").tag(StabilizationMode.cropAndSteady)
                                }.controlSize(.small)
                                Text("SMOOTHNESS  \(Int(editor.smoothness * 100))%")
                                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(StudioStyle.muted)
                                Slider(value: $editor.smoothness, in: 0.05...1,
                                       onEditingChanged: { if !$0 { editor.recalculatePlans() } })
                                    .tint(StudioStyle.mint)
                                Text("MAX ZOOM  \(String(format: "%.2f", editor.maxZoom))×")
                                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(StudioStyle.muted)
                                Slider(value: $editor.maxZoom, in: 1...2,
                                       onEditingChanged: { if !$0 { editor.recalculatePlans() } })
                                    .tint(StudioStyle.mint)
                            }
                        } else {
                            Text("Select a clip to edit its timing, color, sound, and stabilization.")
                                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                        }
                        Divider().overlay(StudioStyle.line)
                        Text("CANVAS").font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(StudioStyle.amber)
                        HStack(spacing: 5) {
                            canvasButton("16:9", 1920, 1080)
                            canvasButton("9:16", 1080, 1920)
                            canvasButton("1:1", 1080, 1080)
                        }
                        Picker("Frame rate", selection: Binding(get: { editor.project.frameRate },
                                                                 set: { editor.setFrameRate($0) })) {
                            Text("24 fps").tag(24.0)
                            Text("30 fps").tag(30.0)
                            Text("60 fps").tag(60.0)
                        }.controlSize(.small)
                        Text("Changes apply to the whole project.")
                            .font(.system(size: 9)).foregroundStyle(StudioStyle.muted)
                    }.padding(14)
                }
            }
        }
    }

    private func inspectorField(_ label: String, value: Binding<String>, action: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(StudioStyle.muted)
            Spacer()
            TextField("0.0", text: value, onCommit: action)
                .textFieldStyle(.roundedBorder).frame(width: 80)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    private func canvasButton(_ label: String, _ width: Int, _ height: Int) -> some View {
        Button(label) { editor.setCanvas(width: width, height: height) }
            .buttonStyle(StudioButton())
    }

    private func inspectorSlider(_ label: String, value: Double, range: ClosedRange<Double>,
                                 tint: Color, change: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.2f", value))
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(StudioStyle.muted)
            Slider(value: Binding(get: { value }, set: change), in: range).tint(tint)
        }
    }

    private var timelinePanel: some View {
        StudioPanel {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    StudioHeading(number: "04", title: "TIMELINE")
                    Spacer()
                    Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(StudioButton()).disabled(!editor.canUndo).help("Undo ⌘Z")
                    Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .buttonStyle(StudioButton()).disabled(!editor.canRedo).help("Redo ⇧⌘Z")
                    Button { bladeMode = false; timelineFocused = true } label: {
                        Label("Select", systemImage: "cursorarrow")
                    }.buttonStyle(StudioButton(primary: !bladeMode)).help("Select tool V")
                    Button { bladeMode = true; timelineFocused = true } label: {
                        Label("Blade", systemImage: "scissors")
                    }.buttonStyle(StudioButton(primary: bladeMode))
                        .help("Click to split all tracks; drag to cut a time range · B")
                    Button { editor.splitAtPlayhead() } label: { Label("Split", systemImage: "scissors") }
                        .buttonStyle(StudioButton()).help("Split at playhead ⌘B")
                    Button("Cut before") { editor.trimAtPlayhead(removeBefore: true) }
                        .buttonStyle(StudioButton()).help("Trim selected clips before playhead · Q")
                    Button("Cut after") { editor.trimAtPlayhead(removeBefore: false) }
                        .buttonStyle(StudioButton()).help("Trim selected clips after playhead · W")
                    Button("Delete") { editor.deleteSelected(ripple: false) }
                        .buttonStyle(StudioButton()).disabled(editor.selectedClipIDs.isEmpty)
                    Button("Ripple delete") { editor.deleteSelected(ripple: true) }
                        .buttonStyle(StudioButton()).disabled(editor.selectedClipIDs.isEmpty)
                    Button { editor.addTitle() } label: { Label("Text", systemImage: "textformat") }
                        .buttonStyle(StudioButton())
                    Button("+V") { editor.addTrack(.video) }.buttonStyle(StudioButton()).help("Add video track")
                    Button("+A") { editor.addTrack(.audio) }.buttonStyle(StudioButton()).help("Add audio track")
                    Slider(value: $timelineZoom, in: 28...160).frame(width: 80).tint(StudioStyle.mint)
                }.padding(.horizontal, 12).frame(height: 48)
                Divider().overlay(StudioStyle.line)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        Text("TRACKS").font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(StudioStyle.muted).frame(height: 30)
                        ForEach(editor.project.tracks) { track in trackHeader(track) }
                    }.frame(width: 122)
                    Divider().overlay(StudioStyle.line)
                    ScrollView(.horizontal) {
                        let timelineWidth = max(1000, CGFloat(editor.duration + 5) * timelineZoom)
                        VStack(spacing: 0) {
                            ruler(width: timelineWidth)
                            ForEach(editor.project.tracks) { track in
                                trackLane(track, width: timelineWidth)
                            }
                        }
                        .frame(width: timelineWidth)
                    }
                    .background(StudioStyle.field)
                }
                Spacer(minLength: 0)
            }
        }
        .focusable()
        .focused($timelineFocused)
        .onKeyPress { press in handleTimelineKey(press) }
    }

    private func trackHeader(_ track: TimelineTrack) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(track.kind == .video ? StudioStyle.blue : StudioStyle.violet)
                .frame(width: 3, height: 24)
            Button(track.name) { editor.selectedTrackID = track.id }
                .buttonStyle(.plain)
                .foregroundStyle(editor.selectedTrackID == track.id ? StudioStyle.mint : StudioStyle.text)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            Spacer(minLength: 0)
            Button { editor.toggleTrackMute(track.id) } label: {
                Text(track.isMuted ? "M" : "M").foregroundStyle(track.isMuted ? StudioStyle.amber : StudioStyle.muted)
            }.buttonStyle(.plain).help("Mute track audio")
            Button { editor.toggleTrackLock(track.id) } label: {
                Image(systemName: track.isLocked ? "lock.fill" : "lock.open")
                    .foregroundStyle(track.isLocked ? StudioStyle.amber : StudioStyle.muted)
            }.buttonStyle(.plain).help("Lock track")
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 7).frame(height: 45)
        .background(StudioStyle.surface)
        .overlay(alignment: .bottom) { StudioStyle.line.frame(height: 1) }
    }

    private func ruler(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            StudioStyle.raised
            let count = Int(width / timelineZoom)
            let labelEvery = rulerLabelInterval
            ForEach(0...max(0, count), id: \.self) { second in
                let labeled = second % labelEvery == 0
                StudioStyle.line.frame(width: 1, height: labeled ? 10 : 5)
                    .offset(x: CGFloat(second) * timelineZoom, y: labeled ? 19 : 24)
                if labeled {
                    Text(editor.timecode(Double(second)))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(StudioStyle.muted)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: CGFloat(second) * timelineZoom + 4, y: 3)
                }
            }
            StudioStyle.mint.frame(width: 2, height: 30)
                .offset(x: editor.currentTime * timelineZoom)
        }
        .frame(width: width, height: 30)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            editor.seek(to: value.location.x / timelineZoom)
        })
    }

    private var rulerLabelInterval: Int {
        let steps = [1, 2, 3, 5, 10, 15, 30, 60, 120, 300, 600]
        return steps.first { Double($0) * timelineZoom >= 76 } ?? steps[steps.count - 1]
    }

    private func trackLane(_ track: TimelineTrack, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            (track.kind == .video ? StudioStyle.surface : StudioStyle.field)
            ForEach(0...max(0, Int(width / timelineZoom)), id: \.self) { second in
                StudioStyle.line.opacity(0.35).frame(width: 1)
                    .offset(x: CGFloat(second) * timelineZoom)
            }
            ForEach(track.clips) { clip in clipView(clip, track: track) }
            if let cutDrag {
                StudioStyle.amber.opacity(0.25)
                    .frame(width: max(2, abs(cutDrag.1 - cutDrag.0) * timelineZoom))
                    .offset(x: min(cutDrag.0, cutDrag.1) * timelineZoom)
                    .allowsHitTesting(false)
            }
            StudioStyle.mint.opacity(0.9).frame(width: 2)
                .offset(x: editor.currentTime * timelineZoom)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: 45)
        .overlay(alignment: .bottom) { StudioStyle.line.frame(height: 1) }
        .onTapGesture { focusTimeline(); editor.selectedTrackID = track.id }
        .onDrop(of: [.plainText], isTargeted: nil) { providers, location in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let text = value as? String, let id = UUID(uuidString: text) else { return }
                Task { @MainActor in
                    editor.addMediaToTimeline(id, on: track.id,
                        at: Double(location.x / timelineZoom))
                }
            }
            return true
        }
    }

    private func clipView(_ clip: TimelineClip, track: TimelineTrack) -> some View {
        let color = clip.isTitle ? StudioStyle.amber : track.kind == .audio ? StudioStyle.violet : StudioStyle.blue
        let selected = editor.selectedClipIDs.contains(clip.id)
        return HStack(spacing: 5) {
            Image(systemName: clip.isTitle ? "textformat" : track.kind == .audio ? "waveform" : "film")
                .font(.system(size: 10))
            Text(clip.title ?? editor.project.media(for: clip)?.name ?? "Clip")
                .lineLimit(1).font(.system(size: 10, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(width: max(12, clip.duration * timelineZoom - 2), height: 33)
        .background(color.opacity(selected ? 0.65 : 0.3))
        .overlay(Rectangle().stroke(selected ? StudioStyle.mint : color, lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            Rectangle().fill(StudioStyle.mint.opacity(selected ? 0.9 : 0.45))
                .frame(width: 5, height: 33)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3).onEnded { value in
                    editor.selectOnly(clip.id)
                    editor.trimSelected(leading: clip.start + value.translation.width / timelineZoom)
                })
                .allowsHitTesting(!bladeMode)
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(StudioStyle.mint.opacity(selected ? 0.9 : 0.45))
                .frame(width: 5, height: 33)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3).onEnded { value in
                    editor.selectOnly(clip.id)
                    editor.trimSelected(trailing: clip.end + value.translation.width / timelineZoom)
                })
                .allowsHitTesting(!bladeMode)
        }
        .simultaneousGesture(SpatialTapGesture().onEnded { value in
            focusTimeline()
            if bladeMode {
                let time = clip.start + value.location.x / timelineZoom
                editor.bladeCut(from: time, to: time)
            } else {
                let modifiers = NSEvent.modifierFlags
                editor.selectClip(clip.id, additive: modifiers.contains(.command),
                                  range: modifiers.contains(.shift))
            }
        })
        .gesture(DragGesture(minimumDistance: 5).onChanged { value in
            if bladeMode {
                if cutDrag == nil { focusTimeline() }
                cutDrag = (clip.start + value.startLocation.x / timelineZoom,
                           clip.start + value.location.x / timelineZoom)
            } else {
                if draggingClipID == nil {
                    focusTimeline()
                    if !editor.selectedClipIDs.contains(clip.id) { editor.selectOnly(clip.id) }
                    draggingClipID = clip.id
                }
                dragOffset = value.translation
            }
        }.onEnded { value in
            if bladeMode {
                editor.bladeCut(from: clip.start + value.startLocation.x / timelineZoom,
                                to: clip.start + value.location.x / timelineZoom)
                cutDrag = nil
            } else {
                if draggingClipID == nil { editor.selectOnly(clip.id) }
                let vertical = Int((value.translation.height / 45).rounded())
                if abs(value.translation.width) > 2 || vertical != 0 {
                    editor.moveSelectedClips(by: value.translation.width / timelineZoom,
                                             trackOffset: vertical)
                }
                draggingClipID = nil
                dragOffset = .zero
            }
        })
        .offset(x: clip.start * timelineZoom +
            (draggingClipID != nil && selected ? dragOffset.width : 0),
                y: draggingClipID != nil && selected ? dragOffset.height : 0)
        .zIndex(draggingClipID != nil && selected ? 10 : 0)
    }

    private var statusBar: some View {
        HStack {
            Circle().fill(editor.isBuilding || editor.isExporting ? StudioStyle.amber : StudioStyle.mint)
                .frame(width: 6, height: 6)
            Text(editor.status).lineLimit(1)
            Spacer()
            Text("LOCAL • NO ACCOUNT • NO PAYWALL")
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(StudioStyle.muted)
        .padding(.horizontal, 16)
        .frame(height: 26)
    }

    private func handleTimelineKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) {
            if press.key == "a" { editor.selectAllClips(); return .handled }
            return .ignored
        }
        if press.key == .delete || press.key == .deleteForward ||
            press.key.character == "\u{7f}" {
            editor.deleteSelected(ripple: press.modifiers.contains(.shift))
            return .handled
        }
        switch press.key {
        case "v": bladeMode = false
        case "b": bladeMode = true
        case "q": editor.trimAtPlayhead(removeBefore: true)
        case "w": editor.trimAtPlayhead(removeBefore: false)
        case .escape:
            bladeMode = false
            editor.selectOnly(nil)
        case .space: editor.togglePlayback()
        case .leftArrow:
            editor.seek(to: editor.currentTime - (press.modifiers.contains(.shift) ? 1 :
                1 / editor.project.frameRate))
        case .rightArrow:
            editor.seek(to: editor.currentTime + (press.modifiers.contains(.shift) ? 1 :
                1 / editor.project.frameRate))
        default: return .ignored
        }
        return .handled
    }

    private func focusTimeline() {
        timelineFocused = false
        DispatchQueue.main.async { timelineFocused = true }
    }

    private func syncInspector() {
        guard let clip = editor.selectedClip else { return }
        titleDraft = clip.title ?? ""
        startDraft = String(format: "%.3f", clip.start)
        endDraft = String(format: "%.3f", clip.end)
        sourceDraft = String(format: "%.3f", clip.sourceStart)
        speedDraft = String(format: "%.2f", clip.speed)
    }
}
