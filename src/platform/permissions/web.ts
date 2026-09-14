import type { PermissionName, PermissionState } from "../types";
import type { PermissionService } from "./types";

// Browsers only expose a subset of these through the Permissions API, and
// Safari exposes almost none of it. Anything we cannot truthfully read is
// reported as "not-requested" rather than guessed.
const QUERYABLE: Partial<Record<PermissionName, PermissionDescriptor["name"]>> = {
  camera: "camera" as PermissionDescriptor["name"],
  microphone: "microphone" as PermissionDescriptor["name"],
};

function mapState(state: string): PermissionState {
  if (state === "granted") return "granted";
  if (state === "denied") return "denied";
  return "not-requested";
}

export const webPermissions: PermissionService = {
  name: "permissions.web",
  available: () => typeof navigator !== "undefined",

  async check(name) {
    const descriptor = QUERYABLE[name];
    if (!descriptor) return "unavailable";
    try {
      const status = await navigator.permissions?.query({ name: descriptor });
      return status ? mapState(status.state) : "not-requested";
    } catch {
      return "not-requested";
    }
  },

  async request(name) {
    if (name !== "camera" && name !== "microphone") return "unavailable";
    if (!navigator.mediaDevices?.getUserMedia) return "unavailable";
    try {
      // The browser has no "request" call: asking for the stream is the prompt.
      const stream = await navigator.mediaDevices.getUserMedia(
        name === "camera" ? { video: true } : { audio: true },
      );
      stream.getTracks().forEach((t) => t.stop());
      return "granted";
    } catch (err) {
      return (err as { name?: string })?.name === "NotAllowedError" ? "denied" : "unavailable";
    }
  },

  canOpenSettings: () => false,
  async openSettings() {
    /* no such thing in a browser */
  },
};
