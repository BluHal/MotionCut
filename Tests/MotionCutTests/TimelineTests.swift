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

    func testGroupMoveAcrossTracksKeepsRelativeTimingAndRejectsLockedLane() {
        var project = EditingProject()
        let first = TimelineClip(title: "One", start: 1, duration: 2)
        let second = TimelineClip(title: "Two", start: 4, duration: 2)
        project.tracks[1].clips = [first, second]
        XCTAssertTrue(project.move([first.id, second.id], by: 3, trackOffset: -1))
        XCTAssertEqual(project.tracks[0].clips.map(\.start), [4, 7])
        XCTAssertEqual(project.tracks[1].clips.count, 0)
        project.tracks[1].isLocked = true
        let unchanged = project
        XCTAssertFalse(project.move([first.id, second.id], by: -2, trackOffset: 1))
        XCTAssertEqual(project, unchanged)
    }

    func testBladeDragSplitsRangeAcrossTracksAndSelectsMiddle() {
        var project = EditingProject()
        let video = TimelineClip(title: "Video", start: 0, duration: 10)
        let audio = TimelineClip(title: "Audio", start: 0, duration: 10)
        project.tracks[1].clips = [video]
        project.tracks[2].clips = [audio]
        let middle = project.cutRange(from: 6, to: 2)
        XCTAssertEqual(middle.count, 2)
        XCTAssertEqual(project.tracks[1].clips.map(\.duration), [2, 4, 4])
        XCTAssertEqual(project.tracks[2].clips.map(\.start), [0, 2, 6])
        XCTAssertTrue(project.tracks.flatMap(\.clips)
            .filter { middle.contains($0.id) }.allSatisfy { $0.start == 2 && $0.end == 6 })
    }

    func testCutBeforeAndAfterPreservesSourceOffset() {
        var project = EditingProject()
        let source = MediaAsset(url: URL(fileURLWithPath: "/tmp/source.mov"),
                                kind: .video, duration: 20)
        project.media = [source]
        let clip = TimelineClip(mediaID: source.id, start: 2, duration: 5, speed: 2)
        project.tracks[1].clips = [clip]
        XCTAssertEqual(project.trim([clip.id], at: 4, removeBefore: true), [clip.id])
        XCTAssertEqual(project.tracks[1].clips[0].start, 4)
        XCTAssertEqual(project.tracks[1].clips[0].sourceStart, 4)
        XCTAssertEqual(project.trim([clip.id], at: 6, removeBefore: false), [clip.id])
        XCTAssertEqual(project.tracks[1].clips[0].duration, 2)
    }

    func testMultiRippleDeleteClosesDisjointRangesAcrossTracks() {
        var project = EditingProject()
        let a = TimelineClip(title: "A", start: 0, duration: 2)
        let b = TimelineClip(title: "B", start: 2, duration: 2)
        let c = TimelineClip(title: "C", start: 4, duration: 2)
        let d = TimelineClip(title: "D", start: 6, duration: 2)
        let music = TimelineClip(title: "Music", start: 0, duration: 8)
        project.tracks[1].clips = [a, b, c, d]
        project.tracks[2].clips = [music]
        XCTAssertTrue(project.delete([b.id, d.id], ripple: true))
        XCTAssertEqual(project.tracks[1].clips.map(\.title), ["A", "C"])
        XCTAssertEqual(project.tracks[1].clips.map(\.start), [0, 2])
        XCTAssertEqual(project.tracks[2].clips.map(\.duration), [2, 2])
        XCTAssertEqual(project.duration, 4)
    }

    @MainActor
    func testCommandAndShiftSelection() {
        let editor = StudioModel()
        let a = TimelineClip(title: "A", start: 0, duration: 1)
        let b = TimelineClip(title: "B", start: 1, duration: 1)
        let c = TimelineClip(title: "C", start: 2, duration: 1)
        editor.project.tracks[1].clips = [a, b, c]
        editor.selectOnly(a.id)
        editor.selectClip(c.id, range: true)
        XCTAssertEqual(editor.selectedClipIDs, [a.id, b.id, c.id])
        editor.selectClip(b.id, additive: true)
        XCTAssertEqual(editor.selectedClipIDs, [a.id, c.id])
        editor.selectClip(c.id)
        XCTAssertEqual(editor.selectedClipIDs, [c.id])
    }
}
