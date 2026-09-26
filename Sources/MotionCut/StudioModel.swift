import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class StudioModel: ObservableObject {
    @Published var project = EditingProject()
    @Published var player = AVPlayer()
    @Published var currentTime = 0.0
    @Published var isPlaying = false
    @Published var isBuilding = false
    @Published var isExporting = false
    @Published var selectedClipID: UUID?
    @Published var selectedMediaID: UUID?
    @Published var selectedTrackID: UUID?
    @Published var analyzingMedia: Set<UUID> = []
    @Published var status = "Import videos, images, or audio to begin."
    @Published var errorMessage: String?
    @Published var stabilizationMode: StabilizationMode = .balanced
    @Published var smoothness = 0.55
    @Published var maxZoom = 1.20

    private var rendered: RenderedTimeline?
    private var analyses: [UUID: MotionAnalysis] = [:]
    private var plans: [UUID: StabilizationPlan] = [:]
    private var parsedLUTs: [UUID: CubeLUT] = [:]
    private var renderGeneration = 0
    private var planGeneration = 0
    private var undoStack: [EditingProject] = []
    private var redoStack: [EditingProject] = []
    private var projectURL: URL?
    private var soundPreview: AVAudioPlayer?
    private var timeObserver: Any?

    var duration: Double { project.duration }
    var selectedClip: TimelineClip? {
        guard let id = selectedClipID, let location = project.clipLocation(id) else { return nil }
        return project.tracks[location.track].clips[location.clip]
    }
    var selectedTrack: TimelineTrack? {
        guard let id = selectedClipID, let location = project.clipLocation(id) else { return nil }
        return project.tracks[location.track]
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var canExport: Bool { rendered != nil && !isBuilding && !isExporting }

    init() {
        selectedTrackID = project.tracks.first { $0.name == "V1" }?.id
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.08, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                if self.duration > 0 && self.currentTime >= self.duration - 0.03 {
                    self.player.pause()
                    self.isPlaying = false
                } else {
                    self.isPlaying = self.player.rate != 0
                }
            }
        }
    }

    func importMediaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .video, .audio, .image, .mpeg4Movie,
                                     .quickTimeMovie, .mp3, .wav, .aiff]
        guard panel.runModal() == .OK else { return }
        Task { await importMedia(panel.urls) }
    }

    func importAudioPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff]
        guard panel.runModal() == .OK else { return }
        Task { await importMedia(panel.urls) }
    }

    func importMedia(_ urls: [URL]) async {
        var additions: [MediaAsset] = []
        for url in urls {
            if project.media.contains(where: { $0.url == url }) { continue }
            do { additions.append(try await mediaMetadata(for: url)) }
            catch { errorMessage = error.localizedDescription }
        }
        guard !additions.isEmpty else { return }
        let placeVideos = project.tracks.flatMap(\.clips).isEmpty
        commit("Import media") { project in
            project.media.append(contentsOf: additions)
            if placeVideos, let first = additions.first(where: { $0.kind == .video }) {
                project.canvasWidth = max(2, first.width)
                project.canvasHeight = max(2, first.height)
                var start = 0.0
                if let lane = project.tracks.firstIndex(where: { $0.name == "V1" }) {
                    for media in additions where media.kind == .video {
                        project.tracks[lane].clips.append(TimelineClip(
                            mediaID: media.id, start: start, duration: media.duration,
                            stabilized: true))
                        start += media.duration
                    }
                }
            }
        }
        selectedMediaID = additions.first?.id
        status = "Imported \(additions.count) media item\(additions.count == 1 ? "" : "s")"
        for media in additions where media.kind == .video { analyze(media) }
    }

    private func mediaMetadata(for url: URL) async throws -> MediaAsset {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .image) == true {
            let image = NSImage(contentsOf: url)
            return MediaAsset(url: url, kind: .image, duration: 6,
                              width: Int(image?.size.width ?? 1920),
                              height: Int(image?.size.height ?? 1080))
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        if let video = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await video.load(.naturalSize)
            let preferred = try await video.load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: size).applying(preferred)
            return MediaAsset(url: url, kind: .video, duration: max(0.05, duration),
                              width: Int(abs(bounds.width)), height: Int(abs(bounds.height)))
        }
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw TimelineRenderError.invalidTrack(url.lastPathComponent)
        }
        return MediaAsset(url: url, kind: .audio, duration: max(0.05, duration))
    }

    func addMediaToTimeline(_ mediaID: UUID, on trackID: UUID? = nil, at time: Double? = nil) {
        guard let media = project.media.first(where: { $0.id == mediaID }) else { return }
        let kind: TrackKind = media.kind == .audio ? .audio : .video
        let targetID = trackID ?? selectedTrackID
        let target = project.tracks.first(where: { $0.id == targetID && $0.kind == kind }) ??
            project.tracks.first(where: { $0.kind == kind && $0.name.hasSuffix("1") })
        guard let target, !target.isLocked else { return }
        let start = snap(time ?? currentTime, excluding: nil)
        let clip = TimelineClip(mediaID: media.id, start: start,
                                duration: media.kind == .image ? 6 : media.duration,
                                stabilized: media.kind == .video)
        commit("Add clip") { project in
            project.tracks[project.tracks.firstIndex(where: { $0.id == target.id })!].clips.append(clip)
        }
        selectedClipID = clip.id
        selectedTrackID = target.id
        if media.kind == .video, analyses[media.id] == nil { analyze(media) }
    }

    func splitAtPlayhead() {
        let target = selectedClipID.flatMap { id in
            selectedClip.flatMap { currentTime > $0.start + 0.05 && currentTime < $0.end - 0.05 ? id : nil }
        } ??
            project.tracks.flatMap(\.clips).first(where: { currentTime > $0.start + 0.05 &&
                currentTime < $0.end - 0.05 })?.id
        guard let target else { return }
        var copy = project
        guard let right = copy.split(target, at: currentTime) else { return }
        rememberUndo()
        project = copy
        selectedClipID = right
        scheduleRender()
        status = "Split at \(timecode(currentTime))"
    }

    func deleteSelected(ripple: Bool) {
        guard let id = selectedClipID else { return }
        var copy = project
        guard copy.delete(id, ripple: ripple) else { return }
        rememberUndo()
        project = copy
        selectedClipID = nil
        if ripple { currentTime = min(currentTime, project.duration) }
        scheduleRender()
        status = ripple ? "Ripple deleted clip" : "Deleted clip"
    }

    func moveClip(_ id: UUID, to start: Double, on trackID: UUID) {
        let snapped = snap(start, excluding: id)
        var copy = project
        guard copy.move(id, to: snapped, on: trackID) else { return }
        rememberUndo()
        project = copy
        selectedClipID = id
        selectedTrackID = trackID
        scheduleRender()
    }

    func trimSelected(leading: Double? = nil, trailing: Double? = nil) {
        guard let id = selectedClipID else { return }
        var copy = project
        guard copy.trim(id, leading: leading, trailing: trailing) else { return }
        rememberUndo()
        project = copy
        scheduleRender()
    }

    func updateSelectedClip(_ change: (inout TimelineClip) -> Void) {
        guard let id = selectedClipID, let location = project.clipLocation(id),
              !project.tracks[location.track].isLocked else { return }
        commit("Edit clip") { project in
            change(&project.tracks[location.track].clips[location.clip])
        }
    }

    func setSelectedSpeed(_ value: Double) {
        let speed = min(4, max(0.25, value))
        updateSelectedClip { clip in
            clip.duration = max(0.05, clip.duration * clip.speed / speed)
            clip.speed = speed
        }
    }

    func detachSelectedAudio() {
        guard let selected = selectedClip,
              let media = project.media(for: selected), media.kind == .video,
              let audioTrack = project.tracks.first(where: { $0.name == "A1" && !$0.isLocked }) ??
                project.tracks.first(where: { $0.kind == .audio && !$0.isLocked }) else { return }
        Task {
            do {
                let source = AVURLAsset(url: media.url)
                guard let sourceAudio = try await source.loadTracks(withMediaType: .audio).first else {
                    throw TimelineRenderError.invalidTrack("recorded audio in \(media.name)")
                }
                let audioRange = try await sourceAudio.load(.timeRange)
                let remainingSource = audioRange.end.seconds - selected.sourceStart
                guard remainingSource > 0.05 else {
                    throw TimelineRenderError.invalidTrack("recorded audio at this clip position")
                }
                var audioClip = selected
                audioClip.id = UUID()
                audioClip.title = nil
                audioClip.lutID = nil
                audioClip.stabilized = false
                audioClip.duration = min(selected.duration, remainingSource / max(0.01, selected.speed))
                commit("Detach audio") { project in
                    if let location = project.clipLocation(selected.id) {
                        project.tracks[location.track].clips[location.clip].sourceAudioEnabled = false
                    }
                    if let index = project.tracks.firstIndex(where: { $0.id == audioTrack.id }) {
                        project.tracks[index].clips.append(audioClip)
                    }
                }
                selectedClipID = audioClip.id
                selectedTrackID = audioTrack.id
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func addTrack(_ kind: TrackKind) {
        commit("Add track") { project in
            let number = project.tracks.filter { $0.kind == kind }.count + 1
            let prefix = kind == .video ? "V" : "A"
            let track = TimelineTrack(name: "\(prefix)\(number)", kind: kind)
            if kind == .video { project.tracks.insert(track, at: 0) }
            else { project.tracks.append(track) }
            selectedTrackID = track.id
        }
    }

    func addTitle() {
        let track = project.tracks.first { $0.name == "V2" } ??
            project.tracks.first { $0.kind == .video }
        guard let track, !track.isLocked else { return }
        let clip = TimelineClip(title: "Your title", start: snap(currentTime, excluding: nil),
                                duration: 3)
        commit("Add title") { project in
            project.tracks[project.tracks.firstIndex(where: { $0.id == track.id })!].clips.append(clip)
        }
        selectedClipID = clip.id
        selectedTrackID = track.id
    }

    func newProject() {
        player.pause()
        planGeneration += 1
        project = EditingProject()
        projectURL = nil
        selectedClipID = nil
        selectedMediaID = nil
        selectedTrackID = project.tracks.first { $0.name == "V1" }?.id
        analyses = [:]
        plans = [:]
        parsedLUTs = [:]
        analyzingMedia = []
        stabilizationMode = .balanced
        smoothness = 0.55
        maxZoom = 1.20
        undoStack = []
        redoStack = []
        currentTime = 0
        scheduleRender()
        status = "New project"
    }

    func toggleTrackMute(_ id: UUID) {
        commit("Mute track") { project in
            guard let index = project.tracks.firstIndex(where: { $0.id == id }) else { return }
            project.tracks[index].isMuted.toggle()
        }
    }

    func toggleTrackLock(_ id: UUID) {
        commit("Lock track") { project in
            guard let index = project.tracks.firstIndex(where: { $0.id == id }) else { return }
            project.tracks[index].isLocked.toggle()
        }
    }

    func setCanvas(width: Int, height: Int) {
        commit("Canvas size") { project in
            project.canvasWidth = width
            project.canvasHeight = height
        }
    }

    func setFrameRate(_ frameRate: Double) {
        commit("Frame rate") { $0.frameRate = frameRate }
    }

    func setMode(_ mode: StabilizationMode) {
        stabilizationMode = mode
        if mode == .cropAndSteady { maxZoom = max(maxZoom, 1.5) }
        else { maxZoom = min(maxZoom, 1.5) }
        recalculatePlans()
    }

    func recalculatePlans() {
        planGeneration += 1
        let generation = planGeneration
        let source = analyses
        let mode = stabilizationMode
        let strength = smoothness
        let zoom = maxZoom
        guard !source.isEmpty else { scheduleRender(); return }
        status = "Updating stabilization…"
        Task {
            var updated: [UUID: StabilizationPlan] = [:]
            for (id, analysis) in source {
                updated[id] = await Task.detached(priority: .userInitiated) {
                    StabilizationPlan(analysis: analysis, strength: strength,
                                      maxZoom: zoom, mode: mode)
                }.value
            }
            guard generation == planGeneration else { return }
            plans = updated
            scheduleRender()
        }
    }

    private func analyze(_ media: MediaAsset) {
        guard !analyzingMedia.contains(media.id), analyses[media.id] == nil else { return }
        analyzingMedia.insert(media.id)
        Task {
            do {
                let analysis = try await Task.detached(priority: .utility) {
                    try await MotionAnalyzer.analyze(media.url)
                }.value
                guard project.media.contains(where: { $0.id == media.id }) else { return }
                analyses[media.id] = analysis
                analyzingMedia.remove(media.id)
                recalculatePlans()
            } catch {
                analyzingMedia.remove(media.id)
                status = "Video imported; stabilization analysis failed"
                errorMessage = error.localizedDescription
            }
        }
    }

    func importLUTPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                guard url.pathExtension.lowercased() == "cube" else {
                    throw CubeLUTError.malformed("select a .cube file")
                }
                let folder = FileManager.default.urls(for: .applicationSupportDirectory,
                                                       in: .userDomainMask)[0]
                    .appendingPathComponent("MotionCut/LUTs", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: destination)
                let parsed = try CubeLUT(url: destination)
                let asset = LUTAsset(url: destination)
                parsedLUTs[asset.id] = parsed
                commit("Import LUT") { $0.luts.append(asset) }
                if selectedClip != nil {
                    updateSelectedClip { $0.lutID = asset.id }
                }
                status = "Imported LUT: \(asset.name)"
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func addLibrarySound(_ sound: LibrarySound) {
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try AudioLibrary.file(for: sound)
                }.value
                if !project.media.contains(where: { $0.url == url }) { await importMedia([url]) }
                guard let media = project.media.first(where: { $0.url == url }) else { return }
                addMediaToTimeline(media.id, on: project.tracks.first(where: { $0.name == "A1" })?.id)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func previewLibrarySound(_ sound: LibrarySound) {
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try AudioLibrary.file(for: sound)
                }.value
                soundPreview?.stop()
                soundPreview = try AVAudioPlayer(contentsOf: url)
                soundPreview?.play()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func previewImportedAudio(_ media: MediaAsset) {
        do {
            soundPreview?.stop()
            soundPreview = try AVAudioPlayer(contentsOf: media.url)
            soundPreview?.play()
        } catch { errorMessage = error.localizedDescription }
    }

    func togglePlayback() {
        if player.rate != 0 {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let value = min(max(0, seconds), duration)
        currentTime = value
        player.seek(to: CMTime(seconds: value, preferredTimescale: 60_000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func exportPanel() {
        guard let rendered, canExport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.nameFieldStringValue = project.name + ".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        status = "Exporting timeline…"
        Task {
            do {
                guard let session = AVAssetExportSession(asset: rendered.composition,
                                         presetName: AVAssetExportPresetHighestQuality) else {
                    throw TimelineRenderError.noVideo
                }
                session.videoComposition = rendered.videoComposition
                session.audioMix = rendered.audioMix
                let type: AVFileType = url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
                try await session.export(to: url, as: type)
                status = "Export complete · \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                status = "Export failed"
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }

    func saveProject() {
        let destination: URL
        if let projectURL { destination = projectURL }
        else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = project.name + ".motioncut.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var saved = project
            saved.stabilizationMode = stabilizationMode
            saved.stabilizationSmoothness = smoothness
            saved.stabilizationMaxZoom = maxZoom
            try encoder.encode(saved).write(to: destination, options: .atomic)
            projectURL = destination
            status = "Saved project · \(destination.lastPathComponent)"
        } catch { errorMessage = error.localizedDescription }
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try JSONDecoder().decode(EditingProject.self, from: Data(contentsOf: url))
            planGeneration += 1
            project = loaded
            stabilizationMode = loaded.stabilizationMode
            smoothness = loaded.stabilizationSmoothness
            maxZoom = loaded.stabilizationMaxZoom
            projectURL = url
            selectedClipID = nil
            selectedMediaID = nil
            selectedTrackID = loaded.tracks.first { $0.name == "V1" }?.id
            analyses = [:]
            plans = [:]
            parsedLUTs = [:]
            analyzingMedia = []
            undoStack = []
            redoStack = []
            for lut in loaded.luts {
                if let parsed = try? CubeLUT(url: lut.url) { parsedLUTs[lut.id] = parsed }
            }
            scheduleRender()
            for media in loaded.media where media.kind == .video { analyze(media) }
            status = "Opened project · \(url.lastPathComponent)"
        } catch { errorMessage = error.localizedDescription }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        project = previous
        selectedClipID = nil
        scheduleRender()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        selectedClipID = nil
        scheduleRender()
    }

    private func commit(_ label: String, _ change: (inout EditingProject) -> Void) {
        rememberUndo()
        var copy = project
        change(&copy)
        project = copy
        scheduleRender()
        status = label
    }

    private func rememberUndo() {
        undoStack.append(project)
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func snap(_ time: Double, excluding id: UUID?) -> Double {
        let frame = 1 / max(1, project.frameRate)
        let value = max(0, (time / frame).rounded() * frame)
        let boundaries = [currentTime] + project.tracks.flatMap(\.clips)
            .filter { $0.id != id }.flatMap { [$0.start, $0.end] }
        guard let near = boundaries.min(by: { abs($0 - value) < abs($1 - value) }),
              abs(near - value) < 0.12 else { return value }
        return near
    }

    private func scheduleRender() {
        renderGeneration += 1
        let generation = renderGeneration
        let snapshot = project
        let selectedPlans = plans
        let selectedLUTs = parsedLUTs
        let position = currentTime
        let wasPlaying = player.rate != 0
        player.pause()
        isBuilding = true
        guard snapshot.duration > 0 else {
            rendered = nil
            player.replaceCurrentItem(with: nil)
            isBuilding = false
            return
        }
        Task {
            do {
                let result = try await TimelineRenderer.build(project: snapshot,
                                                                plans: selectedPlans, luts: selectedLUTs)
                guard generation == renderGeneration else { return }
                rendered = result
                let item = AVPlayerItem(asset: result.composition)
                item.videoComposition = result.videoComposition
                item.audioMix = result.audioMix
                player.replaceCurrentItem(with: item)
                let seekTime = min(position, snapshot.duration)
                await player.seek(to: CMTime(seconds: seekTime, preferredTimescale: 60_000),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
                currentTime = seekTime
                if wasPlaying { player.play() }
                isPlaying = wasPlaying
                isBuilding = false
                status = "Timeline ready · \(timecode(snapshot.duration))"
            } catch {
                guard generation == renderGeneration else { return }
                rendered = nil
                isBuilding = false
                status = "Timeline needs attention"
                errorMessage = error.localizedDescription
            }
        }
    }

    func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00.0" }
        let minutes = Int(max(0, seconds)) / 60
        let remainder = max(0, seconds) - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, remainder)
    }
}
