import { randomUUID } from "node:crypto";
import {
	mkdir,
	readFile,
	realpath,
	rename,
	stat,
	writeFile,
} from "node:fs/promises";
import { isAbsolute, join, relative, resolve } from "node:path";

const MAX_IMAGE_BYTES = 10 * 1024 * 1024;
const NOTE =
	"Saved in LarpedIn only. LinkedIn's API cannot create unpublished post drafts.";

export class DraftError extends Error {
	status: number;
	constructor(message: string, status = 400) {
		super(message);
		this.status = status;
	}
}

export interface LinkedInDraft {
	id: string;
	status: "draft" | "publishing" | "published" | "publish_unknown";
	published: boolean;
	storage: "local";
	note: string;
	created_at: string;
	post: string;
	image_path: string;
	image_type: string;
	post_urn?: string;
	post_url?: string;
	linkedin?: {
		author: string;
		image_urn: string;
		media_status: "uploaded_not_verified";
		// Publishing adds lifecycle and distribution explicitly.
		post_fields: {
			author: string;
			commentary: string;
			visibility: "PUBLIC";
			content: { media: { id: string } };
		};
	};
}

export interface DraftOptions {
	directory?: string;
	mediaRoot?: string;
}

function directory(options: DraftOptions) {
	return resolve(
		options.directory ??
			process.env.LINKEDIN_DRAFT_DIR ??
			"data/linkedin-drafts",
	);
}

function draftPath(id: string, options: DraftOptions) {
	if (!/^[0-9a-f-]{36}$/.test(id)) throw new DraftError("Invalid draft ID");
	return join(directory(options), `${id}.json`);
}

function imageType(bytes: Buffer): string {
	if (bytes.subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff])))
		return "image/jpeg";
	if (
		bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
	)
		return "image/png";
	if (["GIF87a", "GIF89a"].includes(bytes.subarray(0, 6).toString()))
		return "image/gif";
	throw new DraftError("Photo must be a JPEG, PNG, or GIF");
}

