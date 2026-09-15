// Saving a finished recording out of the app.
//
// Web: the existing share-sheet-then-download behaviour in
// `src/lib/save-clips.ts`, untouched.
// iOS native: the file goes to the Photos library directly from its path on
// disk. A fake HTML download link is not an acceptable native answer, so if
// the Photos plugin is missing this reports that honestly instead.

import { hasPlugin, isNative } from "../runtime";
import { fail, ok, type ServiceResult } from "../types";

import { loadModule, PLUGIN_MODULES } from "../native-plugins";

type MediaPlugin = {
  saveVideo: (o: { path: string; album?: string }) => Promise<unknown>;
};

export type MediaLibraryCapabilities = {
  canSaveToPhotos: boolean;
  canDownload: boolean;
  requiresUserGesture: boolean;
};

export function mediaLibraryCapabilities(): MediaLibraryCapabilities {
  if (isNative()) {
    return {
      canSaveToPhotos: hasPlugin("Media"),
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

/**
 * Native only: copy a recording from app storage into Photos. The original
 * file stays put — it is only ever deleted by the user, never by an export.
 */
export async function saveVideoToPhotos(path: string): Promise<ServiceResult<void>> {
  if (!isNative()) return fail("Use the browser save flow on the web.", "web-runtime");
  try {
    const mod = await loadModule<{ Media?: MediaPlugin }>(PLUGIN_MODULES.media);
    if (!mod?.Media) return fail("The Photos plugin is not installed in this build.", "plugin-missing");
    if (!mod.Media) return fail("The Photos plugin is not installed in this build.", "plugin-missing");
    await mod.Media.saveVideo({ path });
    return ok(undefined);
  } catch (err) {
    return fail(
      (err as { message?: string })?.message || "Photos refused to save this video.",
      "photos-failed",
    );
  }
}

/** Kept for callers holding a File; native prefers the path-based call above. */
export async function saveToPhotos(_file: File): Promise<ServiceResult<void>> {
  return fail("On iPhone, save from the file on disk with saveVideoToPhotos().", "use-path");
}
