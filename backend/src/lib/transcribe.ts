import { z } from "zod";
import { env } from "#/env";

const Transcript = z.object({ text: z.string() });

/** ElevenLabs Scribe accepts the mp4 directly, so no audio extraction step. */
export async function transcribe(video: Blob): Promise<string> {
	const form = new FormData();
	form.append("model_id", "scribe_v2");
	form.append("file", video, "clip.mp4");

	const res = await fetch("https://api.elevenlabs.io/v1/speech-to-text", {
		method: "POST",
		headers: { "xi-api-key": env.ELEVENLABS_API_KEY },
		body: form,
	});
	if (!res.ok) throw new Error(`ElevenLabs ${res.status}: ${await res.text()}`);
	return Transcript.parse(await res.json()).text.trim();
}