async function photo(input: Record<string, unknown>, options: DraftOptions) {
	let bytes: Buffer;
	if (typeof input.image === "string" && input.image.startsWith("data:")) {
		const match =
			/^data:image\/(?:jpeg|png|gif);base64,([A-Za-z0-9+/]+={0,2})$/.exec(
				input.image,
			);
		if (!match || match[1].length % 4 !== 0)
			throw new DraftError("Invalid image data URL");
		if (match[1].length > Math.ceil(MAX_IMAGE_BYTES / 3) * 4)
			throw new DraftError("Photo exceeds 10 MB", 413);
		bytes = Buffer.from(match[1], "base64");
	} else {
		const source = input.image_path ?? input.image;
		if (typeof source !== "string" || !source.trim())
			throw new DraftError("Provide image or image_path");
		const root = await realpath(
			resolve(options.mediaRoot ?? process.env.LINKEDIN_MEDIA_ROOT ?? "media"),
		);
		const path = await realpath(resolve(root, source));
		const rel = relative(root, path);
		if (
			rel === ".." ||
			rel.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`) ||
			isAbsolute(rel)
		) {
			throw new DraftError("Photo path must be inside LINKEDIN_MEDIA_ROOT");
		}
		if ((await stat(path)).size > MAX_IMAGE_BYTES)
			throw new DraftError("Photo exceeds 10 MB", 413);
		bytes = await readFile(path);
	}
	if (!bytes.length || bytes.length > MAX_IMAGE_BYTES)
		throw new DraftError("Photo must be 1 byte to 10 MB", 413);
	return { bytes, type: imageType(bytes) };
}

async function save(draft: LinkedInDraft, options: DraftOptions) {
	const path = draftPath(draft.id, options);
	const temporary = `${path}.${randomUUID()}.tmp`;
	await writeFile(temporary, JSON.stringify(draft, null, 2), { mode: 0o600 });
	await rename(temporary, path);
}

/** Accepts the existing /api/clip response without changing Claude or the decoder. */
export async function createLinkedInDraft(
	input: unknown,
	options: DraftOptions = {},
): Promise<LinkedInDraft> {
	if (!input || typeof input !== "object" || Array.isArray(input))
		throw new DraftError("Expected a JSON object");
	const value = input as Record<string, unknown>;
	const text = value.post ?? value.text ?? value.caption;
	if (typeof text !== "string" || !text.trim() || text.length > 3000) {
		throw new DraftError("Post text must contain 1–3,000 characters");
	}
	const image = await photo(value, options);
	const id = randomUUID();
	await mkdir(directory(options), { recursive: true });
	const extension =
		image.type === "image/jpeg" ? "jpg" : image.type.split("/")[1];
	const imagePath = join(directory(options), `${id}.${extension}`);
	await writeFile(imagePath, image.bytes, { mode: 0o600, flag: "wx" });
	const draft: LinkedInDraft = {
		id,
		status: "draft",
		published: false,
		storage: "local",
		note: NOTE,
		created_at: new Date().toISOString(),
		post: text,
		image_path: imagePath,
		image_type: image.type,
	};
	await save(draft, options);
	return draft;
}

export async function getLinkedInDraft(
	id: string,
	options: DraftOptions = {},
): Promise<LinkedInDraft> {
	try {
		return JSON.parse(await readFile(draftPath(id, options), "utf8"));
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT")
			throw new DraftError("Draft not found", 404);
		throw error;
	}
}

export function escapeCommentary(text: string) {
	return text.replace(/[\\|{}@[\]()<>#*_~]/g, "\\$&");
}

interface PrepareOptions extends DraftOptions {
	token?: string;
	author?: string;
	version?: string;
	fetcher?: typeof fetch;
	/** Publish with the draft's photo (default) or as a text-only post. */
	withImage?: boolean;
}

function credentials(options: PrepareOptions) {
	const token = options.token ?? process.env.LINKEDIN_ACCESS_TOKEN;
	const author = options.author ?? process.env.LINKEDIN_AUTHOR_URN;
	const version =
		options.version ?? process.env.LINKEDIN_API_VERSION ?? "202610";
	if (!token || !author)
		throw new DraftError(
			"Set LINKEDIN_ACCESS_TOKEN and LINKEDIN_AUTHOR_URN on the server",
			503,
		);
	if (
		!/^urn:li:(person|organization):[A-Za-z0-9_-]+$/.test(author) ||
		!/^\d{6}$/.test(version)
	) {
		throw new DraftError("Invalid LinkedIn author URN or API version", 503);
	}
	return { token, author, version };
}

/** Uploads the draft's photo ONLY. There is intentionally no Posts API create call. */
export async function prepareLinkedInMedia(
	id: string,
	options: PrepareOptions = {},
): Promise<LinkedInDraft> {
	const draft = await getLinkedInDraft(id, options);
	const { token, author, version } = credentials(options);
	if (draft.linkedin?.author === author) return draft;
	const fetcher = options.fetcher ?? fetch;
	const headers = {
		Authorization: `Bearer ${token}`,
		"LinkedIn-Version": version,
		"X-Restli-Protocol-Version": "2.0.0",
	};
	const initialized = await fetcher(
		"https://api.linkedin.com/rest/images?action=initializeUpload",
		{
			method: "POST",
			headers: { ...headers, "Content-Type": "application/json" },
			body: JSON.stringify({ initializeUploadRequest: { owner: author } }),
			signal: AbortSignal.timeout(30_000),
			redirect: "error",
		},
	);
	if (!initialized.ok)
		throw new DraftError(
			`LinkedIn image initialization failed (HTTP ${initialized.status}). Check token and permissions.`,
			502,
		);
	const { value } = await initialized.json();
	if (
		!value ||
		typeof value.uploadUrl !== "string" ||
		typeof value.image !== "string" ||
		!value.image.startsWith("urn:li:image:")
	) {
		throw new DraftError(
			"LinkedIn returned an invalid image upload response",
			502,
		);
	}
	const url = new URL(value.uploadUrl);
	if (
		url.protocol !== "https:" ||
		!(
			url.hostname === "linkedin.com" || url.hostname.endsWith(".linkedin.com")
		) ||
		url.username ||
		url.password ||
		(url.port && url.port !== "443")
	) {
		throw new DraftError("LinkedIn returned an unexpected upload host", 502);
	}
	// Use our own copied image, never an arbitrary path read from stored JSON.
	const extension =
		draft.image_type === "image/jpeg" ? "jpg" : draft.image_type.split("/")[1];
	const bytes = await readFile(
		join(directory(options), `${draft.id}.${extension}`),
	);
	const uploaded = await fetcher(url, {
		method: "PUT",
		headers: {
			Authorization: headers.Authorization,
			"Content-Type": draft.image_type,
		},
		body: new Uint8Array(bytes),
		signal: AbortSignal.timeout(60_000),
		redirect: "error",
	});
	if (!uploaded.ok)
		throw new DraftError(
			`LinkedIn photo upload failed (HTTP ${uploaded.status})`,
			502,
		);
	draft.linkedin = {
		author,
		image_urn: value.image,
		media_status: "uploaded_not_verified",
		post_fields: {
			author,
			commentary: escapeCommentary(draft.post),
			visibility: "PUBLIC",
			content: { media: { id: value.image } },
		},
	};
	await save(draft, options);
	return draft;
}

const publishing = new Set<string>();

/** Publish an existing saved draft; never blindly repeat an uncertain create request. */
export async function publishLinkedInDraft(
	id: string,
	options: PrepareOptions = {},
): Promise<LinkedInDraft> {
	if (publishing.has(id))
		throw new DraftError("This post is already being published", 409);
	publishing.add(id);
	try {
		let draft = await getLinkedInDraft(id, options);
		if (draft.status === "published") return draft;
		if (draft.status === "publishing" || draft.status === "publish_unknown") {
			throw new DraftError(
				"A previous publish may have succeeded. Check LinkedIn before retrying to avoid a duplicate.",
				409,
			);
		}
		const { token, author, version } = credentials(options);
		let postFields: object;
		if (options.withImage === false) {
			postFields = {
				author,
				commentary: escapeCommentary(draft.post),
				visibility: "PUBLIC",
			};
		} else {
			draft = await prepareLinkedInMedia(id, options);
			if (!draft.linkedin) throw new DraftError("Prepare the image first", 503);
			postFields = draft.linkedin.post_fields;
		}
		draft.status = "publishing";
		await save(draft, options);
		let response: Response;
		try {
			response = await (options.fetcher ?? fetch)(
				"https://api.linkedin.com/rest/posts",
				{
					method: "POST",
					headers: {
						Authorization: `Bearer ${token}`,
						"Content-Type": "application/json",
						"LinkedIn-Version": version,
						"X-Restli-Protocol-Version": "2.0.0",
					},
					body: JSON.stringify({
						...postFields,
						lifecycleState: "PUBLISHED",
						distribution: {
							feedDistribution: "MAIN_FEED",
							targetEntities: [],
							thirdPartyDistributionChannels: [],
						},
						isReshareDisabledByAuthor: false,
					}),
					signal: AbortSignal.timeout(60_000),
					redirect: "error",
				},
			);
		} catch {
			draft.status = "publish_unknown";
			await save(draft, options);
			throw new DraftError(
				"LinkedIn did not confirm publication. Check your profile before retrying; the post may be live.",
				502,
			);
		}
		if (!response.ok) {
			draft.status = response.status >= 500 ? "publish_unknown" : "draft";
			await save(draft, options);
			throw new DraftError(
				`LinkedIn post creation failed (HTTP ${response.status}). ${draft.status === "publish_unknown" ? "Check your profile before retrying." : "Check media readiness, token, and permissions before retrying with the same draft ID."}`,
				502,
			);
		}
		const urn = response.headers.get("x-restli-id");
		if (!urn || !/^urn:li:(share|ugcPost):[A-Za-z0-9_-]+$/.test(urn)) {
			draft.status = "publish_unknown";
			await save(draft, options);
			throw new DraftError(
				"LinkedIn accepted the post without returning a post ID. Check your profile before retrying.",
				502,
			);
		}
		draft.status = "published";
		draft.published = true;
		draft.post_urn = urn;
		draft.post_url = `https://www.linkedin.com/feed/update/${urn}/`;
		draft.note = "Published to LinkedIn. This post may appear in feeds.";
		await save(draft, options);
		return draft;
	} finally {
		publishing.delete(id);
	}
}

export function draftErrorResponse(error: unknown) {
	if (error instanceof DraftError)
		return Response.json({ error: error.message }, { status: error.status });
	if (error instanceof SyntaxError)
		return Response.json({ error: "Invalid JSON" }, { status: 400 });
	if ((error as NodeJS.ErrnoException)?.code === "ENOENT")
		return Response.json(
			{ error: "Photo or media folder not found" },
			{ status: 400 },
		);
	console.error(
		"LinkedIn draft operation failed",
		error instanceof Error ? error.name : "Unknown error",
	);
	return Response.json(
		{
			error:
				"LinkedIn operation failed. Check the saved draft status before retrying.",
		},
		{ status: 502 },
	);
}
