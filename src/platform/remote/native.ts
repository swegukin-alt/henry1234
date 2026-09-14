// Native remotes.
//
// A Bluetooth HID remote (Desview and most clickers) reaches the WebView as
// ordinary key events even inside the native app, so keyboard handling stays
// shared — no BLE scanning for those devices. Genuine BLE peripherals should go
// through @capacitor-community/bluetooth-le once it is installed.

import { hasPlugin } from "../runtime";
import { webRemote } from "./web";
import type { RemoteService } from "./types";

export const nativeRemote: RemoteService = {
  name: "remote.ios",
  available: () => hasPlugin("BluetoothLe"),

  capabilities: () => ({
    supportsKeyboardRemotes: true,
    supportsBle: hasPlugin("BluetoothLe"),
    supportsScanning: hasPlugin("BluetoothLe"),
    supportsBluetoothClassic: false,
  }),

  // Identical to the web path on purpose: HID remotes are keyboards.
  listenKeyboard: webRemote.listenKeyboard,

  async scanBle() {
    return [];
  },
};
