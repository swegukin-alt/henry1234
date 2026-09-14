// iOS audio.
//
// Recording audio in the app is captured by the native capture session
// alongside the video — there is no getUserMedia anywhere on this path, and no
// MediaStream to hand around (the `stream` arguments are ignored here).
//
// What this service does is report and steer that session: which input is in
// use (built-in, wired/USB, AirPods or other Bluetooth), route changes,
// interruptions (calls, Siri, another app taking the mic) and the mic
// disappearing. All of that needs AVAudioSession, which no Capacitor core
// plugin exposes, so it lives in the custom Swift plugin
// `ios-plugin/TeleprompterCapture`. Without that plugin this service says
// plainly that it cannot steer the session — it never reverts to browser audio.

import { noteImpl } from "../runtime";
import { customCapturePlugin } from "../native-plugins";
import { fail, ok } from "../types";
import type { AudioCapabilities, AudioService, MicInfo } from "./types";

type NativeInput = { deviceId: string; label: string; external: boolean; available: boolean };

type CapturePlugin = {
  audioStatus: () => Promise<NativeInput & { route: string }>;
  listAudioInputs: () => Promise<{ inputs: NativeInput[] }>;
  setAudioInput: (o: { deviceId: string }) => Promise<void>;
  addListener: (
    event: "audioInterruption" | "audioRouteChange",
    cb: (data: { type?: string; reason?: string }) => void,
  ) => Promise<{ remove: () => void }>;
};

let plugin: CapturePlugin | null = null;
let looked = false;
let liveKnown = true;

async function capture(): Promise<CapturePlugin | null> {
  if (!looked) {
    looked = true;
    plugin = await customCapturePlugin<CapturePlugin>();
    noteImpl(
      "audio",
      plugin ? "native (TeleprompterCapture)" : "native capture session (no control plugin)",
    );
  }
  return plugin;
}

const needsPlugin =
  "Microphone control on iOS needs the TeleprompterCapture plugin. The camera's own microphone is still recording.";

export const nativeAudio: AudioService = {
  name: "audio.ios",
  // The native capture session always records audio with the video, so audio
  // itself works on iOS even before the control plugin is added.
  available: () => true,

  capabilities(): AudioCapabilities {
    const full = !!plugin;
    return {
      supportsDeviceSelection: full,
      supportsRouteChangeEvents: full,
      supportsInterruptionEvents: full,
      supportsAudioSession: full,
    };
  },

  async pickBestInput(): Promise<MicInfo | null> {
    const p = await capture();
    if (!p) return null;
    try {
      const list = await p.listAudioInputs();
      const inputs = (list.inputs ?? []).filter((i) => i.available);
      // An external mic (DJI, USB-C, wired or AirPods) beats the built-in one.
      const best = inputs.find((i) => i.external) ?? inputs[0];
      liveKnown = inputs.length > 0;
      return best ? { id: best.deviceId, label: best.label, external: best.external } : null;
    } catch {
      return null;
    }
  },

  async applyInput(_stream, mic) {
    const p = await capture();
    if (!p) return fail(needsPlugin, "plugin-missing");
    try {
      await p.setAudioInput({ deviceId: mic.id });
      return ok(undefined);
    } catch (e) {
      return fail((e as { message?: string })?.message || "That microphone could not be selected.");
    }
  },

  async reacquire(_stream, preferredId) {
    const p = await capture();
    if (!p) return fail(needsPlugin, "plugin-missing");
    try {
      if (preferredId) await p.setAudioInput({ deviceId: preferredId });
      const s = await p.audioStatus();
      liveKnown = !!s.available;
      return s.available
        ? ok(undefined)
        : fail("No microphone is connected. Reconnect it and press record again.");
    } catch {
      liveKnown = false;
      return fail("The microphone could not be checked.");
    }
  },

  // Synchronous by contract. The value is refreshed by route-change events and
  // by reacquire(); with no control plugin the capture session owns the mic and
  // there is nothing that could have taken it away.
  hasLiveInput() {
    return plugin ? liveKnown : true;
  },

  onDeviceChange(cb) {
    let off: (() => void) | null = null;
    void capture().then(async (p) => {
      if (!p) return;
      const sub = await p.addListener("audioRouteChange", () => {
        void p.audioStatus().then((s) => {
          liveKnown = !!s.available;
        });
        cb();
      });
      off = () => sub.remove();
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
      off = () => sub.remove();
    });
    return () => off?.();
  },
};
