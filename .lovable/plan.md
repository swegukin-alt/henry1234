# Video + Teleprompter mode

Add a second entry point on the home screen that opens the existing teleprompter in landscape with a **live front-camera feed as the background**. All existing controls (play/pause, speed, mirror, font size, remote) behave identically. Clips are recorded locally, stack up in a per-script library across sessions, and export to the iPhone Camera Roll with one tap.

## What you get (capabilities & limits)

Recording is done through the browser's `MediaRecorder` on iOS Safari — the app is a PWA, not a native app. So:

**Available**
- Front camera (`facingMode: "user"`), 1080p30 H.264 in an MP4 container
- Built-in mic, always on (AAC)
- User-selectable quality: 720p30 / 1080p30 / attempt 4K (falls back to 1080p if the device refuses)
- Preview mirrored (natural while filming); **saved file un-mirrored** (reads correctly on playback)
- Script overlay stays a DOM layer — **never burnt into the video**
- Clips persisted locally, survive app close / phone lock / navigating away

**Not available on iOS Safari (would require a native wrapper)**
- Cinematic mode, ProRes, HDR, Portrait mode
- Manual focus / exposure / ISO / white balance / zoom
- Front-camera flash (hardware doesn't have one anyway)
- Direct write to Photos without user tap (iOS requires the Share Sheet)

## User flow

1. Home screen shows a second button below **Let's go** → **Video + Teleprompter** (with a small camera icon).
2. Tap a script → tap Video + Teleprompter → permission prompt for camera + mic (first time only).
3. Landscape reader loads. Layout:
   - Full-screen mirrored front-camera preview as the background
   - Script text on top with a subtle dark scrim behind it for readability (scrim intensity adjustable in a small overlay setting)
   - Existing controls (play/pause, speed, mirror, font size) in the same positions as today
   - New floating **Record** control (red dot) on the right; tapping starts recording, shows a running timer + red REC pill
4. Reading with remote / gestures works identically to today. Scroll position, speed, mirror, font-size all behave the same.
5. Tap Stop → the clip is silently saved to a **per-script clip library**. Reader stays exactly where it is (script position, speed, mirror all preserved). User can immediately record another take — or close the app, drive to a new location, come back, and continue from the same script position.
6. A small **Clips (N)** chip in the top corner opens a bottom sheet showing all clips for this script: thumbnail, duration, size, delete, plus **Export all to Photos** and **Export selected**.
7. **Export to Photos** opens the iOS Share Sheet with the clips as MP4 files — user taps *Save to Photos*. (This tap is required by iOS; there is no web API to write to Photos silently.)

## State that must survive app close

For each script, we keep:
- Current teleprompter position (scroll offset), speed, mirror state, font size
- The clip library (blobs + metadata)

Storage: **IndexedDB** for the video blobs (localStorage cannot hold binary). Metadata + reader state in the same DB. Nothing goes to a server — everything stays on-device.

## New UI surfaces

- Home screen: second CTA button "Video + Teleprompter" under "Let's go"
- Landscape recorder view (new route, mirrors existing reader layout)
- Recording HUD: REC pill + timer + Stop
- Clips bottom sheet: list, select, delete, export
- Small quality selector (720 / 1080 / 4K-try) accessible from the recorder settings gear

## Technical section

**New route**: `src/routes/read.$id.video.tsx` — reuses the existing landscape reader component, swaps the black background for a `<video autoPlay muted playsInline>` element bound to the live `MediaStream`. Mirror preview via CSS `transform: scaleX(-1)`; do NOT mirror the recorded stream so the saved file plays back correctly.

**Camera capture**:
```ts
navigator.mediaDevices.getUserMedia({
  video: { facingMode: "user", width: {ideal: 1920}, height: {ideal: 1080}, frameRate: {ideal: 30} },
  audio: true,
})
```
Quality tiers just swap the `width`/`height` ideals. Feature-detect `MediaRecorder.isTypeSupported("video/mp4;codecs=h264,mp4a.40.2")` and fall back to `video/mp4` then `video/webm` if needed.

**Recording**: `MediaRecorder` with 250 ms `timeslice`, chunks pushed into an array, finalized into a single `Blob` on stop. Bitrate: 6 Mbps for 1080p, 3 Mbps for 720p, 20 Mbps if 4K negotiated.

**Persistence**: IndexedDB via a tiny wrapper (no dep, ~40 lines) or `idb-keyval` if we want a dep. Schema:
- `clips` store: `{ id, scriptId, blob, mimeType, durationMs, sizeBytes, createdAt, width, height }`
- `readerState` store: `{ scriptId, scrollY, speed, mirror, fontSize, updatedAt }` — written on every meaningful change, restored on reader mount.

**Export to Photos**: build `File` objects from blobs, call `navigator.share({ files: [...] })` inside a user gesture. On iOS this opens the Share Sheet with "Save Video" / "Save N Videos". If `navigator.canShare({files})` returns false (older iOS), fall back to per-clip download links.

**Preventing the script from burning in**: the DOM overlay is never composited into the `MediaRecorder` stream — only the raw camera track is recorded. This is automatic given how we wire the stream; no canvas compositing.

**Permissions & lifecycle**:
- Request camera+mic on first entry to the video mode; if denied, show a helpful message with instructions to enable in iOS Settings → Safari → Camera.
- Stop all tracks on route leave to release the camera indicator.
- Handle `visibilitychange` — if the user backgrounds mid-recording, stop cleanly and save what we have (iOS will kill the stream anyway).
- Wake Lock API to keep the screen on while the reader is active (already useful for the existing mode too — we can add it here first).

**Files to create/change**
- `src/routes/read.$id.video.tsx` — new landscape recorder route
- `src/components/reader/CameraLayer.tsx` — live preview + recorder
- `src/components/reader/RecordHUD.tsx` — REC pill, timer, stop button
- `src/components/reader/ClipsSheet.tsx` — clip library + export
- `src/lib/clip-store.ts` — IndexedDB wrapper for clips + reader state
- `src/lib/media-recorder.ts` — capability detection, quality tiers, recorder lifecycle
- `src/routes/index.tsx` — add the second CTA button per script
- Existing reader component refactored slightly so the background is a slot (black by default, camera in video mode). No behavior change to the current mode.

**No backend**. No Lovable Cloud needed. Everything is on-device.

## Out of scope (say the word if you want any of these)

- Editing / trimming clips in-app
- Overlaying the script into the recording (burn-in)
- Multi-camera / rear camera toggle
- Direct auto-save to Photos without tapping Share (impossible on web iOS)
- Cinematic mode / ProRes / manual pro controls (requires native wrapper)
