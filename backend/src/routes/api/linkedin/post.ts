import { createFileRoute } from "@tanstack/react-router";
import {
	createLinkedInDraft,
	draftErrorResponse,
	publishLinkedInDraft,
} from "#/lib/linkedin";

export const Route = createFileRoute("/api/linkedin/post")({
	server: {
		handlers: {
			POST: async ({ request }) => {
				let id: string | undefined;
				try {
					const input = await request.json();
					const draftId: string =
						typeof input?.id === "string"
							? input.id
							: (await createLinkedInDraft(input)).id;
					id = draftId;
					return Response.json(await publishLinkedInDraft(draftId));
				} catch (error) {
					const response = draftErrorResponse(error);
					return Response.json(
						{ ...(await response.json()), draft_id: id },
						{ status: response.status },
					);
				}
			},
		},
	},
});
