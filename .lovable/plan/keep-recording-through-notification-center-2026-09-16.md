# Keep recording through Notification Center

## Change
- Track the user’s record-button intent separately from AVFoundation’s temporary recording state.
- If iOS unexpectedly closes the current movie while the record button remains active, preserve that file immediately and automatically continue into a new protected segment when capture is available again.
- Keep the interface in REC state throughout the interruption; only the record button clears recording intent.
- When the record button is pressed to stop, finalize and register every segment without overwriting or losing footage.
- Leave teleprompter layout, camera quality, storage format, settings, and all unrelated behavior unchanged.

## Verification
- Confirm Notification Center, Control Center, alarms, and temporary capture interruptions contain no user-stop call.
- Confirm only the record button changes the requested recording state.
- Confirm every involuntarily closed non-empty file is registered before continuation.
- Check available diagnostics and source consistency; final interruption behavior requires an iPhone/Xcode test.
