# Native readiness audit — Swegukin Teleprompter

Target: one codebase. Browser → browser APIs. Capacitor 8 on iOS → native APIs
where they genuinely improve reliability. No second UI, no second teleprompter
engine.

App shape as audited:

- `src/routes/index.tsx` (~2.2k lines) — the whole app: library, editor, reader,
  video mode, video library.
- `src/lib/clip-store.ts` — IndexedDB clip/chunk/session store (v3).
- `src/lib/save-clips.ts`, `src/components/SaveOverlay.tsx` — export/share.
- `src/lib/voice-follow-v2.ts`, `src/lib/chunk-script.ts` — voice follow.
- `src/routes/api/public/transcribe.ts` — server transcription endpoint.
- **No backend, no login, no cloud database.** Nothing to migrate for auth.

Flow traced end to end: script selection → editor → assists toggles → Play/Video
(fullscreen + landscape lock) → camera open with quality tiers → mic pick and
watchdog → tap to start → MediaRecorder with timeslice chunks written to
IndexedDB → scroll engine (rAF) with optional voice follow → stop → finalize
session → clip appears in All videos → Save → share sheet or download.

---

## Feature-by-feature

Legend — Where: `web` = stays browser, `native` = should use iOS,
`both` = shared engine with a native adapter. Test: `sim` = iOS Simulator is
enough, `device` = needs a real iPhone.

### 1. Camera preview and video recording — PRIORITY 1 — IMPLEMENTED
- Now: `getUserMedia` with quality tiers (4K → 1080p → 720p → bare), 60 fps
  *ideal*, zoom 1 via `applyConstraints`, live-track check before enabling
  record. `MediaRecorder` at 45/14/6 Mbps + 192 kbps audio, MIME fallback chain,
  timeslice chunks.
- Files: `src/routes/index.tsx`; now behind `src/platform/camera/*`.
- Where: both. WebKit inside Capacitor can still use `getUserMedia`, but a
  native AVFoundation preview is far more reliable for long takes, gives real
  file output instead of blobs, and survives backgrounding better.
- Plugin: `@capacitor-community/camera-preview` (Capacitor 8 compatible). It
  renders the preview **behind** the WebView — exactly the layout needed, with
  the teleprompter HTML on top. The WebView and body background must be
  transparent while that preview is live.
- Genuine plugin limits: it exposes start/stop preview, camera switching, zoom,
  torch, and video recording to a file. It does **not** expose focus point,
  exposure control, lens selection (ultra-wide/tele), explicit 4K/60 fps
  selection, or stabilisation mode. Those require a small custom
  Swift/AVFoundation Capacitor plugin. The capability object
  (`CameraCapabilities`) reports this truthfully; the UI must hide what is not
  supported rather than fail at the tap.
- Fallback: current web implementation, unchanged.
- Permission: `NSCameraUsageDescription`.
- Test: device (the Simulator has no camera).
- Risk to web: none — the web class is the same code as before.
- **Implemented:** `src/platform/camera/native.ts` prefers the custom
  `TeleprompterCapture` plugin (`ios-plugin/TeleprompterCapture/`, registered via
  `registerPlugin`), then `@capacitor-community/camera-preview`. If neither is
  present it returns `plugin-missing` and the screen shows a visible camera
  error — it never reopens `getUserMedia`. `src/routes/index.tsx` has a separate
  native camera effect and `startRecording`/`stopRecording` branch to
  `startNativeRecording`/`finishNativeRecording`, which hand the native file
  straight to `importRecording()` in the filesystem take store. No Blob, no
  MediaRecorder, no IndexedDB on the native path.

### 2. Microphone and audio session — PRIORITY 1 — IMPLEMENTED (needs the Swift plugin)
- Now: `enumerateDevices` + label matching to prefer an external mic (DJI, USB,
  wireless); external mics get raw audio, built-in keeps processing; track swap
  without disturbing the recorder; 2 s watchdog reacquires a dropped mic;
  `devicechange` listener.
- Files: `src/routes/index.tsx`; now behind `src/platform/audio/*`.
- Where: both. Inside the native app the WebView still gives `getUserMedia`, but
  correct behaviour for AirPods/Bluetooth routes, call/Siri interruptions and
  route changes needs an `AVAudioSession` (`playAndRecord`, `allowBluetooth`,
  `defaultToSpeaker`, interruption notifications).
- Plugin: no maintained Capacitor 8 plugin covers this — **custom Swift plugin
  required** for the audio session. Documented, not stubbed as working.
