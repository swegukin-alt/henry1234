import type { PlatformService } from "../types";

/** Every remote, of every kind, is normalised into these actions. */
export type RemoteAction =
  | "RECORD_TOGGLE"
  | "RECORD_START"
  | "RECORD_STOP"
  | "SCROLL_TOGGLE"
  | "SCROLL_START"
  | "SCROLL_PAUSE"
  | "SPEED_UP"
  | "SPEED_DOWN"
  | "JUMP_FORWARD"
  | "JUMP_BACK"
  | "NEXT_CUE"
  | "PREVIOUS_CUE"
  | "FONT_UP"
  | "FONT_DOWN"
  | "EXIT";

export type RemoteKind =
  /** Appears to iOS as a keyboard/media controller (Desview and most clickers). */
  | "hid-keyboard"
  /** A real Bluetooth Low Energy peripheral with services and characteristics. */
  | "ble"
  | "none";

export type RemoteEvent = {
  action: RemoteAction;
  kind: RemoteKind;
  /** The raw key or characteristic value, for the mapping UI and diagnostics. */
  raw: string;
  at: number;
};

export type RemoteMapping = Record<string, RemoteAction>;

export type RemoteCapabilities = {
  supportsKeyboardRemotes: boolean;
  supportsBle: boolean;
  supportsScanning: boolean;
  /** Bluetooth Classic (non-BLE) devices can never be reached from either runtime. */
  supportsBluetoothClassic: false;
};

export type RemoteService = PlatformService & {
  capabilities: () => RemoteCapabilities;
  /** Keyboard-style remotes. Returns an unsubscribe function. */
  listenKeyboard: (onEvent: (e: RemoteEvent) => void, mapping?: RemoteMapping) => () => void;
  /** BLE peripherals only — never used for a device acting as a keyboard. */
  scanBle: () => Promise<{ id: string; name: string }[]>;
};
