# Native iOS: recordings as real files on disk

Today, inside the iPhone app, takes would still land in WebKit's IndexedDB. This makes the iPhone app write every recording to the phone's own filesystem instead, while the website keeps working exactly as it does now.

## What changes for you

- On iPhone, a take is written to a real file in the app's own storage as it records — no browser database, no size ceiling beyond the phone's free space.
- Playback, the saved-takes list, repair, delete, share and Save to Photos all read that file.
- An interrupted take still leaves a real, playable file behind.
- On the website nothing changes at all: same recording, same storage, same save flow.

## What gets built

### 1. One media-store interface, two implementations

New `src/platform/storage/media-store.ts` defines the contract the app already uses in `src/lib/clip-store.ts`: create a session, append a chunk, finalize, list, get, delete, usage, purge orphans, recover orphan sessions.

- **Web implementation** — a thin wrapper that forwards to the existing `src/lib/clip-store.ts`. No logic moves, no behaviour changes.
- **Native implementation** — `src/platform/storage/media-store.native.ts`, backed by `@capacitor/filesystem` in `Directory.Data` under `recordings/<id>.mp4`, with a small JSON index file for metadata (id, scriptId, title, createdAt, durationMs, sizeBytes, mimeType, state).

`mediaStore()` picks one via the existing `pickImpl` so a native failure falls back honestly rather than silently.

Chunks append with `Filesystem.appendFile` (base64 per chunk, one chunk per `MediaRecorder` timeslice) so the file on disk grows in step with the recording and survives a crash mid-take. Finalize only updates the index entry — no re-copy, preserving the near-instant stop you asked for earlier.

### 2. Recording path

`src/routes/index.tsx` currently calls `appendChunk`/`finalizeSession` from `clip-store` directly. Those call sites move to the media-store interface. The recording engine, MediaRecorder timing, progress bar, watchdogs and mic handling are untouched.

Note on the camera: `@capacitor-community/camera-preview` hands back one finished file at stop rather than live chunks, so native recording keeps using MediaRecorder inside the WebView for now and writes those chunks to the native filesystem. That gives you real files without a rewrite of the recording engine. Swapping to a fully native AVFoundation recorder is a later, separate step.

### 3. Playback, share and Photos on native

- Playback uses `Capacitor.convertFileSrc(uri)` on the `<video>` element — no Blob URL, no loading gigabytes into memory.
- Share: `platform/share/shareFilePath()` gets a real body calling `@capacitor/share` with the file URI, opening the iOS share sheet.
- Photos: `platform/media-library/saveToPhotos()` gets a real body writing the file to the Photos library. The original stays in app storage until the save reports success.
- Web keeps `src/lib/save-clips.ts` exactly as is.

### 4. Packages and config

Added as dependencies so the iOS build can resolve them, all loaded through lazy dynamic imports so the website bundle never pulls them in: `@capacitor/core`, `@capacitor/cli`, `@capacitor/ios`, `@capacitor/filesystem`, `@capacitor/share`, `@capacitor/preferences`, and a Photos plugin (`@capacitor-community/media`, version-verified against Capacitor 8 at install time).

`NATIVE_READINESS.md` and the `/diagnostics` page are updated: diagnostics gains a media-store row showing which store is live, the recordings directory and free space.

## Verification before handing back

- Typecheck clean, `bun run build:ios` produces `dist-ios/`.
- Website check in the browser: record, stop, play, share, All videos — identical to today, still on IndexedDB, no Capacitor module resolved in the bundle.
- The native filesystem paths cannot be exercised here; they are validated on your Mac/iPhone.

## Still yours to do on the Mac

`npx cap add ios && npx cap sync ios`, Info.plist keys (`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSPhotoLibraryAddUsageDescription`), and the Xcode build on a physical iPhone.
