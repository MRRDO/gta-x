# Tools

## flow.mjs — end-to-end exam + semester test (NEVER RUN — run this first)

Drives a real Chromium through: start a 30q exam → answer 3 → verify the clock
ticks → pause → verify the clock STOPS → reload the page → verify the exam
survived → resume → verify the clock and answers are intact → answer the rest →
submit → verify the score screen and domain breakdown → verify Status picked up
the numbers → close a semester and start a new one → verify the old one kept its
data and the new one is zeroed.

```bash
# it expects a wrapped preview file next to it:
cd tools
python3 - <<'PY'
body = open('../app/artifact-source.html').read()
open('preview.html','w').write(
  '<!doctype html><head><meta charset="utf-8">'
  '<meta name="viewport" content="width=device-width,initial-scale=1">'
  '<style>:root{color-scheme:dark}body{margin:0}img{max-width:100%}</style>'
  '</head><body>' + body + '</body>')
PY
node flow.mjs        # needs playwright + chromium; edit the executablePath at the top
```

Exits non-zero and prints every failure if anything breaks.

## shot.mjs — screenshot walkthrough

Renders the 7 main screens at 420px into PNGs. Same preview.html setup.

## validate-data.cjs — question bank validator

```bash
node -e '
const {DOMAINS,QUESTIONS,CARDS,SPEED,PBQS}=require("./validate-data.cjs");
console.log(QUESTIONS.length+" questions, "+CARDS.length+" cards, "+PBQS.length+" PBQs");
'
```
Checks for duplicate ids, wrong choice counts, out-of-range answer indices,
unknown domains, and missing explanation/example/topic fields.
