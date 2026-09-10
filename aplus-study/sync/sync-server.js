#!/usr/bin/env node
/**
 * Bench Test sync server — zero dependencies, Node 18+.
 *
 * Serves the study app AND stores its progress under a secret code, so one
 * ngrok tunnel gives you a single URL that does both. Same-origin, so there
 * are no CORS problems and no second thing to configure.
 *
 *   node sync-server.js            # port 8787, serves ../app
 *   PORT=9000 APP_DIR=./app node sync-server.js
 *
 * Routes:
 *   GET  /s/:code   -> the stored state JSON, or {} if that code is new
 *   PUT  /s/:code   -> replace the stored state for that code
 *   GET  /*         -> static files from APP_DIR (index.html at /)
 *
 * The code is the only secret. Anyone with the URL and the code can read and
 * write that progress, so pick something unguessable and don't post the link.
 */

const http = require("http");
const fs   = require("fs");
const path = require("path");

const PORT    = Number(process.env.PORT || 8787);
const APP_DIR = path.resolve(process.env.APP_DIR || path.join(__dirname, "..", "app"));
const DATA_DIR= path.resolve(process.env.DATA_DIR || path.join(__dirname, "data"));
const MAX_BODY= 4 * 1024 * 1024;   // 4 MB is far more than the state ever needs

fs.mkdirSync(DATA_DIR, { recursive: true });

const TYPES = {
  ".html":"text/html; charset=utf-8", ".js":"text/javascript; charset=utf-8",
  ".css":"text/css; charset=utf-8",   ".json":"application/json; charset=utf-8",
  ".png":"image/png", ".jpg":"image/jpeg", ".svg":"image/svg+xml",
  ".ico":"image/x-icon", ".webmanifest":"application/manifest+json"
};

// Only these characters, max 64. Rejects "..", "/", and anything else that
// could climb out of DATA_DIR.
function safeCode(raw){
  const c = decodeURIComponent(raw || "");
  return /^[A-Za-z0-9_-]{3,64}$/.test(c) ? c : null;
}
const fileFor = code => path.join(DATA_DIR, code + ".json");

function send(res, status, body, type){
  res.writeHead(status, {
    "content-type": type || "application/json; charset=utf-8",
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET,PUT,OPTIONS",
    "access-control-allow-headers": "content-type",
    "cache-control": "no-store"
  });
  res.end(body);
}

function readBody(req){
  return new Promise((resolve, reject) => {
    let n = 0; const chunks = [];
    req.on("data", d => {
      n += d.length;
      if(n > MAX_BODY){ reject(new Error("too large")); req.destroy(); return; }
      chunks.push(d);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

// Write to a temp file then rename, so a crash mid-write can never leave a
// truncated state file behind.
function writeAtomic(file, text){
  const tmp = file + "." + process.pid + ".tmp";
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, file);
}

function serveStatic(res, urlPath){
  let rel = decodeURIComponent(urlPath.split("?")[0]);
  if(rel === "/" || rel === "") rel = "/index.html";
  const file = path.join(APP_DIR, rel);
  if(!file.startsWith(APP_DIR + path.sep) && file !== path.join(APP_DIR, "index.html")){
    return send(res, 403, "Forbidden", "text/plain; charset=utf-8");
  }
  fs.readFile(file, (err, buf) => {
    if(err) return send(res, 404, "Not found", "text/plain; charset=utf-8");
    send(res, 200, buf, TYPES[path.extname(file).toLowerCase()] || "application/octet-stream");
  });
}

http.createServer(async (req, res) => {
  const url = req.url || "/";

  if(req.method === "OPTIONS") return send(res, 204, "");

  const m = url.match(/^\/s\/([^/?#]+)/);
  if(m){
    const code = safeCode(m[1]);
    if(!code) return send(res, 400, JSON.stringify({
      error: "Bad code. Use 3-64 characters: letters, numbers, hyphen, underscore."
    }));

    if(req.method === "GET"){
      fs.readFile(fileFor(code), "utf8", (err, txt) => {
        if(err) return send(res, 200, "{}");          // new code = empty state
        send(res, 200, txt);
      });
      return;
    }

    if(req.method === "PUT"){
      let txt;
      try { txt = await readBody(req); }
      catch { return send(res, 413, JSON.stringify({ error: "State too large." })); }
      try { JSON.parse(txt); }                        // never store invalid JSON
      catch { return send(res, 400, JSON.stringify({ error: "Body must be JSON." })); }
      try { writeAtomic(fileFor(code), txt); }
      catch (e) { return send(res, 500, JSON.stringify({ error: String(e.message) })); }
      console.log(new Date().toISOString(), "saved", code, (txt.length/1024).toFixed(1) + " KB");
      return send(res, 200, JSON.stringify({ ok: true, bytes: txt.length }));
    }

    return send(res, 405, JSON.stringify({ error: "Use GET or PUT." }));
  }

  if(req.method !== "GET") return send(res, 405, "Method not allowed", "text/plain; charset=utf-8");
  serveStatic(res, url);
}).listen(PORT, () => {
  console.log("Bench Test sync server");
  console.log("  app     " + APP_DIR);
  console.log("  data    " + DATA_DIR);
  console.log("  local   http://localhost:" + PORT);
  console.log("");
  console.log("Now open the tunnel:  ngrok http " + PORT);
  console.log("Then visit the ngrok URL with your code:  https://<id>.ngrok-free.app/#code=your-secret-code");
});
