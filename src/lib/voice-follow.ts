// Voice-follow: rolling-window transcription via the Lovable AI Gateway.
//
// The browser Web Speech API (webkitSpeechRecognition) is unreliable on iOS,
// especially for Korean. Instead we capture PCM through the Web Audio API,
// encode a ~3s WAV window every ~1.6s, POST it to /api/public/transcribe,
// and match the returned text against the script's word list to advance
// the highlight anchor.

import { useEffect, useRef, useState } from "react";
import { normalizeWord } from "./chunk-script";

export type VoiceFollowStatus = "off" | "starting" | "listening" | "error";

type Word = { norm: string; wordIndex: number };

export function isVoiceFollowSupported(): boolean {
  if (typeof window === "undefined") return false;
  const AC = (window as any).AudioContext || (window as any).webkitAudioContext;
  return !!(AC && navigator.mediaDevices?.getUserMedia);
}

// ---- WAV encoding (16-bit PCM, mono, downsampled to 16 kHz) ---------------

function downsampleTo16k(input: Float32Array, inRate: number): Float32Array {
  if (inRate === 16000) return input;
  const ratio = inRate / 16000;
  const outLen = Math.floor(input.length / ratio);
  const out = new Float32Array(outLen);
  for (let i = 0; i < outLen; i++) {
    const start = Math.floor(i * ratio);
    const end = Math.min(input.length, Math.floor((i + 1) * ratio));
    let sum = 0;
    for (let j = start; j < end; j++) sum += input[j];
    out[i] = sum / Math.max(1, end - start);
  }
  return out;
}

function encodeWav(pcm: Float32Array, sampleRate: number): Blob {
  const bytesPerSample = 2;
  const blockAlign = bytesPerSample;
  const byteRate = sampleRate * blockAlign;
  const dataSize = pcm.length * bytesPerSample;
  const buf = new ArrayBuffer(44 + dataSize);
  const dv = new DataView(buf);
  const wStr = (o: number, s: string) => { for (let i = 0; i < s.length; i++) dv.setUint8(o + i, s.charCodeAt(i)); };
  wStr(0, "RIFF");
  dv.setUint32(4, 36 + dataSize, true);
  wStr(8, "WAVE");
  wStr(12, "fmt ");
  dv.setUint32(16, 16, true);
  dv.setUint16(20, 1, true);       // PCM
  dv.setUint16(22, 1, true);       // mono
  dv.setUint32(24, sampleRate, true);
  dv.setUint32(28, byteRate, true);
  dv.setUint16(32, blockAlign, true);
  dv.setUint16(34, 16, true);      // bits per sample
  wStr(36, "data");
  dv.setUint32(40, dataSize, true);
  let off = 44;
  for (let i = 0; i < pcm.length; i++) {
    const s = Math.max(-1, Math.min(1, pcm[i]));
    dv.setInt16(off, s < 0 ? s * 0x8000 : s * 0x7fff, true);
    off += 2;
  }
  return new Blob([buf], { type: "audio/wav" });
}

// Peak level of a Float32 buffer — used to skip near-silent windows.
function peak(buf: Float32Array): number {
  let m = 0;
  for (let i = 0; i < buf.length; i++) {
    const a = Math.abs(buf[i]);
    if (a > m) m = a;
  }
  return m;
}

// ---- Hook -----------------------------------------------------------------

