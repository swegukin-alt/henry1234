# Reliable iPhone recording and video library

## Recording stability
- Remove the full-length in-memory duplicate of each recording so long takes do not exhaust iPhone memory.
- Keep writing ordered chunks to durable phone storage during recording, wait for the final chunk before completing a take, and surface any failed write.
- Finish microphone selection before recording becomes available, verify a live audio track at record start, and preserve the selected external microphone.

## Complete, ordered video library
- Recover unfinished sessions before loading All videos.
- Store and load lightweight recording metadata separately from large video data so opening All videos does not load every full movie into memory.
- Sort newest recordings first with a deterministic tie-breaker.
- Show the script title, recording date/time, duration, size, and resolution for each take.

## Reliable saving
- Load only the selected recording when Save is tapped.
- Export one recording at a time, without rebuilding or copying multi-gigabyte files in memory.
- For normal recordings, open the iPhone share sheet directly from the tap so Save Video remains available.
- For long recordings, download directly to Files and keep clear on-screen status instead of attempting a share operation likely to crash.
- Keep fallback actions available and never auto-close save feedback.

## Verification
- Check the recording start/stop and audio-track paths, library order and labels, individual playback, and individual save behavior.
- Validate the app build and run browser checks for the All videos workflow.

## Technical details
- Upgrade the IndexedDB schema with a metadata-only store and migrate existing clip records during database upgrade.
- Add lazy `getClip(id)` loading for playback, repair, restore, and save.
- Keep existing recordings compatible; no stored clip is deleted or transcoded.
