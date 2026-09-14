// iOS audio.
//
// Recording audio on the app is captured by the native capture session
// alongside the video — there is no getUserMedia anywhere on this path. What
// this service does is report and steer that session: permission, which input
// is in use (built-in, wired/USB, AirPods or other Bluetooth), route changes,
// interruptions (calls, Siri, another app grabbing the mic) and the mic
// disappearing.
//
// Everything beyond "is a microphone present" needs AVAudioSession, which no
// Capacitor core plugin exposes, so it lives in the custom Swift plugin
// `ios-plugin/TeleprompterCapture`. Without that plugin this service reports
// honestly that it cannot steer the session; it never falls back to browser
// audio inside the app.

import { noteImpl } from "../runtime";
import { customCapturePlugin } from "../native-plugins";
import { fail, ok } from "../types";
import type { AudioInput, AudioService } from "./types";

type AudioStatus = {
  available: boolean;
  deviceId: string;
  label: string;
  external: boolean;
  route: string;
};

type CapturePlugin = {
  audioStatus: () => Promise<AudioStatus>;
  listAudioInputs: () => Promise<{ inputs: AudioStatus[] }>;
  setAudioInput: (o: { deviceId: string }) => Promise<void>;
  addListener: (
    event: "audioInterruption" | "audioRouteChange",
    cb: (data: { type?: string; reason?: string }) => void,
  ) => Promise<{ remove: () => Promise<void> }> | { remove: () => void };
};

let plugin: CapturePlugin | null = null;
let looked = false;

async function capture(): Promise<CapturePlugin | null> {
  if (!looked) {
    looked = true;
    plugin = await customCapturePlugin<CapturePlugin>();
    noteImpl("audio", plugin ? "native (TeleprompterCapture)" : "native capture session (no control plugin)");
  }
  return plugin;
}

const needsPlugin =
  "Microphone control on iOS needs the TeleprompterCapture plugin. The camera's own microphone is still recording.";

export const nativeAudio: AudioService = {
  name: "audio.ios",
  // The native capture session always records audio with the video, so this
  // service is "available" on iOS even before the control plugin is added.
  available: () => true,

  async pickBestInput(): Promise<AudioInput | null> {
    const p = await capture();
    if (!p) return null;
    try {
      const s = await p.audioStatus();
      if (!s.available) return null;
      return { id: s.deviceId, label: s.label, external: s.external };
    } catch {
      return null;
    }
  },

  async applyInput(input) {
    const p = await capture();
    if (!p) return fail(needsPlugin, "plugin-missing");
    try {
      await p.setAudioInput({ deviceId: input.id });
      return ok(undefined);
    } catch (e) {
      return fail((e as { message?: string })?.message || "That microphone could not be selected.");
    }
  },

  async reacquire() {
    const p = await capture();
    if (!p) return fail(needsPlugin, "plugin-missing");
    try {
      const s = await p.audioStatus();
      return s.available
        ? ok(undefined)
        : fail("No microphone is connected. Reconnect it and press record again.");
    } catch {
      return fail("The microphone could not be checked.");
    }
  },

  async hasLiveInput() {
    const p = await capture();
    if (!p) return true; // the capture session owns the mic; assume nothing else
    try {
      return (await p.audioStatus()).available;
    } catch {
      return false;
    }
  },

  onDeviceChange(cb) {
    let off: (() => void) | null = null;
    void capture().then(async (p) => {
      if (!p) return;
      const sub = await p.addListener("audioRouteChange", () => cb());
      off = () => void (sub as { remove: () => void }).remove();
    });
    return () => off?.();
  },

  onInterruption(cb) {
    let off: (() => void) | null = null;
    void capture().then(async (p) => {
      if (!p) return;
      const sub = await p.addListener("audioInterruption", (d) =>
        cb(d?.type === "ended" ? "ended" : "began"),
      );
      off = () => void (sub as { remove: () => void }).remove();
    });
    return () => off?.();
  },
};
