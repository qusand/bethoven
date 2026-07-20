import { readFile } from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const directory = path.dirname(fileURLToPath(import.meta.url));
const html = await readFile(path.join(directory, "index.html"));
const server = http.createServer((request, response) => {
  if (request.url === "/favicon.ico") {
    response.writeHead(204).end();
    return;
  }
  if (request.url !== "/") {
    response.writeHead(404, { "content-type": "text/plain" }).end("not found");
    return;
  }
  response.writeHead(200, {
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store",
    "content-length": html.byteLength,
  });
  response.end(html);
});

server.listen(0, "127.0.0.1", () => {
  const address = server.address();
  process.stdout.write(`http://127.0.0.1:${address.port}\n`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
