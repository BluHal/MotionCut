import AVFoundation
import CoreGraphics
import Vision

struct MotionSample {
    let time: CMTime
    let cumulative: CGAffineTransform
    let segment: Int
    let inlierRatio: Double
}

struct MotionAnalysis {
    let samples: [MotionSample]
    let rawSize: CGSize
    let displayTransform: CGAffineTransform
    let displaySize: CGSize
    let duration: CMTime
    let nominalFrameRate: Float
}

enum MotionAnalyzerError: LocalizedError {
    case noVideoTrack
    case readerFailed(String)
    case tooShort

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The file has no video track."
        case .readerFailed(let message): "Could not decode the video: \(message)"
        case .tooShort: "The video needs at least two frames."
        }
    }
}

enum MotionAnalyzer {
    static func analyze(_ url: URL) async throws -> MotionAnalysis {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MotionAnalyzerError.noVideoTrack
        }
        let rawSize = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let bounds = CGRect(origin: .zero, size: rawSize).applying(preferred)
        let displayTransform = preferred.concatenating(
            CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
        )
        let displaySize = CGSize(width: abs(bounds.width), height: abs(bounds.height))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw MotionAnalyzerError.readerFailed(reader.error?.localizedDescription ?? "Unknown error")
        }

        var samples: [MotionSample] = []
        var previous: GrayFrame?
        var previousFlowBuffer: CVPixelBuffer?
        var cumulative = CGAffineTransform.identity
        var segment = 0

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let image = GrayFrame(pixelBuffer: buffer, maxWidth: 480)
            let flowBuffer = image.makePixelBuffer()
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)

            if let previous {
                let estimate: Estimate
                if let previousFlowBuffer, let flowBuffer,
                   let visionEstimate = estimateVision(from: previousFlowBuffer,
                                                       to: flowBuffer, texture: previous),
                   visionEstimate.matches >= 8 && visionEstimate.inlierRatio >= 0.28 {
                    estimate = visionEstimate
                } else {
                    estimate = estimateMotion(from: previous, to: image)
                }
                if estimate.matches >= 8 && estimate.inlierRatio >= 0.28 {
                    // The estimate is in analysis pixels; convert it to decoded-pixel coordinates.
                    let toAnalysis = CGAffineTransform(scaleX: image.scale, y: image.scale)
                    let toRaw = CGAffineTransform(scaleX: 1 / image.scale, y: 1 / image.scale)
                    let rawMotion = toAnalysis.concatenating(estimate.transform).concatenating(toRaw)
                    cumulative = cumulative.concatenating(rawMotion)
                } else {
                    // Do not smooth motion across a cut or an untrackable transition.
                    segment += 1
                    cumulative = .identity
                }
                samples.append(MotionSample(time: timestamp, cumulative: cumulative,
                                            segment: segment, inlierRatio: estimate.inlierRatio))
            } else {
                samples.append(MotionSample(time: timestamp, cumulative: .identity,
                                            segment: segment, inlierRatio: 1))
            }
            previous = image
            previousFlowBuffer = flowBuffer
        }

        if reader.status == .failed {
            throw MotionAnalyzerError.readerFailed(reader.error?.localizedDescription ?? "Unknown error")
        }
        guard samples.count >= 2 else { throw MotionAnalyzerError.tooShort }
        return MotionAnalysis(samples: samples, rawSize: rawSize,
                              displayTransform: displayTransform, displaySize: displaySize,
                              duration: duration, nominalFrameRate: nominalFrameRate)
    }

    private struct GrayFrame {
        let width: Int
        let height: Int
        let scale: CGFloat
        let pixels: [UInt8]

        init(pixelBuffer: CVPixelBuffer, maxWidth: Int) {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
            let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
            scale = min(1, CGFloat(maxWidth) / CGFloat(sourceWidth))
            width = max(1, Int(CGFloat(sourceWidth) * scale))
            height = max(1, Int(CGFloat(sourceHeight) * scale))
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            var result = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                let sy = min(sourceHeight - 1, Int(CGFloat(y) / scale))
                for x in 0..<width {
                    let sx = min(sourceWidth - 1, Int(CGFloat(x) / scale))
                    let offset = sy * stride + sx * 4
                    let b = Int(base[offset]), g = Int(base[offset + 1]), r = Int(base[offset + 2])
                    result[y * width + x] = UInt8((29 * b + 150 * g + 77 * r) >> 8)
                }
            }
            pixels = result
        }

        subscript(_ x: Int, _ y: Int) -> Int { Int(pixels[y * width + x]) }

        func makePixelBuffer() -> CVPixelBuffer? {
            var optional: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                             kCVPixelFormatType_32BGRA, nil, &optional)
            guard status == kCVReturnSuccess, let buffer = optional else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let value = pixels[y * width + x]
                    let offset = y * stride + x * 4
                    base[offset] = value
                    base[offset + 1] = value
                    base[offset + 2] = value
                    base[offset + 3] = 255
                }
            }
            return buffer
        }
    }

    private struct Match {
        let from: CGPoint
        let to: CGPoint
    }

    private struct Estimate {
        let transform: CGAffineTransform
        let matches: Int
        let inlierRatio: Double
    }

    private static func estimateVision(from previous: CVPixelBuffer, to current: CVPixelBuffer,
                                       texture: GrayFrame) -> Estimate? {
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: current)
        request.computationAccuracy = .high
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        do {
            try VNImageRequestHandler(cvPixelBuffer: previous).perform([request])
        } catch { return nil }
        guard let flow = request.results?.first?.pixelBuffer,
              CVPixelBufferGetPixelFormatType(flow) == kCVPixelFormatType_TwoComponent32Float else {
            return nil
        }
        CVPixelBufferLockBaseAddress(flow, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(flow, .readOnly) }
        let flowWidth = CVPixelBufferGetWidth(flow), flowHeight = CVPixelBufferGetHeight(flow)
        guard flowWidth > 0, flowHeight > 0 else { return nil }
        let base = CVPixelBufferGetBaseAddress(flow)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(flow)
        let scaleX = CGFloat(texture.width) / CGFloat(flowWidth)
        let scaleY = CGFloat(texture.height) / CGFloat(flowHeight)
        var matches: [Match] = []
        for gy in 1..<11 {
            for gx in 1..<15 {
                let x = gx * flowWidth / 15, y = gy * flowHeight / 11
                let px = min(texture.width - 3, max(2, Int(CGFloat(x) * scaleX)))
                let py = min(texture.height - 3, max(2, Int(CGFloat(y) * scaleY)))
                let textureScore = abs(texture[px + 2, py] - texture[px - 2, py])
                    + abs(texture[px, py + 2] - texture[px, py - 2])
                guard textureScore > 13 else { continue }
                let row = UnsafeRawPointer(base.advanced(by: y * stride)).assumingMemoryBound(to: Float.self)
                let dx = CGFloat(row[x * 2]) * scaleX
                let dy = CGFloat(row[x * 2 + 1]) * scaleY
                guard dx.isFinite, dy.isFinite, abs(dx) < 120, abs(dy) < 120 else { continue }
                matches.append(Match(from: CGPoint(x: px, y: py),
                                     to: CGPoint(x: CGFloat(px) + dx, y: CGFloat(py) + dy)))
            }
        }
        return robustEstimate(matches)
    }

    private static func estimateMotion(from a: GrayFrame, to b: GrayFrame) -> Estimate {
        guard a.width == b.width && a.height == b.height else {
            return Estimate(transform: .identity, matches: 0, inlierRatio: 0)
        }
        let radius = 5
        let search = 18
        let columns = 9, rows = 6
        var matches: [Match] = []

        for gy in 0..<rows {
            for gx in 0..<columns {
                let centerX = (gx * 2 + 1) * a.width / (columns * 2)
                let centerY = (gy * 2 + 1) * a.height / (rows * 2)
                var bestTexture = 0
                var point = (centerX, centerY)
                for oy in stride(from: -8, through: 8, by: 4) {
                    for ox in stride(from: -8, through: 8, by: 4) {
                        let x = centerX + ox, y = centerY + oy
                        guard x > radius + search, y > radius + search,
                              x < a.width - radius - search, y < a.height - radius - search else { continue }
                        var texture = 0
                        for dy in stride(from: -4, through: 4, by: 2) {
                            for dx in stride(from: -4, through: 4, by: 2) {
                                texture += abs(a[x + dx + 1, y + dy] - a[x + dx - 1, y + dy])
                                texture += abs(a[x + dx, y + dy + 1] - a[x + dx, y + dy - 1])
                            }
                        }
                        if texture > bestTexture { bestTexture = texture; point = (x, y) }
                    }
                }
                guard bestTexture > 220 else { continue }
                let (x, y) = point
                var bestScore = Int.max
                var bestOffset = (0, 0)
                for dy in stride(from: -search, through: search, by: 2) {
                    for dx in stride(from: -search, through: search, by: 2) {
                        var score = 0
                        for py in stride(from: -radius, through: radius, by: 2) {
                            for px in stride(from: -radius, through: radius, by: 2) {
                                score += abs(a[x + px, y + py] - b[x + dx + px, y + dy + py])
                            }
                        }
                        if score < bestScore {
                            bestScore = score; bestOffset = (dx, dy)
                        }
                    }
                }
                guard bestScore < 1100 else { continue }
                var refined = bestOffset
                var refinedScore = Int.max
                for dy in (bestOffset.1 - 1)...(bestOffset.1 + 1) {
                    for dx in (bestOffset.0 - 1)...(bestOffset.0 + 1) {
                        var score = 0
                        for py in -radius...radius {
                            for px in -radius...radius {
                                score += abs(a[x + px, y + py] - b[x + dx + px, y + dy + py])
                            }
                        }
                        if score < refinedScore { refinedScore = score; refined = (dx, dy) }
                    }
                }
                matches.append(Match(from: CGPoint(x: x, y: y),
                                     to: CGPoint(x: x + refined.0, y: y + refined.1)))
            }
        }

        return robustEstimate(matches)
    }

    private static func robustEstimate(_ matches: [Match]) -> Estimate {
        guard matches.count >= 8 else { return Estimate(transform: .identity, matches: matches.count, inlierRatio: 0) }
        var bestInliers: [Match] = []
        var state: UInt64 = 0x9E3779B97F4A7C15
        func randomIndex(_ count: Int) -> Int {
            state = state &* 2862933555777941757 &+ 3037000493
            return Int((state >> 32) % UInt64(count))
        }
        for _ in 0..<120 {
            let first = randomIndex(matches.count)
            let second = randomIndex(matches.count)
            guard first != second,
                  let candidate = fitSimilarity([matches[first], matches[second]]) else { continue }
            let inliers = matches.filter {
                let predicted = $0.from.applying(candidate)
                return hypot(predicted.x - $0.to.x, predicted.y - $0.to.y) < 2.8
            }
            if inliers.count > bestInliers.count { bestInliers = inliers }
        }
        let ratio = Double(bestInliers.count) / Double(matches.count)
        let transform = fitSimilarity(bestInliers) ?? .identity
        return Estimate(transform: transform, matches: bestInliers.count, inlierRatio: ratio)
    }

    private static func fitSimilarity(_ matches: [Match]) -> CGAffineTransform? {
        guard matches.count >= 2 else { return nil }
        let n = CGFloat(matches.count)
        let ax = matches.reduce(CGFloat(0)) { $0 + $1.from.x } / n
        let ay = matches.reduce(CGFloat(0)) { $0 + $1.from.y } / n
        let bx = matches.reduce(CGFloat(0)) { $0 + $1.to.x } / n
        let by = matches.reduce(CGFloat(0)) { $0 + $1.to.y } / n
        var dot: CGFloat = 0, cross: CGFloat = 0, norm: CGFloat = 0
        for match in matches {
            let x = match.from.x - ax, y = match.from.y - ay
            let u = match.to.x - bx, v = match.to.y - by
            dot += x * u + y * v
            cross += x * v - y * u
            norm += x * x + y * y
        }
        guard norm > 1 else { return nil }
        let a = dot / norm, b = cross / norm
        let scale = hypot(a, b)
        guard scale > 0.85 && scale < 1.15 else { return nil }
        return CGAffineTransform(a: a, b: b, c: -b, d: a,
                                 tx: bx - a * ax + b * ay,
                                 ty: by - b * ax - a * ay)
    }
}
