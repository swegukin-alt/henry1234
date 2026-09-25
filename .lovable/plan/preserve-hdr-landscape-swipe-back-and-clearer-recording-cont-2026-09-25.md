# Preserve HDR, landscape swipe-back, and clearer recording controls

## Changes

- Keep the selected native HDR mode independent from 180° shutter control.
  - Remove any shutter-angle path that can alter the selected format, HDR flag, color space, or session preset.
  - Apply only the fixed exposure duration and automatic ISO/white balance behavior before and during recording.
  - After applying the shutter, read the device’s actual HDR state and report a camera warning rather than silently changing HDR if the selected hardware mode cannot retain it.
- Make interactive swipe-back work in portrait and landscape.
  - Expand the active left-edge region by the landscape safe-area inset so the gesture starts where the visible screen edge begins around the camera cutout.
  - Keep the current page-following-finger animation, previous-page reveal, completion threshold, and spring cancellation behavior.
- Increase bottom recording-bar visibility without changing its actions.
  - Use a stronger opaque dark bar, higher-contrast equal-size circular button surfaces, brighter/heavier symbols, and a more prominent record/stop control.
  - Preserve the existing rule that controls hide during recording and reappear only when the screen is tapped.

## Verification

- Confirm source checks show shutter-angle code does not write HDR, color-space, format, or session-preset settings.
- Check portrait and landscape swipe geometry in the native layouts.
- Check the latest project health result and report that Xcode/device HDR verification still requires the user’s iPhone if Xcode remains unavailable here.
