# Sharper video: 1080p60 at high bitrate, one continuous recording

## What changes for you

1. **One continuous recording again.** No 5-minute cuts by default — the camera rolls from Record to Stop with no break, so not a single frame is lost.
2. **Splitting becomes an option that is off.** It stays available in video settings ("Split recording: Off / 1 / 2 / 5 / 10 min") in case a very long take ever gets hard to save, but you never hit it unless you turn it on.
3. **Much higher quality.** The default becomes 1080p at 60 frames per second with a very high bitrate, so fast movement and busy backgrounds stop turning the face to mush.
4. **Honest quality readout.** While the camera is live, a small line on the record screen shows what the phone is *actually* giving: resolution, real frame rate, and the bitrate being recorded. If the phone quietly drops to 30 fps or a lower bitrate, you see it instead of guessing.

## Why the picture looked soft

Two separate causes:

- The frame rate is only requested as "ideal 60", so iPhone silently settles on 30 fps at higher resolutions, which is what makes motion smear.
- 1080p is recorded at 14 Mbps, which is below what iPhone's own camera uses and far too low for busy scenes; the encoder spends its budget on the background and the face loses detail.

4K is also offered, but on iPhone it tends to force 30 fps and heavier throttling, so 1080p60 becomes the recommended default for talking-head takes.

## Quality settings after the change

| Mode | Resolution | Frame rate | Bitrate |
| --- | --- | --- | --- |
| 1080p60 (default) | 1920x1080 | 60 fps | 30 Mbps |
| 1080p30 | 1920x1080 | 30 fps | 18 Mbps |
| 4K30 | 3840x2160 | 30 fps | 60 Mbps |
| 720p60 | 1280x720 | 60 fps | 12 Mbps |

Existing recordings are untouched, and the take list, playback, and saving all keep working exactly as they do now.

## Technical notes

**src/routes/index.tsx**

- `Quality` becomes `"720p60" | "1080p30" | "1080p60" | "4k30"` with a stored profile map of `{ width, height, fps, bps }`; the old stored values `720p` / `1080p` / `4k` migrate to `720p60` / `1080p60` / `4k30`. Default `1080p60`.
- `getConstraints` requests `frameRate: { ideal: fps, min: fps === 60 ? 50 : 24 }` plus `width/height: { ideal }`, and after acquisition calls `applyConstraints({ frameRate: { ideal: fps }, zoom: 1 })` so the track is pushed to 60 fps when the first negotiation lands on 30. Fallback tier order stays highest-to-lowest, now fps-aware (1080p60 falls back to 1080p30, then 720p60).
- Recorder options use the profile's `bps` (and keep `audioBitsPerSecond: 192_000`). MediaRecorder is created with `videoBitsPerSecond` and `bitsPerSecond` both set — some Safari builds honour only the latter.
- New `camStats` state read from `track.getSettings()` after acquisition and refreshed once per second while recording, showing `WxH · N fps · M Mbps` under the record button; when the actual fps is below the requested one it is flagged in amber.
- `partMinutes` gains an `Off` value (`0`), stored as the default. `launchPart` already skips the rollover timer when `partMs <= 0`, so continuous recording needs no recorder changes — a take then has exactly one part, as before.
- Settings UI: quality row becomes the four profiles; the split row adds `Off` as the first, default choice with a note that off means one unbroken file.

No changes to clip-store, save-clips, or the take grouping — a single-part take already renders and saves as one video.
