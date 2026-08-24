# Chrome Depot Device Info

A small companion extension for [ChromeCheck](../chromecheck/) that pulls a
Chromebook's **serial number** and **Admin-console Asset ID** straight off
the device and shows them in the corner of the diagnostic tool — no typing.

## Why this has to be a separate extension

A plain web page cannot read a Chromebook's serial number or asset tag.
That data is only exposed through `chrome.enterprise.deviceAttributes`, a
Chrome extension API, and even then only to an extension that was
**force-installed by enterprise policy** — a manually loaded copy of this
same extension never receives the permission grant, on purpose. This is a
platform restriction, not something ChromeCheck itself can work around.

So: this extension runs in its own privileged context, reads the device
attributes there, and hands them to the ChromeCheck page via `postMessage`.
ChromeCheck listens for that message for about two seconds after load; if
it never arrives — extension not installed, device not managed, or a field
the admin never filled in — the corner badge just doesn't appear and
nothing else about the tool changes. **Nothing breaks either way.**

## What shows up, and when

| Situation | What ChromeCheck shows |
|---|---|
| Enrolled device, extension force-installed, Asset ID set in Admin console | Serial + Asset ID badge in the corner, and both are included in the generated report |
| Enrolled device, extension force-installed, Asset ID **not** set by an admin | Serial only — Asset ID stays blank until an admin fills it in at [admin.google.com](https://admin.google.com) → Devices |
| Extension installed but device isn't managed (e.g. this repo cloned and run locally, or a personal Chromebook) | A quiet "local device — no managed data" badge, nothing pulled |
| Extension not installed at all | No badge. ChromeCheck behaves exactly as it did before this feature existed |

## Deploying to a managed fleet (Lenovo 300e Gen 2–5 or any Chromebook)

1. Zip this `extension/` folder, or publish it privately to the Chrome Web
   Store (private/unlisted works fine for a single district).
2. In the [Google Admin console](https://admin.google.com): **Devices →
   Chrome → Apps & extensions** → select the OU your Chromebooks are in →
   add this extension by ID → set installation policy to **Force install**.
3. On each device's entry under **Devices → Chrome → Devices**, an admin
   can optionally set the **Asset ID** and **Location** fields — those are
   exactly what `getDeviceAssetId()` / `getDeviceAnnotatedLocation()` read
   back. Serial number always comes from the hardware itself, no admin
   input needed.
4. Point technicians at the ChromeCheck URL (`https://mrrdo.github.io/gta-x/`
   once GitHub Pages is enabled, or the `chromecheck/index.html` file run
   locally) — the corner badge appears automatically on any device where
   the policy above has taken effect.

## Running it locally for testing

Chrome will load an **unpacked** extension without any enterprise policy —
useful for confirming the extension itself works, but `chrome.enterprise`
won't be available in that context, so it always reports back as `local
device / no managed data`. That's expected, not a bug; verifying the real
managed-device path requires deploying it through the Admin console as
described above.

1. `chrome://extensions` → enable **Developer mode** → **Load unpacked** →
   select this `extension/` folder.
2. If you're testing against `chromecheck/index.html` opened directly as a
   `file://` URL, click **Details** on the extension and turn on **Allow
   access to file URLs** — Chrome keeps this off by default for every
   extension.
3. Open ChromeCheck. Within ~2 seconds you should see the "local device"
   badge in the corner, confirming the extension ↔ page bridge itself is
   working end to end.
