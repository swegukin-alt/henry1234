# Reading-experience upgrade

Two features, both active in text mode AND video mode, both toggleable from the toolbar.

---

## 1. Voice-follow (highlight only)

While you read, the phone listens via the mic and faintly highlights the word/phrase it thinks you're on. **It never touches scroll speed** — the remote and speed slider stay fully in control. This is a visual aid, not an autopilot.

### How it feels
- Soft amber glow behind the current 2–4 word window (no hard box, no color shift on surrounding text — clean on a beam-splitter)
- Highlight fades in/out over ~150ms so it never flickers
- If recognition drifts (silence, laughter, retakes), highlight gently fades and re-locks when it finds you again — never jumps wildly
- Small mic pill in the top-left shows Listening / Paused / Off, matching the existing external-mic pill style
- One-tap toggle in the toolbar (new mic-with-waveform icon). Off by default; remembers your choice per device.

### How it works
- Web Speech API (`webkitSpeechRecognition`) with `continuous: true`, `interimResults: true`
- Language auto-picks `ko-KR` or `en-US` based on script's dominant script (Hangul ratio); mixed scripts get `ko-KR` (Safari handles Latin words inside it fine)
- Fuzzy match interim transcript against a sliding window of the next ~40 words in the script (normalized: lowercased, punctuation stripped, Korean particles optional). Longest-common-subsequence within the window picks the anchor word.
- Only advance the highlight forward, never backward more than 3 words — prevents jitter from re-recognition
- If no match confidence for 4s → fade highlight, keep listening
- **Video mode:** reuse the existing recording MediaStream's audio track — no second mic session, no conflict with `MediaRecorder`. We tap the track via a `MediaStreamAudioSourceNode` for VAD, and feed recognition from the same track.
- **Permissions:** in text mode, prompt on first toggle-on. In video mode, mic is already granted.
- **Fallback:** if `webkitSpeechRecognition` is unavailable (rare on iOS 17+ Safari), the toggle is disabled with a tooltip.

### Guardrails (so it never wrecks a take)
- Recognition errors are swallowed silently; highlight just fades
- Auto-restart on `onend` (Safari cuts sessions every ~60s)
- Stops immediately on route leave / page hide / recording stop
- Zero effect on the recorded audio — we only *read* the track, never modify it

---

## 2. Chunked phrasing + punctuation pauses

Rewrites the visual flow of the script without changing a single character of your text.

### Chunked phrasing (visual only)
Insert soft line breaks at natural breath-group boundaries so each line is roughly one utterance:
- **Korean:** break after particles (은/는/이/가/을/를/에/에서/으로/와/과/도/만) when they end a phrase, and after 그리고 / 하지만 / 그런데 / 그래서 at the start of a clause
- **English:** break after commas, semicolons, and coordinating conjunctions (and, but, so, because) when the line is already >~40% of the width
- Never split mid-word (already enforced) and never orphan a 1–2 word tail line — merge it up
- Purely CSS/DOM: original script text in state is untouched; we render a chunked view derived from it

### Punctuation pauses
- At `.` `?` `!` `…` → scroll slows to 30% speed for 500ms then eases back
- At `,` `;` `:` `—` → slows to 60% for 250ms
- At Korean `。` `？` `！` `、` — same behavior
- Uses a smooth easing curve on the existing rAF scroll loop; feels like natural delivery, not a stutter
- Toggle in the toolbar (metronome icon). On by default in text mode, off by default in video mode (so takes are perfectly consistent unless you want it).

### Interaction with voice-follow
The two features are independent but complementary: chunking makes phrases visually obvious → recognition matches them more reliably → highlight stays locked. You can use either alone.

---

## Settings & persistence
- Both toggles saved to the existing `localStorage` settings blob
- Added to the Settings panel with short one-line descriptions
- **Reset to defaults** button already exists; it will reset these too (voice-follow OFF, chunking ON in text / OFF in video, pauses ON in text / OFF in video)

---

## Technical section

**Files to change**
- `src/routes/index.tsx` — add toggles to Settings + toolbar, wire voice-follow highlight span into the rendered script, hook punctuation-pause easing into the existing rAF `tick` loop
- `src/lib/voice-follow.ts` *(new)* — `webkitSpeechRecognition` wrapper, language autodetect, fuzzy anchor matcher, auto-restart, cleanup. Exports a `useVoiceFollow({ scriptText, activeStreamAudioTrack, enabled })` hook returning `{ anchorIndex, status }`.
- `src/lib/chunk-script.ts` *(new)* — pure function: `chunk(script, lang) → Array<{ text, startCharIndex }>` with Korean particle + English conjunction rules. Also emits per-character pause weights for the scroll loop.
- `src/components/reader/HighlightLayer.tsx` *(new)* — renders the chunked text with a positioned amber glow behind the current anchor window; CSS-only fade, no re-renders per frame (uses `transform` on a single overlay element indexed by anchor char offset).

**Scroll loop change**
Current `tick` adds a constant `speed` per frame. New: multiplier = `pauseWeightAtCurrentScrollY` (1.0 default, 0.3 at sentence end, 0.6 at commas), with a 500ms/250ms decay. Voice-follow does not touch this loop at all.

**Video mode reuse**
`CameraLayer` already owns the MediaStream. It exposes the current audio track via a ref; the voice-follow hook consumes it when in video mode, and requests its own mic (`getUserMedia({ audio: true })`) in text mode.

**Perf**
- Chunking runs once per script load, memoized
- Highlight overlay updates only when `anchorIndex` changes (typically 2–5× per second), not every frame
- No React re-renders in the scroll loop (already true today)

**Out of scope for this plan**
- Auto-pacing based on voice (explicitly ruled out — highlight only)
- Reading-line indicator, contrast presets, time-remaining, bookmarks (parked for a future round)
