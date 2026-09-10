# Finishing the three remaining asks

All three were requested in the final turns and none are done. Each is
self-contained. Suggested order: **2 → 1 → 3** (anti-repeat is a 20-line change
that improves the app immediately, sync unblocks the Chromebook, the redesign is
the biggest job).

---

## 1. ngrok + code sync

> "i can't get to claude on my chromebook. it's blocked. use ngrok instead with a code."

### Why the Artifact doesn't work for this

The published artifact lives on `claude.ai`, which is blocked on the
school-managed Chromebook. It's a fine backup for phone and Mac, but it can't be
the primary.

### The honest limitation of ngrok

**The tunnel only exists while your Mac is awake and running the command.**
Chromebook at school + Mac asleep at home = no sync that session. The app still
works fully offline on whatever device you're on, and syncs the next time both
are up. Also worth knowing: some school networks block `*.ngrok-free.app` too.
Test it on the Chromebook before relying on it.

If that turns out to be a dealbreaker, the alternative that needs no machine of
yours running: host `app/index.html` on **GitHub Pages** (free, always on, and
the repo already exists) and point the sync at any always-on box. The client
code below works unchanged — only the URL differs.

### What's already written for you

`next-steps/sync-server.js` — zero dependencies, Node 18+. It serves the app
*and* the sync API from the same origin, so one ngrok URL does everything and
there are no CORS issues.

```
GET  /s/:code   → stored state JSON, or {} for a new code
PUT  /s/:code   → replace stored state
GET  /*         → the app itself
```

Codes are validated `^[A-Za-z0-9_-]{3,64}$` so they can't escape the data
directory. Writes are atomic (temp file + rename), bodies are capped at 4 MB and
must parse as JSON.

### Running it

```bash
node next-steps/sync-server.js      # http://localhost:8787
ngrok http 8787                     # in a second terminal
```

Then on **any** device: `https://<id>.ngrok-free.app/#code=your-secret-code`

The code goes in the URL fragment, which never leaves the browser — it isn't
sent to the server as part of the request line or logged by ngrok.

To make it survive reboots on the Mac, `start.sh` in this folder wraps both
commands.

### The client change

Replace the Artifact DB block in `p5.js` — the `window.claude?.use?.("db")`
section at the bottom of `start()` — with this. **`mergeState` is reused
unchanged**, which is why this is a small job.

```js
/* ---------- ngrok sync ---------- */
const SYNC_KEY = "benchtest.sync.v1";
let SYNC = { code:null, base:"", status:"local", timer:null, pushing:false };

function loadSync(){
  // code arrives as #code=xyz once, then lives in localStorage
  const m = (location.hash || "").match(/code=([A-Za-z0-9_-]{3,64})/);
  let saved = null;
  try { saved = JSON.parse(localStorage.getItem(SYNC_KEY) || "null"); } catch(e){}
  SYNC.code = (m && m[1]) || (saved && saved.code) || null;
  SYNC.base = location.protocol.startsWith("http") ? location.origin : (saved && saved.base) || "";
  if(SYNC.code) try { localStorage.setItem(SYNC_KEY, JSON.stringify({code:SYNC.code, base:SYNC.base})); } catch(e){}
  if(m) history.replaceState(null, "", location.pathname + location.search); // scrub the code from the bar
}
const syncURL = () => SYNC.base + "/s/" + SYNC.code;

function setSyncStatus(s, label){
  SYNC.status = s;
  const pill = document.getElementById("syncPill"), txt = document.getElementById("syncTxt");
  if(!pill) return;
  pill.className = "syncpill" + (s === "on" ? " on" : s === "err" ? " err" : "");
  if(txt) txt.textContent = label;
}

async function syncPull(){
  if(!SYNC.code || !SYNC.base) return;
  try {
    const r = await fetch(syncURL(), { cache:"no-store" });
    if(!r.ok) throw new Error(r.status);
    const remote = await r.json();
    if(remote && remote.updatedAt){
      const merged = mergeState(S, remote);
      const changed = merged.updatedAt !== S.updatedAt ||
                      JSON.stringify(merged).length !== JSON.stringify(S).length;
      S = merged; saveLocal();
      if(changed && !sub) render();
    }
    setSyncStatus("on", "Synced");
  } catch(e){ setSyncStatus("err", "Offline"); }
}

async function syncPush(){
  if(!SYNC.code || !SYNC.base || SYNC.pushing) return;
  SYNC.pushing = true;
  try {
    const r = await fetch(syncURL(), {
      method:"PUT", headers:{ "content-type":"application/json" }, body: JSON.stringify(S)
    });
    setSyncStatus(r.ok ? "on" : "err", r.ok ? "Synced" : "Offline");
  } catch(e){ setSyncStatus("err", "Offline"); }
  finally { SYNC.pushing = false; }
}

function startSync(){
  loadSync();
  if(!SYNC.code){ setSyncStatus("local", "This device only"); return; }
  setSyncStatus("local", "Connecting");
  syncPull();
  clearInterval(SYNC.timer);
  SYNC.timer = setInterval(() => { if(!document.hidden) syncPull(); }, 25000);
  document.addEventListener("visibilitychange", () => { if(!document.hidden) syncPull(); });
  window.addEventListener("beforeunload", () => {
    if(SYNC.code && navigator.sendBeacon)
      navigator.sendBeacon(syncURL(), new Blob([JSON.stringify(S)], {type:"application/json"}));
  });
}
```

