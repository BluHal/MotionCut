import AVFoundation
import Foundation

func horizontalShifts(_ url: URL) throws -> [Int] {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else { return [] }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ])
    reader.add(output)
    reader.startReading()
    var previous: [UInt8]?
    var shifts: [Int] = []
    while let sample = output.copyNextSampleBuffer(),
          let buffer = CMSampleBufferGetImageBuffer(sample) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var line = [UInt8](repeating: 0, count: width)
        let y = height / 2
        for x in 0..<width { line[x] = base[y * bytesPerRow + x * 4 + 1] }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        if let previous {
            var best = (shift: 0, score: Int.max)
            for shift in -12...12 {
                var score = 0
                for x in 25..<(width - 25) {
                    score += abs(Int(previous[x]) - Int(line[x + shift]))
                }
                if score < best.score { best = (shift, score) }
            }
            shifts.append(best.shift)
        }
        previous = line
    }
    return shifts
}

for name in CommandLine.arguments.dropFirst() {
    let shifts = try horizontalShifts(URL(fileURLWithPath: name))
    let mean = Double(shifts.reduce(0, +)) / Double(max(1, shifts.count))
    let rms = sqrt(shifts.map { pow(Double($0) - mean, 2) }.reduce(0, +) / Double(max(1, shifts.count)))
    print("\(name): \(shifts.count + 1) frames, horizontal step jitter RMS \(String(format: "%.2f", rms)) px")
}
