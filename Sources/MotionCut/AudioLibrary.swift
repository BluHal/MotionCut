import AVFoundation
import Foundation

struct LibrarySound: Identifiable, Hashable {
    let id: String
    let title: String
    let category: String
    let duration: Double

    static let all: [LibrarySound] = [
        .init(id: "soft-pulse", title: "Soft Pulse", category: "Music", duration: 8),
        .init(id: "warm-synth", title: "Warm Synth", category: "Music", duration: 8),
        .init(id: "lofi-beat", title: "Lo-Fi Beat", category: "Music", duration: 8),
        .init(id: "ambient-air", title: "Ambient Air", category: "Ambience", duration: 12),
        .init(id: "rain-room", title: "Rain Room", category: "Ambience", duration: 12),
        .init(id: "whoosh", title: "Whoosh", category: "Effects", duration: 1.2),
        .init(id: "impact", title: "Impact", category: "Effects", duration: 0.8),
        .init(id: "click", title: "Click", category: "Effects", duration: 0.25),
        .init(id: "rise", title: "Rise", category: "Effects", duration: 2)
    ]
}

enum AudioLibrary {
    static func file(for sound: LibrarySound) throws -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
            .appendingPathComponent("MotionCut/Audio Library", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(sound.id + ".wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let rate = 44_100.0
        let frames = AVAudioFrameCount(sound.duration * rate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            let t = Double(index) / rate
            let noise = Double((index &* 1_103_515_245 &+ 12_345) & 65_535) / 32_768 - 1
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            let value: Double
            switch sound.id {
            case "soft-pulse":
                let kick = sin(2 * .pi * (65 - 24 * beat) * t) * exp(-18 * beat)
                value = 0.28 * kick + 0.08 * sin(2 * .pi * 220 * t)
            case "warm-synth":
                let notes = [220.0, 261.63, 329.63, 293.66]
                let note = notes[Int(t / 2) % notes.count]
                value = 0.15 * sin(2 * .pi * note * t) +
                    0.07 * sin(2 * .pi * note * 1.5 * t) +
                    0.08 * sin(2 * .pi * 55 * t) * exp(-12 * beat)
            case "lofi-beat":
                let kick = sin(2 * .pi * 58 * t) * exp(-20 * beat)
                let hat = noise * exp(-70 * (t.truncatingRemainder(dividingBy: 0.25)))
                value = 0.30 * kick + 0.07 * hat +
                    0.09 * sin(2 * .pi * [164.81, 196.0, 220.0, 196.0][Int(t / 2) % 4] * t)
            case "ambient-air":
                value = 0.10 * sin(2 * .pi * 110 * t) +
                    0.09 * sin(2 * .pi * 164.81 * t) +
                    0.04 * sin(2 * .pi * 220.2 * t)
            case "rain-room":
                value = 0.12 * noise * (0.75 + 0.25 * sin(2 * .pi * 0.18 * t)) +
                    0.025 * sin(2 * .pi * 90 * t)
            case "whoosh":
                value = 0.35 * noise * sin(.pi * min(1, t / sound.duration)) *
                    (0.3 + 0.7 * t / sound.duration)
            case "impact":
                value = 0.55 * sin(2 * .pi * (90 - 45 * t) * t) * exp(-8 * t) +
                    0.22 * noise * exp(-20 * t)
            case "click":
                value = 0.4 * noise * exp(-100 * t)
            case "rise":
                value = 0.26 * sin(2 * .pi * (180 + 300 * t) * t) *
                    pow(min(1, t / sound.duration), 1.3) +
                    0.08 * noise * pow(min(1, t / sound.duration), 2)
            default: value = 0
            }
            let fade = min(1, t / 0.015, (sound.duration - t) / 0.04)
            samples[index] = Float(max(-1, min(1, value * max(0, fade))))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
