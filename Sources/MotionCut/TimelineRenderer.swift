import AVFoundation
import AppKit
import CoreImage
import Metal

struct RenderedTimeline {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix
}

private struct RenderLayer: @unchecked Sendable {
    let trackID: CMPersistentTrackID?
    let clip: TimelineClip
    let baseTransform: CGAffineTransform
    let stillImage: CIImage?
    let plan: StabilizationPlan?
    let center: CGPoint
    let lut: CubeLUT?
    let canvas: CGSize

    func transform(at timelineTime: Double) -> CGAffineTransform {
        var result = baseTransform
        if let plan, !plan.frames.isEmpty {
            let sourceTime = clip.sourceStart + (timelineTime - clip.start) * clip.speed
            var low = 0, high = plan.frames.count
            while low < high {
                let middle = (low + high) / 2
                if plan.frames[middle].time.seconds < sourceTime { low = middle + 1 }
                else { high = middle }
            }
            let index = min(plan.frames.count - 1, max(0, low))
            let correction = plan.frames[index].correction
            let zoom = CGAffineTransform(translationX: -center.x, y: -center.y)
                .concatenating(CGAffineTransform(scaleX: plan.zoom, y: plan.zoom))
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            result = correction.concatenating(zoom).concatenating(baseTransform)
        }
        let edit = CGAffineTransform(translationX: -canvas.width / 2, y: -canvas.height / 2)
            .concatenating(CGAffineTransform(scaleX: clip.scale, y: clip.scale))
            .concatenating(CGAffineTransform(translationX: canvas.width / 2, y: canvas.height / 2))
            .concatenating(CGAffineTransform(translationX: clip.positionX * canvas.width,
                                              y: clip.positionY * canvas.height))
        return result.concatenating(edit)
    }

    func opacity(at timelineTime: Double) -> Double {
        let local = max(0, timelineTime - clip.start)
        let entry = clip.fadeIn > 0 ? min(1, local / clip.fadeIn) : 1
        let exit = clip.fadeOut > 0 ? min(1, (clip.duration - local) / clip.fadeOut) : 1
        return max(0, min(1, clip.opacity * entry * exit))
    }
}

private final class TimelineInstruction: NSObject, AVVideoCompositionInstructionProtocol,
                                          @unchecked Sendable {
    let timeRange: CMTimeRange
    let layers: [RenderLayer]
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let containsTweening = false
    let enablePostProcessing = false

    init(range: CMTimeRange, layers: [RenderLayer], timingTrackID: CMPersistentTrackID) {
        timeRange = range
        self.layers = layers
        requiredSourceTrackIDs = [NSNumber(value: timingTrackID)] +
            layers.compactMap { $0.trackID.map { NSNumber(value: $0) } }
    }
}

final class TimelineCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device) }
        return CIContext()
    }()

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? TimelineInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "MotionCut", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: "Unable to create video frame"]))
            return
        }
        let bounds = CGRect(origin: .zero, size: request.renderContext.size)
        var composed = CIImage(color: .black).cropped(to: bounds)
        let time = request.compositionTime.seconds
        for layer in instruction.layers {
            let source = layer.trackID.flatMap { request.sourceFrame(byTrackID: $0) }
            guard var image = source.map({ CIImage(cvPixelBuffer: $0) }) ?? layer.stillImage else { continue }
            if let lut = layer.lut { image = lut.applying(to: image) }
            if layer.clip.brightness != 0 || layer.clip.contrast != 1 || layer.clip.saturation != 1 {
                image = image.applyingFilter("CIColorControls", parameters: [
                    "inputBrightness": layer.clip.brightness,
                    "inputContrast": layer.clip.contrast,
                    "inputSaturation": layer.clip.saturation
                ])
            }
            image = image.transformed(by: layer.transform(at: time))
            let opacity = layer.opacity(at: time)
            if opacity < 0.999 {
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
                ])
            }
            composed = image.cropped(to: bounds).composited(over: composed)
        }
        context.render(composed, to: output, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: output)
    }
}

enum TimelineRenderError: LocalizedError {
    case noVideo
    case missingMedia(String)
    case invalidTrack(String)

    var errorDescription: String? {
        switch self {
        case .noVideo: "Add a video clip before previewing or exporting."
        case .missingMedia(let name): "Media is missing: \(name)"
        case .invalidTrack(let name): "Cannot load a track from \(name)."
        }
    }
}

