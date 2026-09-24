import AVKit
import SwiftUI

private struct PlayerSurface: NSViewRepresentable {
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

private enum Instrument {
    static let field = Color(red: 8/255, green: 11/255, blue: 13/255)
    static let surface = Color(red: 17/255, green: 25/255, blue: 27/255)
    static let raised = Color(red: 22/255, green: 33/255, blue: 36/255)
    static let line = Color(red: 53/255, green: 73/255, blue: 74/255)
    static let grid = Color(red: 49/255, green: 67/255, blue: 70/255)
    static let text = Color(red: 234/255, green: 243/255, blue: 238/255)
    static let secondary = Color(red: 170/255, green: 189/255, blue: 182/255)
    static let muted = Color(red: 130/255, green: 155/255, blue: 146/255)
    static let mint = Color(red: 85/255, green: 233/255, blue: 176/255)
    static let amber = Color(red: 1, green: 184/255, blue: 77/255)
    static let red = Color(red: 1, green: 89/255, blue: 103/255)
    static let blue = Color(red: 106/255, green: 171/255, blue: 1)
    static let violet = Color(red: 193/255, green: 138/255, blue: 1)
}

private struct InstrumentPanel<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .background(Instrument.surface)
            .overlay(alignment: .topLeading) {
                Rectangle().fill(Instrument.amber).frame(width: 32, height: 1).padding(.leading, 18)
            }
            .overlay(Rectangle().stroke(Instrument.line, lineWidth: 1))
    }
}

