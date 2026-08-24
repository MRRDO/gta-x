// Chrome Depot Device Info — background service worker
//
// chrome.enterprise.deviceAttributes only resolves real values when:
//   1. The Chromebook is enrolled in the school's Google Admin console, and
//   2. This extension was force-installed by that same Admin console policy
//      (ExtensionInstallForcelist) — a manually loaded/unpacked copy never
//      gets the permission grant, by design, regardless of device state.
// Every call below is wrapped so a missing API, an unmanaged device, or a
// field the admin never filled in all resolve to '' instead of throwing —
// there is no scenario where this should crash the caller.

function callAttr(fn) {
  return new Promise((resolve) => {
    if (typeof fn !== "function") {
      resolve("");
      return;
    }
    try {
      fn((value) => {
        if (chrome.runtime.lastError) {
          resolve("");
          return;
        }
        resolve(value || "");
      });
    } catch (e) {
      resolve("");
    }
  });
}

async function getDeviceInfo() {
  const da = (chrome.enterprise && chrome.enterprise.deviceAttributes) || null;
  if (!da) {
    // Not ChromeOS, or this build of Chrome has no enterprise.deviceAttributes
    // surface at all — most likely a non-managed/local install.
    return { available: false, managed: false };
  }

  const [serialNumber, assetId, directoryDeviceId, annotatedLocation] = await Promise.all([
    callAttr(da.getDeviceSerialNumber && da.getDeviceSerialNumber.bind(da)),
    callAttr(da.getDeviceAssetId && da.getDeviceAssetId.bind(da)),
    callAttr(da.getDirectoryDeviceId && da.getDirectoryDeviceId.bind(da)),
    callAttr(da.getDeviceAnnotatedLocation && da.getDeviceAnnotatedLocation.bind(da)),
  ]);

  // The API exists but every field came back empty — that's exactly what an
  // unenrolled/local Chromebook looks like (or a manually loaded copy of
  // this extension, which never gets the policy-only permission grant).
  const managed = Boolean(serialNumber || assetId || directoryDeviceId);

  return {
    available: true,
    managed,
    serialNumber,
    assetId,
    directoryDeviceId,
    annotatedLocation,
  };
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.type !== "CHROMECHECK_GET_DEVICE_INFO") return;
  getDeviceInfo()
    .then(sendResponse)
    .catch(() => sendResponse({ available: false, managed: false }));
  return true; // keep the message channel open for the async response
});
