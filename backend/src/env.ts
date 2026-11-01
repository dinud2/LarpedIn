import { z } from "zod";

// Parsed on first import so a missing key fails loudly (including /api/health)
// instead of halfway through processing a clip.
export const env = z
	.object({
		OPENROUTER_API_KEY: z.string().min(1),
		OPENROUTER_MODEL: z.string().default("anthropic/claude-sonnet-5.5"),
		// Must accept audio input, which Claude doesn't.
		OPENROUTER_TRANSCRIBE_MODEL: z.string().default("google/gemini-3.8-flash"),
	})
	.parse(process.env);
