import { createFileRoute } from "@tanstack/react-router";
import {
	createLinkedInDraft,
	draftErrorResponse,
	getLinkedInDraft,
} from "#/lib/linkedin";

export const Route = createFileRoute("/api/linkedin/draft")({
	server: {
		handlers: {
			POST: async ({ request }) => {
				try {
					return Response.json(
						await createLinkedInDraft(await request.json()),
						{ status: 201 },
					);
				} catch (error) {
					return draftErrorResponse(error);
				}
			},
			GET: async ({ request }) => {
				try {
					return Response.json(
						await getLinkedInDraft(
							new URL(request.url).searchParams.get("id") ?? "",
						),
					);
				} catch (error) {
					return draftErrorResponse(error);
				}
			},
		},
	},
});
