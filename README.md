# MotionCut

A native macOS video editor prototype focused on stabilization. The UI follows the Instrument Design System from BluHal's `instrument-ui-demo`: dark field, quiet measurement grid, restrained mint signal, amber caution, and readable controls.

## Run

Requires Xcode with the macOS SDK. No third-party runtime dependencies.

```sh
./Scripts/build-app.sh
open dist/MotionCut.app
```

Open a local video, wait for camera-motion analysis, choose Balanced or Crop + steady, adjust smoothness and maximum frame crop, compare with the original, set in/out points, and export a `.mov` file. The exporter retains the source audio track where supported by AVFoundation.

## Stabilization implementation

1. Decode frames and sample a reduced-resolution grayscale image.
2. Estimate motion with Apple's Vision optical flow, fit a similarity transform using RANSAC, and fall back to textured patch matching if flow cannot provide a reliable estimate. Untrackable frames coast on the last camera position; only a likely scene cut resets the path.
3. Compose the measured motion into a camera path.
4. Solve for a smoother path with an iteratively reweighted L1-style acceleration penalty. Crop + steady uses a stronger penalty and a shot-local temporal low-pass filter.
5. Apply a rigid correction and a constant crop, limiting correction to the selected crop budget.

The rigid transform avoids introducing mesh-induced bending. The motion graph shows recorded and corrected horizontal paths. Crop + steady can spend up to 50% of each frame dimension on a constant crop (2× zoom); it only uses as much as the estimated correction needs. Crop cannot fix motion-estimation errors, rolling shutter, or parallax. This is a practical research-inspired baseline, **not** a reproduction of CamFlow+, a depth-aware stabilizer, or Gyroflow. Analysis currently scans the full clip and may be slow for long 4K media.

## Architecture

- `MotionAnalyzer.swift`: decoding, matching, robust motion fitting.
- `StabilizationPlan.swift`: path optimization and crop bound.
- `VideoCompositionBuilder.swift`: shared transform composition for preview and export.
- `EditorModel.swift`: document and playback state.
- `ContentView.swift`: native SwiftUI editor.

This is a one-clip editing core. Multi-track editing, titles, color, audio tools, project persistence, gyro telemetry, and depth-aware correction remain future work.

## Research and platform references

- [Apple Vision optical flow request](https://developer.apple.com/documentation/vision/vngenerateopticalflowrequest) supplies dense frame-to-frame motion estimates on macOS.
- [Auto-Directed Video Stabilization with Robust L1 Optimal Camera Paths](https://research.google/pubs/auto-directed-video-stabilization-with-robust-l1-optimal-camera-paths/) motivates the path smoothing objective; this project uses a simpler acceleration-focused approximation.
- [CamFlow+](https://arxiv.org/abs/2606.05915) is a recent flow-based research direction, but its full model is not implemented here.
- [Gyroflow](https://github.com/gyroflow/gyroflow) is a useful reference for future gyro-assisted stabilization.

## GitHub account isolation

This repository sets its Git author and credential helper locally. GitHub CLI configuration lives under `.git/gh-config`, while its authentication token is stored in this macOS user's Keychain. No global Git identity or credential helper is changed, and another macOS user has a separate Keychain. For direct GitHub CLI commands in this checkout, run:

```sh
GH_CONFIG_DIR="$PWD/.git/gh-config" .git/tools/gh auth status
```

The `.git` directory is local metadata and is not included when the repository is cloned elsewhere. On another Mac, install GitHub CLI and authenticate that checkout separately.
