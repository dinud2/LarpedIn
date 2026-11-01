import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createLinkedInDraft, getLinkedInDraft, prepareLinkedInMedia, publishLinkedInDraft } from "./linkedin.ts";

const image = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=";

async function context(t) {
 const directory = await mkdtemp(join(tmpdir(), "linkedin-test-"));
 t.after(() => rm(directory, { recursive: true, force: true }));
 return { directory, mediaRoot: directory };
}

test("existing Claude JSON becomes a persistent local draft with identical text and photo", async t => {
 const options = await context(t);
 const post = "A lesson (with details).\n#Building";
 const draft = await createLinkedInDraft({ post, image, transcript: "context" }, options);
 assert.equal(draft.post, post);
 assert.equal(draft.status, "draft");
 assert.equal(draft.published, false);
 assert.equal(draft.storage, "local");
 assert.equal(draft.linkedin, undefined);
 assert.deepEqual(await readFile(draft.image_path), Buffer.from(image.split(",")[1], "base64"));
 assert.deepEqual(await getLinkedInDraft(draft.id, options), draft);
});

test("photo path is copied into the draft so the source can be deleted", async t => {
 const options = await context(t);
 const source = join(options.mediaRoot, "frame.png");
 await writeFile(source, Buffer.from(image.split(",")[1], "base64"));
 const draft = await createLinkedInDraft({ post: "Claude text", image_path: source }, options);
 await rm(source);
 assert.ok((await readFile(draft.image_path)).length);
});

test("rejects invalid text, broken images, and paths escaping the media root", async t => {
 const options = await context(t);
 await assert.rejects(createLinkedInDraft({ post: " ", image }, options));
 await assert.rejects(createLinkedInDraft({ post: "x".repeat(3001), image }, options));
 await assert.rejects(createLinkedInDraft({ post: "ok", image: "data:image/jpeg;base64,YWJj" }, options));
 await assert.rejects(getLinkedInDraft("../../secret", options));
 const outside = await mkdtemp(join(tmpdir(), "outside-media-"));
 t.after(() => rm(outside, { recursive: true, force: true }));
 const source = join(outside, "frame.png");
 await writeFile(source, Buffer.from(image.split(",")[1], "base64"));
 await assert.rejects(createLinkedInDraft({ post: "ok", image_path: source }, options), /inside/);
});

test("LinkedIn preparation uploads only an image and never creates a post", async t => {
 const options = await context(t);
 const draft = await createLinkedInDraft({ post: "Learn (by building) #Code", image }, options);
 const calls = [];
 const fetcher = async (url, init) => {
  calls.push({ url: String(url), init });
  if (calls.length === 1) return Response.json({ value: {
   uploadUrl: "https://www.linkedin.com/dms-uploads/test", image: "urn:li:image:123",
  } });
  return new Response(null, { status: 201 });
 };
 const prepared = await prepareLinkedInMedia(draft.id, { ...options, token: "test", author: "urn:li:person:123", fetcher });
 assert.equal(calls.length, 2);
 assert.equal(calls[0].url, "https://api.linkedin.com/rest/images?action=initializeUpload");
 assert.equal(calls[1].init.method, "PUT");
 assert.equal(prepared.status, "draft");
 assert.equal(prepared.published, false);
 assert.equal(prepared.linkedin.image_urn, "urn:li:image:123");
 assert.equal(prepared.linkedin.post_fields.commentary, "Learn \\(by building\\) \\#Code");
 assert.equal(prepared.linkedin.post_fields.lifecycleState, undefined);
 assert.ok(calls.every(call => !call.url.includes("/rest/posts")));
 await prepareLinkedInMedia(draft.id, { ...options, token: "test", author: "urn:li:person:123", fetcher });
 assert.equal(calls.length, 2);
});

test("rejected LinkedIn token keeps the saved draft intact", async t => {
 const options = await context(t);
 const draft = await createLinkedInDraft({ post: "A lesson", image }, options);
 await assert.rejects(prepareLinkedInMedia(draft.id, { ...options, token: "invalid", author: "urn:li:person:123",
  fetcher: async () => new Response(null, { status: 401 }),
 }), /HTTP 401/);
 assert.equal((await getLinkedInDraft(draft.id, options)).linkedin, undefined);
});

test("never forwards credentials to an unexpected upload host", async t => {
 const options = await context(t);
 const draft = await createLinkedInDraft({ post: "A lesson", image }, options);
 let count = 0;
 await assert.rejects(prepareLinkedInMedia(draft.id, { ...options, token: "secret", author: "urn:li:person:123",
  fetcher: async () => {
   count++;
   return Response.json({ value: { uploadUrl: "https://example.com/upload", image: "urn:li:image:123" } });
  },
 }), /unexpected upload host/);
 assert.equal(count, 1);
});

function linkedinMock(onPublish) {
 return async (url, init) => {
  if (String(url).includes("initializeUpload")) return Response.json({ value: {
   uploadUrl: "https://www.linkedin.com/dms-uploads/test", image: "urn:li:image:123",
  } });
  if (init.method === "PUT") return new Response(null, { status: 201 });
  assert.equal(String(url), "https://api.linkedin.com/rest/posts");
  return onPublish(init);
 };
}

test("direct publishing uploads the photo and creates one post with Claude's text", async t => {
 const options = await context(t);
 const draft = await createLinkedInDraft({ post: "A useful lesson", image }, options);
 let count = 0;
 const preparedOptions = { ...options, token: "test", author: "urn:li:person:123", fetcher: linkedinMock(init => {
  count++;
  const body = JSON.parse(init.body);
  assert.equal(body.lifecycleState, "PUBLISHED");
  assert.equal(body.commentary, "A useful lesson");
  assert.equal(body.content.media.id, "urn:li:image:123");
  assert.equal(body.distribution.feedDistribution, "MAIN_FEED");
  assert.equal(init.headers.Authorization, "Bearer test");
  return new Response(null, { status: 201, headers: { "x-restli-id": "urn:li:share:456" } });
 }) };
 const published = await publishLinkedInDraft(draft.id, preparedOptions);
 assert.equal(published.published, true);
 assert.equal(published.status, "published");
 assert.equal(published.post_url, "https://www.linkedin.com/feed/update/urn:li:share:456/");
 assert.equal((await getLinkedInDraft(draft.id, options)).status, "published");
 await publishLinkedInDraft(draft.id, preparedOptions);
 assert.equal(count, 1);
});

test("uncertain publish is saved and cannot be blindly retried", async t => {
 const options = await context(t);
 const draft = await createLinkedInDraft({ post: "A useful lesson", image }, options);
 let count = 0;
 const preparedOptions = { ...options, token: "test", author: "urn:li:person:123", fetcher: linkedinMock(() => {
  count++;
  throw new Error("Connection lost after sending post");
 }) };
 await assert.rejects(publishLinkedInDraft(draft.id, preparedOptions), /may be live/);
 assert.equal((await getLinkedInDraft(draft.id, options)).status, "publish_unknown");
 await assert.rejects(publishLinkedInDraft(draft.id, preparedOptions), /previous publish/);
 assert.equal(count, 1);
});

test("explicit LinkedIn rejection leaves the saved draft available", async t => {
 const options = await context(t);
 const draft = await createLinkedInDraft({ post: "A useful lesson", image }, options);
 await assert.rejects(publishLinkedInDraft(draft.id, { ...options, token: "test", author: "urn:li:person:123",
  fetcher: linkedinMock(() => new Response(null, { status: 403 })),
 }), /HTTP 403/);
 assert.equal((await getLinkedInDraft(draft.id, options)).status, "draft");
});
