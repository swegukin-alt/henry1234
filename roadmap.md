# Roadmap

## Done
- Teleprompter: library, editor, reading engine, mirror modes, assists, remote keys.
- Video mode: camera, mic selection and watchdog, chunked recording, All videos, repair/restore, save/share.
- Native readiness (Capacitor 8 prep):
  - NATIVE_READINESS.md — full audit, packages, Info.plist keys, risks.
  - src/platform/* — runtime, camera, audio, speech, storage/settings, media-library,
    files, share, remote, keep-awake, orientation, lifecycle, permissions, haptics.
  - App moved onto the layer for settings, wake lock, fullscreen/orientation.
  - capacitor.config.ts + `bun run build:ios` → dist-ios/.
  - Dev-only /diagnostics page.

## Open (needs the Mac / a real iPhone)
- Install the Capacitor packages listed in NATIVE_READINESS.md.
- `npx cap add ios && npx cap sync ios`, add Info.plist keys, build in Xcode.
- Wire the native camera preview, audio session and Photos saving once the
  plugins are present; test on a physical iPhone.
