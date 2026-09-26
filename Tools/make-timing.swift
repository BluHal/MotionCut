import AVFoundation
import CoreVideo
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/Timing.mov")
try? FileManager.default.removeItem(at: destination)
let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: 16,
    AVVideoHeightKey: 16
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    kCVPixelBufferWidthKey as String: 16,
    kCVPixelBufferHeightKey as String: 16
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
for frame in 0..<30 {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
    var optional: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &optional)
    let buffer = optional!
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
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
