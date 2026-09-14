import type { PermissionName, PermissionState } from "../types";
import { hasPlugin } from "../runtime";
import type { PermissionService } from "./types";

// Native permission reads come from the plugins that own each capability
// (camera preview, filesystem, BLE, …). Until those packages are installed on
// the Mac, this reports itself unavailable and the web implementation is used.
// The plugin names below are what Capacitor registers them as.
const PLUGIN_FOR: Record<PermissionName, string> = {
  camera: "CameraPreview",
  microphone: "CameraPreview",
  photos: "Filesystem",
  bluetooth: "BluetoothLe",
  speech: "SpeechRecognition",
};

export const nativePermissions: PermissionService = {
  name: "permissions.ios",
  available: () => Object.values(PLUGIN_FOR).some(hasPlugin),

  async check(name: PermissionName): Promise<PermissionState> {
    if (!hasPlugin(PLUGIN_FOR[name])) return "unavailable";
    // Wired up when the plugin packages are installed; see NATIVE_READINESS.md.
    return "not-requested";
  },

  async request(name: PermissionName): Promise<PermissionState> {
    if (!hasPlugin(PLUGIN_FOR[name])) return "unavailable";
    return "not-requested";
  },

  canOpenSettings: () => hasPlugin("App"),
  async openSettings() {
    /* requires @capacitor/app + a small native call; documented, not stubbed as success */
  },
};
