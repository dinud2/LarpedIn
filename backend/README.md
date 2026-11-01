# backend

Turns a glasses clip into a LinkedIn post. TanStack Start API routes, built with Nitro, shipped as a Docker image (Render and Railway).

## Endpoints

- `GET /api/health` returns `{ "ok": true }`, or 500 if env vars are missing.
- `POST /api/clip` takes an mp4, either as multipart field `file` or as a raw `video/mp4` body (what the iOS app sends). It returns:

  ```json
  { "post": "...", "transcript": "...", "image": "data:image/jpeg;base64,..." }
  ```

  Pipeline: ffmpeg pulls 8 frames and a mono mp3. The mp3 goes to an audio-capable OpenRouter model for the transcript (in parallel with frame extraction), then the frames and transcript go to the post model. `image` is the middle frame.

  The response also includes `draft`: the post and the middle frame are copied into a
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

LinkedIn's Posts API accepts **PUBLISHED only** when creating posts. It cannot create
an unpublished draft on LinkedIn, nor does it document a personal-profile-only post
that is guaranteed to stay out of people's feeds. `feedDistribution: NONE` is documented
for company dark/ad posts, not personal profile-only posts. Published posts in this
integration use normal feed distribution and may appear in people's feeds. Local drafts
are kept in LarpedIn until publication succeeds.

### Publish directly from Claude JSON

`POST /api/linkedin/post` accepts the existing Claude output:

```json
{ "post": "The exact text Claude returned", "image": "data:image/jpeg;base64,..." }
```

Or pass a decoded photo path:

```json
{ "post": "The exact text Claude returned", "image_path": "frame.jpg" }
```

The service copies the photo into local storage, uploads it through LinkedIn's Images
API, then creates the post with `POST /rest/posts`. The returned JSON includes
`status: "published"`, `published: true`, `post_urn`, and `post_url`. It preserves the
text Claude provided and escapes LinkedIn's special commentary characters for display.

To publish automatically after each `/api/clip` request, set `LINKEDIN_AUTO_PUBLISH=true`
after configuring the account variables below. The default is false while credentials
are not configured. To publish a previously saved draft, send `{ "id": "draft-uuid" }`
to `/api/linkedin/post`.

On failure, the direct-post endpoint returns `draft_id`. Reuse that ID instead of
resubmitting the text/image, which would create a new draft. A successfully published
ID returns its existing result without another post creation call. A timeout, connection
failure, missing result ID, or server error can mean LinkedIn created the post even if
the response was lost; such drafts are marked `publish_unknown` and blocked from automatic
retry. Check LinkedIn manually in that case. Explicit API rejections leave the draft
available for retry after permissions or media readiness are resolved. Image processing
is asynchronous; if LinkedIn rejects a not-yet-ready image, retry the same draft ID later.

Official references:
- [Post lifecycle restrictions](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/posts-api#update-posts)
- [Company dark posts](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/posts-api#create-dark-posts)
- [Images API](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/images-api)

### Accept existing Claude JSON or a photo path

`POST /api/linkedin/draft` accepts the existing `/api/clip` response directly:

```json
{ "post": "The exact text Claude returned", "image": "data:image/jpeg;base64,..." }
```

It also accepts a path to a photo already on the backend computer:

```json
{ "post": "The exact text Claude returned", "image_path": "frame.jpg" }
```

`image_path` is relative to `LINKEDIN_MEDIA_ROOT` (default `backend/media` when running
from `backend/`). An absolute path works if it is inside that root. Point the root at
the decoder's screenshot folder to use its output paths. Phone file paths don't refer
to files on the server; use the existing data URL for those. Remote URLs aren't fetched.
Photo bytes must be JPEG, PNG, or GIF, at most 10 MB; post text is at most 3,000 characters.
Aliases `text` and `caption` are accepted for the post text.

The result includes `id`, `post`, `image_path`, `status: "draft"`, `published: false`,
and `storage: "local"`. Photo bytes and JSON metadata are stored under
`LINKEDIN_DRAFT_DIR` (default `data/linkedin-drafts`). The image is copied, so deleting
the decoder's temporary files won't break the draft. `GET /api/linkedin/draft?id=UUID`
loads a saved draft. No credentials are required for local drafts.

### Prepare the photo with LinkedIn's API

Set server environment variables:

| Variable | Purpose |
| --- | --- |
| `LINKEDIN_ACCESS_TOKEN` | OAuth member token with `w_member_social`; for an organization, `w_organization_social` and the required Page role |
| `LINKEDIN_AUTHOR_URN` | The authorized `urn:li:person:...` or `urn:li:organization:...` |
| `LINKEDIN_API_VERSION` | Supported YYYYMM API version; defaults to `202610` |
| `LINKEDIN_MEDIA_ROOT` | Allowed folder for input photo paths; defaults to `media` |
| `LINKEDIN_DRAFT_DIR` | Draft storage folder; defaults to `data/linkedin-drafts` |
| `LINKEDIN_AUTO_PUBLISH` | `true` to publish immediately after generating each clip's post; default false |

Obtain the token through your LinkedIn developer application's OAuth consent flow.
This change uses an existing server-side token; it doesn't implement account login.
Never put tokens in the JSON request, iOS app, or source control. `.env.example`
documents settings; configure the deployment's environment variables as usual.

`POST /api/linkedin/prepare` with `{ "id": "the-draft-uuid" }` initializes an Images
API upload, sends the saved photo bytes to LinkedIn, and stores the resulting image URN
with the draft. The draft remains local and unpublished. The response's `linkedin.post_fields`
contains escaped commentary and image content fields, not a complete publish request.
Image processing availability is not polled because member write-only tokens may not
have permission to read it. Uploaded images may need re-uploading if used much later.

Drafts and publication records are stored on disk; configure a persistent volume in production.
Run one backend instance per draft directory; the in-process publication lock is not a
distributed lock. These API
routes currently follow the existing backend's unauthenticated development setup;
restrict access before deployment, especially to token-backed publishing routes.
No LinkedIn token has been used during development and no post has been created.

Run the isolated tests (Node 22+; no LinkedIn credentials or network needed):

```sh
npm run test:linkedin
```
