# Clear framing preview and 95% zebras

## Changes
- Show the camera at its normal brightness before recording, without the rolling script covering the frame.
- Keep the existing darker overlay and readable script during recording.
- Add a pre-recording Zebra on/off control, fixed at 95%, showing diagonal stripes only over areas whose video signal reaches 95% or above.
- Keep zebras out of saved videos and hide them when recording starts.
- Match the camera preview's crop, rotation and front-camera mirroring in portrait and landscape.

## Technical details
- Limit changes to the native app; leave the web app unchanged.
- Use actual camera frame luminance rather than a decorative overlay or exposure estimate. Normalize supported 8-bit/10-bit full/video-range samples correctly.
- Reuse the existing frame output for Log HEVC. For movie-output modes, use a lightweight preview-only frame tap and disable its work before recording; do not change recording formats, codecs, gain or exposure logic.
- Throttle and downsample zebra analysis, with no queued backlog or frame-processing work during recording.
- 95% zebras measure the current encoded signal. In Apple Log they are not a guarantee of sensor clipping; HDR preview tone mapping may differ from the measured signal.

## Verification
- Check threshold normalization, overlay rotation/mirroring, preview-to-recording transitions and isolation from recorded files.
- Inspect Swift integration and run available checks. Xcode compilation and physical-iPhone testing are unavailable here and will be reported as unverified.