private struct InstrumentButton: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(primary ? Instrument.field : Instrument.text)
            .padding(.horizontal, 15)
            .frame(minHeight: 36)
            .background(primary ? Instrument.mint : Instrument.raised)
            .overlay(Rectangle().stroke(primary ? Instrument.mint : Instrument.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct Kicker: View {
    let number: String
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Text(number).foregroundStyle(Instrument.amber)
            Rectangle().fill(Instrument.amber).frame(width: 19, height: 1)
            Text(title).foregroundStyle(Instrument.secondary)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .tracking(1.2)
    }
}

struct ContentView: View {
    @EnvironmentObject private var editor: EditorModel
    @State private var scrubTime = 0.0
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    previewPanel
                    timelinePanel
                }
                .frame(maxWidth: .infinity)
                inspector
                    .frame(width: 308)
            }
            .padding(18)
            statusBar
        }
        .background(Instrument.field)
        .foregroundStyle(Instrument.text)
        .preferredColorScheme(.dark)
        .alert("MotionCut", isPresented: Binding(
            get: { editor.errorMessage != nil },
            set: { if !$0 { editor.errorMessage = nil } }
        )) {
            Button("OK") { editor.errorMessage = nil }
        } message: {
            Text(editor.errorMessage ?? "")
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in editor.open(url) } }
            }
            return true
        }
    }

    private var topBar: some View {
        HStack(spacing: 15) {
            Text("◢")
                .font(.system(size: 29, weight: .thin))
                .foregroundStyle(Instrument.mint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("MOTIONCUT")
                    .font(.system(size: 15, weight: .heavy, design: .monospaced))
                    .tracking(1.7)
                Text("VIDEO EDITOR / STABILIZATION LAB")
                    .font(.system(size: 9, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(Instrument.muted)
            }
            Rectangle().fill(Instrument.line).frame(width: 1, height: 25).padding(.horizontal, 12)
            Text(editor.sourceURL?.lastPathComponent ?? "NO CLIP LOADED")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Instrument.secondary)
                .lineLimit(1)
            Spacer()
            Button { editor.openVideo() } label: {
                Label("Open video", systemImage: "plus")
            }
            .buttonStyle(InstrumentButton())
            Button { editor.exportVideo() } label: {
                Label(editor.isExporting ? "Exporting…" : "Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(InstrumentButton(primary: true))
            .disabled(editor.sourceURL == nil || editor.isAnalyzing || editor.isExporting)
        }
        .padding(.horizontal, 22)
        .frame(height: 70)
        .background(Color(red: 11/255, green: 17/255, blue: 19/255))
        .overlay(alignment: .bottom) { Instrument.line.frame(height: 1) }
    }

    private var previewPanel: some View {
        InstrumentPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Kicker(number: "01", title: "PROGRAM MONITOR")
                    Spacer()
                    if editor.isAnalyzing {
                        ProgressView().controlSize(.small).tint(Instrument.amber)
                        Text("ANALYZING").foregroundStyle(Instrument.amber)
                    } else if editor.analysis != nil {
                        Circle().fill(Instrument.mint).frame(width: 6, height: 6)
                        Text(editor.stabilizationEnabled ? "STABILIZED" : "ORIGINAL")
                            .foregroundStyle(Instrument.mint)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 18)
                .frame(height: 48)
                Rectangle().fill(Instrument.line).frame(height: 1)

                ZStack {
                    Instrument.field
                    if editor.sourceURL != nil {
                        PlayerSurface(player: editor.player)
                            .aspectRatio(contentMode: .fit)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "film.stack")
                                .font(.system(size: 43, weight: .ultraLight))
                                .foregroundStyle(Instrument.mint)
                            Text("READY FOR SOURCE")
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                                .tracking(2)
                            Text("Open a video or drop one here to analyze its camera motion.")
                                .font(.system(size: 12))
                                .foregroundStyle(Instrument.secondary)
                            Button("Open video…") { editor.openVideo() }
                                .buttonStyle(InstrumentButton(primary: true))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) {
                    if editor.sourceURL != nil {
                        Text("PREVIEW  /  \(editor.timecode(editor.currentTime))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Instrument.mint)
                            .padding(9)
                            .background(Instrument.field.opacity(0.85))
                            .padding(12)
                    }
                }

                Rectangle().fill(Instrument.line).frame(height: 1)
                HStack(spacing: 16) {
                    Button {
                        editor.togglePlayback()
                    } label: {
                        Label(editor.isPlaying ? "Pause" : "Play",
                              systemImage: editor.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(InstrumentButton())
                    .disabled(editor.sourceURL == nil)
                    Text("\(editor.timecode(editor.currentTime))  /  \(editor.timecode(editor.duration))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Instrument.secondary)
                    Spacer()
                    Text("SOURCE + AUDIO PRESERVED")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Instrument.muted)
                }
                .padding(12)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var timelinePanel: some View {
        InstrumentPanel {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Kicker(number: "02", title: "TIMELINE")
                    Spacer()
                    Text("IN \(editor.timecode(editor.trimStart))   OUT \(editor.timecode(editor.trimEnd))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Instrument.secondary)
                }
                if editor.duration > 0 {
                    Slider(value: Binding(
                        get: { isScrubbing ? scrubTime : editor.currentTime },
                        set: { scrubTime = $0; editor.seek(to: $0) }
                    ), in: 0...max(editor.duration, 0.1), onEditingChanged: { isScrubbing = $0 })
                    .tint(Instrument.mint)
                    HStack {
                        Text("00:00.0")
                        Spacer()
                        Text(editor.timecode(editor.duration))
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Instrument.muted)
                } else {
                    Rectangle().fill(Instrument.raised).frame(height: 5)
                    Text("NO CLIP ON TIMELINE")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Instrument.muted)
                }
                HStack(spacing: 9) {
                    Button("Set in") { editor.setInPoint() }.buttonStyle(InstrumentButton())
                    Button("Set out") { editor.setOutPoint() }.buttonStyle(InstrumentButton())
                    Button("Reset trim") { editor.resetTrim() }.buttonStyle(InstrumentButton())
                    Spacer()
                    Text(editor.sourceURL?.lastPathComponent ?? "Drag a video into the window")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Instrument.muted)
                        .lineLimit(1)
                }
                .disabled(editor.sourceURL == nil)
            }
            .padding(18)
        }
        .frame(height: 174)
    }

    private var inspector: some View {
        VStack(spacing: 14) {
            InstrumentPanel {
                VStack(alignment: .leading, spacing: 17) {
                    Kicker(number: "03", title: "STABILIZATION")
                    Text("Camera path")
                        .font(.system(size: 25, weight: .semibold))
                    Text("Rigid frame correction keeps straight lines straight. Motion is analyzed offline, then the path is optimized.")
                        .font(.system(size: 12))
                        .foregroundStyle(Instrument.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Enable stabilization", isOn: $editor.stabilizationEnabled)
                        .toggleStyle(.switch)
                        .tint(Instrument.mint)
                        .onChange(of: editor.stabilizationEnabled) { _, _ in
                            Task { await editor.updateStabilization() }
                        }
                        .disabled(editor.analysis == nil)
                    Divider().overlay(Instrument.line)
                    HStack {
                        Text("SMOOTHNESS")
                        Spacer()
                        Text("\(Int(editor.strength * 100))%")
                            .foregroundStyle(Instrument.mint)
                    }
                    .font(.system(size: 10, design: .monospaced))
                    Slider(value: $editor.strength, in: 0...1, onEditingChanged: { editing in
                        if !editing { Task { await editor.updateStabilization() } }
                    })
                    .tint(Instrument.mint)
                    .disabled(editor.analysis == nil)
                    HStack {
                        Text("MAXIMUM CROP")
                        Spacer()
                        Text("\(Int(((editor.maxZoom - 1) * 100).rounded()))%")
                            .foregroundStyle(Instrument.amber)
                    }
                    .font(.system(size: 10, design: .monospaced))
                    Slider(value: $editor.maxZoom, in: 1.02...1.5, onEditingChanged: { editing in
                        if !editing { Task { await editor.updateStabilization() } }
                    })
                    .tint(Instrument.amber)
                    .disabled(editor.analysis == nil)
                    Text("Crop budget limits correction before empty borders appear.")
                        .font(.system(size: 11))
                        .foregroundStyle(Instrument.muted)
                }
                .padding(18)
            }
            InstrumentPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Kicker(number: "04", title: "MOTION SIGNAL")
                    Text("Horizontal camera path")
                        .font(.system(size: 14, weight: .semibold))
                    MotionGraph(analysis: editor.analysis, plan: editor.plan)
                        .frame(height: 125)
                    HStack(spacing: 14) {
                        Label("Recorded", systemImage: "circle.fill")
                            .foregroundStyle(Instrument.violet)
                        Label("Corrected", systemImage: "circle.fill")
                            .foregroundStyle(Instrument.mint)
                    }
                    .font(.system(size: 9, design: .monospaced))
                    HStack {
                        Text("TRACKING CONFIDENCE")
                        Spacer()
                        Text(editor.plan.map { "\(Int($0.averageConfidence * 100))%" } ?? "—")
                            .foregroundStyle(editor.plan == nil ? Instrument.muted : Instrument.blue)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
                .padding(18)
            }
            Spacer(minLength: 0)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(editor.errorMessage == nil ? Instrument.mint : Instrument.red)
                .frame(width: 6, height: 6)
            Text(editor.status)
            Spacer()
            if let plan = editor.plan {
                Text("ZOOM \(String(format: "%.3f", plan.zoom))×  /  APPLIED \(Int(plan.appliedFraction * 100))%")
            }
            Text("MOTIONCUT / NATIVE MAC")
                .padding(.leading, 15)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Instrument.secondary)
        .padding(.horizontal, 18)
        .frame(height: 31)
        .background(Instrument.raised)
        .overlay(alignment: .top) { Instrument.line.frame(height: 1) }
    }
}

private struct MotionGraph: View {
    let analysis: MotionAnalysis?
    let plan: StabilizationPlan?

    var body: some View {
        Canvas { context, size in
            for fraction in [CGFloat(0.25), 0.5, 0.75] {
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: size.height * fraction))
                grid.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                context.stroke(grid, with: .color(Instrument.grid.opacity(0.65)), lineWidth: 0.7)
            }
            guard let analysis, let plan, analysis.samples.count > 1 else { return }
            let center = CGPoint(x: analysis.rawSize.width / 2, y: analysis.rawSize.height / 2)
            let raw = analysis.samples.map { center.applying($0.cumulative).x }
            let stabilized = zip(analysis.samples, plan.frames).map {
                center.applying($0.0.cumulative).applying($0.1.correction).x
            }
            let all = raw + stabilized
            guard let minValue = all.min(), let maxValue = all.max() else { return }
            let range = max(1, maxValue - minValue)
            func draw(_ values: [CGFloat], color: Color) {
                var path = Path()
                for index in values.indices {
                    let point = CGPoint(
                        x: CGFloat(index) / CGFloat(values.count - 1) * size.width,
                        y: size.height * (0.87 - 0.74 * (values[index] - minValue) / range)
                    )
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(color), lineWidth: 1.6)
            }
            draw(raw, color: Instrument.violet)
            draw(stabilized, color: Instrument.mint)
        }
        .background(Instrument.field)
        .overlay(Rectangle().stroke(Instrument.line, lineWidth: 1))
        .accessibilityLabel("Recorded and corrected horizontal camera position over the clip")
    }
}
