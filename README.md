# MotionCut

A native macOS timeline editor with a local-first workflow and no subscription or account. Its dark, mint-and-amber interface follows [BluHal's Instrument UI style guide](https://github.com/BluHal/instrument-ui-demo).

## Run

Requires Xcode and the macOS SDK. There are no third-party runtime dependencies.

```sh
./Scripts/build-app.sh
open dist/MotionCut.app
```

## Editing workflow

1. Import video, images, and audio. The first imported videos are placed in sequence on V1; later imports remain in the media library until added at the playhead.
2. Click the ruler or monitor scrubber to place the playhead. Select a clip and press **⌘B** or **Split** to cut it at that point. Drag clips to move them; drag their colored edges to trim. The inspector offers precise start, source in, and end fields and a track picker.
3. Use **Delete** to leave a gap or **Ripple delete** to close that span across unlocked tracks. Add video/audio tracks with **+V** and **+A**. Detach a video's recorded audio onto A1 when you want to cut or move it independently. Track mute affects audio; lock prevents edits. Undo/redo work on project edits.
4. Use the inspector for speed, scale, position, opacity, brightness, contrast, saturation, audio level, and fades. Overlap clips and use fades for crossfades. Add centered title clips with **Text** and edit the words in the inspector.
5. Import a 1D or 3D `.cube` LUT and apply it to a selected video or image clip. The LUT browser can search imported looks.
6. Browse the built-in audio starter pack by category, preview a sound, and add it to an audio track. Import your own audio for a searchable personal library.
7. Save a `.motioncut.json` project and export the timeline to MP4 or MOV. Preview and export use the same custom compositor; a tiny bundled timing video lets images, titles, and audio continue after source footage ends.

Project files refer to media by its absolute path. Keep source files available at those paths when reopening a project. The built-in sounds are nine locally synthesized starter clips, not a licensed commercial music catalog. Audio-only projects export as a black video with their audio. This release does not yet provide waveform views, proxy media, multicam, keyframes, subtitle generation, or a large licensed sound catalog.

## Stabilization

Each video clip can use Balanced or Crop + steady stabilization. MotionCut estimates frame motion with Vision optical flow and a RANSAC similarity fit, smooths the resulting camera path, then applies a rigid correction and bounded crop. The rigid transform avoids the wobbly bending caused by mesh warps. Analysis scans the full source clip and can take time on long 4K media. Crop cannot remove rolling shutter or parallax. The implementation is research-inspired; it is not a reproduction of CamFlow+, Gyroflow, or a depth-aware model.

## Architecture

- `TimelineProject.swift`: project, media, tracks, clips, split/ripple/move/trim operations.
- `TimelineRenderer.swift`: AVFoundation composition, Metal-backed Core Image compositor, titles, color, fades, and audio mix.
- `CubeLUT.swift`: `.cube` parsing and Core Image color-cube conversion.
- `AudioLibrary.swift`: built-in locally synthesized sounds.
- `MotionAnalyzer.swift` and `StabilizationPlan.swift`: motion estimation and crop-constrained path smoothing.
- `StudioModel.swift` and `StudioView.swift`: project state and native SwiftUI editor.

Run model and parser tests with `swift test`. A manual composition smoke test also exported video, image, title, LUT, audio, fades, and speed to MP4. The app was visually checked with `/Volumes/Untitled/DCIM/101_FUJI/DSCF2251.MP4`.

## Research and platform references

- [Apple Vision optical flow request](https://developer.apple.com/documentation/vision/vngenerateopticalflowrequest).
- [Apple custom video compositing](https://developer.apple.com/documentation/avfoundation/avvideocompositing).
- [Auto-Directed Video Stabilization with Robust L1 Optimal Camera Paths](https://research.google/pubs/auto-directed-video-stabilization-with-robust-l1-optimal-camera-paths/).
- [CamFlow+](https://arxiv.org/abs/2606.05915) and [Gyroflow](https://github.com/gyroflow/gyroflow) are useful future research directions.

## GitHub account isolation

This repository sets its Git author and credential helper locally. GitHub CLI configuration lives under `.git/gh-config`, while its authentication token is stored in this macOS user's Keychain. No global Git identity or credential helper is changed; another macOS user has a separate Keychain. For direct GitHub CLI commands in this checkout, run:

```sh
GH_CONFIG_DIR="$PWD/.git/gh-config" .git/tools/gh auth status
```

The `.git` directory is local metadata and is not included when the repository is cloned elsewhere. Authenticate each new checkout separately.
