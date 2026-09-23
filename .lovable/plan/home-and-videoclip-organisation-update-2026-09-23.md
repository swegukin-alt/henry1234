# Home and videoclip organisation update

## What will change

- Replace the large standalone logo with a compact, centered top identity: the supplied icon beside “Swegukin Prompter”.
- Keep the three home actions in one row, ordered **Add a script**, **New folder**, **All videoclips**. The first two will share the same blue creation-tile style; All videoclips stays visually separate on the far right.
- Add a native long-press colour picker to user-created organisation folders. Save the selected colour so it remains after relaunching the app.
- Rename **Recent** to **Shooting list** and present every script there as an Apple Files-style folder.
- Each script folder will show its script title, completion control, and video shortcut. The video shortcut starts that script in recording mode; tapping the folder opens that script’s clips.
- Preserve access to editing, deleting, completion, recording, and moving scripts between user-created organisation folders through the existing controls and context menus.
- Change **All videoclips** to a single chronological three-column clip gallery with thumbnails and metadata. Remove only its script-folder browsing layer; keep playback, selection, multi-share/AirDrop, drive copy, camera-roll save, and deletion unchanged.

## Data safety

- Extend only the saved organisation-folder record with an optional colour value, so existing folders and scripts remain compatible.
- Do not change recording, camera, microphone, teleprompter, file naming, clip storage, or export behavior.

## Verification

- Check source references and the available project build signal after implementation.
- Confirm navigation for script-folder → clips and video shortcut → recording.
- Confirm All videoclips remains chronologically ordered and all selection/share/export actions still operate.
- Xcode and physical-device verification will be reported honestly because this environment has no installed iOS SDK.
