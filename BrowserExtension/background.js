// Relays what the chat pages report to the AI Runs app on this Mac.
// Content scripts can't talk to native apps, so they message this worker,
// which hands each message to the AI Runs connector (native messaging).
const HOST = "io.github.alextang809.airuns";

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.event === "ping") {
    chrome.runtime.sendNativeMessage(HOST, message, (reply) => {
      const error = chrome.runtime.lastError;
      sendResponse(error ? { ok: false, error: error.message } : reply);
    });
    return true; // answer asynchronously
  }
  if (!sender.tab) return;
  chrome.runtime.sendNativeMessage(HOST, message, () => {
    void chrome.runtime.lastError; // AI Runs not installed or not running: nothing to do
  });
});
