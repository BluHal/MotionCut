import CoreImage
import Foundation

enum CubeLUTError: LocalizedError {
    case malformed(String)
    var errorDescription: String? {
        switch self { case .malformed(let detail): "Invalid .cube LUT: \(detail)" }
    }
}

struct CubeLUT: Sendable {
    let dimension: Int
    let data: Data
    let domainMin: [Float]
    let domainMax: [Float]

    init(url: URL) throws {
        let source = try String(contentsOf: url, encoding: .utf8)
        var threeDimensionalSize: Int?
        var oneDimensionalSize: Int?
        var rows: [[Float]] = []
        var minimum: [Float] = [0, 0, 0]
        var maximum: [Float] = [1, 1, 1]
        for rawLine in source.components(separatedBy: .newlines) {
            let line = String(rawLine.split(separator: "#", maxSplits: 1).first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            switch fields[0].uppercased() {
            case "TITLE": continue
            case "LUT_3D_SIZE":
                guard fields.count == 2, let size = Int(fields[1]), (2...64).contains(size) else {
                    throw CubeLUTError.malformed("3D size must be 2–64")
                }
                threeDimensionalSize = size
            case "LUT_1D_SIZE":
                guard fields.count == 2, let size = Int(fields[1]), (2...65536).contains(size) else {
                    throw CubeLUTError.malformed("1D size must be 2–65536")
                }
                oneDimensionalSize = size
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard fields.count == 4,
                      let values = Self.floats(Array(fields.dropFirst())) else {
                    throw CubeLUTError.malformed("invalid domain")
                }
                if fields[0].uppercased() == "DOMAIN_MIN" { minimum = values }
                else { maximum = values }
            default:
                guard fields.count == 3, let values = Self.floats(fields) else {
                    throw CubeLUTError.malformed("unexpected line: \(line)")
                }
                rows.append(values)
            }
        }
        guard zip(minimum, maximum).allSatisfy({ $0.0 < $0.1 }) else {
            throw CubeLUTError.malformed("domain maximum must exceed minimum")
        }
        domainMin = minimum
        domainMax = maximum

        let cubeValues: [[Float]]
        if let size = threeDimensionalSize {
            guard oneDimensionalSize == nil else {
                throw CubeLUTError.malformed("combined 1D and 3D tables are not supported")
            }
            guard rows.count == size * size * size else {
                throw CubeLUTError.malformed("expected \(size * size * size) color rows, found \(rows.count)")
            }
            dimension = size
            cubeValues = rows
        } else if let size = oneDimensionalSize {
            guard rows.count == size else {
                throw CubeLUTError.malformed("expected \(size) color rows, found \(rows.count)")
            }
            dimension = 33
            func sample(_ input: Float, channel: Int) -> Float {
                let position = input * Float(size - 1)
                let lower = min(size - 1, Int(position))
                let upper = min(size - 1, lower + 1)
                let fraction = position - Float(lower)
                return rows[lower][channel] * (1 - fraction) + rows[upper][channel] * fraction
            }
            var converted: [[Float]] = []
            converted.reserveCapacity(dimension * dimension * dimension)
            for blue in 0..<dimension {
                for green in 0..<dimension {
                    for red in 0..<dimension {
                        let divisor = Float(dimension - 1)
                        converted.append([sample(Float(red) / divisor, channel: 0),
                                          sample(Float(green) / divisor, channel: 1),
                                          sample(Float(blue) / divisor, channel: 2)])
                    }
                }
            }
            cubeValues = converted
        } else {
            throw CubeLUTError.malformed("missing LUT_3D_SIZE or LUT_1D_SIZE")
        }
        var packed: [Float] = []
        packed.reserveCapacity(cubeValues.count * 4)
        for values in cubeValues { packed.append(contentsOf: values + [1]) }
        data = packed.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func applying(to image: CIImage) -> CIImage {
        var input = image
        if domainMin != [0, 0, 0] || domainMax != [1, 1, 1] {
            let scale = zip(domainMin, domainMax).map { 1 / ($0.1 - $0.0) }
            let bias = zip(domainMin, scale).map { -$0.0 * $0.1 }
            input = input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(scale[0]), y: 0, z: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(scale[1]), z: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scale[2])),
                "inputBiasVector": CIVector(x: CGFloat(bias[0]), y: CGFloat(bias[1]),
                                              z: CGFloat(bias[2]))
            ])
        }
        return input.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": data
        ])
    }

    private static func floats(_ fields: [String]) -> [Float]? {
        let values = fields.compactMap(Float.init)
        return values.count == fields.count && values.allSatisfy(\.isFinite) ? values : nil
    }
}
