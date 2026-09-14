// Browser microphone handling — the existing, working behaviour, unchanged.

import { fail, ok } from "../types";
import type { AudioService, MicInfo } from "./types";

// iOS Safari exposes labels like "DJI MIC 2 (Bluetooth)", "USB Audio Device",
// "iPhone Microphone" once microphone permission has been granted.
const EXTERNAL_MIC_RE =
  /usb|dji|rode|røde|shure|sennheiser|zoom |comica|hollyland|godox|saramonic|maono|movo|boya|blue snowball|blue yeti|wireless|lavalier|lav mic|external|mic 2|mic pro|airpods|beats|bose|sony|jbl|bluetooth/i;
const BUILTIN_MIC_RE = /built.?in|iphone|internal|default/i;

export const webAudio: AudioService = {
  name: "audio.web",
  available: () => typeof navigator !== "undefined" && !!navigator.mediaDevices?.getUserMedia,

  capabilities: () => ({
    supportsDeviceSelection: true,
    supportsRouteChangeEvents: typeof navigator !== "undefined" && !!navigator.mediaDevices,
    supportsInterruptionEvents: false,
    supportsAudioSession: false,
  }),

  async pickBestInput(): Promise<MicInfo | null> {
    try {
      const devices = await navigator.mediaDevices.enumerateDevices();
      const inputs = devices.filter((d) => d.kind === "audioinput" && d.deviceId);
      if (inputs.length === 0) return null;
      const ext = inputs.find((d) => d.label && EXTERNAL_MIC_RE.test(d.label));
      if (ext) return { id: ext.deviceId, label: ext.label, external: true };
      const other = inputs.find(
        (d) => d.deviceId !== "default" && d.label && !BUILTIN_MIC_RE.test(d.label),
      );
      if (other && inputs.length > 1) return { id: other.deviceId, label: other.label, external: true };
      const builtin = inputs.find((d) => BUILTIN_MIC_RE.test(d.label)) || inputs[0];
      return { id: builtin.deviceId, label: builtin.label || "Built-in mic", external: false };
    } catch {
      return null;
    }
  },

  async applyInput(stream, mic) {
    const currentTrack = stream.getAudioTracks()[0];
    const swap = async (constraints: MediaTrackConstraints): Promise<boolean> => {
      const fresh = await navigator.mediaDevices.getUserMedia({ audio: constraints });
      const newTrack = fresh.getAudioTracks()[0];
      if (!newTrack) return false;
      // Swap atomically on the same stream so the video element and any future
      // recorder keep seeing one continuous stream.
      if (currentTrack) {
        stream.removeTrack(currentTrack);
        try {
          currentTrack.stop();
        } catch {
          /* already stopped */
        }
      }
      newTrack.enabled = true;
      stream.addTrack(newTrack);
      return true;
    };
    // External mics get raw audio for fidelity; the built-in mic keeps
    // echo/noise/gain processing on. Preferences only — an unsatisfiable audio
    // requirement must never cost us the microphone entirely.
    const preferred = {
      deviceId: { exact: mic.id },
      echoCancellation: !mic.external,
      noiseSuppression: !mic.external,
      autoGainControl: !mic.external,
      sampleRate: { ideal: 48000 },
      channelCount: { ideal: 2 },
    } as unknown as MediaTrackConstraints;
    try {
      await swap(preferred);
      return ok(undefined);
    } catch {
      try {
        await swap({ deviceId: { exact: mic.id } } as unknown as MediaTrackConstraints);
        return ok(undefined);
      } catch {
        return fail("Could not switch to that microphone.");
      }
    }
  },

  async reacquire(stream, preferredId) {
    if (stream.getAudioTracks().some((t) => t.readyState === "live")) return ok(undefined);
    try {
      const fresh = await navigator.mediaDevices.getUserMedia({
        audio: preferredId ? ({ deviceId: { exact: preferredId } } as MediaTrackConstraints) : true,
      });
      const t = fresh.getAudioTracks()[0];
      if (!t) return fail("No microphone available.");
      stream.getAudioTracks().forEach((old) => {
        try {
          stream.removeTrack(old);
        } catch {
          /* already detached */
        }
      });
      t.enabled = true;
      stream.addTrack(t);
      return ok(undefined);
    } catch {
      return fail("No microphone available.");
    }
  },

  hasLiveInput: (stream) => !!stream?.getAudioTracks().some((t) => t.readyState === "live"),

  onDeviceChange(cb) {
    try {
      navigator.mediaDevices.addEventListener("devicechange", cb);
    } catch {
      return () => {};
    }
    return () => {
      try {
        navigator.mediaDevices.removeEventListener("devicechange", cb);
      } catch {
        /* listener already gone */
      }
    };
  },

  // Browsers give no interruption signal; visibility handling covers the
  // practical cases and the lifecycle service owns that.
  onInterruption: () => () => {},
};
