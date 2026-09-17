# Add native FX6-style horizon gauge

## Changes
- Add a native Core Motion level sensor that measures screen-relative roll in real time and adapts to portrait or landscape orientation.
- Show a compact Sony FX6-inspired horizon indicator in the lower-right camera area before recording, with a moving center line and degree readout.
- Use green only inside a tight level tolerance and red whenever the phone is off-level.
- Hide and suspend the gauge for the entire time recording is requested, then restore it after the recording button stops the take.
- Leave recording, camera, teleprompter, storage, and web behavior unchanged.

## Validation
- Confirm the new source is automatically included by the synchronized Xcode project.
- Check lifecycle and recording-state transitions so the gauge cannot appear during recording.
- Run available source checks here; final sensor accuracy and Xcode compilation require the physical iPhone and Xcode.
