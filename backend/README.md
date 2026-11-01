# backend

Turns a glasses clip into a LinkedIn post. TanStack Start API routes, built with Nitro, shipped as a Docker image (Render and Railway).

## Endpoints

- `GET /api/health` returns `{ "ok": true }`, or 500 if env vars are missing.
- `POST /api/clip` takes an mp4, either as multipart field `file` or as a raw `video/mp4` body (what the iOS app sends). It returns:

  ```json
  { "post": "...", "transcript": "...", "image": "data:image/jpeg;base64,..." }
  ```

  Pipeline: ffmpeg pulls 8 frames and ElevenLabs Scribe transcribes the mp4 (in parallel), then the frames and transcript go to an OpenRouter model. `image` is the middle frame.

```sh
curl -F file=@clip.mp4 http://localhost:3000/api/clip
```

## Env

| Var | |
|---|---|
| `OPENROUTER_API_KEY` | required |
| `ELEVENLABS_API_KEY` | required |
| `OPENROUTER_MODEL` | optional, default `anthropic/claude-sonnet-5.5` |
| `PORT` | set by Render/Railway |

## Run

```sh
bun install
bun run dev                       # needs ffmpeg on PATH
bun run build && bun .output/server/index.mjs
```

## Deploy

Point Render (Docker runtime) or Railway at this repo with root directory `backend/`. Both pick up the `Dockerfile`. Set the env vars and use `/api/health` as the health check path.
