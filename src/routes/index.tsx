import { createFileRoute } from "@tanstack/react-router";
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { ChevronLeft, FlipVertical2, Play, Pause, SlidersHorizontal, Type, MoreHorizontal, Video, Circle, Square, Film, Share2, Trash2, X, Mic, AudioLines, AlignJustify, Timer } from "lucide-react";
import { listClips, deleteClip, deleteAllForScript, fmtSize, fmtDuration, createSession, appendChunk, finalizeSession, recoverOrphanSessions, requestPersistentStorage, type ClipRecord } from "@/lib/clip-store";
import { tokenize, wordListFromTokens, detectLang, type Token } from "@/lib/chunk-script";
import { useVoiceFollow, isVoiceFollowSupported } from "@/lib/voice-follow";


export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Let's kick some ass" },
      { name: "description", content: "A clean, easy-to-read teleprompter with mirror mode, live progress, and Korean support." },
      { name: "theme-color", content: "#0a0a0a" },
      { name: "apple-mobile-web-app-capable", content: "yes" },
      { name: "apple-mobile-web-app-status-bar-style", content: "black-translucent" },
      { property: "og:title", content: "Let's kick some ass" },
      { property: "og:description", content: "A clean teleprompter that runs in your browser." },
    ],
  }),
  component: Index,
});

type Script = { id: string; title: string; body: string; updatedAt: number };
type Settings = {
  fontSize: number;
  speed: number; // px per second
  mirrorH: boolean;
  mirrorV: boolean;
  bg: string; // 'black' | 'white' | 'sepia'
  countdown: number; // seconds
  width: number; // max width % 50-100
  // Reading assist
  voiceFollow: boolean; // soft highlight follows your voice (mic)
  chunking: boolean;    // break script into breath-groups at natural pauses
  pauses: boolean;      // briefly slow scroll at commas / sentence ends
};

const STORAGE_SCRIPTS = "prompter.scripts.v1";
const STORAGE_ACTIVE = "prompter.active.v1";
const STORAGE_SETTINGS = "prompter.settings.v1";

const DEFAULT_SETTINGS: Settings = {
  fontSize: 72,
  speed: 70,

  mirrorH: false,
  mirrorV: false,
  bg: "black",
  countdown: 3,
  width: 82,
  voiceFollow: false,
  chunking: true,
  pauses: true,
};


const SAMPLE = `여러분, 안녕하세요. 오늘 이 자리에 함께해 주셔서 감사합니다.

Welcome. This is your teleprompter. Paste a script, tap Play, and the words will scroll smoothly.

화면 하단에 남은 분량이 퍼센트로 표시됩니다. Adjust speed and font size from the controls. Tap the screen to pause.`;

function uid() {
  return Math.random().toString(36).slice(2, 10);
}

// Unified landscape entry — same call from both Play and Video buttons.
// Must run synchronously inside the user gesture for iOS to honor fullscreen.
function enterLandscape() {
  if (typeof document === "undefined") return;
  const el: any = document.documentElement;
  const req = el.requestFullscreen || el.webkitRequestFullscreen || el.webkitEnterFullscreen;
  try { req?.call(el)?.catch?.(() => {}); } catch {}
  try { (screen as any).orientation?.lock?.("landscape")?.catch?.(() => {}); } catch {}
}

function load<T>(key: string, fallback: T): T {
  if (typeof window === "undefined") return fallback;
  try {
    const raw = localStorage.getItem(key);
    return raw ? (JSON.parse(raw) as T) : fallback;
  } catch {
    return fallback;
  }
}

function save<T>(key: string, value: T) {
  if (typeof window === "undefined") return;
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {}
}