enum TimelineRenderer {
    static func build(project: EditingProject,
                      plans: [UUID: StabilizationPlan],
                      luts: [UUID: CubeLUT]) async throws -> RenderedTimeline {
        let composition = AVMutableComposition()
        let audioMix = AVMutableAudioMix()
        var audioParameters: [AVAudioMixInputParameters] = []
        var videoLayers: [RenderLayer] = []
        let canvas = CGSize(width: project.canvasWidth, height: project.canvasHeight)
        let byMedia = Dictionary(uniqueKeysWithValues: project.media.map { ($0.id, $0) })

        for track in project.tracks.reversed() {
            for clip in track.clips.sorted(by: { $0.start < $1.start }) {
                guard let mediaID = clip.mediaID, let media = byMedia[mediaID] else { continue }
                guard FileManager.default.fileExists(atPath: media.url.path) else {
                    throw TimelineRenderError.missingMedia(media.name)
                }
                let asset = AVURLAsset(url: media.url)
                let sourceStart = CMTime(seconds: clip.sourceStart, preferredTimescale: 60_000)
                let at = CMTime(seconds: clip.start, preferredTimescale: 60_000)
                let range = CMTimeRange(start: sourceStart,
                                        duration: CMTime(seconds: clip.duration * clip.speed,
                                                         preferredTimescale: 60_000))
                if track.kind == .video, media.kind == .video {
                    guard let source = try await asset.loadTracks(withMediaType: .video).first,
                          let destination = composition.addMutableTrack(withMediaType: .video,
                                 preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw TimelineRenderError.invalidTrack(media.name)
                    }
                    try destination.insertTimeRange(range, of: source, at: at)
                    destination.scaleTimeRange(CMTimeRange(start: at, duration: range.duration),
                        toDuration: CMTime(seconds: clip.duration, preferredTimescale: 60_000))
                    let size = try await source.load(.naturalSize)
                    let preferred = try await source.load(.preferredTransform)
                    let oriented = CGRect(origin: .zero, size: size).applying(preferred)
                    let displaySize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
                    let scale = min(canvas.width / max(1, displaySize.width),
                                    canvas.height / max(1, displaySize.height))
                    let offset = CGPoint(x: (canvas.width - displaySize.width * scale) / 2,
                                         y: (canvas.height - displaySize.height * scale) / 2)
                    let normalized = preferred.concatenating(
                        CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
                    let base = normalized
                        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                        .concatenating(CGAffineTransform(translationX: offset.x, y: offset.y))
                    videoLayers.append(RenderLayer(
                        trackID: destination.trackID, clip: clip, baseTransform: base,
                        stillImage: nil,
                        plan: clip.stabilized ? plans[mediaID] : nil,
                        center: CGPoint(x: size.width / 2, y: size.height / 2),
                        lut: clip.lutID.flatMap { luts[$0] }, canvas: canvas
                    ))
                    if !track.isMuted, clip.sourceAudioEnabled,
                       let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                        try addAudio(source: sourceAudio, range: range, at: at,
                                     clip: clip, to: composition, parameters: &audioParameters)
                    }
                } else if track.kind == .video, media.kind == .image {
                    guard let image = CIImage(contentsOf: media.url) else {
                        throw TimelineRenderError.invalidTrack(media.name)
                    }
                    let extent = image.extent
                    let scale = min(canvas.width / max(1, extent.width),
                                    canvas.height / max(1, extent.height))
                    let transform = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                        .concatenating(CGAffineTransform(translationX:
                            (canvas.width - extent.width * scale) / 2,
                            y: (canvas.height - extent.height * scale) / 2))
                    videoLayers.append(RenderLayer(trackID: nil, clip: clip,
                        baseTransform: transform, stillImage: image, plan: nil,
                        center: .zero, lut: clip.lutID.flatMap { luts[$0] }, canvas: canvas))
                } else if track.kind == .audio, !track.isMuted,
                          let source = try await asset.loadTracks(withMediaType: .audio).first {
                    try addAudio(source: source, range: range, at: at,
                                 clip: clip, to: composition, parameters: &audioParameters)
                }
            }
            if track.kind == .video {
                for clip in track.clips where clip.isTitle {
                    let image = titleImage(clip.title ?? "", canvas: canvas)
                    videoLayers.append(RenderLayer(trackID: nil, clip: clip,
                        baseTransform: .identity, stillImage: image, plan: nil,
                        center: .zero, lut: nil, canvas: canvas))
                }
            }
        }
        guard project.duration > 0 else { throw TimelineRenderError.noVideo }
        audioMix.inputParameters = audioParameters

        let duration = max(1 / project.frameRate, project.duration)
        guard let timingURL = Bundle.main.url(forResource: "Timing", withExtension: "mov") ??
                (FileManager.default.fileExists(atPath: "Resources/Timing.mov") ?
                 URL(fileURLWithPath: "Resources/Timing.mov") : nil) else {
            throw TimelineRenderError.invalidTrack("the bundled timing source")
        }
        let timingAsset = AVURLAsset(url: timingURL)
        guard let timingSource = try await timingAsset.loadTracks(withMediaType: .video).first,
              let timingTrack = composition.addMutableTrack(withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TimelineRenderError.invalidTrack("the bundled timing source")
        }
        var timingPosition = 0.0
        while timingPosition < duration - 0.0001 {
            let length = min(1, duration - timingPosition)
            try timingTrack.insertTimeRange(
                CMTimeRange(start: .zero,
                            duration: CMTime(seconds: length, preferredTimescale: 60_000)),
                of: timingSource,
                at: CMTime(seconds: timingPosition, preferredTimescale: 60_000))
            timingPosition += length
        }
        let edges = ([0, duration] + videoLayers.flatMap { [$0.clip.start, $0.clip.end] })
            .filter { $0.isFinite && $0 >= 0 && $0 <= duration }
            .sorted()
        var instructions: [TimelineInstruction] = []
        for index in 0..<(edges.count - 1) where edges[index + 1] - edges[index] > 0.0001 {
            let start = edges[index], end = edges[index + 1]
            let middle = (start + end) / 2
            let active = videoLayers.filter { $0.clip.start <= middle && $0.clip.end > middle }
            instructions.append(TimelineInstruction(
                range: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60_000),
                                   duration: CMTime(seconds: end - start, preferredTimescale: 60_000)),
                layers: active, timingTrackID: timingTrack.trackID
            ))
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = TimelineCompositor.self
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(seconds: 1 / project.frameRate,
                                                preferredTimescale: 60_000)
        videoComposition.instructions = instructions
        return RenderedTimeline(composition: composition,
                                videoComposition: videoComposition, audioMix: audioMix)
    }

    private static func titleImage(_ title: String, canvas: CGSize) -> CIImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height),
                                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let font = NSFont.systemFont(ofSize: max(36, canvas.height * 0.075), weight: .bold)
        let attributed = NSAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black, .strokeWidth: -3
        ])
        let size = attributed.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(at: CGPoint(x: (canvas.width - size.width) / 2,
                                    y: (canvas.height - size.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return CIImage(cgImage: context.makeImage()!)
    }

    private static func addAudio(source: AVAssetTrack, range: CMTimeRange, at: CMTime,
                                 clip: TimelineClip, to composition: AVMutableComposition,
                                 parameters: inout [AVAudioMixInputParameters]) throws {
        guard let destination = composition.addMutableTrack(withMediaType: .audio,
                                preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        try destination.insertTimeRange(range, of: source, at: at)
        destination.scaleTimeRange(CMTimeRange(start: at, duration: range.duration),
            toDuration: CMTime(seconds: clip.duration, preferredTimescale: 60_000))
        let parameter = AVMutableAudioMixInputParameters(track: destination)
        let volume = Float(max(0, min(2, clip.volume)))
        let fadeIn = min(clip.fadeIn, clip.duration / 2)
        let fadeOut = min(clip.fadeOut, clip.duration / 2)
        if fadeIn > 0 {
            parameter.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume,
                timeRange: CMTimeRange(start: at,
                    duration: CMTime(seconds: fadeIn, preferredTimescale: 60_000)))
        } else { parameter.setVolume(volume, at: at) }
        if fadeOut > 0 {
            parameter.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: clip.end - fadeOut, preferredTimescale: 60_000),
                    duration: CMTime(seconds: fadeOut, preferredTimescale: 60_000)))
        }
        parameters.append(parameter)
    }
}
