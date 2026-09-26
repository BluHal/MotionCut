import Foundation

enum MediaKind: String, Codable {
    case video, audio, image
}

struct MediaAsset: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL
    var kind: MediaKind
    var duration: Double
    var width: Int = 0
    var height: Int = 0
    var name: String { url.lastPathComponent }
}

enum TrackKind: String, Codable {
    case video, audio
}

struct TimelineClip: Identifiable, Codable, Equatable {
    var id = UUID()
    var mediaID: UUID?
    var title: String?
    var start: Double
    var sourceStart: Double = 0
    var duration: Double
    var volume: Double = 1
    var opacity: Double = 1
    var speed: Double = 1
    var scale: Double = 1
    var positionX: Double = 0
    var positionY: Double = 0
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var sourceAudioEnabled = true
    var lutID: UUID?
    var stabilized = false
    var end: Double { start + duration }
    var isTitle: Bool { title != nil }
}

struct TimelineTrack: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var kind: TrackKind
    var clips: [TimelineClip] = []
    var isMuted = false
    var isLocked = false
}

struct LUTAsset: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL
    var name: String {
        let stem = url.deletingPathExtension().lastPathComponent
        let prefix = String(stem.prefix(36))
        if UUID(uuidString: prefix) != nil, stem.dropFirst(36).first == "-" {
            return String(stem.dropFirst(37))
        }
        return stem
    }
}

struct EditingProject: Codable, Equatable {
    var name = "Untitled Project"
    var canvasWidth = 1920
    var canvasHeight = 1080
    var frameRate = 30.0
    var stabilizationMode: StabilizationMode = .balanced
    var stabilizationSmoothness = 0.55
    var stabilizationMaxZoom = 1.20
    var media: [MediaAsset] = []
    var luts: [LUTAsset] = []
    var tracks: [TimelineTrack] = [
        TimelineTrack(name: "V2", kind: .video),
        TimelineTrack(name: "V1", kind: .video),
        TimelineTrack(name: "A1", kind: .audio),
        TimelineTrack(name: "A2", kind: .audio)
    ]

    var duration: Double {
        max(0, tracks.flatMap(\.clips).map(\.end).max() ?? 0)
    }

    func media(for clip: TimelineClip) -> MediaAsset? {
        guard let id = clip.mediaID else { return nil }
        return media.first { $0.id == id }
    }

    func clipLocation(_ id: UUID) -> (track: Int, clip: Int)? {
        for track in tracks.indices {
            if let clip = tracks[track].clips.firstIndex(where: { $0.id == id }) {
                return (track, clip)
            }
        }
        return nil
    }

    mutating func split(_ id: UUID, at time: Double) -> UUID? {
        guard let location = clipLocation(id), !tracks[location.track].isLocked else { return nil }
        let original = tracks[location.track].clips[location.clip]
        let offset = time - original.start
        guard offset > 0.05, offset < original.duration - 0.05 else { return nil }
        tracks[location.track].clips[location.clip].duration = offset
        tracks[location.track].clips[location.clip].fadeOut = 0
        var right = original
        right.id = UUID()
        right.start = time
        right.sourceStart += offset * original.speed
        right.duration -= offset
        right.fadeIn = 0
        tracks[location.track].clips.insert(right, at: location.clip + 1)
        return right.id
    }

    mutating func delete(_ id: UUID, ripple: Bool) -> Bool {
        guard let location = clipLocation(id), !tracks[location.track].isLocked else { return false }
        let removed = tracks[location.track].clips.remove(at: location.clip)
        guard ripple else { return true }
        let cutStart = removed.start
        let cutEnd = removed.end
        for track in tracks.indices where !tracks[track].isLocked {
            var result: [TimelineClip] = []
            for clip in tracks[track].clips {
                if clip.end <= cutStart {
                    result.append(clip)
                } else if clip.start >= cutEnd {
                    var shifted = clip
                    shifted.start -= removed.duration
                    result.append(shifted)
                } else if clip.start < cutStart && clip.end > cutEnd {
                    var left = clip
                    left.duration = cutStart - clip.start
                    var right = clip
                    right.id = UUID()
                    right.sourceStart += (cutEnd - clip.start) * clip.speed
                    right.start = cutStart
                    right.duration = clip.end - cutEnd
                    result.append(contentsOf: [left, right])
                } else if clip.start < cutStart {
                    var left = clip
                    left.duration = cutStart - clip.start
                    result.append(left)
                } else if clip.end > cutEnd {
                    var right = clip
                    right.sourceStart += (cutEnd - clip.start) * clip.speed
                    right.start = cutStart
                    right.duration = clip.end - cutEnd
                    result.append(right)
                }
            }
            tracks[track].clips = result
        }
        return true
    }

    mutating func move(_ id: UUID, to start: Double, on trackID: UUID) -> Bool {
        guard let source = clipLocation(id),
              let target = tracks.firstIndex(where: { $0.id == trackID }),
              !tracks[source.track].isLocked, !tracks[target].isLocked,
              tracks[source.track].kind == tracks[target].kind else { return false }
        var clip = tracks[source.track].clips.remove(at: source.clip)
        clip.start = max(0, start)
        tracks[target].clips.append(clip)
        tracks[target].clips.sort { $0.start < $1.start }
        return true
    }

