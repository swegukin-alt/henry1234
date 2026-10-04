# Make the Apple Log HEVC bitrate true while recording

## What went wrong
135 GB for ~35 minutes is about 515 Mbps — that is ProRes, not HEVC at 35 Mbps. With Apple Log on, iPhone's built-in recorder does not offer HEVC for that camera mode, so it silently recorded ProRes. The "compress after the take" safety step can't rescue a file that big: it needs another full copy's worth of free space, roughly real-time processing (30+ minutes with the app open), and it is stopped when the phone locks or the app goes to the background. So the slider never had a chance to work.

The only reliable fix is to encode HEVC at the chosen bitrate live, while recording — the same way pro camera apps record Apple Log in HEVC.

## What changes for you
- With Apple Log + HEVC, the file is written at the slider's bitrate as it records. 35 Mbps for 35 minutes ≈ 9 GB, no waiting afterwards.
- The size readout under the slider becomes accurate (video at the chosen rate + ~1–2 MB/min sound).
- Your manual dB gain is applied to the sound as it records in this mode, so there is no after-take rewrite either.
- ProRes 422 and normal (non-Log) recording stay exactly as they are.
- If the camera ever can't record Log in HEVC, the settings say so plainly ("HEVC unavailable — will record ProRes") instead of quietly making huge files.

## Safety (recordings can never be lost)
- The new recorder writes the file in 2-second protected chunks, like the current one, so a crash, call or dead battery still leaves a playable file.
- Calls, Control Center, alarms etc. are handled exactly as today: the file is closed, saved to clips, and recording continues into a new file.
- Record button remains the only way to start/stop; double-tap / stalled-save protections and the low-space check are kept.
- The after-take steps (gain/compression) are skipped when a file is too large for the free space, and run with background time so locking the phone can't cut them off. Originals are only replaced by a complete, smaller file.

## Technical details
- New `Camera/LogHEVCWriter.swift`: AVAssetWriter (.mov, movieFragmentInterval 2 s) with an HEVC input — `AVVideoCodecType.hevc`, `AVVideoAverageBitRateKey = mbps × 1_000_000`, `kVTProfileLevel_HEVC_Main10_AutoLevel`, expectsMediaDataInRealTime true — and an AAC audio input (48 kHz, mic channel count, 256/128 kbps). Session starts at the first video sample's timestamp; audio PCM is scaled by `AudioGain.factor(db:)` before appending.
- `CameraManager.configure`: when `appleLog && logCodec == "hevc"` and Log actually engaged, use `AVCaptureVideoDataOutput` (10-bit `420YpCbCr10BiPlanarVideoRange`, only if listed in `availableVideoCodecTypes`/`availableVideoPixelFormatTypes`; `alwaysDiscardsLateVideoFrames = false`) instead of `movieOutput`; otherwise the existing movie output path is untouched. Stabilization/mirroring set on that connection the same way.
- The existing `audioDataOutput` delegate fans out: level meter as now, plus the writer while recording. Metering pause behaviour unchanged.
- `startRecordingSegment` / `stopRecording` / interruption + continuation / stop watchdog / `onInvoluntaryFinish` branch to the writer in this mode with the same Result<URL> callbacks, so PrompterView's register-first flow is unchanged.
- Colour tags: no colour-properties key is set, so the encoder carries the capture buffers' own colour attachments; the `[Verify]` line will confirm codec `hvc1`, real bitrate and transfer on device.
- PrompterView: skip `AudioGain.apply` and `VideoBitrate.enforce` for writer-mode takes; for other takes wrap them in `UIApplication.beginBackgroundTask` and skip when free space < file size × 1.1. Settings label shows the real recording codec (`recordingCodecName`), including the HEVC-unavailable notice.
- Not verifiable here: no Xcode or iPhone in this environment — build and device behaviour must be checked on your Mac/phone.
