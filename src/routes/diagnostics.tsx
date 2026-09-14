// Development-only diagnostics.
//
// Not linked from anywhere in the app. In a production build the page renders
// nothing but a short notice, so it can never become a normal navigation
// destination.

import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import {
  cameraCapabilities,
  checkPermission,
  connectRemote,
  currentOrientation,
  describeRuntime,
  filePickCapabilities,
  hapticsSupported,
  isOnline,
  keepAwakeSupported,
  mediaLibraryCapabilities,
  mediaStoreKind,
  onLifecycleChange,
  orientationSupport,
  remoteService,
  shareCapabilities,
  speechCapabilities,
  storageEstimate,
  type CameraCapabilities,
  type LifecycleState,
  type PermissionState,
  type RemoteEvent,
} from "@/platform";

export const Route = createFileRoute("/diagnostics")({
  head: () => ({
    meta: [
      { title: "Native diagnostics" },
      { name: "description", content: "Development-only view of the device capabilities this build can reach." },
      { name: "robots", content: "noindex" },
      { property: "og:title", content: "Native diagnostics" },
      { property: "og:description", content: "Development-only device capability report." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: Diagnostics,
});

type Row = { label: string; value: string };

function Section({ title, rows }: { title: string; rows: Row[] }) {
  return (
    <section className="mb-6">
      <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-muted-foreground">{title}</h2>
      <dl className="divide-y divide-border rounded-lg border border-border">
        {rows.map((r) => (
          <div key={r.label} className="flex items-center justify-between gap-4 px-3 py-2 text-sm">
            <dt className="text-muted-foreground">{r.label}</dt>
            <dd className="font-mono text-right">{r.value}</dd>
          </div>
        ))}
      </dl>
    </section>
  );
}

const yn = (b: boolean) => (b ? "yes" : "no");

function Diagnostics() {
  const [caps, setCaps] = useState<CameraCapabilities | null>(null);
  const [perms, setPerms] = useState<Record<string, PermissionState>>({});
  const [usage, setUsage] = useState<{ usedBytes: number; quotaBytes: number | null } | null>(null);
  const [events, setEvents] = useState<RemoteEvent[]>([]);
  const [lifecycle, setLifecycle] = useState<LifecycleState>("active");
  const [bleSupported, setBleSupported] = useState(false);
  // Device capabilities only exist in the browser, so nothing is read until
  // after hydration.
  const [ready, setReady] = useState(false);

  useEffect(() => {
    setReady(true);
    void cameraCapabilities().then(setCaps);
    void storageEstimate().then(setUsage);
    void remoteService().then((s) => setBleSupported(s.capabilities().supportsBle));
    void Promise.all(
      (["camera", "microphone", "photos", "bluetooth", "speech"] as const).map(async (p) => [
        p,
        await checkPermission(p),
      ]),
    ).then((pairs) => setPerms(Object.fromEntries(pairs) as Record<string, PermissionState>));

    const offRemote = connectRemote((e) => setEvents((prev) => [e, ...prev].slice(0, 8)));
    const offLifecycle = onLifecycleChange(setLifecycle);
    return () => {
      offRemote();
      offLifecycle();
    };
  }, []);

  if (!import.meta.env.DEV) {
    return <main className="p-8 text-sm text-muted-foreground">Not available in this build.</main>;
  }

  const runtime = describeRuntime();
  const speech = speechCapabilities();
  const share = shareCapabilities();
  const media = mediaLibraryCapabilities();
  const files = filePickCapabilities();
  const orientation = orientationSupport();

  return (
    <main className="mx-auto max-w-2xl px-4 py-8">
      <h1 className="mb-6 text-xl font-semibold">Native diagnostics</h1>

      <Section
        title="Runtime"
        rows={[
          { label: "Platform", value: runtime.platform },
          { label: "Capacitor native", value: yn(runtime.native) },
          { label: "Standalone", value: yn(runtime.standalone) },
          { label: "Lifecycle state", value: lifecycle },
          { label: "Online", value: yn(isOnline()) },
        ]}
      />

      <Section
        title="Camera"
        rows={
          caps
            ? [
                { label: "Preview mode", value: caps.previewMode },
                { label: "Recording output", value: caps.recordingOutput },
                { label: "Zoom", value: yn(caps.supportsZoom) },
                { label: "Focus", value: yn(caps.supportsFocus) },
                { label: "Exposure", value: yn(caps.supportsExposure) },
                { label: "Lens selection", value: yn(caps.supportsLensSelection) },
                { label: "4K", value: yn(caps.supports4K) },
                { label: "60 fps", value: yn(caps.supports60fps) },
                { label: "Stabilisation", value: yn(caps.supportsStabilization) },
                { label: "Torch", value: yn(caps.supportsTorch) },
              ]
            : [{ label: "Camera", value: "reading…" }]
        }
      />

      <Section
        title="Audio and speech"
        rows={[
          { label: "Speech mode", value: speech.mode },
          { label: "On device", value: yn(speech.onDevice) },
          { label: "Needs network", value: yn(speech.requiresNetwork) },
        ]}
      />

      <Section
        title="Storage"
        rows={[
          { label: "Media store", value: mediaStoreKind() },
          { label: "Used", value: usage ? `${(usage.usedBytes / 1e9).toFixed(2)} GB` : "…" },
          { label: "Quota", value: usage?.quotaBytes ? `${(usage.quotaBytes / 1e9).toFixed(2)} GB` : "unknown" },
        ]}
      />

      <Section
        title="Device services"
        rows={[
          { label: "Keep awake", value: yn(keepAwakeSupported()) },
          { label: "Orientation lock", value: yn(orientation.canLock) },
          { label: "Orientation now", value: currentOrientation() },
          { label: "Share files", value: yn(share.canShareFiles) },
          { label: "Save to Photos", value: yn(media.canSaveToPhotos) },
          { label: "Document picker", value: yn(files.canPickDocuments) },
          { label: "Bluetooth LE", value: yn(bleSupported) },
          { label: "Haptics", value: yn(hapticsSupported()) },
        ]}
      />

      <Section
        title="Permissions"
        rows={Object.entries(perms).map(([k, v]) => ({ label: k, value: v }))}
      />

      <Section
        title="Remote events"
        rows={
          events.length
            ? events.map((e, i) => ({ label: `${i + 1}. ${e.raw}`, value: e.action }))
            : [{ label: "Press a remote button", value: "none yet" }]
        }
      />
    </main>
  );
}
