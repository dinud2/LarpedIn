# backend

Turns a glasses clip into a LinkedIn post. TanStack Start API routes, built with Nitro, shipped as a Docker image (Render and Railway).

## Endpoints

- `GET /api/health` returns `{ "ok": true }`, or 500 if env vars are missing.
- `POST /api/clip` takes an mp4, either as multipart field `file` or as a raw `video/mp4` body (what the iOS app sends). It returns:

  ```json
  { "post": "...", "transcript": "...", "image": "data:image/jpeg;base64,..." }
  ```

  Pipeline: ffmpeg pulls 16 frames and a mono mp3. The mp3 goes to an audio-capable OpenRouter model for the transcript (in parallel with frame extraction), then the frames and transcript go to the post model, which writes the post and picks the best frame as `image`.

```sh
curl -F file=@clip.mp4 http://localhost:3000/api/clip
```

## Env

| Var | |
|---|---|
| `OPENROUTER_API_KEY` | required |
| `OPENROUTER_MODEL` | optional, writes the post, default `anthropic/claude-sonnet-5.5` |
| `OPENROUTER_TRANSCRIBE_MODEL` | optional, must accept audio, default `google/gemini-3.8-flash` |
| `PORT` | set by Render/Railway |

## Run

```sh
bun install
bun run dev                       # needs ffmpeg on PATH
bun run build && bun .output/server/index.mjs
```

## Deploy

Point Render (Docker runtime) or Railway at this repo with root directory `backend/`. Both pick up the `Dockerfile`. Set the env vars and use `/api/health` as the health check path.
