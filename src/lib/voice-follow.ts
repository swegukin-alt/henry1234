// Voice-follow: rolling-window transcription via the Lovable AI Gateway.
//
// The browser Web Speech API (webkitSpeechRecognition) is unreliable on iOS,
// especially for Korean. Instead we capture PCM through the Web Audio API,
// encode a short overlapping WAV window, POST it to /api/public/transcribe,
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

function commonPrefixLength(a: string, b: string): number {
  const limit = Math.min(a.length, b.length);
  let i = 0;
  while (i < limit && a[i] === b[i]) i++;
  return i;
}

function commonSuffixLength(a: string, b: string): number {
  const limit = Math.min(a.length, b.length);
  let i = 0;
  while (i < limit && a[a.length - 1 - i] === b[b.length - 1 - i]) i++;
  return i;
}

// Korean transcription spacing is not stable (e.g. "할 수" / "할수"), so
// compare a joined Hangul stream as well as normal whitespace-delimited words.
function joinedSimilarity(a: string, b: string): number {
  if (!a || !b) return 0;
  if (a === b) return 1;
  if (a.includes(b) || b.includes(a)) return Math.min(a.length, b.length) / Math.max(a.length, b.length);
  const edge = Math.max(commonPrefixLength(a, b), commonSuffixLength(a, b));
  const aPairs = new Set<string>();
  for (let i = 0; i < a.length - 1; i++) aPairs.add(a.slice(i, i + 2));
  let shared = 0;
  for (let i = 0; i < b.length - 1; i++) if (aPairs.has(b.slice(i, i + 2))) shared++;
  const dice = (2 * shared) / Math.max(1, a.length + b.length - 2);
  return Math.max(dice, edge / Math.max(a.length, b.length));
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
    let inFlight = 0;
    let requestSequence = 0;
    let latestAppliedSequence = 0;

    // Voice-follow is a sequential reader, not a document search. Always begin
    // at word zero when it is enabled and preserve this cursor through silence.
    anchorRef.current = 0;
    setAnchorWordIndex(wordsRef.current.length ? 0 : -1);
    setStatus("starting");

    const langCode = lang.startsWith("ko") ? "ko" : lang.startsWith("en") ? "en" : "";

    const advanceAnchor = (heardRaw: string) => {
      const wordsList = wordsRef.current;
      if (!wordsList.length) return;
      const heard = heardRaw.trim().split(/\s+/).map(normalizeWord).filter(Boolean);
      if (heard.length === 0) return;
      const anchor = Math.max(0, anchorRef.current);
      // Only inspect the immediate reading neighborhood. This is the key
      // invariant that prevents repeated Korean phrases from jumping elsewhere.
      const from = Math.max(0, anchor - 3);
      const to = Math.min(wordsList.length, anchor + 15);
      const tail = heard.slice(-8);
      let bestIdx = -1;
      let bestScore = 0;
      const heardJoined = tail.join("");
      // Score transcript suffixes against phrases ending at each nearby word.
      // A distance penalty makes the next expected phrase beat a later repeat.
      for (let end = from; end < to; end++) {
        for (let start = Math.max(from, end - 6); start <= end; start++) {
          const candidate = wordsList
            .slice(start, end + 1)
            .map((word) => word.norm)
            .join("");
          if (candidate.length < 3) continue;
          const compareLength = Math.min(candidate.length, heardJoined.length);
          const similarity = joinedSimilarity(
            candidate.slice(-compareLength),
            heardJoined.slice(-compareLength),
          );
          const distancePenalty = Math.max(0, end - anchor - 5) * 0.025;
          const lengthBonus = Math.min(0.08, compareLength * 0.004);
          const score = similarity + lengthBonus - distancePenalty;
          if (similarity >= (compareLength < 5 ? 0.92 : 0.67) && score > bestScore) {
            bestIdx = end;
            bestScore = score;
          }
        }
      }
      if (bestIdx <= anchor) return;
      // Even a bad transcription can move only a short natural phrase. Later
      // windows continue from the new cursor instead of teleporting the page.
      const next = Math.min(bestIdx, anchor + 7);
      anchorRef.current = next;
      setAnchorWordIndex(next);
    };

    const sendWindow = async () => {
      if (inFlight >= 2 || cancelled) return;
      // A 1.35 s window gives the model enough Korean context without forcing
      // the reader to wait several seconds before every update.
      const wantSamples = Math.floor(inRate * 1.35);
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
      // Keep 0.75 s so adjacent requests overlap across Korean word endings.
      const keepFromEnd = Math.floor(inRate * 0.75);
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

      const sequence = ++requestSequence;
      inFlight++;
      try {
        const fd = new FormData();
        fd.append("file", wav, "window.wav");
        if (langCode) fd.append("language", langCode);
        const contextStart = Math.max(0, anchorRef.current - 2);
        const context = wordsRef.current.slice(contextStart, contextStart + 28).map((word) => word.norm).join(" ");
        if (context) fd.append("prompt", context);
        const res = await fetch("/api/public/transcribe", { method: "POST", body: fd });
        if (!res.ok) return;
        const data = await res.json().catch(() => null);
        const text: string = data?.text || "";
        if (text && sequence > latestAppliedSequence) {
          advanceAnchor(text);
          latestAppliedSequence = sequence;
        }
      } catch { /* network hiccup — the next window will try again */ }
      finally { inFlight--; }
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
       processor = ctx!.createScriptProcessor(2048, 1, 1);
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
       // First result can begin after ~0.8 s; subsequent overlapping windows
       // are dispatched every 600 ms, with at most two requests in flight.
       window.setTimeout(sendWindow, 800);
       windowTimer = window.setInterval(sendWindow, 600);
    })();

    return () => {
      cancelled = true;
      if (windowTimer) window.clearInterval(windowTimer);
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
