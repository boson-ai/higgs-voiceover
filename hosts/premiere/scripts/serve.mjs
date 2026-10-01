// Serve build-preview/ on localhost for the browser preview.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const dir = fileURLToPath(new URL("../build-preview/", import.meta.url));
const port = Number(process.env.PORT ?? 5178);
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" };

createServer(async (req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url ?? "/", "http://x").pathname)).replace(/^(\.\.[/\\])+/, "");
  try {
    const body = await readFile(join(dir, path === "/" ? "index.html" : path));
    res.writeHead(200, { "Content-Type": types[extname(path || ".html")] ?? "text/html" });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end("not found");
  }
}).listen(port, "127.0.0.1", () => console.log(`preview: http://localhost:${port}/?state=done`));
