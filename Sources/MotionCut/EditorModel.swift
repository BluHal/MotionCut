import AppKit
import AVFoundation
import AVKit
import SwiftUI

@MainActor
final class EditorModel: ObservableObject {
    @Published var sourceURL: URL?
    @Published var analysis: MotionAnalysis?
    @Published var plan: StabilizationPlan?
    @Published var player = AVPlayer()
    @Published var isAnalyzing = false
    @Published var isPlanning = false
    @Published var isExporting = false
    @Published var isPlaying = false
    @Published var stabilizationEnabled = true
    @Published var strength = 0.55
    @Published var maxZoom = 1.20
    @Published var stabilizationMode: StabilizationMode = .balanced
    @Published var currentTime = 0.0
    @Published var duration = 0.0
    @Published var trimStart = 0.0
    @Published var trimEnd = 0.0
    @Published var status = "Open a video to begin."
    @Published var errorMessage: String?

    private var timeObserver: Any?
    private var analysisTask: Task<MotionAnalysis, Error>?
    private var sourceGeneration = 0
    private var planGeneration = 0

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                if self.trimEnd > self.trimStart && self.currentTime >= self.trimEnd - 0.03 {
                    self.player.pause()
                    self.isPlaying = false
                } else {
                    self.isPlaying = self.player.rate != 0
                }
            }
        }
    }

    func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        analysisTask?.cancel()
        sourceGeneration += 1
        planGeneration += 1
        let generation = sourceGeneration
        sourceURL = url
        analysis = nil
        plan = nil
        duration = 0
        trimStart = 0
        trimEnd = 0
        currentTime = 0
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        isAnalyzing = true
        isPlanning = false
        status = "Analyzing camera motion…"
        let task = Task.detached(priority: .userInitiated) {
            try await MotionAnalyzer.analyze(url)
        }
        analysisTask = task
        Task {
            do {
                let result = try await task.value
                guard generation == sourceGeneration else { return }
                analysisTask = nil
                analysis = result
                duration = result.duration.seconds
                trimEnd = duration
                isAnalyzing = false
                status = "Motion analysis complete · \(result.samples.count) frames"
                await updateStabilization()
            } catch {
                guard generation == sourceGeneration else { return }
                analysisTask = nil
                isAnalyzing = false
                status = "Analysis failed"
                errorMessage = error.localizedDescription
            }
        }
    }

    func updateStabilization() async {
        guard let analysis, let sourceURL else { return }
        planGeneration += 1
        isPlanning = true
        let generation = planGeneration
        let source = sourceGeneration
        let wasPlaying = player.rate != 0
        let position = player.currentTime()
        let selectedStrength = strength
        let selectedMaxZoom = maxZoom
        let selectedMode = stabilizationMode
        player.pause()
        let newPlan = await Task.detached(priority: .userInitiated) {
            StabilizationPlan(analysis: analysis, strength: selectedStrength,
                              maxZoom: selectedMaxZoom, mode: selectedMode)
        }.value
        guard generation == planGeneration, source == sourceGeneration else { return }
        plan = newPlan
        let item = AVPlayerItem(url: sourceURL)
        if stabilizationEnabled {
            do {
                let asset = AVURLAsset(url: sourceURL)
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    item.videoComposition = VideoCompositionBuilder.build(
                        track: track, analysis: analysis, plan: newPlan
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        player.replaceCurrentItem(with: item)
        await player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.play() }
        isPlaying = wasPlaying
        status = stabilizationEnabled
            ? "\(selectedMode.title) · \(newPlan.frameCropPercent)% frame crop"
            : "Original preview"
        isPlanning = false
    }

    func selectStabilizationMode(_ mode: StabilizationMode) async {
        guard mode != stabilizationMode else { return }
        stabilizationMode = mode
        if mode == .cropAndSteady {
            maxZoom = max(maxZoom, 1.5)
        } else {
            maxZoom = min(maxZoom, 1.5)
        }
        await updateStabilization()
    }

    func togglePlayback() {
        if player.rate != 0 {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= trimEnd - 0.05 { seek(to: trimStart) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let value = min(max(seconds, trimStart), max(trimStart, trimEnd))
        player.seek(to: CMTime(seconds: value, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = value
    }

    func setInPoint() {
        trimStart = min(currentTime, max(0, trimEnd - 0.1))
        status = "In point set at \(timecode(trimStart))"
    }

    func setOutPoint() {
        trimEnd = max(currentTime, min(duration, trimStart + 0.1))
        status = "Out point set at \(timecode(trimEnd))"
    }

    func resetTrim() {
        trimStart = 0
        trimEnd = duration
        status = "Trim reset"
    }

    func exportVideo() {
        guard let sourceURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-motioncut.mov"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isExporting = true
        status = "Exporting video…"
        Task {
            do {
                let asset = AVURLAsset(url: sourceURL)
                guard let session = AVAssetExportSession(asset: asset,
                                                          presetName: AVAssetExportPresetHighestQuality) else {
                    throw ExportError.unavailable
                }
                if stabilizationEnabled, let analysis, let plan,
                   let track = try await asset.loadTracks(withMediaType: .video).first {
                    session.videoComposition = VideoCompositionBuilder.build(
                        track: track, analysis: analysis, plan: plan
                    )
                }
                session.timeRange = CMTimeRange(
                    start: CMTime(seconds: trimStart, preferredTimescale: 600),
                    duration: CMTime(seconds: trimEnd - trimStart, preferredTimescale: 600)
                )
                try await session.export(to: destination, as: .mov)
                status = "Export complete · \(destination.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                status = "Export failed"
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }

    func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00.0" }
        let minutes = Int(seconds) / 60
        let remaining = seconds - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, remaining)
    }

    private enum ExportError: LocalizedError {
        case unavailable
        var errorDescription: String? { "No compatible video export preset was found." }
    }
}