function Index() {
  const [scripts, setScripts] = useState<Script[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [settings, setSettings] = useState<Settings>(DEFAULT_SETTINGS);
  const [mode, setMode] = useState<"library" | "edit" | "play" | "video">("library");
  const [hydrated, setHydrated] = useState(false);

  useEffect(() => {
    const loaded = load<Script[]>(STORAGE_SCRIPTS, []);
    if (loaded.length === 0) {
      const first: Script = { id: uid(), title: "Sample script", body: SAMPLE, updatedAt: Date.now() };
      setScripts([first]);
      setActiveId(first.id);
      save(STORAGE_SCRIPTS, [first]);
      save(STORAGE_ACTIVE, first.id);
    } else {
      setScripts(loaded);
      setActiveId(load<string | null>(STORAGE_ACTIVE, loaded[0].id));
    }
    setSettings({ ...DEFAULT_SETTINGS, ...load<Partial<Settings>>(STORAGE_SETTINGS, {}) });
    setHydrated(true);
  }, []);

  useEffect(() => { if (hydrated) save(STORAGE_SCRIPTS, scripts); }, [scripts, hydrated]);
  useEffect(() => { if (hydrated && activeId) save(STORAGE_ACTIVE, activeId); }, [activeId, hydrated]);
  useEffect(() => { if (hydrated) save(STORAGE_SETTINGS, settings); }, [settings, hydrated]);

  const active = useMemo(() => scripts.find((s) => s.id === activeId) ?? null, [scripts, activeId]);

  const updateActive = (patch: Partial<Script>) => {
    setScripts((arr) => arr.map((s) => (s.id === activeId ? { ...s, ...patch, updatedAt: Date.now() } : s)));
  };
  const createScript = () => {
    const s: Script = { id: uid(), title: "Untitled script", body: "", updatedAt: Date.now() };
    setScripts((a) => [s, ...a]);
    setActiveId(s.id);
    setMode("edit");
  };
  const deleteScript = (id: string) => {
    setScripts((a) => a.filter((s) => s.id !== id));
    if (activeId === id) setActiveId(null);
  };

  if (!hydrated) return <div className="min-h-screen bg-[#0a0a0a]" />;

  if ((mode === "play" || mode === "video") && active) {
    return (
      <Prompter
        script={active}
        settings={settings}
        videoMode={mode === "video"}
        onExit={() => setMode("edit")}
        onSettings={setSettings}
      />
    );
  }

  return (
    <Shell>
      {mode === "library" || !active ? (
        <Library
          scripts={scripts}
          activeId={activeId}
          onSelect={(id) => { setActiveId(id); setMode("edit"); }}
          onCreate={createScript}
          onDelete={deleteScript}
        />
      ) : (
        <Editor
          script={active}
          settings={settings}
          onChange={updateActive}
          onSettings={setSettings}
          onBack={() => setMode("library")}
          onPlay={() => { enterLandscape(); setMode("play"); }}
          onVideo={() => { enterLandscape(); setMode("video"); }}
        />
      )}
    </Shell>
  );
}

function Shell({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen bg-[#0a0a0a] text-neutral-100" style={{ fontFamily: "var(--font-sans)" }}>
      <div className="mx-auto max-w-2xl px-4 pb-24 pt-[max(env(safe-area-inset-top),1rem)]">
        {children}
      </div>
    </div>
  );
}

function Library({
  scripts, activeId, onSelect, onCreate, onDelete,
}: {
  scripts: Script[]; activeId: string | null;
  onSelect: (id: string) => void; onCreate: () => void; onDelete: (id: string) => void;
}) {
  return (
    <div>
      <header className="pt-6 pb-5">
        <h1 className="text-[26px] sm:text-3xl font-black tracking-tight leading-[1.15] bg-gradient-to-br from-amber-300 to-amber-500 bg-clip-text text-transparent">
          Let's kick some ass
        </h1>
        <p className="text-[13px] text-neutral-400 mt-2 leading-snug">
          Never give up. Remember where you came from.
        </p>
        <button
          onClick={onCreate}
          className="mt-5 w-full rounded-2xl bg-amber-400 px-4 py-3.5 text-base font-bold text-black active:scale-[0.98] transition shadow-lg shadow-amber-400/20"
        >
          Let's go
        </button>
      </header>

      <ul className="mt-2 space-y-2">
        {scripts.map((s) => (
          <li key={s.id} className={`rounded-2xl border ${activeId === s.id ? "border-amber-400/50" : "border-white/10"} bg-white/[0.03]`}>
            <div className="flex items-stretch">
              <button onClick={() => onSelect(s.id)} className="flex-1 text-left px-4 py-3">
                <div className="font-semibold truncate">{s.title || "Untitled"}</div>
                <div className="text-xs text-neutral-400 mt-0.5 line-clamp-1">
                  {s.body.trim().slice(0, 80) || "Empty script"}
                </div>
              </button>
              <button
                onClick={() => {
                  if (confirm(`Delete "${s.title}"?`)) onDelete(s.id);
                }}
                className="px-4 text-neutral-500 hover:text-red-400 text-sm"
                aria-label="Delete"
              >
                ✕
              </button>
            </div>
          </li>
        ))}
        {scripts.length === 0 && (
          <li className="rounded-2xl border border-dashed border-white/10 px-4 py-10 text-center text-neutral-400">
            No scripts yet. Tap <span className="text-amber-400 font-bold">Let's go</span> to start.
          </li>
        )}
      </ul>
    </div>
  );
}

function Editor({
  script, settings, onChange, onSettings, onBack, onPlay, onVideo,
}: {
  script: Script;
  settings: Settings;
  onChange: (patch: Partial<Script>) => void;
  onSettings: (s: Settings) => void;
  onBack: () => void;
  onPlay: () => void;
  onVideo: () => void;
}) {
  const disabled = !script.body.trim();
  return (
    <div>
      <header className="flex items-center justify-between py-3 gap-2">
        <button onClick={onBack} className="text-sm text-neutral-400 hover:text-white">‹ Scripts</button>
        <div className="flex items-center gap-2">
          <button
            onClick={onVideo}
            disabled={disabled}
            className="rounded-full border border-amber-400/60 bg-amber-400/10 px-4 py-2 text-sm font-bold text-amber-300 disabled:opacity-40 active:scale-95 transition inline-flex items-center gap-1.5"
          >
            <Video className="h-4 w-4" /> Video
          </button>
          <button
            onClick={onPlay}
            disabled={disabled}
            className="rounded-full bg-amber-400 px-5 py-2 text-sm font-bold text-black disabled:opacity-40 active:scale-95 transition"
          >
            ▶ Play
          </button>
        </div>
      </header>


      <input
        value={script.title}
        onChange={(e) => onChange({ title: e.target.value })}
        placeholder="Script title"
        className="w-full bg-transparent text-2xl font-bold outline-none placeholder:text-neutral-600 py-2"
      />

      <textarea
        value={script.body}
        onChange={(e) => onChange({ body: e.target.value })}
        placeholder="Paste or type your script here… 한글도 지원합니다."
        className="mt-2 min-h-[40vh] w-full resize-y rounded-2xl border border-white/10 bg-white/[0.03] p-4 text-base leading-relaxed outline-none focus:border-amber-400/50"
      />

      <SettingsPanel settings={settings} onChange={onSettings} />
    </div>
  );
}

function SettingsPanel({ settings, onChange }: { settings: Settings; onChange: (s: Settings) => void }) {
  const set = (patch: Partial<Settings>) => onChange({ ...settings, ...patch });
  return (
    <section className="mt-6 rounded-2xl border border-white/10 bg-white/[0.03] p-4">
      <h2 className="text-sm font-bold uppercase tracking-widest text-neutral-400">Settings</h2>
      <div className="mt-4 space-y-4">
        <Slider label="Font size" value={settings.fontSize} min={24} max={140} step={1} suffix="px"
          onChange={(v) => set({ fontSize: v })} />
        <Slider label="Scroll speed" value={settings.speed} min={10} max={250} step={1} suffix="px/s"
          onChange={(v) => set({ speed: v })} />
        <Slider label="Text width" value={settings.width} min={50} max={100} step={1} suffix="%"
          onChange={(v) => set({ width: v })} />
        <div className="flex flex-wrap gap-2 pt-1">
          <Toggle on={settings.mirrorH} onClick={() => set({ mirrorH: !settings.mirrorH })}>Mirror ↔</Toggle>
          <Toggle on={settings.mirrorV} onClick={() => set({ mirrorV: !settings.mirrorV })}>Mirror ↕</Toggle>
        </div>
        <div className="flex gap-2 pt-1">
          {(["black", "white", "sepia"] as const).map((b) => (
            <button
              key={b}
              onClick={() => set({ bg: b })}
              className={`flex-1 rounded-xl px-3 py-2 text-sm font-semibold border transition ${
                settings.bg === b ? "border-amber-400 text-amber-300" : "border-white/10 text-neutral-300"
              }`}
            >
              {b === "black" ? "Dark" : b === "white" ? "Light" : "Sepia"}
            </button>
          ))}
        </div>
        <div className="pt-2">
          <button
            onClick={() => {
              if (confirm("Reset all teleprompter settings to defaults?")) onChange({ ...DEFAULT_SETTINGS });
            }}
            className="w-full rounded-xl border border-white/10 bg-white/[0.02] px-3 py-2 text-sm font-semibold text-neutral-300 transition hover:border-amber-400/50 hover:text-amber-300"
          >
            Reset to defaults
          </button>
        </div>
      </div>
    </section>
  );
}

function Slider({
  label, value, min, max, step, suffix, onChange,
}: { label: string; value: number; min: number; max: number; step: number; suffix?: string; onChange: (v: number) => void }) {
  return (
    <label className="block">
      <div className="flex justify-between text-sm">
        <span className="text-neutral-300">{label}</span>
        <span className="font-mono text-amber-300">{value}{suffix}</span>
      </div>
      <input
        type="range" min={min} max={max} step={step} value={value}
        onChange={(e) => onChange(Number(e.target.value))}
        className="slider-fluid mt-2 w-full accent-amber-400"
      />
    </label>
  );
}

function Toggle({ on, onClick, children }: { on: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      onClick={onClick}
      className={`rounded-full px-4 py-2 text-sm font-semibold border transition ${
        on ? "border-amber-400 bg-amber-400/10 text-amber-300" : "border-white/10 text-neutral-300"
      }`}
    >
      {children}
    </button>
  );
}

function Prompter({
  script, settings, onExit, onSettings, videoMode = false,
}: { script: Script; settings: Settings; onExit: () => void; onSettings: (s: Settings) => void; videoMode?: boolean }) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const rafRef = useRef<number | null>(null);
  const lastTsRef = useRef<number>(0);
  const [playing, setPlaying] = useState(false);
  const [progress, setProgress] = useState(0); // 0..1
  const [isPortrait, setIsPortrait] = useState(false);
  const [speed, setSpeed] = useState(settings.speed);
  const [fontSize, setFontSize] = useState(settings.fontSize);
  // Beam-splitter teleprompter rig: horizontal flip so text reads correctly
  // through the angled glass.
  // Mirror flip is disabled in video mode — the script should always read naturally on camera.
  const [mirrorV, setMirrorV] = useState(videoMode ? false : settings.mirrorV);
  const [panel, setPanel] = useState<null | "settings" | "size" | "more" | "assist">(null);
  const [controlsVisible, setControlsVisible] = useState(true);
  const scrollDirectionRef = useRef<1 | -1>(1); // 1 = increasing scrollTop, -1 = decreasing

  // ==== Reading-assist features ====
  const [voiceFollow, setVoiceFollow] = useState<boolean>(settings.voiceFollow ?? false);
  const [chunking, setChunking] = useState<boolean>(settings.chunking ?? true);
  const [pauses, setPauses] = useState<boolean>(settings.pauses ?? true);
  const vfSupported = useMemo(() => isVoiceFollowSupported(), []);
  const tokens = useMemo<Token[]>(() => tokenize(script.body, chunking), [script.body, chunking]);
  const words = useMemo(() => wordListFromTokens(tokens), [tokens]);
  const lang = useMemo(() => detectLang(script.body), [script.body]);
  const { anchorWordIndex, status: vfStatus } = useVoiceFollow({ enabled: voiceFollow && vfSupported, words, lang });
  const wordRefsRef = useRef<Array<HTMLSpanElement | null>>([]);
  const prevAnchorRef = useRef<number>(-1);
  const pauseAnchorsRef = useRef<Array<{ y: number; kind: "strong" | "soft" }>>([]);


  // Video-mode state
  const videoElRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const [camError, setCamError] = useState<string | null>(null);
  const [camReady, setCamReady] = useState(false);
  // Mic state: label of the currently-active audio input + whether it's external.
  const [activeMicLabel, setActiveMicLabel] = useState<string>("");
  const [micIsExternal, setMicIsExternal] = useState(false);
  const currentMicIdRef = useRef<string>("");

  const recorderRef = useRef<MediaRecorder | null>(null);
  const recordingIdRef = useRef<string | null>(null);
  const appendQueueRef = useRef<Promise<unknown>>(Promise.resolve());
  const recordStartRef = useRef<number>(0);
  const [recording, setRecording] = useState(false);
  const recordingRef = useRef(false);
  useEffect(() => { recordingRef.current = recording; }, [recording]);
  const [elapsedMs, setElapsedMs] = useState(0);
  const [clips, setClips] = useState<ClipRecord[]>([]);
  const [clipsOpen, setClipsOpen] = useState(false);
  type Quality = "720p" | "1080p" | "4k";
  const [quality, setQuality] = useState<Quality>(() => {
    if (typeof window === "undefined") return "1080p";
    return (localStorage.getItem("prompter.quality") as Quality) || "1080p";
  });
  useEffect(() => { try { localStorage.setItem("prompter.quality", quality); } catch {} }, [quality]);

  // Update scroll direction when mirrorV changes
  useEffect(() => {
    scrollDirectionRef.current = mirrorV ? -1 : 1;
  }, [mirrorV]);

  // Persist live edits back to settings
  useEffect(() => {
    onSettings({ ...settings, speed, fontSize, mirrorV, voiceFollow, chunking, pauses });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [speed, fontSize, mirrorV, voiceFollow, chunking, pauses]);


  // In video mode, use transparent background so the camera shows through.
  const bgClass = videoMode
    ? "bg-black text-neutral-50"
    : settings.bg === "white" ? "bg-white text-neutral-900"
    : settings.bg === "sepia" ? "bg-[#f5ecd7] text-[#2a1f0f]"
    : "bg-black text-neutral-50";

  // ==== Video mode: camera acquisition ====
  // Regexes for detecting external USB / wireless mics vs the iPhone built-in.
  // iOS Safari exposes labels like "DJI MIC 2 (Bluetooth)", "USB Audio Device",
  // "iPhone Microphone", etc. after mic permission is granted.
  const EXTERNAL_MIC_RE = /usb|dji|rode|røde|shure|sennheiser|zoom |comica|hollyland|godox|saramonic|maono|movo|boya|blue snowball|blue yeti|wireless|lavalier|lav mic|external|mic 2|mic pro|airpods|beats|bose|sony|jbl|bluetooth/i;
  const BUILTIN_MIC_RE = /built.?in|iphone|internal|default/i;

  const pickBestAudioInput = async (): Promise<{ id: string; label: string; external: boolean } | null> => {
    try {
      const devices = await navigator.mediaDevices.enumerateDevices();
      const inputs = devices.filter((d) => d.kind === "audioinput" && d.deviceId);
      if (inputs.length === 0) return null;
      // 1) explicit external hint in the label
      const ext = inputs.find((d) => d.label && EXTERNAL_MIC_RE.test(d.label));
      if (ext) return { id: ext.deviceId, label: ext.label, external: true };
      // 2) any non-default non-builtin labeled device when multiple exist
      const other = inputs.find(
        (d) => d.deviceId !== "default" && d.label && !BUILTIN_MIC_RE.test(d.label)
      );
      if (other && inputs.length > 1) return { id: other.deviceId, label: other.label, external: true };
      // 3) fallback to built-in
      const builtin = inputs.find((d) => BUILTIN_MIC_RE.test(d.label)) || inputs[0];
      return { id: builtin.deviceId, label: builtin.label || "Built-in mic", external: false };
    } catch {
      return null;
    }
  };

  // Replace the audio track on the live stream with the preferred mic.
  // External mics get raw audio (no processing) for max fidelity; built-in
  // gets echo/noise/gain processing on. Only runs when NOT recording so
  // MediaRecorder sync is never disturbed mid-clip.
  const refineAudioTrack = async (): Promise<void> => {
    const stream = streamRef.current;
    if (!stream || recordingRef.current) return;
    const pick = await pickBestAudioInput();
    if (!pick) return;
    const currentTrack = stream.getAudioTracks()[0];
    const currentId = currentTrack?.getSettings?.().deviceId as string | undefined;
    if (currentId === pick.id && currentMicIdRef.current === pick.id) {
      setActiveMicLabel(pick.label);
      setMicIsExternal(pick.external);
      return;
    }
    try {
      const audioConstraints: MediaTrackConstraints = pick.external
        ? {
            deviceId: { exact: pick.id },
            echoCancellation: false,
            noiseSuppression: false,
            autoGainControl: false,
            sampleRate: 48000,
            channelCount: 2,
          } as any
        : {
            deviceId: { exact: pick.id },
            echoCancellation: true,
            noiseSuppression: true,
            autoGainControl: true,
            sampleRate: 48000,
            channelCount: 2,
          } as any;
      const newAudio = await navigator.mediaDevices.getUserMedia({ audio: audioConstraints });
      const newTrack = newAudio.getAudioTracks()[0];
      if (!newTrack) return;
      // Swap tracks atomically on the same stream so the video element and
      // any future MediaRecorder see a single continuous stream.
      if (currentTrack) {
        stream.removeTrack(currentTrack);
        try { currentTrack.stop(); } catch {}
      }
      stream.addTrack(newTrack);
      currentMicIdRef.current = pick.id;
      setActiveMicLabel(pick.label);
      setMicIsExternal(pick.external);
    } catch {
      // Keep whatever audio track we have if the swap fails.
    }
  };


  useEffect(() => {
    if (!videoMode) return;
    let cancelled = false;
    const getConstraints = (q: Quality): MediaStreamConstraints => {
      const dims = q === "4k" ? { width: 3840, height: 2160 }
                : q === "1080p" ? { width: 1920, height: 1080 }
                : { width: 1280, height: 720 };
      const videoConstraints: any = {
        // Use the front camera, but let the browser fall back if it can't
        // satisfy every ideal constraint.
        facingMode: { ideal: "user" },
        width: { ideal: dims.width },
        height: { ideal: dims.height },
        // Prefer 60fps for the smoothest, sharpest capture; the camera
        // will fall back to 30 automatically if 60 isn't available at
        // the chosen resolution.
        frameRate: { ideal: 60, min: 30 },
      };

      return {
        video: videoConstraints as MediaTrackConstraints,
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
          sampleRate: 48000,
          channelCount: 2,
        },
      };
    };
    const start = async () => {
      try {
        // Try requested quality; fall back to 1080p then 720p on failure.
        let stream: MediaStream | null = null;
        const tiers: Quality[] = quality === "4k" ? ["4k", "1080p", "720p"]
                                : quality === "1080p" ? ["1080p", "720p"]
                                : ["720p"];
        for (const q of tiers) {
          try { stream = await navigator.mediaDevices.getUserMedia(getConstraints(q)); break; }
          catch (e) { if (q === tiers[tiers.length - 1]) throw e; }
        }
        if (cancelled || !stream) { stream?.getTracks().forEach(t => t.stop()); return; }
        // Lock the camera at 1x zoom after acquisition as a safety net; some
        // browsers ignore zoom in getUserMedia but honor it via applyConstraints.
        stream.getVideoTracks().forEach(track => {
          try { track.applyConstraints({ advanced: [{ zoom: 1 }] } as any); } catch {}
        });
        streamRef.current = stream;
        if (videoElRef.current) {
          videoElRef.current.srcObject = stream;
          try { await videoElRef.current.play(); } catch {}
        }
        setCamReady(true);
        setCamError(null);
        // Now that mic permission is granted, labels are visible — pick the
        // best available input (external USB / wireless mic if present).
        refineAudioTrack();

        // iOS drops out of fullscreen when the camera-permission prompt appears
        // on first grant. Re-request landscape now that the prompt is gone so
        // video mode behaves identically to text mode.
        if (!document.fullscreenElement && !(document as any).webkitFullscreenElement) {
          enterLandscape();
        } else {
          try { (screen as any).orientation?.lock?.("landscape")?.catch?.(() => {}); } catch {}
        }
      } catch (e: any) {
        setCamError(e?.message || "Camera unavailable. Check Settings → Safari → Camera.");
      }
    };
    start();
    // Re-pick mic whenever devices change (plug/unplug DJI Mic 2, AirPods, etc.).
    const onDeviceChange = () => { refineAudioTrack(); };
    try { navigator.mediaDevices.addEventListener("devicechange", onDeviceChange); } catch {}
    return () => {
      cancelled = true;
      try { navigator.mediaDevices.removeEventListener("devicechange", onDeviceChange); } catch {}
      if (recorderRef.current && recorderRef.current.state !== "inactive") {
        try { recorderRef.current.stop(); } catch {}
      }
      streamRef.current?.getTracks().forEach((t) => t.stop());
      streamRef.current = null;
      setCamReady(false);
      setActiveMicLabel("");
      setMicIsExternal(false);
      currentMicIdRef.current = "";
    };
    // Re-acquire on quality change
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [videoMode, quality]);


  // Load existing clips, recover any orphan session from a prior crash / close,
  // and ask for persistent storage so recordings survive eviction.
  useEffect(() => {
    if (!videoMode) return;
    let cancelled = false;
    (async () => {
      try { await requestPersistentStorage(); } catch {}
      try { await recoverOrphanSessions(); } catch {}
      if (cancelled) return;
      try { const list = await listClips(script.id); if (!cancelled) setClips(list); } catch {}
    })();
    return () => { cancelled = true; };
  }, [videoMode, script.id]);

  // Restore reader state per script in video mode (scrollTop only; other prefs already persist globally)
  const readerStateKey = `prompter.readerState.${script.id}`;
  useEffect(() => {
    if (!videoMode) return;
    const el = scrollRef.current;
    if (!el) return;
    try {
      const raw = localStorage.getItem(readerStateKey);
      if (raw) {
        const s = JSON.parse(raw) as { scrollTop?: number };
        if (typeof s.scrollTop === "number") {
          // Wait one frame so layout is measured
          requestAnimationFrame(() => { if (scrollRef.current) scrollRef.current.scrollTop = s.scrollTop!; setProgress(computeProgress()); });
        }
      }
    } catch {}
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [videoMode, script.id]);

  // Persist scroll position (debounced) in video mode
  const saveStateTimer = useRef<number | null>(null);
  const scheduleSaveState = useCallback(() => {
    if (!videoMode) return;
    if (saveStateTimer.current) window.clearTimeout(saveStateTimer.current);
    saveStateTimer.current = window.setTimeout(() => {
      const el = scrollRef.current;
      if (!el) return;
      try { localStorage.setItem(readerStateKey, JSON.stringify({ scrollTop: el.scrollTop, updatedAt: Date.now() })); } catch {}
    }, 250);
  }, [videoMode, readerStateKey]);

  // Recording timer tick
  useEffect(() => {
    if (!recording) return;
    const id = window.setInterval(() => setElapsedMs(Date.now() - recordStartRef.current), 200);
    return () => window.clearInterval(id);
  }, [recording]);

  const pickMime = (): string => {
    const candidates = [
      "video/mp4;codecs=h264,mp4a.40.2",
      "video/mp4",
      "video/webm;codecs=h264,opus",
      "video/webm;codecs=vp9,opus",
      "video/webm",
    ];
    for (const m of candidates) {
      if (typeof MediaRecorder !== "undefined" && MediaRecorder.isTypeSupported(m)) return m;
    }
    return "";
  };

  const startRecording = useCallback(async () => {
    const stream = streamRef.current;
    if (!stream || recording) return;
    const mimeType = pickMime();
    // Match iPhone-native quality tiers. iOS records 1080p60 at ~10-12 Mbps
    // and 4K30 at ~40-50 Mbps; we mirror those numbers so recordings look
    // as good as the native Camera app.
    const bps = quality === "4k" ? 45_000_000 : quality === "1080p" ? 14_000_000 : 6_000_000;
    const audioBps = 192_000;
    let rec: MediaRecorder;
    try {
      rec = new MediaRecorder(stream, mimeType
        ? { mimeType, videoBitsPerSecond: bps, audioBitsPerSecond: audioBps }
        : { videoBitsPerSecond: bps, audioBitsPerSecond: audioBps });
    } catch { try { rec = new MediaRecorder(stream); } catch { return; } }

    const recordingId = Math.random().toString(36).slice(2, 12);
    const track = stream.getVideoTracks()[0];
    const s = track?.getSettings?.() || {};
    const finalMime = rec.mimeType || mimeType || "video/mp4";
    const startedAt = Date.now();
    // In-memory chunks give us instant playback the moment the user hits Stop
    // (no wait for IndexedDB read-back). The DB copy is the crash-safety net.
    const memChunks: Blob[] = [];

    try {
      await createSession({
        id: recordingId,
        scriptId: script.id,
        mimeType: finalMime,
        startedAt,
        width: (s.width as number) || 0,
        height: (s.height as number) || 0,
      });
    } catch { return; }

    recordingIdRef.current = recordingId;
    appendQueueRef.current = Promise.resolve();

    // Serialize DB appends so chunk order matches wire order; keep a memory
    // copy in parallel for instant playback.
    rec.ondataavailable = (e) => {
      if (!e.data || e.data.size === 0) return;
      const blob = e.data;
      memChunks.push(blob);
      appendQueueRef.current = appendQueueRef.current
        .catch(() => {})
        .then(() => appendChunk(recordingId, blob).catch(() => {}));
    };

    const buildInstantClip = (): ClipRecord | null => {
      if (memChunks.length === 0) return null;
      const blob = new Blob(memChunks, { type: finalMime });
      return {
        id: recordingId,
        scriptId: script.id,
        mimeType: finalMime,
        durationMs: Math.max(0, Date.now() - recordStartRef.current),
        sizeBytes: blob.size,
        createdAt: startedAt,
        width: (s.width as number) || 0,
        height: (s.height as number) || 0,
        blob,
      };
    };

    rec.onerror = () => {
      const clip = buildInstantClip();
      if (clip) setClips((cs) => cs.some((c) => c.id === clip.id) ? cs : [...cs, clip]);
      recorderRef.current = null;
      recordingIdRef.current = null;
      setRecording(false);
      setPlaying(false);
      setControlsVisible(true);
      // Background DB cleanup — the in-memory clip is already the source of truth for playback.
      appendQueueRef.current
        .catch(() => {})
        .then(() => finalizeSession(recordingId, { durationMs: Date.now() - recordStartRef.current }))
        .catch(() => {});
    };

    rec.onstop = () => {
      recordingIdRef.current = null;
      // Instant: assemble from memory and push into the list right now.
      const clip = buildInstantClip();
      if (clip) setClips((cs) => cs.some((c) => c.id === clip.id) ? cs : [...cs, clip]);
      // Background: finalize the persisted copy so a future page load has it.
      appendQueueRef.current
        .catch(() => {})
        .then(() => finalizeSession(recordingId, { durationMs: Date.now() - recordStartRef.current }))
        .catch(() => {});
    };

    recordStartRef.current = Date.now();
    setElapsedMs(0);
    // 1s timeslice = big enough to keep write overhead low, small enough
    // that at most ~1s of footage is ever unflushed if the process dies.
    try { rec.start(1000); } catch { try { rec.start(); } catch { return; } }
    recorderRef.current = rec;
    setRecording(true);
    // Start the script rolling in sync with the recording
    setPlaying(true);
    setControlsVisible(false);
    setPanel(null);
  }, [quality, recording, script.id]);

  const stopRecording = useCallback(() => {
    const rec = recorderRef.current;
    if (!rec) return;
    try { if (rec.state !== "inactive") rec.stop(); } catch {}
    recorderRef.current = null;
    setRecording(false);
    // Stop the script when recording stops
    setPlaying(false);
    setControlsVisible(true);
    // Persist scroll position IMMEDIATELY so it survives an app close / reload.
    // The debounced scheduleSaveState may not fire before the page unloads.
    const el = scrollRef.current;
    if (el) {
      try { localStorage.setItem(readerStateKey, JSON.stringify({ scrollTop: el.scrollTop, updatedAt: Date.now() })); } catch {}
    }
  }, [readerStateKey]);

  // Stop recording cleanly if user backgrounds the app, and flush scroll position
  useEffect(() => {
    if (!videoMode) return;
    const flush = () => {
      const el = scrollRef.current;
      if (!el) return;
      try { localStorage.setItem(readerStateKey, JSON.stringify({ scrollTop: el.scrollTop, updatedAt: Date.now() })); } catch {}
    };
    const onVis = () => {
      if (document.visibilityState === "hidden") {
        flush();
        if (recording) stopRecording();
      }
    };
    const onPageHide = () => flush();
    document.addEventListener("visibilitychange", onVis);
    window.addEventListener("pagehide", onPageHide);
    return () => {
      document.removeEventListener("visibilitychange", onVis);
      window.removeEventListener("pagehide", onPageHide);
    };
  }, [videoMode, recording, stopRecording, readerStateKey]);

  const exportClips = useCallback(async (subset?: ClipRecord[]) => {
    const arr = subset && subset.length ? subset : clips;
    if (!arr.length) return;
    const ext = (mt: string) => mt.includes("mp4") ? "mp4" : "webm";
    const files = arr.map((c, i) => new File([c.blob], `${script.title || "script"}-${i + 1}.${ext(c.mimeType)}`, { type: c.mimeType }));
    const nav: any = navigator;
    if (nav.share && nav.canShare && nav.canShare({ files })) {
      try { await nav.share({ files, title: script.title || "Teleprompter clips" }); return; }
      catch (e: any) { if (e?.name === "AbortError") return; }
    }
    // Fallback: download each
    for (const f of files) {
      const url = URL.createObjectURL(f);
      const a = document.createElement("a"); a.href = url; a.download = f.name; document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    }
  }, [clips, script.title]);


  const computeProgress = useCallback(() => {
    const el = scrollRef.current;
    if (!el) return 0;
    const max = el.scrollHeight - el.clientHeight;
    if (max <= 0) return 1;
    const raw = el.scrollTop / max;
    // When mirrored we start at the bottom and scroll toward top,
    // so invert the raw ratio so progress still goes 0 -> 1.
    const p = mirrorV ? 1 - raw : raw;
    return Math.min(1, Math.max(0, p));
  }, [mirrorV]);

  const tick = useCallback((ts: number) => {
    const el = scrollRef.current;
    if (!el) return;
    if (!lastTsRef.current) lastTsRef.current = ts;
    const dt = (ts - lastTsRef.current) / 1000;
    lastTsRef.current = ts;
    const dir = scrollDirectionRef.current;
    el.scrollTop += dir * speed * dt;
    const p = computeProgress();
    // Throttle React updates — only re-render when the visible % actually shifts.
    setProgress((prev) => (Math.abs(prev - p) > 0.005 ? p : prev));
    if (p >= 1) { setPlaying(false); return; }
    rafRef.current = requestAnimationFrame(tick);
  }, [speed, computeProgress]);

  useEffect(() => {
    if (playing) {
      lastTsRef.current = 0;
      rafRef.current = requestAnimationFrame(tick);
    } else if (rafRef.current) {
      cancelAnimationFrame(rafRef.current);
      rafRef.current = null;
    }
    return () => { if (rafRef.current) cancelAnimationFrame(rafRef.current); };
  }, [playing, tick]);

  const togglePlay = () => {
    setPlaying((p) => {
      const next = !p;
      if (next) { setControlsVisible(false); setPanel(null); }
      else { setControlsVisible(true); }
      return next;
    });
  };
  const reset = () => {
    setPlaying(false);
    const el = scrollRef.current;
    if (el) {
      const max = el.scrollHeight - el.clientHeight;
      el.scrollTop = mirrorV && max > 0 ? max : 0;
    }
    setProgress(0);
  };
  // Smooth nudge that does NOT stop playback. While playing, the rAF tick
  // mutates scrollTop every frame, so a CSS smooth-scroll target would be
  // overwritten immediately — we apply the offset directly instead.
  const nudge = useCallback((dir: 1 | -1) => {
    const el = scrollRef.current;
    if (!el) return;
    const step = dir * Math.max(60, el.clientHeight * 0.18);
    // When mirrored, scroll direction is reversed, so invert the nudge.
    const effectiveStep = mirrorV ? -step : step;
    if (playing) {
      el.scrollTop += effectiveStep;
    } else {
      try { el.scrollBy({ top: effectiveStep, behavior: "smooth" }); }
      catch { el.scrollTop += effectiveStep; }
    }
    setProgress(computeProgress());
  }, [computeProgress, playing, mirrorV]);

  // Bluetooth remote (Desview RM-S1/S2 etc.) keyboard mapping
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement)?.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA") return;
      const k = e.key, code = e.code;

      // Escape / Home / font size.
      // While recording, the remote must NEVER be able to stop or exit —
      // Escape would tear down video mode and abort the recording as a side effect.
      if (k === "Escape" || code === "Escape") {
        e.preventDefault();
        if (recordingRef.current) return; // swallow — remote is text-only during recording
        onExit();
        return;
      }
      if (k === "0" || k === "Home") { e.preventDefault(); reset(); return; }
      if (k === "]") { e.preventDefault(); setFontSize((s) => Math.min(140, s + 2)); return; }
      if (k === "[") { e.preventDefault(); setFontSize((s) => Math.max(24, s - 2)); return; }

      // Up / Down — scroll position. NEVER toggles play. Keeps rolling.
      if (k === "ArrowUp" || k === "PageUp" || code === "PageUp" ||
          k === "AudioVolumeUp" || k === "VolumeUp") {
        e.preventDefault(); nudge(-1); return;
      }
      if (k === "ArrowDown" || k === "PageDown" || code === "PageDown" ||
          k === "AudioVolumeDown" || k === "VolumeDown") {
        e.preventDefault(); nudge(1); return;
      }

      // Left / Right — adjust speed.
      if (k === "ArrowLeft" || k === "-" || k === "_") {
        e.preventDefault(); setSpeed((s) => Math.max(10, s - 5)); return;
      }
      if (k === "ArrowRight" || k === "+" || k === "=") {
        e.preventDefault(); setSpeed((s) => Math.min(250, s + 5)); return;
      }

      // Play / pause — space, enter, media keys, k/p, tab, dot, F5
      const playKeys = [
        " ", "Spacebar", "Enter", "MediaPlayPause", "MediaPlay", "MediaPause",
        "k", "K", "p", "P", ".", "Tab", "F5",
      ];
      if (playKeys.includes(k) || playKeys.includes(code)) {
        e.preventDefault();
        togglePlay();
      }
    };
    window.addEventListener("keydown", onKey, { capture: true });
    return () => window.removeEventListener("keydown", onKey, { capture: true } as any);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [nudge, onExit]);

  // Wake lock
  useEffect(() => {
    let wakeLock: any = null;
    const req = async () => { try { wakeLock = await (navigator as any).wakeLock?.request("screen"); } catch {} };
    req();
    const onVis = () => { if (document.visibilityState === "visible") req(); };
    document.addEventListener("visibilitychange", onVis);
    return () => { document.removeEventListener("visibilitychange", onVis); try { wakeLock?.release(); } catch {} };
  }, []);

  // On first mount, position scroll based on initial mirror state.
  const didInitScrollRef = useRef(false);
  useEffect(() => {
    if (didInitScrollRef.current) return;
    const el = scrollRef.current;
    if (!el) return;
    const max = el.scrollHeight - el.clientHeight;
    el.scrollTop = mirrorV && max > 0 ? max : 0;
    setProgress(0);
    didInitScrollRef.current = true;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Toggle mirror while preserving the user's place in the script.
  // Flipping the text upside-down also reverses scroll direction, so we
  // mirror scrollTop (max - current) so the same line stays on screen.
  const toggleMirror = useCallback(() => {
    const el = scrollRef.current;
    if (el) {
      const max = el.scrollHeight - el.clientHeight;
      if (max > 0) el.scrollTop = max - el.scrollTop;
    }
    setMirrorV((v) => !v);
    setProgress((p) => p); // keep progress; computeProgress will resync on next scroll/tick
  }, []);

  const onScroll = () => { if (!playing) setProgress(computeProgress()); scheduleSaveState(); };
  const remaining = Math.round((1 - progress) * 100);

  // Portrait detection for hint only (no auto-rotate)
  useEffect(() => {
    const mq = window.matchMedia("(orientation: portrait)");
    const update = () => setIsPortrait(mq.matches);
    update();
    mq.addEventListener?.("change", update);
    return () => { mq.removeEventListener?.("change", update); };
  }, []);

  const iconBtn = "grid h-10 w-10 sm:h-11 sm:w-11 shrink-0 place-items-center rounded-full text-neutral-300 active:scale-90 transition";

  return (
    <div className={`${bgClass} fixed inset-0 overflow-hidden select-none`} style={{ fontFamily: "var(--font-prompter)" }}>
      {/* Camera preview — behind everything in video mode. Mirrored for natural feel; recorded stream is NOT mirrored. */}
      {videoMode && (
        <>
          <video
            ref={videoElRef}
            className="absolute inset-0 h-full w-full object-cover"
            style={{ transform: "scaleX(-1) translateZ(0)", willChange: "transform" }}
            autoPlay
            muted
            playsInline
          />
          {/* Dark scrim so the script stays readable over the video */}
          <div className="pointer-events-none absolute inset-0 bg-black/45" />
          {camError && (
            <div className="absolute inset-0 z-40 grid place-items-center bg-black/80 p-6 text-center text-sm text-neutral-200">
              <div>
                <div className="mb-2 font-bold text-amber-300">Camera unavailable</div>
                <div className="mb-3 text-neutral-300">{camError}</div>
                <button onClick={onExit} className="rounded-full bg-amber-400 px-4 py-2 text-sm font-bold text-black">Back</button>
              </div>
            </div>
          )}
        </>
      )}

      {/* Scrolling text — finger tap pauses and reveals controls */}
      <div
        ref={scrollRef}
        onScroll={onScroll}
        onClick={() => { togglePlay(); }}
        className="absolute inset-0 overflow-y-auto overscroll-contain"
        style={{ WebkitOverflowScrolling: "touch", contain: "layout paint", willChange: "scroll-position" }}
      >
        <div className="mx-auto" style={{ width: `${settings.width}%` }}>
          <div style={{ height: "20vh" }} />
          <div
            className="whitespace-pre-wrap"
            style={{
              fontSize: `${fontSize}px`,
              fontWeight: 500,
              lineHeight: 1.25,
              letterSpacing: "-0.015em",
              wordBreak: "keep-all",
              overflowWrap: "break-word",
              WebkitHyphens: "none",
              hyphens: "none",
              lineBreak: "strict",
              textWrap: "pretty",
              fontFeatureSettings: '"kern" 1, "palt" 1',
              textRendering: "optimizeLegibility",
              WebkitFontSmoothing: "antialiased",
              transform: mirrorV ? "scaleY(-1)" : undefined,
            } as React.CSSProperties}
          >
            {script.body}
          </div>

          <div style={{ height: "80vh" }} />
        </div>
      </div>

      {/* Portrait nudge — only hint, no rotation hack */}
      {isPortrait && (
        <div className="pointer-events-none absolute inset-x-0 top-4 z-30 flex justify-center">
          <div className="rounded-full bg-black/70 px-3 py-1 text-xs text-amber-300 backdrop-blur-sm">
            Rotate your phone sideways
          </div>
        </div>
      )}

      {/* Popovers */}
      {panel === "settings" && (
        <Popover onClose={() => setPanel(null)}>
          <PopRow label="Speed" value={`${speed}`}>
            <input type="range" min={10} max={250} step={1} value={speed} onChange={(e) => setSpeed(Number(e.target.value))} className="slider-fluid w-full accent-amber-400" />
          </PopRow>
          <PopRow label="Width" value={`${settings.width}%`}>
            <input type="range" min={50} max={100} step={1} value={settings.width} onChange={(e) => onSettings({ ...settings, width: Number(e.target.value) })} className="slider-fluid w-full accent-amber-400" />
          </PopRow>
          <div className="flex gap-2 pt-1">
            {(["black", "white", "sepia"] as const).map((b) => (
              <button key={b} onClick={() => onSettings({ ...settings, bg: b })}
                className={`flex-1 rounded-lg px-3 py-2 text-xs font-semibold border ${settings.bg === b ? "border-amber-400 text-amber-300" : "border-white/15 text-neutral-300"}`}>
                {b === "black" ? "Dark" : b === "white" ? "Light" : "Sepia"}
              </button>
            ))}
          </div>
        </Popover>
      )}
      {panel === "size" && (
        <Popover onClose={() => setPanel(null)}>
          <PopRow label="Font size" value={`${fontSize}px`}>
            <input type="range" min={24} max={140} step={1} value={fontSize} onChange={(e) => setFontSize(Number(e.target.value))} className="slider-fluid w-full accent-amber-400" />
          </PopRow>
        </Popover>
      )}
      {panel === "more" && (
        <Popover onClose={() => setPanel(null)}>
          <div className={videoMode ? "grid grid-cols-1 gap-2" : "grid grid-cols-2 gap-2"}>
            <button onClick={() => { reset(); setPanel(null); }} className="rounded-lg border border-white/15 px-3 py-2 text-sm">↺ Reset</button>
            {!videoMode && (
              <button onClick={toggleMirror} className={`rounded-lg border px-3 py-2 text-sm ${mirrorV ? "border-amber-400 text-amber-300" : "border-white/15"}`}>Flip ↕ (beam-splitter rig)</button>
            )}
          </div>
          {videoMode && (
            <div className="mt-3">
              <div className="mb-1 text-xs text-neutral-300">Recording quality</div>
              <div className="flex gap-2">
                {(["720p", "1080p", "4k"] as const).map((q) => (
                  <button key={q} disabled={recording} onClick={() => setQuality(q)}
                    className={`flex-1 rounded-lg border px-3 py-2 text-xs font-semibold disabled:opacity-40 ${quality === q ? "border-amber-400 text-amber-300" : "border-white/15 text-neutral-300"}`}>
                    {q === "4k" ? "4K (try)" : q}
                  </button>
                ))}
              </div>
              <p className="mt-2 text-[11px] text-neutral-400">4K is attempted but iPhone Safari may fall back to 1080p.</p>
            </div>
          )}
          <p className="mt-2 text-[11px] text-neutral-400">Tap the script to play / pause. Bluetooth remotes (Desview, AirTurn) work too.</p>
        </Popover>
      )}

      {/* REC pill — top-left when recording */}
      {videoMode && recording && (
        <div
          className="absolute z-40 flex items-center gap-2 rounded-full bg-red-600/90 px-3 py-1.5 text-sm font-bold text-white backdrop-blur-sm"
          style={{
            top: "calc(env(safe-area-inset-top, 0px) + 0.6rem)",
            left: "calc(env(safe-area-inset-left, 0px) + 0.6rem)",
            transform: mirrorV ? "scaleY(-1)" : undefined,
          }}
        >
          <span className="h-2.5 w-2.5 animate-pulse rounded-full bg-white" />
          REC {fmtDuration(elapsedMs)}
        </div>
      )}

      {/* Clips chip — top-left when NOT recording */}
      {videoMode && !recording && (
        <button onClick={(e) => { e.stopPropagation(); setClipsOpen(true); }}
          className="absolute z-40 inline-flex items-center gap-1.5 rounded-full bg-black/60 px-3 py-1.5 text-sm font-semibold text-neutral-100 backdrop-blur-sm active:scale-95"
          style={{
            top: "calc(env(safe-area-inset-top, 0px) + 0.6rem)",
            left: "calc(env(safe-area-inset-left, 0px) + 0.6rem)",
            transform: mirrorV ? "scaleY(-1)" : undefined,
          }}
          aria-label="Clips"
        >
          <Film className="h-4 w-4 text-amber-300" /> Clips {clips.length > 0 && <span className="text-amber-300">({clips.length})</span>}
        </button>
      )}

      {/* Mic pill — shows the active audio input; highlights when external (USB / DJI Mic 2 / wireless). */}
      {videoMode && camReady && activeMicLabel && controlsVisible && (
        <div
          className={`absolute z-40 inline-flex max-w-[60vw] items-center gap-1.5 rounded-full px-3 py-1.5 text-xs font-semibold backdrop-blur-sm ${
            micIsExternal ? "bg-emerald-500/90 text-black" : "bg-black/60 text-neutral-100"
          }`}
          style={{
            top: "calc(env(safe-area-inset-top, 0px) + 0.6rem)",
            left: "50%",
            transform: `translateX(-50%)${mirrorV ? " scaleY(-1)" : ""}`,
          }}
          aria-label={`Active microphone: ${activeMicLabel}`}
        >
          <Mic className="h-3.5 w-3.5 shrink-0" />
          <span className="truncate">{micIsExternal ? activeMicLabel : "Built-in mic"}</span>
        </div>
      )}



      {/* % remaining — always visible */}
      <div
        className="absolute z-40 rounded-full bg-black/60 px-3 py-1.5 text-base font-semibold text-amber-300 backdrop-blur-sm"
        style={{
          top: "calc(env(safe-area-inset-top, 0px) + 0.6rem)",
          right: "calc(env(safe-area-inset-right, 0px) + 0.6rem)",
          fontFamily: "var(--font-sans)",
          transform: mirrorV ? "scaleY(-1)" : undefined,
        }}
      >
        {remaining}% left
      </div>

      {/* Clips sheet */}
      {videoMode && clipsOpen && (
        <ClipsSheet
          clips={clips}
          onClose={() => setClipsOpen(false)}
          onDelete={async (id) => { await deleteClip(id); setClips((cs) => cs.filter((c) => c.id !== id)); }}
          onDeleteAll={async () => { await deleteAllForScript(script.id); setClips([]); }}
          onExport={exportClips}
        />
      )}


      {/* Tiny reveal pill — only thing on screen when controls are hidden */}
      {!controlsVisible && (
        <button
          onClick={(e) => { e.stopPropagation(); setControlsVisible(true); }}
          className="absolute left-1/2 z-40 -translate-x-1/2 rounded-full bg-black/40 px-3 py-1 text-[10px] font-semibold text-white/60 backdrop-blur-sm active:scale-90"
          style={{ top: "calc(env(safe-area-inset-top, 0px) + 0.6rem)" }}
          aria-label="Show controls"
        >
          •••
        </button>
      )}

      {controlsVisible && (
        <>
          {/* Thin progress line above toolbar */}
          <div
            className="absolute left-0 right-0 z-20 h-[2px] bg-white/10"
            style={{ bottom: "calc(64px + env(safe-area-inset-bottom, 0px))" }}
          >
            <div className="h-full bg-amber-400" style={{ width: `${progress * 100}%`, willChange: "width" }} />
          </div>

          {/* Bottom toolbar */}
          <div
            className="absolute bottom-0 left-0 right-0 z-30 bg-black/85 backdrop-blur-md"
            style={{
              paddingBottom: "max(env(safe-area-inset-bottom, 0px), 0px)",
              paddingLeft: "env(safe-area-inset-left, 0px)",
              paddingRight: "env(safe-area-inset-right, 0px)",
            }}
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between gap-1 px-2 py-2 sm:px-3">
              <button onClick={onExit} className={iconBtn} aria-label="Back">
                <ChevronLeft className="h-6 w-6 text-sky-400" strokeWidth={2.5} />
              </button>
              {!videoMode && (
                <button onClick={toggleMirror} className={iconBtn} aria-label="Mirror vertically for beam splitter">
                  <FlipVertical2 className={`h-6 w-6 ${mirrorV ? "text-amber-300" : ""}`} />
                </button>
              )}
              <button onClick={togglePlay} className={iconBtn} aria-label="Play / Pause">
                {playing
                  ? <Pause className="h-7 w-7 text-sky-400" fill="currentColor" />
                  : <Play className="h-7 w-7 text-sky-400" fill="currentColor" />}
              </button>
              {videoMode && (
                <button
                  onClick={recording ? stopRecording : startRecording}
                  disabled={videoMode && !camReady && !recording}
                  className={`${iconBtn} ${recording ? "bg-red-600 text-white" : "bg-red-500/90 text-white"} disabled:opacity-40`}
                  aria-label={recording ? "Stop recording" : "Start recording"}
                >
                  {recording ? <Square className="h-5 w-5" fill="currentColor" /> : <Circle className="h-6 w-6" fill="currentColor" />}
                </button>
              )}
              <button onClick={() => setPanel(panel === "settings" ? null : "settings")} className={iconBtn} aria-label="Settings">
                <SlidersHorizontal className="h-6 w-6" />
              </button>
              <button onClick={() => setPanel(panel === "size" ? null : "size")} className={iconBtn} aria-label="Text size">
                <Type className="h-6 w-6" />
              </button>
              <button onClick={() => setPanel(panel === "more" ? null : "more")} className={`${iconBtn} bg-sky-500/90 text-white`} aria-label="More">
                <MoreHorizontal className="h-5 w-5" />
              </button>
            </div>
          </div>
        </>
      )}
    </div>
  );
}


function Popover({ children, onClose }: { children: React.ReactNode; onClose: () => void }) {
  return (
    <>
      <div className="absolute inset-0 z-30" onClick={onClose} />
      <div
        className="absolute left-1/2 z-40 w-[min(92vw,420px)] -translate-x-1/2 rounded-2xl border border-white/10 bg-black/90 p-3 text-neutral-100 backdrop-blur-md"
        style={{ bottom: "calc(72px + env(safe-area-inset-bottom, 0px))" }}
      >
        {children}
      </div>
    </>
  );
}

function PopRow({ label, value, children }: { label: string; value: string; children: React.ReactNode }) {
  return (
    <div className="mb-3 last:mb-0">
      <div className="mb-1 flex justify-between text-xs">
        <span className="text-neutral-300">{label}</span>
        <span className="font-mono text-amber-300">{value}</span>
      </div>
      {children}
    </div>
  );
}

function ClipsSheet({
  clips, onClose, onDelete, onDeleteAll, onExport,
}: {
  clips: ClipRecord[];
  onClose: () => void;
  onDelete: (id: string) => void | Promise<void>;
  onDeleteAll: () => void | Promise<void>;
  onExport: (subset?: ClipRecord[]) => void | Promise<void>;
}) {
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [playingClip, setPlayingClip] = useState<ClipRecord | null>(null);
  const [playUrl, setPlayUrl] = useState<string | null>(null);
  const videoElRef = useRef<HTMLVideoElement | null>(null);
  const toggle = (id: string) => setSelected((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; });
  const selectedClips = clips.filter((c) => selected.has(c.id));

  // Open a clip: create the object URL SYNCHRONOUSLY inside the click handler
  // so iOS Safari treats the subsequent video.play() as a user-gesture.
  const openClip = useCallback((c: ClipRecord) => {
    setPlayUrl((prev) => { if (prev) URL.revokeObjectURL(prev); return URL.createObjectURL(c.blob); });
    setPlayingClip(c);
  }, []);
  const closePlayer = useCallback(() => {
    setPlayUrl((prev) => { if (prev) URL.revokeObjectURL(prev); return null; });
    setPlayingClip(null);
  }, []);
  useEffect(() => () => { if (playUrl) URL.revokeObjectURL(playUrl); }, [playUrl]);

  return (
    <>
      <div className="absolute inset-0 z-40 bg-black/70 backdrop-blur-sm" onClick={onClose} />
      <div className="absolute inset-x-0 bottom-0 z-50 max-h-[85vh] overflow-hidden rounded-t-3xl border-t border-white/10 bg-neutral-950 text-neutral-100"
        onClick={(e) => e.stopPropagation()} style={{ paddingBottom: "max(env(safe-area-inset-bottom, 0px), 0px)", paddingLeft: "env(safe-area-inset-left, 0px)", paddingRight: "env(safe-area-inset-right, 0px)" }}>
        <div className="flex items-center justify-between px-4 pt-3">
          <div className="text-base font-bold">Clips <span className="text-neutral-400 font-normal">({clips.length})</span></div>
          <button onClick={onClose} className="grid h-9 w-9 place-items-center rounded-full text-neutral-400 hover:text-white" aria-label="Close">
            <X className="h-5 w-5" />
          </button>
        </div>
        <div className="max-h-[55vh] overflow-y-auto px-3 py-2">
          {clips.length === 0 ? (
            <div className="px-3 py-10 text-center text-sm text-neutral-400">No clips yet. Tap the red record button to start.</div>
          ) : (
            <ul className="space-y-2">
              {clips.map((c, i) => (
                <li key={c.id} className={`flex items-center gap-3 rounded-xl border p-2 ${selected.has(c.id) ? "border-amber-400/60 bg-amber-400/5" : "border-white/10 bg-white/[0.03]"}`}>
                  <button onClick={() => toggle(c.id)} className={`h-5 w-5 shrink-0 rounded-md border ${selected.has(c.id) ? "border-amber-400 bg-amber-400" : "border-white/30"}`} aria-label="Select" />
                  <button onClick={() => openClip(c)} className="flex-1 min-w-0 text-left active:opacity-70">
                    <div className="text-sm font-semibold truncate flex items-center gap-1.5">
                      <Play className="h-3.5 w-3.5 text-amber-300" fill="currentColor" /> Take {i + 1}
                    </div>
                    <div className="text-[11px] text-neutral-400">
                      {fmtDuration(c.durationMs)} · {fmtSize(c.sizeBytes)} · {c.width && c.height ? `${c.width}×${c.height}` : c.mimeType.split(";")[0]}
                    </div>
                  </button>
                  <button onClick={() => onExport([c])} className="grid h-9 w-9 place-items-center rounded-full text-amber-300 hover:bg-white/5" aria-label="Share this clip">
                    <Share2 className="h-4 w-4" />
                  </button>
                  <button onClick={() => { if (confirm("Delete this clip?")) onDelete(c.id); }} className="grid h-9 w-9 place-items-center rounded-full text-red-400 hover:bg-white/5" aria-label="Delete">
                    <Trash2 className="h-4 w-4" />
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
        {clips.length > 0 && (
          <div className="flex gap-2 border-t border-white/10 p-3">
            <button onClick={() => { if (confirm("Delete all clips for this script?")) onDeleteAll(); }} className="rounded-full border border-white/15 px-4 py-2 text-sm text-neutral-300">
              Delete all
            </button>
            <div className="flex-1" />
            <button onClick={() => onExport(selectedClips.length ? selectedClips : clips)} className="inline-flex items-center gap-1.5 rounded-full bg-amber-400 px-4 py-2 text-sm font-bold text-black">
              <Share2 className="h-4 w-4" />
              {selectedClips.length ? `Export ${selectedClips.length}` : "Export all to Photos"}
            </button>
          </div>
        )}
      </div>

      {playingClip && playUrl && (
        <div
          className="fixed inset-0 z-[60] bg-black"
          onClick={(e) => e.stopPropagation()}
        >
          {/* Video fills the whole screen and is centered by object-contain.
              Try to play as soon as it can; if the browser blocks it the
              native controls remain visible so the user can tap play. */}
          <video
            key={playingClip.id}
            ref={videoElRef}
            src={playUrl}
            controls
            playsInline
            preload="auto"
            onCanPlay={() => { videoElRef.current?.play().catch(() => {}); }}
            className="absolute inset-0 h-full w-full object-contain"
          />

          {/* Floating close button — top-right, safe-area aware */}
          <button
            onClick={closePlayer}
            className="absolute z-10 grid h-10 w-10 place-items-center rounded-full bg-black/60 text-white backdrop-blur-sm active:scale-90"
            style={{
              top: "calc(env(safe-area-inset-top, 0px) + 0.5rem)",
              right: "calc(env(safe-area-inset-right, 0px) + 0.5rem)",
            }}
            aria-label="Close player"
          >
            <X className="h-5 w-5" />
          </button>

          {/* Floating take label — top-left */}
          <div
            className="absolute z-10 rounded-full bg-black/60 px-3 py-1.5 text-xs font-semibold text-neutral-100 backdrop-blur-sm max-w-[60vw] truncate"
            style={{
              top: "calc(env(safe-area-inset-top, 0px) + 0.5rem)",
              left: "calc(env(safe-area-inset-left, 0px) + 0.5rem)",
            }}
          >
            Take {clips.findIndex((c) => c.id === playingClip.id) + 1} · {fmtDuration(playingClip.durationMs)}
          </div>

          {/* Floating action row — bottom, above native video controls */}
          <div
            className="absolute z-10 left-0 right-0 flex gap-2 px-3"
            style={{
              bottom: "calc(env(safe-area-inset-bottom, 0px) + 3.75rem)",
              paddingLeft: "calc(env(safe-area-inset-left, 0px) + 0.75rem)",
              paddingRight: "calc(env(safe-area-inset-right, 0px) + 0.75rem)",
            }}
          >
            <button onClick={() => onExport([playingClip])} className="inline-flex items-center gap-1.5 rounded-full bg-amber-400 px-4 py-2 text-sm font-bold text-black shadow-lg">
              <Share2 className="h-4 w-4" /> Save / Share
            </button>
            <div className="flex-1" />
            <button
              onClick={() => { const c = playingClip; if (confirm("Delete this clip?")) { onDelete(c.id); closePlayer(); } }}
              className="inline-flex items-center gap-1.5 rounded-full bg-black/70 border border-red-400/50 px-4 py-2 text-sm text-red-300 backdrop-blur-sm"
            >
              <Trash2 className="h-4 w-4" /> Delete
            </button>
          </div>
        </div>
      )}
    </>
  );
}

