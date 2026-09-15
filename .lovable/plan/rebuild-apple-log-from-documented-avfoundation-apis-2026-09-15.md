# Rebuild Apple Log from documented AVFoundation APIs

## Scope
- Leave the teleprompter, recording flow, camera controls, storage, permissions, and all unrelated UI unchanged.
- Remove the current Apple Log implementation completely, including the custom Core Image/Metal view-assist file and every call into it.
- Preserve only the existing Apple Log setting row and persistence key, then reconnect them to the clean implementation.

## Implementation
1. Remove `Camera/LogViewAssist.swift` and all preview-assist capture/output/rendering code from `CameraManager` and `PrompterView`.
2. Add a small Apple Log capability layer inside the existing camera manager using only SDK-declared AVFoundation members:
   - inspect `AVCaptureDevice.formats`;
   - require a format whose `supportedColorSpaces` contains `.appleLog`;
   - choose a format compatible with the selected resolution and frame rate where possible;
   - while the device is locked, set `activeFormat` first and then `activeColorSpace = .appleLog`;
   - preserve and restore the previous format and color space when Apple Log is turned off;
   - turn HDR off only when required for the chosen Apple Log format.
3. Keep the Apple Log toggle disabled with “Apple Log is not supported on this camera.” when the selected physical camera reports no compatible format.
4. Remove the Rec. 709 view-assist toggle because the current custom LUT/rendering implementation is being deleted and no undocumented substitute will be introduced.

## Verification
- After each focused edit, run repository checks for stale Apple Log/view-assist references and Swift delimiter/source consistency.
- Run the native Xcode build if Apple tooling is available. This Linux workspace currently has neither `xcodebuild` nor `swiftc`, so an actual iOS SDK compile cannot run here; the final report will state that limitation explicitly rather than claiming an Xcode build occurred.
- Confirm the web app and every unrelated native file remain unchanged.
