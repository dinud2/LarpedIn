import { env } from "#/env";
import { chat } from "#/lib/openrouter";

/** Transcribes a base64 mp3 with an audio-capable OpenRouter model (Claude can't take audio). */
export async function transcribe(mp3: string): Promise<string> {
	const text = await chat(env.OPENROUTER_TRANSCRIBE_MODEL, [
		{
			role: "user",
			content: [
				{
					type: "text",
					text: "Transcribe the speech in this audio verbatim. Reply with only the transcript, or NONE if nobody speaks.",
				},
				{ type: "input_audio", input_audio: { data: mp3, format: "mp3" } },
			],
		},
	]);
	return text === "NONE" ? "" : text;
}
