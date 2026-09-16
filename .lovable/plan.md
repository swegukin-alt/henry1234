# Keep recording through Control Center

## Change
- Stop treating temporary camera-session interruptions as a request to end recording.
- Remove the screen-lifecycle stop triggered when Control Center or another system overlay appears.
- Keep the existing safety behavior that saves any file only when iOS itself has already ended capture.
- Preserve record-button start/stop behavior and all existing camera, teleprompter, storage, and UI behavior.

## Verification
- Confirm no interruption or app-overlay observer calls `stopRecording` or `finalizeIfRecording`.
- Confirm only the record button intentionally starts or stops a take.
- Check the available build diagnostics; final iPhone behavior still requires an Xcode/device test.
