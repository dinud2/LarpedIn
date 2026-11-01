import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createFileRoute } from "@tanstack/react-router";
import { extractAudio, extractFrames } from "#/lib/media";
import { writePost } from "#/lib/post";
import { transcribe } from "#/lib/transcribe";

const MAX_BYTES = 50 * 1024 * 1024;

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
				const video = await readVideo(request);
				if (video instanceof Response) return video;

				const dir = await mkdtemp(join(tmpdir(), "clip-"));
				try {
					const path = join(dir, "clip.mp4");
					await writeFile(path, Buffer.from(await video.arrayBuffer()));
					const [frames, transcript] = await Promise.all([
						extractFrames(path),
						extractAudio(path).then((mp3) => (mp3 ? transcribe(mp3) : "")),
					]);
					const post = await writePost(frames, transcript);
					return Response.json({
						post,
						transcript,
						// Middle frame as a ready-made image for the post.
						image: `data:image/jpeg;base64,${frames[Math.floor(frames.length / 2)]}`,
					});
				} catch (error) {
					console.error("clip processing failed", error);
					return Response.json({ error: "Processing failed" }, { status: 502 });
				} finally {
					await rm(dir, { recursive: true, force: true });
				}
			},
		},
	},
});
