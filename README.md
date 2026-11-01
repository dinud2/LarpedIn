# LarpedIn

Turn whatever you just did into an insufferable LinkedIn thought-leadership post, hands-free.

Stream from Ray-Ban Meta glasses to your phone. Hold the capture button and the last few seconds become a clip. A backend watches it, listens to it, writes a dramatically self-important post about the moment, and publishes it to LinkedIn with the best frame attached.

## How it works

```
Ray-Ban Meta ──(Meta Wearables SDK)──▶ iOS app ──POST mp4──▶ backend ──▶ OpenRouter ──▶ LinkedIn
   glasses       HEVC + audio stream    rolling buffer        ffmpeg      transcribe +    post +
                                        (last 5–30s)          frames/mp3  write post      image
```

1. The iOS app streams video and audio from the glasses and keeps the last 30 seconds in memory.
2. A hold on the glasses capture button (or the in-app Clip button) cuts the chosen length (5–30s) into an mp4 and POSTs it to `<server>/api/clip`.
3. The backend uses ffmpeg to pull 32 frames and a mono mp3. An audio-capable model transcribes the mp3, then a second model writes the post from the frames and transcript and picks the best frame.
4. The post and frame are published to LinkedIn. A Live Activity on the phone shows each step and ends with a "View post" button.

## Repo layout

| Path | What |
|---|---|
| `LarpedIn/` | iOS app (SwiftUI, Meta Wearables Device Access Toolkit) plus the `LarpedInWidgets` Live Activity extension |
| `backend/` | TanStack Start API service with ffmpeg, OpenRouter and LinkedIn publishing, shipped as a Docker image. See [`backend/README.md`](backend/README.md) |
| `linkedin-backend/` | Early Python prototype, not used |

## iOS app

Needs Xcode 27, an iPhone on iOS 26.6+, Ray-Ban Meta glasses, and the Meta AI app with **Developer Mode** turned on (Settings → your glasses → Developer Mode).

1. Open `LarpedIn/LarpedIn.xcodeproj`, pick your team under Signing, and run the **LarpedIn** scheme on your phone.
2. Tap **Connect to Meta AI** and approve. Camera and mic permissions are requested through Meta AI on first stream.
3. In Settings (gear icon), set the server URL to your backend's base address, e.g. `https://your-app.onrender.com`.
4. Streaming starts automatically when the glasses connect.

On the glasses: **hold** the capture button to clip, **short press** for a photo. The glasses button uses Meta's experimental Inputs API. If it's unavailable, use the in-app buttons.

## Backend

```sh
cd backend
bun install
bun run dev        # needs ffmpeg on PATH
```

Required env: `OPENROUTER_API_KEY`. To publish to LinkedIn, also set `LINKEDIN_ACCESS_TOKEN` (with `w_member_social`), `LINKEDIN_AUTHOR_URN`, and `LINKEDIN_AUTO_PUBLISH=true`. Deploy the `backend/` directory to Render or Railway, which build it from the Dockerfile. Full details are in [`backend/README.md`](backend/README.md).

## Heads up

- LinkedIn's API only creates **public** posts, so every clip with auto-publish on goes straight to your feed.
- `/api/clip` has no auth. Anyone with the URL can post to your LinkedIn, so don't leave it running with a token set.
- Meta's Inputs and audio streaming features are experimental and can't ship to production builds yet.
