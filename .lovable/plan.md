# Simplify scripts, reader settings, and clip sharing

## Changes
- Remove the manual title field from script creation; continue deriving each title from the script text.
- Keep empty drafts out of the home screen and discard them when the editor closes without text.
- Remove Slow at punctuation, Reading highlight, and Voice follow from settings and playback, while leaving ordinary scrolling unchanged.
- Remove Light/Sepia choices and keep the reader permanently dark.
- Place Save beside Video using matching button dimensions.
- Give completed script rows a clear green background.
- Make sharing work reliably when clips are opened from one script, including single and multi-clip sharing.

## Verification
- Search the native project for removed feature and theme references.
- Validate the affected Swift source structure with the tooling available here.
- Report Xcode/device verification honestly if the iOS SDK is unavailable in this environment.
