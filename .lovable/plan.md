# Fix landscape back swipes and meter placement

## Changes
- Make the interactive back gesture use the full physical left edge in both landscape directions, while preserving vertical scrolling and existing screen transitions.
- Add the same interactive swipe-back behavior when clips are opened from the recording screen, returning to that recording screen rather than Home.
- Move the pre-recording microphone meter and horizon gauge from above the bottom toolbar to the middle-left safe area so they remain unobstructed in landscape.

## Verification
- Check the navigation stack still returns to the immediately previous folder or screen.
- Validate source structure and the available project build diagnostics; report that physical iPhone/Xcode testing is still required if unavailable here.
