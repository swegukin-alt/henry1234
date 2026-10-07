# Roadmap

- [x] Replace Log's opaque exposure-offset feedback with whole-frame 48-zone scene-linear metering and separate measured EV from compensation (synthetic calibration/integration checks passed; Xcode build, iPhone exposure/colour-matrix and performance verification unavailable).

- [x] Make native 95% zebras screen-sized with finer coverage, bounded 30 Hz updates and verified signal thresholds (source checks passed; Xcode and iPhone visual/performance testing unavailable).

- [x] Add pre-recording 95% zebras and an undimmed, unobstructed framing preview (source/threshold checks passed; Xcode and physical-iPhone verification unavailable).

- [x] Prevent long native scripts from truncating or losing their reading position.
- [x] Match the native library and editor to the web app.
- [x] Match native prompter typography, scrolling, controls, settings, and video treatment to the web app.
- [x] Match the clips presentation while retaining Save to camera roll and Share.
- [x] Validate all native Swift sources available in this environment.
- [x] Correct native camera field of view and portrait/landscape rotation.
- [x] Keep long pasted scripts inside a fixed-height scrolling editor.
- [x] Reduce long-script redraw work during teleprompter scrolling.
- [x] Expose native camera quality controls before capture starts.
- [x] Remove front-camera crop, reset zoom, and enable continuous focus/exposure.
- [x] Keep video controls above the camera and reduce per-frame text composition work.
- [x] Lock native reading geometry, chunk spacing, font features, and tap-to-hide controls to web behavior.
- [x] Keep native recording active through Control Center and other temporary system overlays.
- [x] Continue native recording in protected segments after Notification Center or system interruptions.
- [x] Add a live FX6-style native horizon gauge before recording.
- [x] Record USB-C microphones at full sample rate and channel count.
- [x] Show accurate pre-recording audio levels with a manual gain control.
- [x] Remember the manual gain level between takes and app launches.
- [x] Give the microphone a manual -20…+20 dB gain that is applied to the recorded audio.
- [x] Simplify native script creation, remove discontinued reader options, style completed scripts, and restore per-script clip sharing.
- [x] Generate smarter local script titles, use globally numbered recording files, and show videoclips in three-column grids.
- [x] Brand the native home screen and organize scripts with pinned folders and drag-and-drop.
- [x] Refine native home branding, colour organisation folders, move script clip folders to Shooting list, and flatten All videoclips.
- [x] Simplify organisation-folder interiors and clarify each shooting-list folder's record and edit controls.
- [x] Enlarge and evenly space recording controls, keeping them visible throughout each take.
- [x] Keep HDR independent while enforcing an exact 180° shutter before and during recording.
- [x] Hide recording controls until tapped and unify the toolbar with sleek, equal-size native icons.
- [x] Preserve native HDR when 180° shutter is incompatible, support landscape swipe-back, and improve recording-bar visibility.
- [x] Make every back swipe work from either landscape orientation, including clips opened from recording.
- [x] Move the pre-recording audio meter and horizon gauge clear of the bottom toolbar.
- [x] Record Apple Log HEVC live at the exact slider bitrate (no ProRes fallback surprise, no after-take rewrite).
