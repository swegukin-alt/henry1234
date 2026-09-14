// Importing and exporting script text.
// Web: the normal file input / download. Native: the iOS document picker and
// Files/iCloud Drive through @capacitor/filesystem (documented).

import { hasPlugin, isNative } from "../runtime";

export type FilePickCapabilities = {
  canPickDocuments: boolean;
  canWriteToFiles: boolean;
  usesNativePicker: boolean;
};

export function filePickCapabilities(): FilePickCapabilities {
  if (isNative()) {
    return {
      canPickDocuments: hasPlugin("FilePicker") || hasPlugin("Filesystem"),
      canWriteToFiles: hasPlugin("Filesystem"),
      usesNativePicker: true,
    };
  }
  return {
    canPickDocuments: typeof document !== "undefined",
    canWriteToFiles: true,
    usesNativePicker: false,
  };
}

/** Browser text import: a plain file input, created and cleaned up per call. */
export function pickTextFile(accept = ".txt,.md,.rtf,text/plain"): Promise<{ name: string; text: string } | null> {
  return new Promise((resolve) => {
    if (typeof document === "undefined") return resolve(null);
    const input = document.createElement("input");
    input.type = "file";
    input.accept = accept;
    input.style.display = "none";
    const cleanup = () => input.remove();
    input.onchange = async () => {
      const file = input.files?.[0];
      if (!file) {
        cleanup();
        return resolve(null);
      }
      try {
        resolve({ name: file.name.replace(/\.[^.]+$/, ""), text: await file.text() });
      } catch {
        resolve(null);
      } finally {
        cleanup();
      }
    };
    document.body.appendChild(input);
    input.click();
  });
}

/** Browser text export. */
export function downloadText(name: string, text: string): void {
  const url = URL.createObjectURL(new Blob([text], { type: "text/plain" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = `${name}.txt`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}
