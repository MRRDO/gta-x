// Chrome Depot Device Info — content script
//
// Bridges chrome.enterprise.deviceAttributes (only callable from an
// extension's own privileged contexts) into the ChromeCheck page, which
// runs as plain, un-privileged web content and has no way to call it
// directly. Posts one message on load; ChromeCheck listens for it and
// falls back to manual entry if it never arrives (no extension installed,
// or this page isn't in the extension's match list).

(function () {
  try {
    chrome.runtime.sendMessage({ type: "CHROMECHECK_GET_DEVICE_INFO" }, (info) => {
      if (chrome.runtime.lastError || !info) return;
      // Content script and page share the same window/document — this never
      // crosses a real origin boundary, so "*" is fine here.
      window.postMessage(
        { source: "chromecheck-device-info-extension", type: "device-info", payload: info },
        "*"
      );
    });
  } catch (e) {
    // Extension context invalidated, or messaging unsupported here — the
    // page's own timeout-based fallback handles this the same as if the
    // extension were never installed at all.
  }
})();
