// Sharing. Web keeps navigator.share with the download fallback that already
// works; native uses @capacitor/share against a real file path.

import { hasPlugin, isNative } from "../runtime";
import { fail, ok, type ServiceResult } from "../types";

import { loadModule, PLUGIN_MODULES } from "../native-plugins";

type SharePlugin = {
  share: (o: { title?: string; text?: string; url?: string; dialogTitle?: string }) => Promise<unknown>;
};

export type ShareCapabilities = {
  canShareFiles: boolean;
  /** Must be called synchronously inside the tap (iOS Safari). */
  requiresUserGesture: boolean;
};

export function shareCapabilities(): ShareCapabilities {
  if (isNative()) {
    return { canShareFiles: hasPlugin("Share"), requiresUserGesture: false };
  }
  const nav = typeof navigator === "undefined" ? null : navigator;
  return { canShareFiles: !!nav?.share, requiresUserGesture: true };
}

/**
 * Open the iOS share sheet for a file already on disk. Nothing is copied: the
 * sheet is handed the file's own URI, so multi-gigabyte takes share instantly.
 */
export async function shareFilePath(path: string, title: string): Promise<ServiceResult<void>> {
  if (!isNative()) return fail("Use the browser share flow on the web.", "web-runtime");
  try {
    const mod = await loadModule<{ Share?: SharePlugin }>(PLUGIN_MODULES.share);
    if (!mod?.Share) return fail("The share plugin is not installed in this build.", "plugin-missing");
    if (!mod.Share) return fail("The share plugin is not installed in this build.", "plugin-missing");
    await mod.Share.share({ title, url: path, dialogTitle: title });
    return ok(undefined);
  } catch (err) {
    const msg = (err as { message?: string })?.message || "";
    if (/cancel/i.test(msg)) return fail("Sharing was cancelled.", "cancelled");
    return fail(msg || "The share sheet could not be opened.", "share-failed");
  }
}