Then in `save()`, swap the Artifact DB write for the push:

```js
function save(){
  S.updatedAt = Date.now(); saveLocal();
  clearTimeout(saveTimer);
  saveTimer = setTimeout(syncPush, 900);
}
```

And call `startSync()` at the end of `start()` instead of the `claude.use("db")`
block.

> `sendBeacon` sends a POST, not a PUT. Either add a POST branch to the server's
> `/s/:code` handler (three lines — treat it the same as PUT) or drop the
> beacon; the 900 ms debounced push covers almost every case already.

Finally, add a **Sync** section to the settings sheet so a code can be entered
without editing a URL — one text field for the code, one for the base URL, both
writing to `localStorage[SYNC_KEY]`, then `startSync()` again.

### Keep the artifact too

Nothing stops both from working. Publish the same file as an artifact for
phone/Mac and use the ngrok URL on the Chromebook. They just won't share state
unless you point the artifact build at the sync server as well.

---

## 2. Stop repeating the same questions

> "make sure i don't get too many of the same questions too often"

### The current problem

`smartPick()` in `p5.js` scores every question and takes the top `n × 2`, then
shuffles. Because a wrong answer adds `+1.9` and `lastWrong` never expires until
you get it right, a question you just missed is **almost guaranteed to reappear
in the very next set**. Recency isn't considered at all.

### The fix

Bucket by recency *before* scoring, and exhaust fresher buckets first. Add to
state: `S.recent` (a rolling list of the last ~45 answered ids) and `m.last`
(timestamp, already half-there as `m.seen`).

```js
const RECENT_KEEP = 45;
const COOL_MS = 8 * 3600 * 1000;   // 8 hours

function pickQuestions(n, src){
  const list = (src && src.length ? src : pool()).slice();
  const now = Date.now(), recent = new Set(S.recent || []);

  // 0 = fair game, 1 = seen but cooled off, 2 = just saw it
  const tier = q => {
    if(recent.has(q.i)) return 2;
    const m = S.mastery[q.i];
    if(m && now - (m.seen || 0) < COOL_MS) return 1;
    return 0;
  };
  const score = q => {
    const m = S.mastery[q.i];
    let s = Math.random() * 0.5;
    if(!m) s += 1.4;
    else {
      if(m.lastWrong) s += 1.9;
      s += (1 - m.c / (m.c + m.w)) * 1.1;
      s -= Math.min(0.7, m.c * 0.18);
    }
    s += (1 - domainStat(q.d).ready) * 0.9;
    return s;
  };

  const buckets = [[], [], []];
  list.forEach(q => buckets[tier(q)].push(q));

  const out = [];
  for(const b of buckets){                    // drain tier 0, then 1, then 2
    if(out.length >= n) break;
    const want = n - out.length;
    const ranked = b.map(q => ({ q, s: score(q) })).sort((x, y) => y.s - x.s);
    const widen = ranked.slice(0, Math.max(want * 2, want + 6));
    shuffle(widen).slice(0, want).forEach(x => out.push(x.q));
  }
  return shuffle(out);
}
```

Then in `recordAnswer()`:

```js
S.recent = [q.i, ...(S.recent || []).filter(x => x !== q.i)].slice(0, RECENT_KEEP);
```

