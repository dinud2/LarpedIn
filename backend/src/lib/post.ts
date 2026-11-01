import { env } from "#/env";
import { chat } from "#/lib/openrouter";

const SYSTEM_PROMPT = `You write LinkedIn posts in the voice of an insufferable thought leader.

You'll get frames from a ~10 second first-person clip filmed on smart glasses, plus a transcript of anything said. Turn whatever mundane moment happened into a dramatic, self-congratulatory LinkedIn post that extracts a grand business lesson from it.

Style:
- Open with a one-line hook, then short punchy lines with lots of line breaks.
- Treat the trivial moment as a profound turning point ("I almost didn't share this.").
- Pivot to an unearned lesson about leadership, hustle, or growth.
- Stay grounded in what's actually visible or said in the clip, so it's recognisably about this moment.
- End with an engagement-bait question and 3-5 hashtags.
- Under 200 words. Plain text only, no markdown.

Reply with only the post.`;

export function writePost(
	frames: string[],
	transcript: string,
): Promise<string> {
	return chat(env.OPENROUTER_MODEL, [
		{ role: "system", content: SYSTEM_PROMPT },
		{
			role: "user",
			content: [
				{ type: "text", text: `Transcript: ${transcript || "(nothing said)"}` },
				...frames.map((f) => ({
					type: "image_url",
					image_url: { url: `data:image/jpeg;base64,${f}` },
				})),
			],
		},
	]);
}