- Permission: `NSMicrophoneUsageDescription`.
- Test: device (external mic and route changes cannot be simulated).
- **Implemented:** the Swift plugin is written
  (`ios-plugin/TeleprompterCapture/TeleprompterCapture.swift`): `AVAudioSession`
  `playAndRecord` / `videoRecording` with `allowBluetooth`, input enumeration and
  selection, plus `audioRouteChange` and `audioInterruption` events surfaced to
  `src/platform/audio/native.ts`. Audio is captured by the capture session
  itself, so recording never touches `getUserMedia` on iOS. Drop the two Swift
  files into the Xcode target; without them the camera reports unavailable
  rather than falling back.

### 3. Voice follow / speech recognition — PRIORITY 3
- Now: PCM windows → WAV → `/api/public/transcribe` (AI gateway). The browser
  recognizer was removed because it is unreliable on iOS and poor for Korean.
- Files: `src/lib/voice-follow-v2.ts`, `src/lib/voice-follow.ts`.
- Where: both, behind `src/platform/speech`. iOS `SFSpeechRecognizer` would be
  faster, on-device and offline-capable — custom Swift plugin.
- Permission (only if adopted): `NSSpeechRecognitionUsageDescription`.
- Test: device. Network required for today's path.

### 4. Teleprompter scrolling engine — PRIORITY 1 (do not nativise)
- Now: `requestAnimationFrame` loop, DOM-direct progress painting, stall
  watchdog, mirror H/V with reversed scroll, punctuation slowdown, chunking,
  reading highlight, per-script scroll restore in localStorage.
- Where: stays platform-independent, identical on web and native. Already
  rAF-based, so 120 Hz ProMotion is handled by the browser's frame pacing.
- Risk: any nativisation here would fork the app. Explicitly out of scope.

### 5. Settings and small preferences — PRIORITY 2
- Now: `localStorage` — `prompter.scripts.v1`, `prompter.active.v1`,
  `prompter.settings.v1`, `prompter.quality`, per-script reader state.
- Now routed through `src/platform/storage/settings.ts`: synchronous cached
  reads; native writes mirror to `@capacitor/preferences`, hydrated once at
  startup. Behaviour on the web is byte-for-byte the same.
- Note: scripts are text and stay in this store. If script libraries grow large
  or gain structure (folders, versions, cues), SQLite
  (`@capacitor-community/sqlite`) is the right native home — not Preferences.

### 6. Large recordings — PRIORITY 1 — IMPLEMENTED
- Interface: `src/platform/storage/media-store.ts`. Every call site in
  `src/routes/index.tsx` and `src/lib/save-clips.ts` goes through it; nothing
  imports `clip-store` for stateful work any more.
- Web (`webMediaStore`): forwards verbatim to the existing IndexedDB store
  `src/lib/clip-store.ts` — same chunk writes, same recovery, same instant stop.
- iOS (`src/platform/storage/media-store.native.ts`): `@capacitor/filesystem`
  in `Directory.Data`, one real file per take at `recordings/<id>.<ext>`, plus a
  small `recordings/index.json` metadata index. Chunks are appended as they
  arrive (`Filesystem.appendFile`, base64 per timeslice), so a crash, call or
  force-quit leaves a real playable file; `recoverOrphanSessions()` re-closes
  any take still marked open and drops empty leftovers.
- Finalize only rewrites the index entry — no second copy, so stop stays
  instant and disk use is not doubled.
- No IndexedDB, Blob URL or WebKit storage is involved on the native path;
  playback uses `Capacitor.convertFileSrc(uri)` so the video streams off disk.
- `repairClip` / `deepRestore` on native simply report the file's real state:
  there are no pieces to stitch on a filesystem store.
- If the Filesystem plugin is absent, `mediaStore()` falls back to the browser
  store rather than pretending a file was written.
- Test: device (multi-GB behaviour); sim can validate the code path.

### 7. Saving to Photos / export — PRIORITY 1 — IMPLEMENTED
- Web: unchanged — `navigator.share({files})` inside the tap, `<a download>`
  fallback, >1.2 GB straight to Files.
- iOS: `saveVideoToPhotos(path)` in `src/platform/media-library` calls
  `@capacitor-community/media` `saveVideo` against the on-disk path. No blob,
  no download link. The original file stays in app storage regardless of the
  export result. Missing plugin is reported honestly, never faked.
