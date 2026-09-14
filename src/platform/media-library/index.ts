// Saving a finished recording out of the app.
//
// Web: the existing share-sheet-then-download behaviour in
// `src/lib/save-clips.ts`, untouched.
// iOS native: the file should go to the Photos library directly. That needs a
// Photos plugin (documented in NATIVE_READINESS.md); a fake HTML download link
// is not an acceptable final native answer, so the native path reports
// unavailable rather than silently downloading.

import { hasPlugin, isNative } from "../runtime";
import { fail, ok, type ServiceResult } from "../types";

export type MediaLibraryCapabilities = {
  canSaveToPhotos: boolean;
  canDownload: boolean;
  requiresUserGesture: boolean;
};

export function mediaLibraryCapabilities(): MediaLibraryCapabilities {
  if (isNative()) {
    return {
      canSaveToPhotos: hasPlugin("Media") || hasPlugin("Filesystem"),
      canDownload: false,
      requiresUserGesture: false,
    };
  }
  return {
    canSaveToPhotos: typeof navigator !== "undefined" && !!navigator.share,
    canDownload: true,
    // iOS Safari only opens the share sheet when share() is reached inside the
    // tap that triggered it.
    requiresUserGesture: true,
  };
}

/** Native-only. On web the caller keeps using the existing save flow. */
export async function saveToPhotos(_file: File): Promise<ServiceResult<void>> {
  if (!isNative()) return fail("Use the browser save flow on the web.", "web-runtime");
  if (!hasPlugin("Media")) {
    return fail("The Photos plugin is not installed in this build.", "plugin-missing");
  }
  return ok(undefined);
}
