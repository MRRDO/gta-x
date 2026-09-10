# Bench Test — handoff

A CompTIA A+ study tracker built in one session. This doc explains what exists,
what state it's in, what's half-done, and exactly how to finish it.

- **Session:** https://claude.ai/code/session_01Q7Lk41wEhAvP9CQRNVheBs
- **Repo / branch:** `MRRDO/gta-x` → `claude/aplus-study-tracker-k8m7yp`
- **Commit:** `92ad798`
- **Draft PR:** https://github.com/MRRDO/gta-x/pull/17 (open, clean, mergeable, no CI configured on this path)
- **Published artifact (v1):** https://claude.ai/code/artifact/b7bab869-1fca-4d10-95c4-666eef2bf7e7

---

## ⚠️ Read this first — current state

**The app is finished and working. The redesign is not.**

| Thing | State |
| --- | --- |
| The A+ study app (all features) | ✅ **Done, tested, shipped** |
| Published as a Claude Artifact | ✅ Live — but **useless on the Chromebook, claude.ai is blocked there** |
| Committed + PR opened | ✅ Done |
| 1. ngrok + code sync | ❌ **Not started** — full spec + working server code in `next-steps/` |
| 2. Stop repeating questions | ❌ **Not started** — algorithm written out in `next-steps/` |
| 3. Apple redesign | 🟡 **Half done** — new CSS written, engine not updated to match |

### The half-done bit, precisely

`source-parts/p1-APPLE-REDESIGN-unfinished.html` is a complete new stylesheet in
Apple's design language. `source-parts/p5.js` is still the **old** engine and
generates the **old** class names. **They do not match.** If you concatenate the
new `p1` with the current `p5`, you get a mostly unstyled page.

Two ways forward:
- **Ship working, then redesign:** use `p1-ORIGINAL-working.html` (that's what's
  in `app/`) and do the redesign as its own pass.
- **Finish the redesign:** rewrite `p5.js` to emit the new class names. The
  mapping is in `next-steps/NEXT-STEPS.md`.

Everything in `app/` is the **last known-good build** and runs today.

---

## What the app is

A single-file study app for the current **CompTIA A+ V15** exams — 220-1201
(Core 1) and 220-1202 (Core 2), the objectives that replaced 1101/1102 in
September 2025. Verified against published objectives, not written from memory.

### Five tabs

**Status** — a readiness dial scored as *accuracy × coverage*, weighted by the
real exam domain percentages, so grinding one easy domain can't fake a good
score. A rank label ("Cold Boot" → "Overqualified"), lifetime right/wrong ratio,
day streak, daily goal, exam countdown, a per-domain readout, and weak-spot
callouts that jump straight into a drill on that domain.

**Drill** — Smart mix (weights unseen questions, previous misses, and weak
domains), redo-my-misses, per-domain sets, and 8 drag-and-drop
performance-based sims.

**Cards** — 60 flashcards on a Leitner schedule (0 / 1 / 3 / 7 / 21 days), plus a
60-second ports-and-acronyms speed round with a personal best.

**Exam** — deliberately separate from daily practice. 30 / 45 / 90 questions.
**Pausable mid-attempt with the clock frozen**, so one exam splits across
sittings — 10 minutes now, 20 tonight, resumes on the exact question with the
exact time left. Question navigator, flagging, a review screen, an estimated
100–900 scaled score against the real 675 / 700 cut lines, and a per-domain
post-mortem that offers to drill whichever domain cost the most.

**Progress** — a 12-week study heatmap, and **semesters** you open and close on
demand. Each keeps its own accuracy, W/L ratio, per-domain breakdown, and
targeted recommendations ("Networking is at 41% — this is bleeding points").

### Content

**210 questions** across all nine domains, distributed by exam weighting and
skewed toward hardware. Every one has an explanation, a concrete worked example,
and a topic-scoped video link. Plus 60 flashcards, 50 speed-round terms, 8 PBQs.

| Core | Domain | Questions | Exam weight |
| --- | --- | ---: | ---: |
| 1 | 1.0 Mobile Devices | 16 | 13% |
| 1 | 2.0 Networking | 26 | 23% |
| 1 | 3.0 Hardware | 32 | 25% |
| 1 | 4.0 Virtualization & Cloud | 12 | 11% |
| 1 | 5.0 Hardware & Network Troubleshooting | 30 | 28% |
| 2 | 1.0 Operating Systems | 28 | 28% |
| 2 | 2.0 Security | 26 | 28% |
| 2 | 3.0 Software Troubleshooting | 20 | 23% |
| 2 | 4.0 Operational Procedures | 20 | 21% |

The 8 PBQs: troubleshooting methodology order, T568B pin order, laser printing
steps, port matching, RAID selection, Windows tool matching, malware removal
order, tool selection.

---

## What's in this package

