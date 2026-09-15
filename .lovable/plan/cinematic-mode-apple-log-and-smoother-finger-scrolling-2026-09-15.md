# Cinematic Mode, Apple Log, and smoother finger scrolling

Additive only. No existing recording, teleprompter, storage, permissions, or UI behaviour changes beyond the scroll-feel fix.

## 1. Smoother finger scrolling

Today the first movement of a drag snaps by the gesture's activation distance, and the release velocity comes straight from the predicted end point, which can fling hard and then stop abruptly. The fix stays inside the scrolling engine and the drag gesture:

- Anchor the drag to the finger's first reported position so there is no initial jump when the gesture activates.
- Smooth the per-frame position instead of writing raw touch values, so touch-rate input and the 60 Hz display refresh no longer fight each other.
- Clamp and damp the release velocity so the glide decelerates the way iOS lists do, then hands back to auto-scroll.

Nothing else about speed, playback, highlighting or progress changes.

## 2. Cinematic Mode

- New ON/OFF switch in the existing Settings panel, in the CAMERA section under the current Resolution/FPS/HDR menu, using the same `Toggle` style already there.
- Shown only when the hardware and OS actually report Cinematic video capture support for the selected camera; otherwise the row is hidden entirely.
- When ON, an Aperture slider appears underneath with the same slider style as Font size / Scroll speed, labelled with real f-stop values (f/1.4, f/2.8, …) taken from the device's own supported aperture range.
- The aperture slider is disabled while recording; the Cinematic toggle is likewise locked during a take.
- Uses Apple's AVFoundation Cinematic video capture only — no custom depth or blur processing.

## 3. Apple Log

- New ON/OFF switch below Cinematic Mode, same visual style.
- Only shown/enabled when the currently selected capture format reports Apple Log in its supported color spaces.
- Turning it on switches the capture color space to Apple Log; turning it off restores the previous (standard) color space.
- If the chosen combination conflicts with HDR, HDR is turned off automatically for that session, and the existing Resolution/FPS/HDR menu keeps working exactly as it does now.
- Both settings persist like the other camera preferences and are re-applied when the camera starts.

## Technical notes

- `AppSettings`: add `cinematicMode: Bool`, `simulatedAperture: Double`, `appleLog: Bool`, persisted through the existing `UserDefaults` write helper. Defaults: off / device default aperture / off. Not touched by `resetReaderDefaults()`.
- `CameraManager`: add runtime capability reads and appliers, all guarded by `if #available` and by `isCinematicVideoCaptureSupported` / `activeFormat.supportedColorSpaces.contains(.appleLog)`; applied inside the existing `configure` / session-queue paths after the current format selection, never replacing it. Publishes `cinematicSupported`, `appleLogSupported`, and the aperture min/max so SwiftUI can render exact ranges. Any unsupported path is a silent no-op, so current behaviour is unchanged on devices without these APIs.
- `SettingsPanel`: reuses the existing `slider(...)` and `Toggle` helpers; aperture slider `.disabled(isRecording)`; rows appear with the panel's default animation.
- The Cinematic APIs require a recent iOS SDK; on older SDKs/devices the rows simply never appear and the app builds and behaves as it does today.

## Files touched

- `Settings/AppSettings.swift`
- `Settings/SettingsPanel.swift`
- `Camera/CameraManager.swift`
- `Teleprompter/TeleprompterEngine.swift` and the drag gesture in `Teleprompter/PrompterView.swift` (scroll feel only)
