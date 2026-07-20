import { createFileRoute } from "@tanstack/react-router";

// Public endpoint that forwards short audio windows to the Lovable AI
// transcription gateway. Streaming partials are passed through immediately.
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
        const upstream = new FormData();
        upstream.append("model", "openai/gpt-4o-transcribe");
        upstream.append("file", file, file.name || "window.wav");
        if (lang) upstream.append("language", lang);
        const prompt = form.get("prompt");
        if (typeof prompt === "string" && prompt.trim()) {
          // Bias recognition toward the small script neighborhood currently at
          // the reader's eye-line. This improves Korean names and spacing while
          // still allowing natural off-script speech to be ignored client-side.
          upstream.append("prompt", prompt.slice(0, 1200));
        }
        upstream.append("stream", "true");

        const res = await fetch(
          "https://ai.gateway.lovable.dev/v1/audio/transcriptions",
          {
            method: "POST",
            headers: {
              "Lovable-API-Key": apiKey,
              "X-Lovable-AIG-SDK": "vercel-ai-sdk",
            },
            body: upstream,
          }
        );
        const responseHeaders = new Headers({
          "Content-Type": res.headers.get("content-type") || "text/event-stream",
          "Cache-Control": "no-cache, no-transform",
        });
        res.headers.forEach((value, name) => {
          if (name.toLowerCase().startsWith("x-lovable-aig-")) responseHeaders.set(name, value);
        });
        if (!res.ok) {
          const message = await res.text();
          return new Response(message || "Transcription failed", {
            status: res.status,
            headers: responseHeaders,
          });
        }
        return new Response(res.body, {
          status: res.status,
          headers: responseHeaders,
        });
      },
    },
  },
});