- Permission: `NSPhotoLibraryAddUsageDescription` (and
  `NSPhotoLibraryUsageDescription` only if we ever read the library).
- Test: device.

### 8. Sharing — PRIORITY 2 — IMPLEMENTED
- Web: unchanged Web Share + Files fallback.
- iOS: `shareFilePath(uri, title)` in `src/platform/share` calls
  `@capacitor/share` with the file's own URI — no size limit, no gesture
  requirement, nothing copied. `src/lib/save-clips.ts` takes this path first
  whenever a native file exists, with Save to Photos as the secondary action.

### 9. Script import/export — PRIORITY 3
- Now: typing/pasting only; no file picker exists today. `src/platform/files`
  adds a browser picker and text download, and documents the native document
  picker / Files + iCloud Drive path (`@capacitor/filesystem`, or
  `@capawesome/capacitor-file-picker`).

### 10. Remote controls — PRIORITY 1
- Now: a capture-phase `keydown` handler in the reader: Escape/Home exit,
  `[` `]` font size, arrows/page/volume scroll and speed, space/Enter/media keys
  toggle play; Escape is swallowed during recording.
- **Deliberately left exactly as-is.** The Desview remote is programmed against
  it and the user asked for no change.
- Added alongside: `src/platform/remote` normalises input into
  `RECORD_TOGGLE`, `SCROLL_TOGGLE`, `SPEED_UP/DOWN`, `JUMP_FORWARD/BACK`,
  `NEXT_CUE/PREVIOUS_CUE`, `FONT_UP/DOWN`, `EXIT`, with a remappable key table
  that mirrors the current bindings. Used by diagnostics today; available for a
  future mapping screen.
- Two remote kinds, handled differently: HID remotes (Desview, most clickers)
  arrive as key events on both runtimes — never BLE-scan for those. Real BLE
  peripherals go through `@capacitor-community/bluetooth-le`. Bluetooth Classic
  is unreachable from either runtime.
- Permission (BLE only): `NSBluetoothAlwaysUsageDescription`.
- Test: device.

### 11. Keep awake — PRIORITY 1
- Now: Screen Wake Lock, re-requested on `visibilitychange`; now
  `src/platform/keep-awake` (`keepScreenAwake()` returns a release function, held
  for the whole reading/recording session).
- **Implemented:** `keepScreenAwake()` calls `KeepAwake.keepAwake()/allowSleep()`
  on native and `navigator.wakeLock` on web. Install
  `@capacitor-community/keep-awake` on the Mac. Test: sim.

### 12. Orientation and fullscreen — PRIORITY 2
- Now: `requestFullscreen` + `screen.orientation.lock("landscape")` on entering
  Play/Video, called synchronously inside the tap; iOS Safari ignores both, and
  the user rotates manually — which is the intended behaviour.
- Now `src/platform/orientation`. Native: `@capacitor/screen-orientation` can
  really lock landscape during recording, and `@capacitor/status-bar` hides the
  status bar for the reading screen only, restoring it on exit.
- **Implemented:** `lockOrientation()` uses `ScreenOrientation.lock/unlock` on
  native (`@capacitor/screen-orientation`) and `screen.orientation.lock` on web;
  `enterImmersive()` is a no-op on native, where WebView fullscreen throws.
  The video screen locks landscape on entry and unlocks on exit.
- Test: sim.

### 13. App lifecycle and interruptions — PRIORITY 1
- Now: `visibilitychange` re-request of the wake lock; recording continues in
  the background as far as WebKit allows.
- `src/platform/lifecycle` normalises active/inactive/background/resumed and
  network changes. Native should use `@capacitor/app`; if iOS stops a recording,
  the UI must say so — never pretend it continued. The existing chunk store
  means whatever was written is already recoverable.
- **Implemented:** `onLifecycleChange()` uses `@capacitor/app`
  (`appStateChange`/`pause`/`resume`) on native. While recording in the app, a
  move to background finalises the take through `finishNativeRecording()` so the
  real file is saved and the UI shows the true state.
- Test: device.

### 14. Permissions — PRIORITY 2
- Now: implicit, via `getUserMedia` at the moment of use. No permission is
  requested at startup — keep it that way.
- `src/platform/permissions` centralises states (`not-requested`, `granted`,
  `denied`, `restricted`, `unavailable`) and exposes `openAppSettings()` for the
  native hard-denial case. **Implemented natively:** camera and microphone go
  through `TeleprompterCapture.checkPermissions/requestPermissions`, Photos
  through `@capacitor-community/media`, and `openAppSettings()` opens
  `app-settings:`. Permission is requested when the video screen is opened by
  the user, never at startup; a denied camera or mic shows a plain message with
  a route into iOS Settings.