Replace both `smartPick(...)` call sites with `pickQuestions(...)`.

**Guarantee this gives you:** a question you just answered can only come back
once every unseen and cooled-off question in the pool has been used. With 210
questions and 10-question sets, that's ~20 sets before anything repeats.

Also worth doing in `examPick()`: within each domain, sort by `m.seen` ascending
before slicing, so consecutive exams don't draw the same questions.

`S.recent` is a plain array of strings — add a line to `mergeState` keeping
whichever device's list is longer, or just let the newer doc win (it's not
important data).

---

## 3. Apple redesign

> "make the site more apple themed. make it look like its designed by apple and a clean dark theme and stuff too."

### What's done

`source-parts/p1-APPLE-REDESIGN-unfinished.html` is a complete stylesheet:

- **Color:** iOS system palette. True black `#000` ground (real OLED black on
  the iPhone), `#1c1c1e` / `#2c2c2e` / `#3a3a3c` elevated surfaces, `#38383a`
  hairline separators, label opacities at 100 / 60 / 30 / 18%. Accent is
  systemBlue `#0a84ff` dark / `#007aff` light, with the real system green, red,
  orange, yellow, purple, teal, indigo. Full light-mode palette, all three theme
  states handled (`data-theme` stamps plus bare `prefers-color-scheme`).
- **Type:** San Francisco via `-apple-system, BlinkMacSystemFont, "SF Pro Text"`
  — on the iPhone and Mac that's the *real* SF Pro, no webfont download. The
  iOS type scale (34 large title / 22 title2 / 17 headline / 17 body / 15 subhead
  / 13 footnote / 12 caption) with Apple's actual negative tracking values.
- **Components:** grouped inset lists with hairline separators between rows,
  translucent blurred tab bar with `backdrop-filter: saturate(180%) blur(20px)`,
  segmented controls with the sliding elevated thumb, bottom sheets with a
  grabber and `cubic-bezier(.32,.72,0,1)` spring easing, circular icon buttons,
  pill badges, tabular-numeral stat rows.

### What's left

**`p5.js` still emits the old class names.** The new CSS and the current engine
don't match — concatenating them gives a mostly unstyled page. Every
`el('<div class="...">')` call in `p5.js` needs updating.

Mapping:

| Old | New |
| --- | --- |
| `.card` | `.group` + `.pad`, or `.group` with `.cell` children |
| `.readout` / `.readout-top` | `.hero` |
| `.readout-strip` / `.strip-cell` | `.statrow` / `.statcell` |
| `.meter` | `.meterrow` (with `.top`, `.nm`, `.pc`, `.note` inside) |
| `.meter-track` / `.meter-fill` | `.bar` / `.bar i` |
| `.wl` / `.wl .w` / `.wl .l` | `.split` / `.split i` |
| `.btn.primary` | `.btn.filled` |
| `.btn` (secondary) | `.btn.tinted` or plain `.btn` |
| `.pill` | `.badge` (+ `.blue` / `.green` / `.red` / `.orange`) |
| `.tile` / `.tiles` | `button.cell` inside a `.group` |
| `.verdict` | `.explain` + `.explain-head` + `.mark` |
| `.qbar` / `.qprog` | `.qhead` / `.track` |
| `.chipdrag` | `.chip` (`.armed` instead of `.picked`) |
| `.slot.wrongslot` | `.slot.miss` |
| `.rec` / `.rec-i` | `.cell` with a colored `.dot` or a badge |
| `.sheet-in` | same, but prepend `<div class="grabber"></div>` |
| `.eyebrow` | `.sec-label` (section headers) or `.foot` (inline) |
| `.score-big` | `.bigscore` |
| `.icobtn` | `.circbtn` |
| `.syncdot` | `.syncpill` (`<i>` inside + a text label) |
| `.exam-clock` | `.clock` |

Two structural changes the new shell needs:

1. The navbar now has `#navTitle` and `#navSub` — `render()` should set them per
   route (large-title style, like an iOS nav bar). Titles: Status / Drill /
   Cards / Exam / Progress.
2. `#syncPill` / `#syncTxt` replaced the old `#syncDot`.

The tab bar SVG icons in `TABS` can stay — they already read as SF Symbols.

**Do this after 1 and 2.** It's a pure presentation change with no behavior risk,
and it's much easier to verify once the app logic is settled.
