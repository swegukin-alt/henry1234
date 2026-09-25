# Enlarge recording controls and enforce true 180° shutter

## Changes
- Enlarge the complete bottom recording toolbar, including the record control and surrounding icons, with even spacing and safe-area clearance in portrait and landscape.
- Keep the record control visually dominant while preserving every existing action and recording safeguard.
- Make the 180° shutter switch available before and during recording.
- Lock exposure duration to exactly half the active frame interval (`1/60` at 30 fps, `1/120` at 60 fps) while leaving white balance automatic.
- Continuously compensate ISO from the camera meter without ever changing the locked shutter duration, including during an active take and after camera interruptions.
- Keep HDR unchanged when shutter angle is enabled; Apple Log remains the only existing mode that disables HDR.

## Validation
- Inspect every exposure and HDR write to confirm shutter mode cannot disable HDR or be replaced by continuous auto exposure.
- Run available source checks and confirm the web preview remains healthy.
- Physical-device exposure and HDR verification remains required in Xcode on the iPhone because this environment has no iOS SDK or camera hardware.
