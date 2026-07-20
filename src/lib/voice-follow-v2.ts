import { useEffect, useRef, useState } from "react";
import { normalizeWord } from "./chunk-script";

export type VoiceFollowStatus = "off" | "starting" | "listening" | "error";
type Word = { norm: string; wordIndex: number };

export function isVoiceFollowSupported(): boolean {
  if (typeof window === "undefined") return false;
  const AC = (window as any).AudioContext || (window as any).webkitAudioContext;
  return !!(AC && navigator.mediaDevices?.getUserMedia);
}

function downsample(input: Float32Array, rate: number) {
  if (rate === 16000) return input;
  const ratio = rate / 16000;
  const out = new Float32Array(Math.floor(input.length / ratio));
  for (let i = 0; i < out.length; i++) {
    const start = Math.floor(i * ratio), end = Math.min(input.length, Math.floor((i + 1) * ratio));
    let sum = 0;
    for (let j = start; j < end; j++) sum += input[j];
    out[i] = sum / Math.max(1, end - start);
  }
  return out;
}

function wav(pcm: Float32Array) {
  const buffer = new ArrayBuffer(44 + pcm.length * 2), view = new DataView(buffer);
  const text = (at: number, value: string) => [...value].forEach((char, i) => view.setUint8(at + i, char.charCodeAt(0)));
  text(0, "RIFF"); view.setUint32(4, 36 + pcm.length * 2, true); text(8, "WAVE"); text(12, "fmt ");
  view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
  view.setUint32(24, 16000, true); view.setUint32(28, 32000, true); view.setUint16(32, 2, true);
  view.setUint16(34, 16, true); text(36, "data"); view.setUint32(40, pcm.length * 2, true);
  pcm.forEach((value, i) => {
    const sample = Math.max(-1, Math.min(1, value));
    view.setInt16(44 + i * 2, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
  });
  return new Blob([buffer], { type: "audio/wav" });
}

function peak(input: Float32Array) {
  let result = 0;
  for (const value of input) result = Math.max(result, Math.abs(value));
  return result;
}

function similarity(a: string, b: string) {
  if (!a || !b) return 0;
  if (a === b) return 1;
  if (a.includes(b) || b.includes(a)) return Math.min(a.length, b.length) / Math.max(a.length, b.length);
  const pairs = new Map<string, number>();
  for (let i = 0; i < a.length - 1; i++) pairs.set(a.slice(i, i + 2), (pairs.get(a.slice(i, i + 2)) || 0) + 1);
  let shared = 0;
  for (let i = 0; i < b.length - 1; i++) {
    const pair = b.slice(i, i + 2), count = pairs.get(pair) || 0;
    if (count) { shared++; pairs.set(pair, count - 1); }
  }
  return (2 * shared) / Math.max(1, a.length + b.length - 2);
}

export function useVoiceFollow({ enabled, words, lang }: { enabled: boolean; words: Word[]; lang: string }) {
  const [anchorWordIndex, setAnchorWordIndex] = useState(-1);
  const [status, setStatus] = useState<VoiceFollowStatus>("off");
  const anchor = useRef(-1), wordList = useRef(words);
  useEffect(() => { wordList.current = words; }, [words]);
  useEffect(() => { anchor.current = -1; setAnchorWordIndex(-1); }, [words]);

  useEffect(() => {
    if (!enabled) {
      anchor.current = -1;
      setAnchorWordIndex(-1);
      setStatus("off");
      return;
    }
    if (!isVoiceFollowSupported()) { setStatus("error"); return; }
    let stopped = false, stream: MediaStream | null = null, context: AudioContext | null = null;
    let source: MediaStreamAudioSourceNode | null = null, processor: ScriptProcessorNode | null = null;
    let recognition: any = null, chunks: Float32Array[] = [], samples = 0, rate = 48000, timer = 0, inFlight = 0;
    anchor.current = 0;
    setAnchorWordIndex(wordList.current.length ? 0 : -1);
    setStatus("starting");

    // Sequential alignment: only phrases touching the current cursor are legal.
    const advance = (raw: string, interim: boolean) => {
      const list = wordList.current, cursor = Math.max(0, anchor.current);
      const heard = raw.split(/\s+/).map(normalizeWord).filter(Boolean).slice(-7).join("");
      if (!list.length || heard.length < 2) return;
      const from = Math.max(0, cursor - 2), to = Math.min(list.length - 1, cursor + (interim ? 8 : 12));
      let bestEnd = -1, best = 0;
      for (let start = from; start <= Math.min(cursor + 2, to); start++) {
        let candidate = "";
        for (let end = start; end <= to; end++) {
          candidate += list[end].norm;
          if (end < cursor || candidate.length < 2) continue;
          const width = Math.min(candidate.length, heard.length);
          const score = similarity(candidate.slice(-width), heard.slice(-width)) - Math.max(0, end - cursor - 6) * 0.035;
          if (score > best) { best = score; bestEnd = end; }
        }
      }
      if (bestEnd <= cursor || best < (interim ? 0.82 : 0.68)) return;
      const next = Math.min(bestEnd, cursor + (interim ? 3 : 6));
      anchor.current = next;
      setAnchorWordIndex(next);
    };

    // Fast local interim results (usually 100–300 ms), used conservatively.
    const Recognition = (window as any).SpeechRecognition || (window as any).webkitSpeechRecognition;
    if (Recognition) try {
      recognition = new Recognition();
      recognition.lang = lang; recognition.continuous = true; recognition.interimResults = true; recognition.maxAlternatives = 1;
      recognition.onresult = (event: any) => {
        let transcript = "";
        for (let i = event.resultIndex; i < event.results.length; i++) transcript += ` ${event.results[i][0]?.transcript || ""}`;
        if (transcript.trim()) advance(transcript, true);
      };
      recognition.onend = () => { if (!stopped) try { recognition.start(); } catch {} };
      recognition.start();
    } catch { recognition = null; }

    const readEvents = async (response: Response) => {
      if (!response.body) return;
      const reader = response.body.getReader(), decoder = new TextDecoder();
      let buffer = "", transcript = "";
      while (!stopped) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const events = buffer.split("\n\n"); buffer = events.pop() || "";
        for (const event of events) for (const line of event.split("\n")) if (line.startsWith("data:")) try {
          const data = JSON.parse(line.slice(5).trim());
          if (data.type === "transcript.text.delta" && data.delta) { transcript += data.delta; advance(transcript, false); }
          if (data.type === "transcript.text.done" && data.text) advance(data.text, false);
        } catch {}
      }
    };

    const send = async () => {
      if (stopped || inFlight >= 2 || samples < rate * 0.55) return;
      const count = Math.min(samples, Math.floor(rate * 1.1)), audio = new Float32Array(count);
      let need = count, pos = count;
      for (let i = chunks.length - 1; i >= 0 && need; i--) {
        const take = Math.min(need, chunks[i].length);
        audio.set(chunks[i].subarray(chunks[i].length - take), pos - take); pos -= take; need -= take;
      }
      const overlap = audio.slice(Math.max(0, audio.length - Math.floor(rate * 0.42)));
      chunks = [overlap]; samples = overlap.length;
      if (peak(audio) < 0.008) return;
      const audioFile = wav(downsample(audio, rate));
      inFlight++;
      try {
        const body = new FormData(); body.append("file", audioFile, "speech.wav");
        body.append("language", lang.startsWith("ko") ? "ko" : "en");
        const response = await fetch("/api/public/transcribe", { method: "POST", body });
        if (response.ok) await readEvents(response);
      } catch {} finally { inFlight--; }
    };

    (async () => {
      try { stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } }); }
      catch { if (!stopped) setStatus("error"); return; }
      if (stopped) { stream.getTracks().forEach((track) => track.stop()); return; }
      const AC = (window as any).AudioContext || (window as any).webkitAudioContext;
      context = new AC(); await context!.resume(); rate = context!.sampleRate;
      source = context!.createMediaStreamSource(stream); processor = context!.createScriptProcessor(1024, 1, 1);
      processor.onaudioprocess = (event) => {
        const copy = new Float32Array(event.inputBuffer.getChannelData(0)); chunks.push(copy); samples += copy.length;
        while (samples > rate * 2 && chunks.length > 1) samples -= chunks.shift()!.length;
      };
      const silent = context!.createGain(); silent.gain.value = 0;
      source.connect(processor); processor.connect(silent); silent.connect(context!.destination);
      setStatus("listening"); window.setTimeout(send, 600); timer = window.setInterval(send, 520);
    })();

    return () => {
      stopped = true; window.clearInterval(timer);
      try { recognition?.abort(); processor?.disconnect(); source?.disconnect(); } catch {}
      try { stream?.getTracks().forEach((track) => track.stop()); context?.close(); } catch {}
      setStatus("off");
    };
  }, [enabled, lang]);

  return { anchorWordIndex, status };
}