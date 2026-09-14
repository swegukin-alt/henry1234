// Collects the prerendered web build into dist-ios/, the folder Capacitor
// copies into the Xcode project (see capacitor.config.ts → webDir).
//
// Run through: bun run build:ios
//
// The normal website build is untouched; this only reads its output.

import { cp, mkdir, rm, access } from "node:fs/promises";
import { resolve } from "node:path";

const root = process.cwd();
const out = resolve(root, "dist-ios");

// Candidate locations for the prerendered client output, newest layout first.
const CANDIDATES = [
  ".output/public",
  "dist/client",
  ".tanstack/start/build/client-dist",
  "dist",
];

async function exists(p) {
  try {
    await access(p);
    return true;
  } catch {
    return false;
  }
}

const found = [];
for (const c of CANDIDATES) {
  const p = resolve(root, c);
  if (await exists(resolve(p, "index.html"))) found.push(p);
}

if (found.length === 0) {
  console.error(
    "No prerendered index.html found. Checked:\n  " +
      CANDIDATES.join("\n  ") +
      "\nRun `CAP_IOS=1 vite build` first, and make sure prerendering is enabled in vite.config.ts.",
  );
  process.exit(1);
}

await rm(out, { recursive: true, force: true });
await mkdir(out, { recursive: true });
await cp(found[0], out, { recursive: true });

console.log(`iOS web bundle ready: ${found[0]} -> dist-ios`);
console.log("Next, on your Mac: npx cap add ios && npx cap sync ios");