### 15. Safe areas, keyboard, haptics, network, clipboard
- Safe areas: `env(safe-area-inset-*)` already applied throughout the reader,
  toolbar and video controls, in both orientations. Re-check on device for the
  Dynamic Island in landscape.
- Keyboard: the editor is a plain textarea; `capacitor.config.ts` sets
  `Keyboard.resize: "none"` so the teleprompter viewport is never resized.
- Haptics: **implemented** — `haptic()` fires `@capacitor/haptics` impact on
  record start/stop and an error notification on a failed take; on web it uses
  `navigator.vibrate` and silently does nothing when unavailable.
- Network: only transcription needs the network. `isOnline()` exists so a lost
  connection is never reported as a camera or storage fault.
- Clipboard, external links, in-app navigation, auth/session storage: **not used
  by this app.** Nothing to migrate, nothing stored insecurely.

### 16. Future native-only ideas (not implemented)
Screen brightness boost while reading; external display / AirPlay clean output;
HDMI out; a second device as a remote over the local network.

---

## Packages

Already installed in this repo (used by the implemented native paths):

```
@capacitor/core  @capacitor/filesystem  @capacitor/share  @capacitor/preferences
@capacitor-community/media          (Photos saving)
-d @capacitor/cli  @capacitor/ios
```

Still to add on the Mac, for the parts that are not implemented yet:

```
bun add @capacitor/app @capacitor/haptics @capacitor/keyboard @capacitor/status-bar \
        @capacitor/screen-orientation @capacitor/network
bun add @capacitor-community/camera-preview @capacitor-community/bluetooth-le \
        @capacitor-community/keep-awake
```

`@capacitor/app`, `@capacitor/haptics`, `@capacitor/screen-orientation` and
`@capacitor-community/keep-awake` are already wired in code — installing them is
all that is left. `@capacitor-community/bluetooth-le` is only needed if a real
BLE peripheral is added later; the Desview remote is HID and must stay on the
existing keyboard-event path.

```
```
If `@capacitor-community/media` lags Capacitor 8 at install time, swap in a
small Swift `PHPhotoLibrary` plugin behind the same `saveVideoToPhotos()` call.

## Xcode / iOS work still required

1. `bun run build:ios` (static bundle into `dist-ios/`).
2. `npx cap add ios && npx cap sync ios`.
2b. Drag `ios-plugin/TeleprompterCapture/*.swift` into the `App` target (see
   `ios-plugin/TeleprompterCapture/README.md`). Without it the app falls back to
   `@capacitor-community/camera-preview`, and without that too the camera
   reports unavailable — it never uses the browser camera.
3. Add the Info.plist keys below.
4. Enable Background Modes → Audio only if recording must survive
   backgrounding.
5. Make the WebView background transparent while the native camera preview is
   active.
6. Sign and run on a physical iPhone.

## Info.plist keys

| Key | Needed for |
| --- | --- |
| `NSCameraUsageDescription` | camera preview and recording |
| `NSMicrophoneUsageDescription` | recording audio, voice follow |
| `NSPhotoLibraryAddUsageDescription` | saving finished takes to Photos |
| `NSPhotoLibraryUsageDescription` | only if the app ever reads the library |
| `NSBluetoothAlwaysUsageDescription` | BLE remotes only (not HID remotes) |
| `NSSpeechRecognitionUsageDescription` | only if native speech is adopted |

## Needs a real iPhone

Camera, external/Bluetooth microphones, audio routes and interruptions, BLE and
HID remotes, Photos saving, multi-GB recordings, thermal/battery behaviour on
long takes. The Simulator can validate layout, safe areas, orientation, keep
awake, preferences and the filesystem code paths only.

## Likely to need custom Swift later

AVAudioSession control and interruption events; camera focus, exposure, lens
selection, 4K/60 fps and stabilisation; on-device `SFSpeechRecognizer`; Photos
saving if the community plugin is unsuitable.

## Remaining risks

- `camera-preview` recording delivers a file at stop, not live chunks, so the
  native path will need its own recovery story; the existing chunk model does
  not apply to it directly.
- A native preview behind a transparent WebView can be broken by any opaque
  background in the CSS chain.
- The community plugins above must be re-verified against Capacitor 8 at install
  time; versions move.
