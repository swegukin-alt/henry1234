# Stable, crash-resistant iPhone recording

## Goal
Keep motion smooth when recording starts, while preserving every completed segment if Safari closes or storage becomes pressured.

## Changes
- Replace the overly aggressive fixed 1080p60/30 Mbps capture path with an adaptive recorder: prefer 1080p60, but automatically use the highest frame rate the camera can sustain instead of overloading the phone.
- Decouple recording writes from the camera’s critical path. Use larger, less frequent durable chunks and a bounded write queue so IndexedDB work cannot stall video encoding.
- Add automatic performance protection during a take: reduce preview rendering cost and pause voice/highlight analysis if frame delivery or the write queue falls behind; never alter the recorded stream mid-take.
- Harden start/stop/error handling with one finalization path, explicit low-storage/write-failure warnings, lifecycle flushing, and recoverable in-progress sessions.
- Keep continuous recording as the default. Optional splitting remains off unless selected.
- Show the actual delivered resolution and frame rate, plus a clear warning before recording if the requested mode is not sustainable.

## Validation
- Test repeated record/stop cycles and verify audio, playback, duration, ordering, and recovery.
- Stress-test queued writes and long-take finalization without duplicate full-file memory allocation.
- Check portrait and landscape layouts, browser errors, and the production build.

## Technical details
- Measure real frame delivery with `requestVideoFrameCallback` when available rather than relying only on camera settings.
- Tune MediaRecorder timeslices and IndexedDB transactions to reduce main-thread contention while retaining bounded crash-loss exposure.
- Preserve the original media chunks until a finalized clip is durably committed.
