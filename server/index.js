// LarpedIn server: the glasses app POSTs a 10s clip (or a photo) here, and we
// turn it into a LinkedIn thought-leadership post saved as a .txt file.
//
//   clip.mp4 ─┬─ ffmpeg ──────────────> still frames ─┐
//             └─ ElevenLabs Scribe ───> transcript ───┴─> Claude ─> posts/<id>.txt
import { randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import Anthropic from "@anthropic-ai/sdk";
import express from "express";

const PORT = Number(process.env.PORT ?? 3000);
const POSTS_DIR = path.resolve(process.env.POSTS_DIR ?? "posts");
const FFMPEG = process.env.FFMPEG_PATH ?? "ffmpeg"; // installed by the Dockerfile on Render
const MODEL = "claude-opus-5-5";
const FRAME_COUNT = 4;

const run = promisify(execFile);
const anthropic = new Anthropic(); // reads ANTHROPIC_API_KEY

// ── 3a. Pull evenly spaced still frames out of the clip ──────────────────────
async function extractFrames(videoPath, workDir) {
  const { stderr } = await run(FFMPEG, ["-hide_banner", "-i", videoPath], { encoding: "utf8" }).catch(
    (err) => err, // ffmpeg exits non-zero with no output file, but still prints the info we want
  );
  const match = /Duration: (\d+):(\d+):([\d.]+)/.exec(stderr ?? "");
  const duration = match ? Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]) : 10;

  // fps = N / duration gives about N frames spread over the clip.
  const fps = Math.max(FRAME_COUNT / Math.max(duration, 0.1), 0.05);
  await run(FFMPEG, [
    "-hide_banner", "-loglevel", "error",
    "-i", videoPath,
    "-vf", `fps=${fps},scale='min(1024,iw)':-2`,
    "-frames:v", String(FRAME_COUNT),
    "-q:v", "3",
    path.join(workDir, "frame-%02d.jpg"),
  ]);

  const names = (await readdir(workDir)).filter((n) => n.startsWith("frame-")).sort();
  if (names.length === 0) throw new Error("ffmpeg produced no frames");
  return Promise.all(names.map((n) => readFile(path.join(workDir, n))));
}

// ── 3b. Transcribe what was said (ElevenLabs speech-to-text) ─────────────────
async function transcribe(videoPath) {
  if (!process.env.ELEVENLABS_API_KEY) {
    console.warn("[stt] ELEVENLABS_API_KEY not set, skipping transcript");
    return "";
  }
  const form = new FormData();
  form.append("model_id", "scribe_v2");
  form.append("file", new Blob([await readFile(videoPath)], { type: "video/mp4" }), "clip.mp4");

  const res = await fetch("https://api.elevenlabs.io/v1/speech-to-text", {
    method: "POST",
    headers: { "xi-api-key": process.env.ELEVENLABS_API_KEY },
    body: form,
  });
  if (!res.ok) {
    // Clips recorded without the mic permission have no audio track; that's fine.
    console.warn(`[stt] ElevenLabs returned ${res.status}: ${await res.text()}`);
    return "";
  }
  const { text } = await res.json();
  return (text ?? "").trim();
}

// ── 3c. Write the post (Claude, looking at the frames + transcript) ──────────
const SYSTEM = `You are a LinkedIn thought leader who turns every minor life event into a profound B2B SaaS / leadership lesson. You'll get a few still frames from a 10-second clip recorded on smart glasses, plus a transcript of anything that was said.

Work out the mundane thing that just happened, then write a post that:
- Opens with a dramatic, vulnerable one-line hook about that exact event
- Uses "broetry": one short sentence per line, lots of line breaks
- Pivots absurdly from the event to a business lesson (B2B SaaS, product-market fit, scaling, culture, AI, "the grind")
- Includes a 3-item emoji bullet list of "lessons"
- Humblebrags at least once (Series A, "my team", "when I was at a FAANG")
- Ends with an engagement question like "Agree? 👇" and 4-6 hashtags
- Is 120-220 words. The more trivial the event, the more profound the lesson.

If the transcript contains something funny the person said, work it in. Reply with only the post, in plain text (no markdown). This is satire for a parody site.`;

