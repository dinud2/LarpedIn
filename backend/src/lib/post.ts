import { z } from "zod";
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

Also pick the single frame that would make the best image for the post: sharp, well framed, showing the moment. Avoid blurry, dark, or mid-motion frames.

Reply with only JSON: {"post": "<the post>", "frame": <frame number>}`;

const Reply = z.object({ post: z.string(), frame: z.number().int() });

/** Writes the post and picks which frame (0-based index) to use as its image. */
export async function writePost(
	frames: string[],
	transcript: string,
): Promise<{ post: string; frameIndex: number }> {
	const reply = await chat(env.OPENROUTER_MODEL, [
		{ role: "system", content: SYSTEM_PROMPT },
		{
			role: "user",
			content: [
				{ type: "text", text: `Transcript: ${transcript || "(nothing said)"}` },
				...frames.flatMap((f, i) => [
					{ type: "text", text: `Frame ${i + 1}:` },
					{
						type: "image_url",
						image_url: { url: `data:image/jpeg;base64,${f}` },
					},
				]),
			],
		},
	]);
	// Models sometimes wrap JSON in a code fence; take the outermost object.
	const { post, frame } = Reply.parse(
		JSON.parse(reply.slice(reply.indexOf("{"), reply.lastIndexOf("}") + 1)),
	);
	const frameIndex = Math.min(Math.max(frame - 1, 0), frames.length - 1);
	return { post: post.trim(), frameIndex };
}
