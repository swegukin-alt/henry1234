// Native iOS audio.
//
// A correct native implementation configures an AVAudioSession
// (playAndRecord, allowBluetooth, mixWithOthers off) and reports route changes
// and interruptions (calls, Siri, AirPods swaps). No maintained Capacitor 8
// plugin covers that surface, so it needs a small custom Swift plugin — until
// then this reports unavailable and the browser implementation runs inside the
// WebView, which still works.

import { hasPlugin } from "../runtime";
import { fail } from "../types";
import type { AudioService } from "./types";

const PLUGIN = "AudioSession";

export const nativeAudio: AudioService = {
  name: "audio.ios",
  available: () => hasPlugin(PLUGIN),

  capabilities: () => ({
    supportsDeviceSelection: false,
    supportsRouteChangeEvents: true,
    supportsInterruptionEvents: true,
    supportsAudioSession: true,
  }),

  async pickBestInput() {
    return null;
  },
  async applyInput() {
    return fail("Native audio session plugin is not installed in this build.", "plugin-missing");
  },
  async reacquire() {
    return fail("Native audio session plugin is not installed in this build.", "plugin-missing");
  },
  hasLiveInput: (stream) => !!stream?.getAudioTracks().some((t) => t.readyState === "live"),
  onDeviceChange: () => () => {},
  onInterruption: () => () => {},
};
