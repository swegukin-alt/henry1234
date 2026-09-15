# Native migration — web teleprompter → Swift/SwiftUI iPhone app

The web app (`src/`) stays exactly as it is. This document maps every user-facing
feature of the web teleprompter onto the native app in `ios-native/`.

| Feature | Web implementation | Native implementation | Status | Known limitation |
| --- | --- | --- | --- | --- |
| Script library, "Let's go" | React list + localStorage | `LibraryView`, `ScriptStore` (JSON in Application Support) | Complete | — |
| Branding ("Let's kick some ass", "Never give up…") | JSX header | `LibraryView` header | Complete | — |
| Script editor | textarea | `EditorView` with `TextField`/`TextEditor` | Complete | — |
| Scrolling prompter | requestAnimationFrame + scrollTop | `TeleprompterEngine` with `CADisplayLink` (60/120 Hz) | Complete | — |
| Speed control | slider + keys | `AppSettings.speed`, toolbar, remote keys | Complete | Speed change never jumps the text |
| Font size | CSS font-size | `ScriptText` system rounded font | Complete | — |
| Line height / text width / margins | CSS | `lineSpacing`, frame width %, padding | Complete | — |
| Tap to play/pause | onClick overlay | transparent tap layer | Complete | — |
| Countdown | JS timer | `PrompterView.togglePlay` timer | Complete | — |
| Progress badge | % of scroll | `TeleprompterEngine.progress` | Complete | — |
| Last reading position | localStorage | `AppSettings.readingPosition(for:)` | Complete | — |
| Mirror / flip | CSS transforms | `scaleEffect`; in video mode only the camera image mirrors | Complete | — |
| Reading highlight | DOM word spans | `AttributedString` word highlight | Complete | — |
| Voice follow | AI gateway transcription over browser mic | `SFSpeechRecognizer` + `AVAudioEngine`, on-device where supported, Korean locale auto-detected | Complete (reading mode) | Disabled during video recording: the capture session owns the mic |
| Camera preview | `getUserMedia` + `<video>` | `AVCaptureSession` + `AVCaptureVideoPreviewLayer` in `CameraPreviewView` | Complete | — |
| Front/rear camera | facingMode | `CameraManager.switchCamera`, widest front device chosen | Complete | — |
| Recording | `MediaRecorder` → blobs → IndexedDB | `AVCaptureMovieFileOutput` writing a real `.mov` in Documents/Recordings | Complete | — |
| Recording quality | guessed bitrates | exact `AVCaptureDevice.formats` modes (720p/1080p/4K, 30/60, HDR) | Complete | The mode list is read from your iPhone the first time video mode opens |
| Stabilization | n/a | `preferredVideoStabilizationMode` | Complete | — |
| Zoom / focus / torch | n/a | `videoZoomFactor`, focus & exposure point, `torchMode` | Complete | Front camera has no torch |
| Record timer | JS interval | `CameraManager.elapsed` | Complete | — |
| Microphone selection (DJI Mic 2 / USB) | `enumerateDevices` | `AVAudioSession.preferredInput`, USB → wired → Bluetooth → built-in | Complete | Needs the real accessory to verify |
| Audio interruptions / route changes | ad-hoc | `AudioSessionManager` notifications | Complete | — |
| Saved takes list | IndexedDB metadata | `RecordingStore` index + files on disk | Complete | — |
| Recovery / repair of takes | blob rescue, deep restore | not needed: fragmented `.mov` written by AVFoundation stays playable; `reconcile()` re-adopts any orphan file after a crash | Complete | — |
| Playback | `<video>` element | `AVPlayer` / `VideoPlayer` | Complete | — |
| Save to Photos | download/share hacks | `PHPhotoLibrary` add-only | Complete | — |
| Share | Web Share API | `UIActivityViewController` (AirDrop, Files, Messages) | Complete | — |
| Storage management UI | quota, cleanup, delete all | dropped by request; swipe to delete a take | Intentionally removed | iPhone storage is used directly |
| Desview remote | `keydown` listener | `RemoteControlManager` + `UIKeyCommand`/`pressesBegan` | Complete | Mapping preserved: space/enter/./k/p = play, ←/→ speed, ↑/↓ nudge, [ ] font, 0 reset, Esc exit, r record |
| Keep screen awake | Wake Lock API | `UIApplication.isIdleTimerDisabled` | Complete | — |
| Orientation | CSS + screen lock | native portrait / landscape left / right, `RotationCoordinator` drives preview and recorded orientation | Complete | Verify on device |
| Safe areas | env(safe-area-inset) | SwiftUI safe areas | Complete | — |
| Haptics | none | `UIImpactFeedbackGenerator`, `UINotificationFeedbackGenerator` | Complete | — |
| Permissions | browser prompts | `PermissionManager`, asked on first use, deep link to Settings | Complete | — |
| Settings persistence | localStorage | `UserDefaults` via `AppSettings` | Complete | — |

## Must be verified on your physical iPhone

These cannot be exercised from Lovable (no Apple hardware or Xcode here):

1. Xcode compile and signing with your Personal Team.
2. Camera preview, 4K/60 and HDR mode list on your iPhone 16 Pro Max.
3. Long recordings (30 min+) and thermal behaviour.
4. DJI Mic 2 / USB-C audio routing.
5. Desview remote key mapping.
6. Rotation of the recorded file in landscape left and right.
7. Save to Photos and the share sheet.
8. Force-quit → reopen → takes still listed.
