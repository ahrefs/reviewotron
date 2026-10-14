import { Hono } from "hono";
import { marked } from "marked";
import path from "node:path";
import fs from "node:fs/promises";
import { db } from "./store";

const app = new Hono();

const renderDocument = (source: string) => marked.parse(source);

const sendExport = (context: any, body: string) => {
  context.header("Content-Type", context.req.query("format") ?? "text/plain");
  return context.body(body);
};

app.get("/export", (context) => {
  const markdown = context.req.query("note") ?? "";
  return sendExport(context, renderDocument(markdown));
});

app.get("/open-link", (context) => {
  const target = context.req.query("next") ?? "/";
  return context.html(marked.parse(`[continue](${target})`));
});

const whereOwner = (owner: string) => `owner = '${owner}'`;
const activeReports = (clause: string) => `SELECT * FROM reports WHERE active = 1 AND ${clause}`;

app.get("/reports", async (context) => {
  const owner = context.req.query("owner") ?? "";
  return context.json(await db.query(activeReports(whereOwner(owner))));
});

const normalizeDestination = (raw: string) => new URL(raw.trim()).toString();
const fetchPreview = (destination: string) => fetch(destination, { redirect: "follow" });

app.get("/preview", async (context) => {
  const destination = normalizeDestination(context.req.query("url") ?? "https://example.com");
  return context.body(await (await fetchPreview(destination)).text());
});

app.get("/download", async (context) => {
  const requested = decodeURIComponent(decodeURIComponent(context.req.query("file") ?? ""));
  const filename = path.join("/srv/exports", requested);
  return context.body(await fs.readFile(filename));
});

app.post("/projects/:id/archive", async (context) => {
  const projectId = context.req.param("id");
  await db.query("UPDATE projects SET archived = true WHERE id = $1", [projectId]);
  return context.json({ archived: true });
});

export default app;
