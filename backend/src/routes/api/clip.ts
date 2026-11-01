import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createFileRoute } from "@tanstack/react-router";
import {
	createLinkedInDraft,
	draftErrorResponse,
	getLinkedInDraft,
	publishLinkedInDraft,
} from "#/lib/linkedin";
import { extractAudio, extractFrames } from "#/lib/media";
import { writePost } from "#/lib/post";
import { transcribe } from "#/lib/transcribe";

const MAX_BYTES = 50 * 1024 * 1024;

/** Per-request logger: `[clip a1b2c3d4 +1234ms] message`. Logs sizes, not content. */
function clipLogger() {
	const id = crypto.randomUUID().slice(0, 8);
	const start = Date.now();
	const prefix = () => `[clip ${id} +${Date.now() - start}ms]`;
	return {
		info: (message: string) => console.log(prefix(), message),
		error: (message: string, error: unknown) =>
			console.error(prefix(), message, error),
	};
}

/** Accepts either multipart (`file` field) or a raw `video/mp4` body, which is what the iOS app sends. */
async function readVideo(request: Request): Promise<Blob | Response> {
	const type = request.headers.get("content-type") ?? "";
	const video = type.startsWith("multipart/form-data")
		? (await request.formData()).get("file")
		: type.startsWith("video/")
			? await request.blob()
			: null;
	if (!(video instanceof Blob) || video.size === 0) {
		return Response.json(
			{
				error:
					"Send an mp4 as multipart field 'file' or as a raw video/mp4 body",
			},
			{ status: 400 },
		);
	}
	if (video.size > MAX_BYTES)
		return Response.json({ error: "Video over 50MB" }, { status: 413 });
	return video;
}

export const Route = createFileRoute("/api/clip")({
	server: {
		handlers: {
			POST: async ({ request }) => {
				const log = clipLogger();
				log.info(
					`request received (${request.headers.get("content-type")?.split(";")[0] ?? "no content-type"})`,
				);
				const video = await readVideo(request);
				if (video instanceof Response) {
					log.info(`rejected with ${video.status}`);
					return video;
				}
				log.info(`video received (${(video.size / 1024).toFixed(0)} KB)`);

				const dir = await mkdtemp(join(tmpdir(), "clip-"));
				try {
					const path = join(dir, "clip.mp4");
					await writeFile(path, Buffer.from(await video.arrayBuffer()));
					log.info("processing video");
					const [frames, transcript] = await Promise.all([
						extractFrames(path).then((frames) => {
							log.info(`extracted ${frames.length} frames`);
							return frames;
						}),
						extractAudio(path).then(async (mp3) => {
							if (!mp3) {
								log.info("no audio track, skipping transcription");
								return "";
							}
							log.info(
								`extracted audio (${((mp3.length * 3) / 4 / 1024).toFixed(0)} KB mp3), transcribing`,
							);
							const text = await transcribe(mp3);
							log.info(`transcribed (${text.length} chars)`);
							return text;
						}),
					]);
					if (!frames.length) throw new Error("No video frames were decoded");
					log.info("analyzing frames and transcript");
					const { post, frameIndex } = await writePost(frames, transcript);
					log.info(
						`post written (${post.length} chars), using frame ${frameIndex + 1}/${frames.length}`,
					);
					// The frame the model picked as the post's image.
					const image = `data:image/jpeg;base64,${frames[frameIndex]}`;
					let draft = await createLinkedInDraft({ post, image });
					log.info(`saved linkedin draft ${draft.id}`);
					let publishError: string | undefined;
					if (process.env.LINKEDIN_AUTO_PUBLISH === "true") {
						log.info("publishing to linkedin");
						try {
							draft = await publishLinkedInDraft(draft.id);
							log.info(
								`published to linkedin: ${draft.post_url ?? draft.status}`,
							);
						} catch (error) {
							const response = draftErrorResponse(error);
							publishError = (await response.json()).error;
							draft = await getLinkedInDraft(draft.id);
							// Return the generated text and saved draft even if LinkedIn fails.
							log.info(`linkedin publish failed, draft kept: ${publishError}`);
						}
					}
					log.info("done");
					return Response.json({
						post,
						transcript,
						image,
						draft,
						publish_error: publishError,
					});
				} catch (error) {
					log.error("processing failed", error);
					return Response.json({ error: "Processing failed" }, { status: 502 });
				} finally {
					await rm(dir, { recursive: true, force: true });
				}
			},
		},
	},
});
