import AVFoundation
import CoreVideo
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/motioncut-fixture.mov")
try? FileManager.default.removeItem(at: destination)
let width = 320, height = 180, count = 60
let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
for frame in 0..<count {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    var optional: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                        nil, &optional)
    let buffer = optional!
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let shake = [0, 3, -2, 5, -3, 2][frame % 6] + frame / 18
    for y in 0..<height {
        for x in 0..<width {
            let xx = x + shake
            let hash = ((xx * 1103515245 &+ y * 12345) >> 6) & 255
            let bright = (xx % 36 < 2 || y % 29 < 2 || (xx / 27 + y / 23) % 2 == 0)
            let value = UInt8(max(0, min(255, (bright ? 105 : 22) + hash / 3)))
            let offset = y * stride + x * 4
            base[offset] = value
            base[offset + 1] = value
            base[offset + 2] = value
            base[offset + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) else {
        fatalError(writer.error?.localizedDescription ?? "Unable to append frame")
    }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fatalError(writer.error?.localizedDescription ?? "Writer failed") }
print(destination.path)
