import Foundation
import XCTest
@testable import MotionCut

final class TimelineTests: XCTestCase {
    func testSplitPreservesSourceAndRippleClosesGapAcrossTracks() {
        var project = EditingProject()
        let video = MediaAsset(url: URL(fileURLWithPath: "/tmp/example.mov"),
                               kind: .video, duration: 10)
        let audio = MediaAsset(url: URL(fileURLWithPath: "/tmp/example.wav"),
                               kind: .audio, duration: 10)
        project.media = [video, audio]
        let base = TimelineClip(mediaID: video.id, start: 0, duration: 10)
        project.tracks[1].clips = [base]
        project.tracks[2].clips = [TimelineClip(mediaID: audio.id, start: 0,
                                                duration: 10)]
        let rightID = try! XCTUnwrap(project.split(base.id, at: 4))
        XCTAssertEqual(project.tracks[1].clips[0].duration, 4)
        XCTAssertEqual(project.tracks[1].clips[1].sourceStart, 4)
        XCTAssertEqual(project.tracks[1].clips[1].start, 4)
        XCTAssertTrue(project.delete(rightID, ripple: true))
        XCTAssertEqual(project.duration, 4)
        XCTAssertEqual(project.tracks[2].clips.count, 1)
        XCTAssertEqual(project.tracks[2].clips[0].duration, 4)
    }

    func testMoveAndTrimKeepSourceBounds() {
        var project = EditingProject()
        let media = MediaAsset(url: URL(fileURLWithPath: "/tmp/example.mov"),
                               kind: .video, duration: 5)
        project.media = [media]
        let clip = TimelineClip(mediaID: media.id, start: 0, duration: 5)
        project.tracks[1].clips = [clip]
        XCTAssertTrue(project.trim(clip.id, leading: 1))
        XCTAssertEqual(project.tracks[1].clips[0].sourceStart, 1)
        XCTAssertEqual(project.tracks[1].clips[0].duration, 4)
        XCTAssertTrue(project.trim(clip.id, trailing: 20))
        XCTAssertEqual(project.tracks[1].clips[0].duration, 4)
        XCTAssertTrue(project.move(clip.id, to: 3, on: project.tracks[0].id))
        XCTAssertEqual(project.tracks[0].clips[0].start, 3)
        XCTAssertEqual(project.tracks[0].clips[0].sourceStart, 1)
    }

    func testSplitAndTrimUseSourceTimeAtChangedSpeed() {
        var project = EditingProject()
        let media = MediaAsset(url: URL(fileURLWithPath: "/tmp/fast.mov"),
                               kind: .video, duration: 8)
        project.media = [media]
        let clip = TimelineClip(mediaID: media.id, start: 0, duration: 4, speed: 2)
        project.tracks[1].clips = [clip]
        let rightID = try! XCTUnwrap(project.split(clip.id, at: 1))
        let right = project.tracks[1].clips[1]
        XCTAssertEqual(right.id, rightID)
        XCTAssertEqual(right.sourceStart, 2)
        XCTAssertEqual(right.duration, 3)
        XCTAssertTrue(project.trim(rightID, leading: 2))
        XCTAssertEqual(project.tracks[1].clips[1].sourceStart, 4)
        XCTAssertEqual(project.tracks[1].clips[1].duration, 2)
    }

    func testCubeLUTParsesRedFastestAndRejectsTruncatedData() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".cube")
        defer { try? FileManager.default.removeItem(at: file) }
        let rows = (0..<2).flatMap { blue in
            (0..<2).flatMap { green in
                (0..<2).map { red in "\(red) \(green) \(blue)" }
            }
        }
        try ("LUT_3D_SIZE 2\n" + rows.joined(separator: "\n"))
            .write(to: file, atomically: true, encoding: .utf8)
        let lut = try CubeLUT(url: file)
        XCTAssertEqual(lut.dimension, 2)
        XCTAssertEqual(lut.data.count, 8 * 4 * MemoryLayout<Float>.size)
        let floats = lut.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(Array(floats[0..<4]), [0, 0, 0, 1])
        XCTAssertEqual(Array(floats[4..<8]), [1, 0, 0, 1])
        try "LUT_3D_SIZE 2\n0 0 0".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CubeLUT(url: file))
    }

    func testProjectRoundTripPreservesEditingSettings() throws {
        var project = EditingProject()
        project.stabilizationMode = .cropAndSteady
        project.stabilizationSmoothness = 0.8
        project.stabilizationMaxZoom = 1.6
        project.frameRate = 60
        project.tracks[0].clips = [TimelineClip(title: "Opening", start: 1,
            duration: 3, opacity: 0.7, scale: 1.2, fadeIn: 0.4)]
        let decoded = try JSONDecoder().decode(EditingProject.self,
            from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded, project)
    }
}
