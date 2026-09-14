# Fix long-video iPhone sharing

## Goal
Make the Share action hand the exact playable recording to the iPhone share menu without misreporting a system rejection as a user cancellation.

## Changes
- Trace the recording bytes, detected video format, filename, and Share action from storage to iPhone.
- Remove any duplicate whole-video assembly or metadata mismatch before sharing.
- Keep the prepared playable recording stable, then invoke the iPhone share menu directly from one deliberate tap.
- Show an accurate message only when iPhone rejects the file, preserving the recording in the app.
- Recheck recording playback, the Share action, page errors, and the production build.

## Technical details
- Preserve the real MP4/WebM container and matching extension.
- Avoid copying a multi-gigabyte recording during export where the browser can reference the existing Blob.
- Maintain transient user activation by doing no asynchronous work before `navigator.share()`.
