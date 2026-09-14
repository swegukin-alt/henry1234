// iOS permissions.
//
// Camera and microphone come from the custom capture plugin (AVCaptureDevice /
// AVAudioSession), because that is the code that actually opens them. Photos
// comes from @capacitor-community/media, which is what writes to the camera
// roll. Nothing is requested at startup — each call happens only when the user
// uses the feature.
//
// Anything we cannot genuinely read is reported as "not-requested" rather than
// guessed. Settings is opened through @capacitor/app with the iOS
// `app-settings:` URL.

import type { PermissionName, PermissionState } from "../types";
import { hasPlugin, noteImpl } from "../runtime";
import { customCapturePlugin, loadModule, PLUGIN_MODULES } from "../native-plugins";
import type { PermissionService } from "./types";

type NativeState = "granted" | "denied" | "prompt" | "prompt-with-rationale" | "limited" | "restricted";

type CapturePermissions = {
  checkPermissions: () => Promise<{ camera?: NativeState; microphone?: NativeState }>;
  requestPermissions: (o?: { permissions?: string[] }) => Promise<{
    camera?: NativeState;
    microphone?: NativeState;
  }>;
};

type MediaPlugin = {
  checkPermissions?: () => Promise<{ photos?: NativeState }>;
  requestPermissions?: () => Promise<{ photos?: NativeState }>;
};

type AppPlugin = { openUrl: (o: { url: string }) => Promise<{ completed: boolean }> };

function toState(s: NativeState | undefined): PermissionState {
  switch (s) {
    case "granted":
    case "limited":
      return "granted";
    case "denied":
      return "denied";
    case "restricted":
      return "restricted";
    case "prompt":
    case "prompt-with-rationale":
      return "not-requested";
    default:
      return "not-requested";
  }
}

const capture = () => customCapturePlugin<CapturePermissions>();
const media = () =>
  loadModule<{ Media?: MediaPlugin }>(PLUGIN_MODULES.media).then((m) => m?.Media ?? null);

export const nativePermissions: PermissionService = {
  name: "permissions.ios",
  available: () => true,

  async check(name: PermissionName): Promise<PermissionState> {
    noteImpl("permissions", "native");
    if (name === "camera" || name === "microphone") {
      const p = await capture();
      if (!p?.checkPermissions) {
        // Without the custom plugin iOS only reveals the answer when the
        // camera is actually opened; saying "granted" here would be a lie.
        return "not-requested";
      }
      const res = await p.checkPermissions();
      return toState(name === "camera" ? res.camera : res.microphone);
    }
    if (name === "photos") {
      const m = await media();
      if (!m?.checkPermissions) return "not-requested";
      try {
        return toState((await m.checkPermissions()).photos);
      } catch {
        return "not-requested";
      }
    }
    // Bluetooth and speech have no native implementation in this build.
    return "unavailable";
  },

  async request(name: PermissionName): Promise<PermissionState> {
    if (name === "camera" || name === "microphone") {
      const p = await capture();
      if (!p?.requestPermissions) return "not-requested";
      const res = await p.requestPermissions({ permissions: [name] });
      return toState(name === "camera" ? res.camera : res.microphone);
    }
    if (name === "photos") {
      const m = await media();
      if (!m?.requestPermissions) return "not-requested";
      try {
        return toState((await m.requestPermissions()).photos);
      } catch {
        return "denied";
      }
    }
    return "unavailable";
  },

  canOpenSettings: () => hasPlugin("App"),

  async openSettings() {
    const mod = await loadModule<{ App?: AppPlugin }>(PLUGIN_MODULES.app);
    try {
      await mod?.App?.openUrl({ url: "app-settings:" });
    } catch {
      /* the user can still reach Settings manually */
    }
  },
};
