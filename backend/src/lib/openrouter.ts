import { z } from "zod";
import { env } from "#/env";

const Completion = z.object({
	choices: z
		.array(z.object({ message: z.object({ content: z.string() }) }))
		.min(1),
});

/** One chat completion; returns the reply text. */
export async function chat(
	model: string,
	messages: unknown[],
): Promise<string> {
	const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
		method: "POST",
		headers: {
			Authorization: `Bearer ${env.OPENROUTER_API_KEY}`,
			"Content-Type": "application/json",
		},
		body: JSON.stringify({ model, messages }),
	});
	if (!res.ok) throw new Error(`OpenRouter ${res.status}: ${await res.text()}`);
	return Completion.parse(await res.json()).choices[0].message.content.trim();
}
