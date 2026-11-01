import { execFile } from "node:child_process";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);

/** Pulls `count` evenly spaced JPEG frames out of the video, as base64. */
export async function extractFrames(
	videoPath: string,
	count = 8,
): Promise<string[]> {
	const { stdout } = await run("ffprobe", [
		"-v",
		"error",
		"-show_entries",
		"format=duration",
		"-of",
		"csv=p=0",
		videoPath,
	]);
	const duration = Number.parseFloat(stdout);
	if (!(duration > 0))
		throw new Error(`Couldn't read video duration: ${stdout.trim()}`);

	const dir = await mkdtemp(join(tmpdir(), "frames-"));
	try {
		await run("ffmpeg", [
			"-v",
			"error",
			"-i",
			videoPath,
			// 768px wide keeps the images legible without burning vision tokens.
			"-vf",
			`fps=${count / duration},scale=768:-2`,
			"-frames:v",
			String(count),
			"-q:v",
			"4",
			join(dir, "frame_%02d.jpg"),
		]);
		const files = (await readdir(dir)).sort();
		// Await before `finally` deletes the directory.
		return await Promise.all(
			files.map(async (f) => (await readFile(join(dir, f))).toString("base64")),
		);
	} finally {
		await rm(dir, { recursive: true, force: true });
	}
}

/**
 * Pulls the audio track out as a small mono mp3 (base64), or null if the clip has
 * no audio, e.g. when the glasses mic permission wasn't granted.
 */
export async function extractAudio(videoPath: string): Promise<string | null> {
	const { stdout } = await run("ffprobe", [
		"-v",
		"error",
		"-select_streams",
		"a",
		"-show_entries",
		"stream=index",
		"-of",
		"csv=p=0",
		videoPath,
	]);
	if (!stdout.trim()) return null;

	const dir = await mkdtemp(join(tmpdir(), "audio-"));
	try {
		const out = join(dir, "audio.mp3");
		// 16kHz mono is all speech needs and keeps the upload tiny.
		await run("ffmpeg", [
			"-v",
			"error",
			"-i",
			videoPath,
			"-vn",
			"-ac",
			"1",
			"-ar",
			"16000",
			"-b:a",
			"32k",
			out,
		]);
		return (await readFile(out)).toString("base64");
	} finally {
		await rm(dir, { recursive: true, force: true });
	}
}
