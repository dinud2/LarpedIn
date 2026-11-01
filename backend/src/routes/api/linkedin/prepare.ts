import { createFileRoute } from "@tanstack/react-router";
import {
	DraftError,
	draftErrorResponse,
	prepareLinkedInMedia,
} from "#/lib/linkedin";

export const Route = createFileRoute("/api/linkedin/prepare")({
	server: {
		handlers: {
			POST: async ({ request }) => {
				try {
					const input = await request.json();
					if (!input || typeof input.id !== "string")
						throw new DraftError("Provide the draft id");
					return Response.json(await prepareLinkedInMedia(input.id));
				} catch (error) {
					return draftErrorResponse(error);
				}
			},
		},
	},
});
