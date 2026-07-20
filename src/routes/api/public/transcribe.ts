import { createFileRoute } from "@tanstack/react-router";

// Public endpoint that forwards short audio windows to the Lovable AI
// transcription gateway. Used by the voice-follow reader — the browser's
// webkitSpeechRecognition is unreliable for Korean, so we roll our own by
// posting ~3s WAV windows every couple seconds and matching what came back.
//
// No user PII is stored; the audio is proxied straight to the Gateway and
// only the returned transcript text is echoed back.

export const Route = createFileRoute("/api/public/transcribe")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const apiKey = process.env.LOVABLE_API_KEY;
        if (!apiKey) return new Response("Transcription unavailable", { status: 503 });

        const contentType = request.headers.get("content-type") || "";
        if (!contentType.includes("multipart/form-data")) {
          return new Response("Expected multipart/form-data", { status: 400 });
        }

        let form: FormData;
        try {
          form = await request.formData();
        } catch {
          return new Response("Invalid form data", { status: 400 });
        }

        const file = form.get("file");
        if (!(file instanceof File) || file.size < 2048) {
          return new Response("Empty or missing audio", { status: 400 });
        }
        // 25 MiB gateway ceiling — our windows are ~100 KB, so anything
        // remotely close is a client bug.
        if (file.size > 2 * 1024 * 1024) {
          return new Response("Audio window too large", { status: 413 });
        }

        const lang = (form.get("language") as string | null) || "";
        const prompt = ((form.get("prompt") as string | null) || "").slice(0, 1200);

        const upstream = new FormData();
        upstream.append("model", "openai/gpt-4o-transcribe");
        upstream.append("file", file, file.name || "window.wav");
        if (lang) upstream.append("language", lang);
        if (prompt) upstream.append("prompt", prompt);

        const res = await fetch(
          "https://ai.gateway.lovable.dev/v1/audio/transcriptions",
          {
            method: "POST",
            headers: { Authorization: `Bearer ${apiKey}` },
            body: upstream,
          }
        );
        const body = await res.text();
        return new Response(body, {
          status: res.status,
          headers: { "Content-Type": res.headers.get("content-type") || "application/json" },
        });
      },
    },
  },
});