async function writePost(frames, transcript) {
  const response = await anthropic.beta.messages.create({
    model: MODEL,
    max_tokens: 16000,
    output_config: { effort: "medium" },
    // If the model declines, the API retries on a fallback model in the same call.
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    system: SYSTEM,
    messages: [
      {
        role: "user",
        content: [
          ...frames.map((frame) => ({
            type: "image",
            source: { type: "base64", media_type: "image/jpeg", data: frame.toString("base64") },
          })),
          {
            type: "text",
            text: transcript
              ? `Transcript of the clip: "${transcript}"`
              : "There was no speech in the clip.",
          },
        ],
      },
    ],
  });
  if (response.stop_reason === "refusal") throw new Error("Claude declined to write this post");
  const post = response.content
    .flatMap((block) => (block.type === "text" ? [block.text] : []))
    .join("")
    .trim();
  if (!post) throw new Error(`Empty post (stop_reason: ${response.stop_reason})`);
  return post;
}

// ── 2. Receive the upload from the iOS app ───────────────────────────────────
const app = express();

app.get("/healthz", (_req, res) => res.send("ok"));

// The app sends the raw file as the body: Content-Type video/mp4 (hold) or image/jpeg (tap).
app.post("/upload", express.raw({ type: ["video/*", "image/*"], limit: "200mb" }), async (req, res) => {
  const id = `${new Date().toISOString().replace(/[:.]/g, "-")}-${randomUUID().slice(0, 8)}`;
  const type = req.get("content-type") ?? "";
  if (!Buffer.isBuffer(req.body) || req.body.length === 0) {
    return res.status(400).json({ error: "Send the clip as the raw request body (video/mp4 or image/jpeg)" });
  }
  console.log(`[${id}] received ${type}, ${(req.body.length / 1e6).toFixed(1)} MB`);

  const workDir = await mkdtemp(path.join(tmpdir(), "larp-"));
  try {
    let frames;
    let transcript = "";
    if (type.startsWith("image/")) {
      frames = [req.body]; // A photo from a short press: no audio to transcribe.
    } else {
      const videoPath = path.join(workDir, "clip.mp4");
      await writeFile(videoPath, req.body);
      [frames, transcript] = await Promise.all([extractFrames(videoPath, workDir), transcribe(videoPath)]);
    }
    console.log(`[${id}] ${frames.length} frame(s), transcript: ${JSON.stringify(transcript)}`);

    const post = await writePost(frames, transcript);
    await mkdir(POSTS_DIR, { recursive: true });
    await writeFile(path.join(POSTS_DIR, `${id}.txt`), post + "\n");
    console.log(`[${id}] wrote posts/${id}.txt\n\n${post}\n`);

    res.json({ id, transcript, frames: frames.length, post });
  } catch (err) {
    console.error(`[${id}] failed:`, err);
    res.status(500).json({ id, error: String(err?.message ?? err) });
  } finally {
    await rm(workDir, { recursive: true, force: true });
  }
});

// Read posts back (handy on Render, where you can't open the server's files directly).
app.get("/posts", async (_req, res) => {
  const names = await readdir(POSTS_DIR).catch(() => []);
  res.json(names.filter((n) => n.endsWith(".txt")).sort().reverse());
});

app.get("/posts/latest", async (_req, res) => {
  const names = (await readdir(POSTS_DIR).catch(() => [])).filter((n) => n.endsWith(".txt")).sort();
  if (names.length === 0) return res.status(404).type("text").send("No posts yet\n");
  res.type("text").send(await readFile(path.join(POSTS_DIR, names.at(-1)), "utf8"));
});

app.get("/posts/:name", async (req, res) => {
  const name = path.basename(req.params.name);
  try {
    res.type("text").send(await readFile(path.join(POSTS_DIR, name.endsWith(".txt") ? name : `${name}.txt`), "utf8"));
  } catch {
    res.status(404).type("text").send("Not found\n");
  }
});

app.listen(PORT, () => console.log(`LarpedIn server listening on :${PORT} (ffmpeg: ${FFMPEG})`));
