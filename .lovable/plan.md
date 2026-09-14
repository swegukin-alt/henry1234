# Prepare the teleprompter for a native iPhone app

Goal: one codebase. The website keeps behaving exactly as it does today; the code is reorganised so that, once you add Capacitor on your Mac, the app automatically uses native iPhone features instead of browser ones.

Nothing about how the app looks or feels changes in this round.

## What the audit already found

The whole app lives in one screen file (`src/routes/index.tsx`, ~2,280 lines) plus a few helpers. It has no backend, no login and no cloud database, so there is nothing to migrate there. Device features currently used directly:

- Camera and video recording: `getUserMedia` + `MediaRecorder`, quality tiers, microphone picking and repair, device-change watching
- Microphone and voice-follow: separate audio capture, transcription through the AI service
- Storage: recordings in the browser's local database, small settings and last-read position in browser settings storage
- Saving and sharing: the iPhone share sheet with a download fallback
- Screen awake, rotation lock, fullscreen, keyboard remote, visibility handling, safe-area padding (already handled throughout)

The Desview remote already works through keyboard events and will not be touched.

## What I will do

### 1. NATIVE_READINESS.md
A full written audit: every device feature found, where it lives, which browser interface it uses today, whether it stays web-based or should go native, which Capacitor package to use, the web fallback, the iPhone permission text needed, whether the simulator can test it or a real iPhone is required, priority, and the risk to the current website.

It will also cover: what needs a small custom Swift plugin later (advanced camera control such as lens choice, focus, exposure, stabilisation, torch), Apple's own speech recognition, Photos-library saving, native BLE, screen brightness, external display/AirPlay as future ideas, and the fact that hardware can only be truly verified on a physical iPhone.

### 2. A platform layer (`src/platform/`)
Small, clearly-typed services the screen calls instead of talking to the browser directly:

`runtime` (web / ios detection and a capabilities report), `camera`, `audio`, `speech`, `storage` (settings vs. large files), `media-library` (saving finished videos), `files` (import/export), `share`, `remote`, `keep-awake`, `orientation`, `lifecycle`, `permissions`, `haptics`.

Each has a web implementation containing exactly today's working code, and a native implementation that currently reports itself as unavailable and falls back to web. When you install the Capacitor packages on your Mac, the native implementations light up without touching any screen code. A failure is always reported honestly — never faked as success.

### 3. Move the existing screen onto the platform layer
Replace the direct browser calls in the teleprompter screen with the service calls, keeping identical behaviour. The scrolling engine, script handling, settings and UI stay exactly as they are. The remote handling is wrapped, not rewritten: the same keys produce the same actions.

### 4. Capacitor configuration and a static build for iOS
Add `capacitor.config.ts` and a separate static build command that produces the file bundle the iPhone app ships, leaving the existing website build untouched. No Capacitor package becomes a runtime requirement for the website.

### 5. A hidden diagnostics screen
Reachable only by a direct address (not in navigation, dev builds only): shows runtime, native yes/no, camera/microphone/storage/Bluetooth/rotation/keep-awake availability, permission states, remote events received and lifecycle state.

### 6. Final report
What I found, what changed, what I deliberately left alone, every package you must install, every iPhone permission entry, what needs a real device, what may need Swift later, and remaining risks.

## What I will not do

No second iPhone interface, no redesign, no rewrite of recording, scrolling or saving, no change to the Desview remote, no Swift plugin, no Xcode work, no automatic permission requests at startup.

## Technical details

- `src/platform/<domain>/{index.ts,types.ts,web.ts,native.ts}` with a single resolver reading `Capacitor.isNativePlatform()` behind a safe wrapper so the web bundle never imports Capacitor.
- Native implementations are lazy dynamic imports, keeping Capacitor out of the browser bundle entirely.
- Documented target packages: `@capacitor/core`, `cli`, `ios`, `filesystem`, `preferences`, `share`, `haptics`, `keyboard`, `status-bar`, `screen-orientation`, `app`, `network`, `@capacitor-community/camera-preview`, `@capacitor-community/bluetooth-le`, a maintained keep-awake plugin, plus a Photos-saving plugin (documented, not yet chosen).
- Camera capability object: `supportsZoom`, `supportsFocus`, `supportsExposure`, `supportsLensSelection`, `supports4K`, `supports60fps`, `supportsStabilization`, `supportsTorch` — each reported truthfully per platform.
- Large recordings stay out of settings storage in both worlds: browser database on web, app filesystem on iPhone, with recoverable metadata and interrupted-save recovery preserved.
- Info.plist keys documented: camera, microphone, photo library (read + add), Bluetooth, and speech recognition only if native speech is adopted.
- Strict typing throughout; no new `any` beyond the existing vendor-prefixed browser calls.
