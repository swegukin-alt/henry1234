// Sharing. Web keeps navigator.share with the download fallback that already
// works; native should use @capacitor/share against a real file path.

import { hasPlugin, isNative } from "../runtime";
import { fail, ok, type ServiceResult } from "../types";

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

export async function shareFilePath(path: string, title: string): Promise<ServiceResult<void>> {
  if (!isNative()) return fail("Use the browser share flow on the web.", "web-runtime");
  if (!hasPlugin("Share")) return fail("The share plugin is not installed in this build.", "plugin-missing");
  void path;
  void title;
  return ok(undefined);
}
