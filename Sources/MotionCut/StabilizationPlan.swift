import AVFoundation
import CoreGraphics

struct StabilizedFrame {
    let time: CMTime
    let correction: CGAffineTransform
    let inlierRatio: Double
}

struct StabilizationPlan {
    let frames: [StabilizedFrame]
    let zoom: CGFloat
    let appliedFraction: CGFloat
    let averageConfidence: Double

    init(analysis: MotionAnalysis, strength: Double, maxZoom: Double) {
        let samples = analysis.samples
        let center = CGPoint(x: analysis.rawSize.width / 2, y: analysis.rawSize.height / 2)
        let radius = max(1, min(analysis.rawSize.width, analysis.rawSize.height) / 2)
        var corrections = [CGAffineTransform](repeating: .identity, count: samples.count)

        var start = 0
        while start < samples.count {
            var end = start + 1
            while end < samples.count && samples[end].segment == samples[start].segment { end += 1 }
            let segment = Array(samples[start..<end])
            let paths = segment.map { sample -> (CGFloat, CGFloat, CGFloat, CGFloat) in
                let mapped = center.applying(sample.cumulative)
                let scale = max(0.01, hypot(sample.cumulative.a, sample.cumulative.b))
                return (mapped.x, mapped.y,
                        atan2(sample.cumulative.b, sample.cumulative.a) * radius,
                        log(scale) * radius)
            }
            let x = Self.smooth(paths.map { Double($0.0) }, strength: strength)
            let y = Self.smooth(paths.map { Double($0.1) }, strength: strength)
            let angles = Self.unwrap(paths.map { Double($0.2) }, period: Double.pi * 2 * Double(radius))
            let theta = Self.smooth(angles, strength: strength)
            let logarithmicScale = Self.smooth(paths.map { Double($0.3) }, strength: strength)

            for local in segment.indices {
                let desired = Self.similarity(center: center,
                                         mappedCenter: CGPoint(x: x[local], y: y[local]),
                                         angle: CGFloat(theta[local]) / radius,
                                         scale: exp(CGFloat(logarithmicScale[local]) / radius))
                corrections[start + local] = segment[local].cumulative.inverted().concatenating(desired)
            }
            start = end
        }

        let permittedZoom = CGFloat(max(1, maxZoom))
        var fraction: CGFloat = 1
        if Self.requiredZoom(corrections, center: center, size: analysis.rawSize) > permittedZoom {
            var low: CGFloat = 0, high: CGFloat = 1
            for _ in 0..<22 {
                let middle = (low + high) / 2
                let scaled = corrections.map { Self.interpolate($0, fraction: middle, center: center) }
                if Self.requiredZoom(scaled, center: center, size: analysis.rawSize) <= permittedZoom {
                    low = middle
                } else { high = middle }
            }
            fraction = low
            corrections = corrections.map { Self.interpolate($0, fraction: fraction, center: center) }
        }
        let neededZoom = min(permittedZoom, Self.requiredZoom(corrections, center: center, size: analysis.rawSize))
        zoom = min(permittedZoom, max(1, neededZoom * 1.005))
        appliedFraction = fraction
        averageConfidence = samples.map(\.inlierRatio).reduce(0, +) / Double(samples.count)
        frames = zip(samples, corrections).map {
            StabilizedFrame(time: $0.0.time, correction: $0.1, inlierRatio: $0.0.inlierRatio)
        }
    }

    private static func unwrap(_ values: [Double], period: Double) -> [Double] {
        guard !values.isEmpty else { return [] }
        var result = [values[0]]
        for value in values.dropFirst() {
            var next = value
            while next - result.last! > period / 2 { next -= period }
            while next - result.last! < -period / 2 { next += period }
            result.append(next)
        }
        return result
    }

    // IRLS minimizes fidelity plus an L1-like acceleration penalty.
    // It favors steady pans and stationary intervals over a continuously drifting average.
    private static func smooth(_ input: [Double], strength: Double) -> [Double] {
        guard input.count >= 4, strength > 0 else { return input }
        let lambda = 1.0 + 320.0 * strength * strength
        var solution = input
        for _ in 0..<5 {
            let weights = (0..<(input.count - 2)).map { i -> Double in
                let acceleration = solution[i] - 2 * solution[i + 1] + solution[i + 2]
                return 1 / sqrt(acceleration * acceleration + 0.75 * 0.75)
            }
            solution = conjugateGradient(rhs: input, initial: solution, weights: weights, lambda: lambda)
        }
        return solution
    }

    private static func conjugateGradient(rhs: [Double], initial: [Double],
                                          weights: [Double], lambda: Double) -> [Double] {
        func multiply(_ values: [Double]) -> [Double] {
            var output = values
            for i in weights.indices {
                let acceleration = values[i] - 2 * values[i + 1] + values[i + 2]
                let amount = lambda * weights[i] * acceleration
                output[i] += amount
                output[i + 1] -= 2 * amount
                output[i + 2] += amount
            }
            return output
        }
        func dot(_ a: [Double], _ b: [Double]) -> Double {
            zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        }
        var x = initial
        let ax = multiply(x)
        var residual = zip(rhs, ax).map(-)
        var direction = residual
        var residualNorm = dot(residual, residual)
        let tolerance = max(1e-8, dot(rhs, rhs) * 1e-10)
        for _ in 0..<min(160, rhs.count * 2) {
            if residualNorm < tolerance { break }
            let ad = multiply(direction)
            let denominator = dot(direction, ad)
            if denominator <= 0 { break }
            let step = residualNorm / denominator
            for i in x.indices {
                x[i] += step * direction[i]
                residual[i] -= step * ad[i]
            }
            let nextNorm = dot(residual, residual)
            let beta = nextNorm / residualNorm
            for i in direction.indices { direction[i] = residual[i] + beta * direction[i] }
            residualNorm = nextNorm
        }
        return x
    }

    private static func similarity(center: CGPoint, mappedCenter: CGPoint,
                                   angle: CGFloat, scale: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: mappedCenter.x, y: mappedCenter.y))
    }

    private static func interpolate(_ transform: CGAffineTransform, fraction: CGFloat,
                                    center: CGPoint) -> CGAffineTransform {
        let mapped = center.applying(transform)
        let angle = atan2(transform.b, transform.a)
        let scale = max(0.01, hypot(transform.a, transform.b))
        return similarity(center: center,
                          mappedCenter: CGPoint(x: center.x + (mapped.x - center.x) * fraction,
                                                y: center.y + (mapped.y - center.y) * fraction),
                          angle: angle * fraction,
                          scale: exp(log(scale) * fraction))
    }

    private static func requiredZoom(_ transforms: [CGAffineTransform], center: CGPoint,
                                     size: CGSize) -> CGFloat {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
                       CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
        func fits(_ zoom: CGFloat, _ transform: CGAffineTransform) -> Bool {
            let zoomTransform = CGAffineTransform(translationX: -center.x, y: -center.y)
                .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            let inverse = transform.concatenating(zoomTransform).inverted()
            return corners.allSatisfy { corner in
                let point = corner.applying(inverse)
                return point.x >= -0.5 && point.y >= -0.5 &&
                    point.x <= size.width + 0.5 && point.y <= size.height + 0.5
            }
        }
        var required: CGFloat = 1
        for transform in transforms {
            if fits(required, transform) { continue }
            var low = required, high: CGFloat = 4
            if !fits(high, transform) { return high }
            for _ in 0..<17 {
                let middle = (low + high) / 2
                if fits(middle, transform) { high = middle } else { low = middle }
            }
            required = high
        }
        return required
    }
}