    mutating func move(_ ids: Set<UUID>, by delta: Double, trackOffset: Int = 0) -> Bool {
        guard !ids.isEmpty else { return false }
        let locations = ids.compactMap { id -> (Int, TimelineClip)? in
            guard let location = clipLocation(id) else { return nil }
            return (location.track, tracks[location.track].clips[location.clip])
        }
        guard locations.count == ids.count,
              locations.allSatisfy({ source, clip in
                  let target = source + trackOffset
                  return target >= 0 && target < tracks.count &&
                      !tracks[source].isLocked && !tracks[target].isLocked &&
                      tracks[source].kind == tracks[target].kind && clip.start + delta >= -0.0001
              }) else { return false }
        for index in tracks.indices {
            tracks[index].clips.removeAll { ids.contains($0.id) }
        }
        for (source, original) in locations {
            var moved = original
            moved.start = max(0, original.start + delta)
            tracks[source + trackOffset].clips.append(moved)
        }
        for index in tracks.indices { tracks[index].clips.sort { $0.start < $1.start } }
        return true
    }

    mutating func split(_ ids: Set<UUID>, at time: Double) -> Set<UUID> {
        var rightIDs: Set<UUID> = []
        for id in ids {
            if let right = split(id, at: time) { rightIDs.insert(right) }
        }
        return rightIDs
    }

    mutating func splitAll(at time: Double) -> Set<UUID> {
        let ids = Set(tracks.filter { !$0.isLocked }.flatMap(\.clips)
            .filter { time > $0.start + 0.05 && time < $0.end - 0.05 }.map(\.id))
        return split(ids, at: time)
    }

    mutating func cutRange(from first: Double, to second: Double) -> Set<UUID> {
        let lower = max(0, min(first, second))
        let upper = max(first, second)
        guard upper - lower > 0.05 else { return splitAll(at: lower) }
        _ = splitAll(at: lower)
        _ = splitAll(at: upper)
        return Set(tracks.filter { !$0.isLocked }.flatMap(\.clips)
            .filter { $0.start >= lower - 0.001 && $0.end <= upper + 0.001 }
            .map(\.id))
    }

    mutating func trim(_ ids: Set<UUID>, at time: Double, removeBefore: Bool) -> Set<UUID> {
        var changed: Set<UUID> = []
        for id in ids {
            guard let location = clipLocation(id), !tracks[location.track].isLocked else { continue }
            let clip = tracks[location.track].clips[location.clip]
            guard time > clip.start + 0.05 && time < clip.end - 0.05 else { continue }
            if trim(id, leading: removeBefore ? time : nil,
                    trailing: removeBefore ? nil : time) { changed.insert(id) }
        }
        return changed
    }

    mutating func delete(_ ids: Set<UUID>, ripple: Bool) -> Bool {
        let removable = tracks.filter { !$0.isLocked }.flatMap(\.clips)
            .filter { ids.contains($0.id) }
        guard !removable.isEmpty else { return false }
        if !ripple {
            for index in tracks.indices where !tracks[index].isLocked {
                tracks[index].clips.removeAll { ids.contains($0.id) }
            }
            return true
        }
        let intervals = removable.map { ($0.start, $0.end) }.sorted { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for interval in intervals {
            if let last = merged.last, interval.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, interval.1)
            } else { merged.append(interval) }
        }
        for (start, end) in merged.reversed() { removeTimeRange(start: start, end: end) }
        return true
    }

    private mutating func removeTimeRange(start: Double, end: Double) {
        let removed = end - start
        for index in tracks.indices where !tracks[index].isLocked {
            var result: [TimelineClip] = []
            for clip in tracks[index].clips {
                if clip.end <= start { result.append(clip) }
                else if clip.start >= end {
                    var shifted = clip
                    shifted.start -= removed
                    result.append(shifted)
                } else if clip.start < start && clip.end > end {
                    var left = clip
                    left.duration = start - clip.start
                    var right = clip
                    right.id = UUID()
                    right.sourceStart += (end - clip.start) * clip.speed
                    right.start = start
                    right.duration = clip.end - end
                    result.append(contentsOf: [left, right])
                } else if clip.start < start {
                    var left = clip
                    left.duration = start - clip.start
                    result.append(left)
                } else if clip.end > end {
                    var right = clip
                    right.sourceStart += (end - clip.start) * clip.speed
                    right.start = start
                    right.duration = clip.end - end
                    result.append(right)
                }
            }
            tracks[index].clips = result
        }
    }

    mutating func trim(_ id: UUID, leading: Double? = nil, trailing: Double? = nil) -> Bool {
        guard let location = clipLocation(id), !tracks[location.track].isLocked else { return false }
        var clip = tracks[location.track].clips[location.clip]
        if let leading {
            let change = max(-clip.sourceStart / max(0.01, clip.speed),
                             min(clip.duration - 0.05, leading - clip.start))
            clip.start += change
            clip.sourceStart += change * clip.speed
            clip.duration -= change
        }
        if let trailing {
            clip.duration = max(0.05, trailing - clip.start)
        }
        if let media = media(for: clip), media.kind != .image {
            clip.duration = min(clip.duration, max(0.05,
                (media.duration - clip.sourceStart) / max(0.01, clip.speed)))
        }
        tracks[location.track].clips[location.clip] = clip
        return true
    }
}