```
bench-test-handoff/
├── HANDOFF.md                              ← you are here
├── TRANSCRIPT.md                           ← full chat transcript, every turn
├── app/
│   ├── index.html                          ← WORKING BUILD. Open this in a browser.
│   ├── artifact-source.html                ← same, minus the doctype wrapper (Artifact form)
│   └── README.md                           ← the repo README for the app
├── source-parts/                           ← the build is these five files concatenated
│   ├── p1-ORIGINAL-working.html            ← styles + page shell (matches p5.js)
│   ├── p1-APPLE-REDESIGN-unfinished.html   ← new Apple CSS (does NOT match p5.js yet)
│   ├── p2.js                               ← Core 1 questions (116)
│   ├── p3.js                               ← Core 2 questions (94)
│   ├── p4.js                               ← flashcards, speed round, PBQs
│   └── p5.js                               ← the whole app engine
├── next-steps/
│   ├── NEXT-STEPS.md                       ← how to finish all three asks
│   ├── sync-server.js                      ← ready-to-run ngrok sync server (zero deps)
│   └── start.sh                            ← one command to run it + open the tunnel
├── screenshots/                            ← 7 screens, rendered at phone width
└── tools/
    ├── shot.mjs                            ← headless screenshot walkthrough
    └── flow.mjs                            ← end-to-end exam + semester test (written, never run)
```

### How the build works

There is no build system. The five `source-parts` files are literally
concatenated in order:

```bash
cat p1-ORIGINAL-working.html p2.js p3.js p4.js p5.js > artifact-source.html
```

Then for a standalone file, wrap that in a doctype/head/body — see
`next-steps/NEXT-STEPS.md` for the exact wrapper. `app/index.html` is already
wrapped and openable from disk.

To sanity-check after editing:

```bash
node --check <(python3 -c "import re,sys; print(re.findall(r'<script>(.*?)</script>', open('artifact-source.html').read(), re.S)[1])")
```

---

## How it stores data

One state object. Shape:

```js
{
  v:1, updatedAt: <ms>,
  profile: { examDate, dailyGoal, focus:"both"|"c1"|"c2", theme:"auto"|"dark"|"light" },
  mastery: { "<questionId>": { c, w, seen, lastWrong } },   // c=correct, w=wrong
  cards:   { "<cardId>":     { box:0-4, due:<dayNumber>, reps } },
  days:    { "2026-09-10":   { a:<answered>, c:<correct> } },
  streak:  { n, last },
  semesters: [ { id, name, start, end, dom:{ "<domainKey>":{c,w} }, tot:{c,w} } ],
  cur: "<active semester id>",
  exam: { core, qids[], answers[], flags[], orders{}, i, remain, started, submitted, result } | null,
  examHistory: [ { core, scaled, right, n, pass, date } ],
  bestSpeed: <number>
}
```

Persisted two places:

- **`localStorage["benchtest.state.v1"]`** — written synchronously on every
  change. This is the source of truth on-device and makes the app work offline.
- **Artifact DB doc `state/main`** — debounced 700 ms. *(This is the layer that
  gets swapped for the ngrok server.)*

On boot the two are merged **field-wise**, not last-writer-wins, so studying on
a phone and then a laptop never discards either side:

- per-question mastery keeps whichever record has more attempts
- per-day counts keep the higher value
- semesters union by id
- the longer streak and higher speed-round best win

`mergeState(a, b)` in `p5.js` is the whole implementation — it's about 25 lines
and is **reused as-is** for the ngrok sync. That's the main reason swapping the
backend is a small job.

---

## What was verified, and how

- Both `<script>` blocks pass `node --check`.
- A data validator confirmed: 210 questions, no duplicate ids, exactly 4 distinct
  choices each, all answer indices in range, every question / card / PBQ maps to
  a real domain, and every question carries an explanation, an example, and a
  video topic.
- Rendered headlessly in Chromium at 420 px and walked Status → Drill → a graded
  question → a PBQ placement → a flipped flashcard → Exam → Progress with **no
  page or console errors**. Screenshots in `screenshots/`.
- PR #17 confirmed `mergeable_state: clean`.

### Not verified

- **The exam pause → reload → resume → submit cycle was never run end-to-end.**
  `tools/flow.mjs` was written to test exactly this and was interrupted before
  it executed. It also covers the semester close/create flow and localStorage
  survival across a reload. **Run it first.** It's the highest-risk untested
  path in the app.
  ```bash
  cd tools && node flow.mjs   # needs preview.html next to it; see NEXT-STEPS.md
  ```

---

## Known compromises

1. **Video links are topic-scoped YouTube searches**, not specific videos. I
   tried to swap in real Professor Messer per-video URLs but
   `professormesser.com` is **blocked by this environment's network egress
   policy** — both `curl` and `WebFetch` were refused. Guessing 63 URL slugs
   would have shipped links that rot, so searches stayed. A session on an
   unrestricted network can fetch the two course index pages and map objective
   numbers to real URLs; the code hook is `videoURL(q)` in `p5.js`.
2. **The scaled score is an estimate.** CompTIA doesn't publish its scaling
   formula, so it's a linear map of percent-correct onto 100–900. Labeled as
   estimated in the UI.
3. **Confidence tap (knew it / guessed) was not built** — it wasn't selected
   from the options offered. "Redo my misses" covers the related need.
4. **Core 2 has 94 questions**, so a full 90-question Core 2 exam uses nearly
   the whole bank. Fine once, repetitive across attempts. More Core 2 questions
   would help.
