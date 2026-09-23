# Improve local titles, filenames, and videoclip browsing

## Changes
- Replace the opening-line title with a smarter fully local title generator that scores meaningful words and sentences from the whole script, supports Korean and English text, and needs no internet or account. Save the generated title with the script while keeping a deterministic fallback.
- Name recordings with one durable global sequence: `Swegukin_000001.mov`, `Swegukin_000002.mov`, and so on. Keep date, script title, script ID, duration, and size in the recording index used for organization; do not rename existing recordings or alter the capture pipeline.
- Rebuild All videoclips as an Apple Files-style three-column grid of large folder icons with names and clip counts underneath.
- Open each folder into a three-column grid of chronological video thumbnails, with the existing play, selection, share, delete, camera-roll, and drive-copy actions preserved.

## Technical details
- Use local Natural Language tokenization and deterministic keyword scoring only; no network, AI key, cloud service, or model download.
- Persist the next recording number atomically and skip any number already present on disk, preventing collisions after restarts or interrupted recordings.
- Reuse the existing asynchronous thumbnail generator and recording metadata store.

## Verification
- Search for old date-based filename creation and confirm the new sequence is the only new-recording path.
- Check the changed Swift files for source consistency and confirm the web build remains healthy.
- Report Xcode and physical-device verification as unavailable in this environment.
