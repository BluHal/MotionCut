import AVFoundation

enum VideoCompositionBuilder {
    static func build(track: AVAssetTrack, analysis: MotionAnalysis,
                      plan: StabilizationPlan) -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.renderSize = analysis.displaySize
        let rate = analysis.nominalFrameRate > 1 ? Double(analysis.nominalFrameRate) : 30
        composition.frameDuration = CMTime(seconds: 1 / rate, preferredTimescale: 60_000)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: analysis.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let center = CGPoint(x: analysis.rawSize.width / 2, y: analysis.rawSize.height / 2)
        let zoom = CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: plan.zoom, y: plan.zoom))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))

        for frame in plan.frames {
            let transform = frame.correction.concatenating(zoom)
                .concatenating(analysis.displayTransform)
            layer.setTransform(transform, at: frame.time)
        }
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        return composition
    }
}
