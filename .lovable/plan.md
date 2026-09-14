# Reliable saving for long recordings

## The real problem

At maximum quality a 55-minute take is one ~18 GB file. iPhone can play it inside the app, but
it cannot hand a file that size to the share menu, and the Files download of a single giant
file is slow, silent, and easy to break (locking the phone, leaving the app, low storage).
No web app can make one 18 GB attachment reliable on iPhone.

The fix is to stop creating one giant file: record in parts, and save part by part.

## What changes

### 1. Recording in parts (max quality kept)

- A take is recorded as a sequence of self-contained video parts instead of one file.
- Default part length: 5 minutes. Selectable on the record screen: 1, 2, 5, 10 minutes.
  Shorter parts are more reliable to save; 1-minute parts are small enough that the iPhone
  share menu accepts them every time.
- Parts roll over seamlessly: the next part starts immediately, recording never pauses.
- Each part is written to storage as it finishes, so nothing waits until the end of a take.
  If the app is closed or crashes mid-take, every completed part is already safe.
- Quality stays exactly as it is now.

### 2. New "take" view

- All videos groups parts under one take: "Take 5 — 55:12 — 11 parts".
- Tapping a take plays the parts back-to-back in order, so a long take still watches as one video.
- Each part can be played, saved, or deleted on its own.

### 3. Saving

- **Save whole take**: saves every part in order, one after the other, waiting for each to
  finish before starting the next. Small parts go through the iPhone share menu; larger parts
  go to Files > Downloads automatically.
- **Save one part**: the single big button as today.
- Parts already saved are ticked, so an interrupted save resumes from where it stopped instead
  of starting over.

### 4. Live progress

- A progress screen shows: current part number of total, percent of bytes prepared for the
  current part, total size written so far, and elapsed time.
- Honest wording about the one thing the browser hides: once a part is handed to iPhone's
  downloader, the app shows "handed to iPhone — keep the app open" rather than a fake bar.
- The stop-recording progress bar stays, now per part, so it finishes almost instantly.

### 5. Existing recordings

- The 55-minute take already on the phone stays exactly as it is and keeps its current
  save path; it is not re-cut. New takes use parts.

## Technical notes

- `clip-store.ts`: IndexedDB v4 adds a `takes` store (`id`, `scriptId`, `title`, `createdAt`,
  `partCount`, `totalDurationMs`, `totalBytes`) and `takeId` + `partIndex` on `ClipMeta`.
  Migration assigns each existing clip a single-part take so nothing is lost.
- Recorder: rotate `MediaRecorder` on a part timer — `requestData()`, `stop()`, then `start()`
  on the same `MediaStream` with the same options, finalising the previous part off the hot
  path. Same-stream restart avoids camera re-acquisition and keeps the handoff under a frame.
- Each part is finalised and validated (playable probe on parts under the large threshold)
  before the next rollover completes.
- `save-clips.ts`: `startSave` takes a queue of parts; a `savedParts` set in the job state
  drives resume. Share path unchanged for parts under `IPHONE_SHARE_SAFE_BYTES`, download
  path unchanged above it, object URLs still kept alive.
- Progress: bytes are read from the blob in slices to emit real percentages during the
  prepare phase; per-part completion drives the overall bar.
- Player: take playback chains part blobs in one `<video>` element, preloading the next part
  so the seam is not visible.