export function useVoiceFollow(opts: {
  enabled: boolean;
  words: Word[];
  lang: string; // "ko-KR" | "en-US"
}): { anchorWordIndex: number; status: VoiceFollowStatus } {
  const { enabled, words, lang } = opts;
  const [anchorWordIndex, setAnchorWordIndex] = useState<number>(-1);
  const [status, setStatus] = useState<VoiceFollowStatus>("off");
  const anchorRef = useRef<number>(-1);
  const wordsRef = useRef(words);
  const lastMatchAtRef = useRef<number>(0);
  const fadeTimerRef = useRef<number | null>(null);

  useEffect(() => { wordsRef.current = words; }, [words]);

  useEffect(() => {
    anchorRef.current = -1;
    setAnchorWordIndex(-1);
  }, [words]);

  useEffect(() => {
    if (!enabled) { setStatus("off"); return; }
    if (!isVoiceFollowSupported()) { setStatus("error"); return; }

    let cancelled = false;
    let stream: MediaStream | null = null;
    let ctx: AudioContext | null = null;
    let source: MediaStreamAudioSourceNode | null = null;
    let processor: ScriptProcessorNode | null = null;
    let ringChunks: Float32Array[] = [];
    let ringSamples = 0;
    let inRate = 48000;
    let windowTimer: number | null = null;
    let inFlight = false;

    setStatus("starting");

    const langCode = lang.startsWith("ko") ? "ko" : lang.startsWith("en") ? "en" : "";

    const scheduleFade = () => {
      if (fadeTimerRef.current) window.clearTimeout(fadeTimerRef.current);
      fadeTimerRef.current = window.setTimeout(() => {
        if (Date.now() - lastMatchAtRef.current >= 3800) {
          anchorRef.current = -1;
          setAnchorWordIndex(-1);
        }
      }, 4000);
    };

    const advanceAnchor = (heardRaw: string) => {
      const wordsList = wordsRef.current;
      if (!wordsList.length) return;
      const heard = heardRaw.trim().split(/\s+/).map(normalizeWord).filter(Boolean);
      if (heard.length === 0) return;
      const anchor = anchorRef.current;
      const from = Math.max(0, anchor - 2);
      const to = Math.min(wordsList.length, from + 200);
      const tail = heard.slice(-14);
      let bestIdx = -1;
      let bestScore = 0;
      for (let i = from; i < to; i++) {
        const wnorm = wordsList[i].norm;
        if (!wnorm) continue;
        let score = 0;
        for (const t of tail) {
          if (wnorm === t) { score += 3; continue; }
          if (t.length >= 2 && wnorm.length >= 2 && (wnorm.startsWith(t) || t.startsWith(wnorm))) score += 1;
        }
        if (score >= 2 && (score > bestScore || i > bestIdx)) {
          bestIdx = i;
          bestScore = score;
        }
      }
      if (bestIdx < 0) return;
      if (bestIdx < anchor - 2) return;
      if (anchor >= 0 && bestIdx - anchor > 60) return;
      if (bestIdx === anchor) return;
      anchorRef.current = bestIdx;
      setAnchorWordIndex(bestIdx);
      lastMatchAtRef.current = Date.now();
      scheduleFade();
    };

    const sendWindow = async () => {
      if (inFlight || cancelled) return;
      // Take the most recent ~3.2s of audio and reset the ring.
      const wantSamples = Math.floor(inRate * 3.2);
      let flat: Float32Array;
      if (ringSamples >= wantSamples) {
        flat = new Float32Array(wantSamples);
        // Copy the tail of the ring.
        let need = wantSamples;
        let pos = wantSamples;
        for (let i = ringChunks.length - 1; i >= 0 && need > 0; i--) {
          const c = ringChunks[i];
          const take = Math.min(need, c.length);
          flat.set(c.subarray(c.length - take), pos - take);
          pos -= take;
          need -= take;
        }
      } else if (ringSamples > 0) {
        flat = new Float32Array(ringSamples);
        let pos = 0;
        for (const c of ringChunks) { flat.set(c, pos); pos += c.length; }
      } else {
        return;
      }
      // Drop the OLDEST ~1.6s so successive windows overlap ~1.6s (good for
      // Korean where words often cross boundaries) and don't grow unbounded.
      const keepFromEnd = Math.floor(inRate * 1.6);
      if (ringSamples > keepFromEnd) {
        const merged = new Float32Array(keepFromEnd);
        let need = keepFromEnd, pos = keepFromEnd;
        for (let i = ringChunks.length - 1; i >= 0 && need > 0; i--) {
          const c = ringChunks[i];
          const take = Math.min(need, c.length);
          merged.set(c.subarray(c.length - take), pos - take);
          pos -= take; need -= take;
        }
        ringChunks = [merged];
        ringSamples = keepFromEnd;
      }

      // Skip if the window is essentially silent — saves credits and stops
      // the model from hallucinating filler on quiet rooms.
      if (peak(flat) < 0.01) return;

      const down = downsampleTo16k(flat, inRate);
      const wav = encodeWav(down, 16000);
      if (wav.size < 2048) return;

      inFlight = true;
      try {
        const fd = new FormData();
        fd.append("file", wav, "window.wav");
        if (langCode) fd.append("language", langCode);
        const res = await fetch("/api/public/transcribe", { method: "POST", body: fd });
        if (!res.ok) return;
        const data = await res.json().catch(() => null);
        const text: string = data?.text || "";
        if (text) advanceAnchor(text);
      } catch { /* network hiccup — the next window will try again */ }
      finally { inFlight = false; }
    };

    (async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
      } catch {
        if (!cancelled) setStatus("error");
        return;
      }
      if (cancelled) { stream?.getTracks().forEach((t) => t.stop()); return; }
      const AC = (window as any).AudioContext || (window as any).webkitAudioContext;
      ctx = new AC();
      inRate = ctx!.sampleRate;
      source = ctx!.createMediaStreamSource(stream);
      processor = ctx!.createScriptProcessor(4096, 1, 1);
      processor.onaudioprocess = (e) => {
        const ch = e.inputBuffer.getChannelData(0);
        // Copy — the underlying buffer is reused by the audio engine.
        const copy = new Float32Array(ch.length);
        copy.set(ch);
        ringChunks.push(copy);
        ringSamples += copy.length;
        // Keep at most ~5s in the ring.
        const maxSamples = Math.floor(inRate * 5);
        while (ringSamples > maxSamples && ringChunks.length > 1) {
          const drop = ringChunks.shift()!;
          ringSamples -= drop.length;
        }
      };
      source.connect(processor);
      // ScriptProcessor only fires when connected to a destination; route to
      // a silent gain node so we don't echo the mic into the speakers.
      const silent = ctx!.createGain();
      silent.gain.value = 0;
      processor.connect(silent);
      silent.connect(ctx!.destination);

      setStatus("listening");
      windowTimer = window.setInterval(sendWindow, 1600);
    })();

    return () => {
      cancelled = true;
      if (windowTimer) window.clearInterval(windowTimer);
      if (fadeTimerRef.current) { window.clearTimeout(fadeTimerRef.current); fadeTimerRef.current = null; }
      try { processor?.disconnect(); } catch {}
      try { source?.disconnect(); } catch {}
      try { stream?.getTracks().forEach((t) => t.stop()); } catch {}
      try { ctx?.close(); } catch {}
      ringChunks = [];
      ringSamples = 0;
      setStatus("off");
    };
  }, [enabled, lang]);

  return { anchorWordIndex, status };
}
