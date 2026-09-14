// Keyboard-style remotes (Desview and friends) plus Web Bluetooth where a
// browser genuinely supports it.
//
// IMPORTANT: the Desview mapping already in the teleprompter screen is the one
// the user's hardware is programmed against. This table mirrors it exactly and
// is here for future remapping and for BLE remotes — the working key handler in
// the teleprompter was deliberately left alone.

import type { RemoteEvent, RemoteMapping, RemoteService } from "./types";

export const DEFAULT_KEY_MAPPING: RemoteMapping = {
  Escape: "EXIT",
  Home: "EXIT",
  "]": "FONT_UP",
  "[": "FONT_DOWN",
  ArrowUp: "JUMP_BACK",
  PageUp: "JUMP_BACK",
  AudioVolumeUp: "JUMP_BACK",
  ArrowDown: "JUMP_FORWARD",
  PageDown: "JUMP_FORWARD",
  AudioVolumeDown: "JUMP_FORWARD",
  ArrowLeft: "SPEED_DOWN",
  "-": "SPEED_DOWN",
  _: "SPEED_DOWN",
  ArrowRight: "SPEED_UP",
  "+": "SPEED_UP",
  "=": "SPEED_UP",
  " ": "SCROLL_TOGGLE",
  Enter: "SCROLL_TOGGLE",
  MediaPlayPause: "SCROLL_TOGGLE",
  MediaPlay: "SCROLL_TOGGLE",
  MediaPause: "SCROLL_TOGGLE",
};

type BluetoothCapableNavigator = Navigator & {
  bluetooth?: { requestDevice: (o: unknown) => Promise<{ id: string; name?: string }> };
};

export const webRemote: RemoteService = {
  name: "remote.web",
  available: () => typeof window !== "undefined",

  capabilities: () => ({
    supportsKeyboardRemotes: true,
    supportsBle:
      typeof navigator !== "undefined" && !!(navigator as BluetoothCapableNavigator).bluetooth,
    supportsScanning:
      typeof navigator !== "undefined" && !!(navigator as BluetoothCapableNavigator).bluetooth,
    supportsBluetoothClassic: false,
  }),

  listenKeyboard(onEvent, mapping = DEFAULT_KEY_MAPPING) {
    const handler = (e: KeyboardEvent) => {
      const action = mapping[e.key];
      if (!action) return;
      const event: RemoteEvent = { action, kind: "hid-keyboard", raw: e.key, at: Date.now() };
      onEvent(event);
    };
    window.addEventListener("keydown", handler, true);
    return () => window.removeEventListener("keydown", handler, true);
  },

  async scanBle() {
    const bt = (navigator as BluetoothCapableNavigator).bluetooth;
    if (!bt) return [];
    try {
      const device = await bt.requestDevice({ acceptAllDevices: true });
      return [{ id: device.id, name: device.name || "Bluetooth device" }];
    } catch {
      return [];
    }
  },
};
