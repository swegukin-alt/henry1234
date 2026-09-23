# Add branded home organization for scripts

## Changes
- Replace the home-screen title with the supplied Swegukin logo and use the same artwork for the native iOS app icon.
- Replace the long Add a script and All videoclips controls with Apple-style square action tiles, and add a matching New folder tile.
- Add persistent script folders. Folders stay pinned above Recent, show their name and script count, and open into a three-column grid of scripts.
- Keep Recent below the folders in newest-first chronological order and show only scripts that have not been placed in a folder.
- Let scripts be pressed, held, and smoothly dragged onto a folder to move them. Support moving scripts between folders and back to Recent without duplicating them.
- Preserve each script’s existing tick, direct-video shortcut, opening, and deletion behavior. Folder deletion will move its scripts back to Recent so no script is lost.

## Technical details
- Extend the backward-compatible script record with an optional folder identifier and persist folder records atomically beside the existing script data.
- Use native SwiftUI drag and drop with the script ID as the transfer value and visible folder drop feedback.
- Add the uploaded 1024×1024 artwork to the native asset catalog as both the app icon and a normal reusable logo image.
- Keep the existing dark theme and Apple Files-style folder visual language.

## Verification
- Check source consistency for old saved scripts, empty folders, folder deletion, drag moves, and the new logo asset catalog entries.
- Confirm the web preview build remains healthy.
- Report Xcode and physical-device drag testing as unavailable in this environment.
