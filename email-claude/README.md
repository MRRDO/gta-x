# Email auto-responder (free, ~1 minute reply time)

Runs inside the Gmail account `quentincpullum@gmail.com`. Email it from
`013244@cm201u.org`; it replies in the same thread. New thread = new chat.

## Setup (5 min)
1. Get a free Gemini key: https://aistudio.google.com/apikey (sign in with the gmail account)
2. Go to https://script.google.com (signed in as quentincpullum@gmail.com) -> New project
3. Delete the default code, paste in `Code.gs`
4. Left sidebar: Project Settings (gear) -> Script Properties -> Add:
   - `API_KEY` = your key
   - (optional) `PROVIDER` = `claude` if you use an Anthropic key instead
5. Select function `setup` in the toolbar -> Run. Approve the permissions
   (Advanced -> Go to project -> Allow).
6. Done. Email the gmail from your school address and wait ~1 min.

## Notes
- Only `ALLOWED` senders get answered. Edit the list at the top of `Code.gs`.
- Mail from before you ran `setup()` is ignored.
- Logs: Apps Script -> Executions.
- Stop it: Triggers (clock icon) -> delete the trigger.
