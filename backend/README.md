# backend

Turns a glasses clip into a LinkedIn post. TanStack Start API routes, built with Nitro, shipped as a Docker image (Render and Railway).

## Endpoints

- `GET /api/health` returns `{ "ok": true }`, or 500 if env vars are missing.
- `POST /api/clip` takes an mp4, either as multipart field `file` or as a raw `video/mp4` body (what the iOS app sends). It returns:

  ```json
  { "post": "...", "transcript": "...", "image": "data:image/jpeg;base64,..." }
  ```

  Pipeline: ffmpeg pulls 32 frames and a mono mp3. The mp3 goes to an audio-capable OpenRouter model for the transcript (in parallel with frame extraction), then the frames and transcript go to the post model, which writes the post and picks the best frame as `image`.

  The response also includes `draft`: the post and the picked frame are copied into a
  persistent local LinkedIn draft. The original `post`, `transcript`, and `image` fields
  are unchanged. With `LINKEDIN_AUTO_PUBLISH=true`, the photo is uploaded and the post is
  published automatically. Otherwise it remains a local draft. If publication fails,
  the generated content is still returned alongside `publish_error` and the saved draft.

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

## LinkedIn publishing

After writing the post, `/api/clip` saves it with the picked frame as a local draft
(`draft` in the response). With `LINKEDIN_AUTO_PUBLISH=true` it then uploads the image
through LinkedIn's Images API and publishes with `POST /rest/posts`. `draft.post_url`
links to the live post. If publishing fails, the response still has the post, the
saved draft and `publish_error`.

LinkedIn's Posts API only creates **published** posts. There's no unpublished draft on
LinkedIn's side, so every auto-published post shows up in people's feeds.

| Var | |
|---|---|
| `LINKEDIN_ACCESS_TOKEN` | OAuth member token with `w_member_social` (or `w_organization_social` and a Page role for an organization) |
| `LINKEDIN_AUTHOR_URN` | The authorized `urn:li:person:...` or `urn:li:organization:...` |
| `LINKEDIN_AUTO_PUBLISH` | `true` to publish after each clip; default false (local drafts only) |
| `LINKEDIN_API_VERSION` | YYYYMM API version, default `202610` |
| `LINKEDIN_DRAFT_DIR` | Draft storage folder, default `data/linkedin-drafts` |

Get the token through your LinkedIn developer app's OAuth consent flow. It's a
server-side env var only, never in the iOS app or the repo.

A timeout, connection failure or 5xx from LinkedIn can mean the post went live even
though the response was lost. Those drafts are marked `publish_unknown` and never retried
automatically, so check the profile by hand. Drafts live on disk: use a persistent
volume if you need them across deploys, and run a single instance (the publish lock is
in-process).

References:
- [Post lifecycle restrictions](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/posts-api#update-posts)
- [Images API](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/images-api)

Tests (no credentials or network needed):

```sh
bun run test:linkedin
```
