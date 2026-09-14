import { pickImpl } from "../runtime";
import { webRemote } from "./web";
import type { RemoteEvent, RemoteMapping, RemoteService } from "./types";

export type * from "./types";
export { DEFAULT_KEY_MAPPING } from "./web";

let resolved: Promise<RemoteService> | null = null;

export function remoteService(): Promise<RemoteService> {
  resolved ??= pickImpl(webRemote, async () => (await import("./native")).nativeRemote);
  return resolved;
}

/** Subscribe to normalised remote actions. Returns an unsubscribe function. */
export function connectRemote(
  onEvent: (e: RemoteEvent) => void,
  mapping?: RemoteMapping,
): () => void {
  let off: (() => void) | null = null;
  let cancelled = false;
  void remoteService().then((svc) => {
    if (cancelled) return;
    off = svc.listenKeyboard(onEvent, mapping);
  });
  return () => {
    cancelled = true;
    off?.();
    off = null;
  };
}
