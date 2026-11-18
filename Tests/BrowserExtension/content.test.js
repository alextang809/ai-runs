const { JSDOM } = require("jsdom");
const assert = require("assert");
const path = require("path");
const AIRuns = require(path.join(__dirname, "../../BrowserExtension/content.js"));

function page(url, html, title) {
  const dom = new JSDOM(`<!doctype html><html><head><title>${title}</title></head><body>${html}</body></html>`, { url });
  // jsdom has no layout: treat every element as visible.
  dom.window.Element.prototype.getClientRects = function () { return [1]; };
  global.getComputedStyle = dom.window.getComputedStyle;
  return dom.window;
}

// ChatGPT, writing.
let w = page("https://chatgpt.com/c/6650aa11-2222-3333", `
  <div data-message-author-role="user">Why does login fail?</div>
  <div data-message-author-role="assistant">Looking…</div>
  <button data-testid="stop-button" aria-label="Stop streaming">■</button>`, "Login bug - ChatGPT");
let s = AIRuns.read(w.document, w.location);
assert.equal(s.site, "chatgpt"); assert.equal(s.conversation, "6650aa11-2222-3333");
assert.equal(s.title, "Login bug"); assert.equal(s.generating, true);
assert.equal(s.lastUser(), "Why does login fail?");

// Tracker: start, then stop only after the page settles.
const sent = [];
const observe = AIRuns.createTracker((m) => sent.push(m), 1500);
observe(s, 0);
assert.deepEqual(sent.map((m) => m.event), ["start", "title"]);
w = page("https://chatgpt.com/c/6650aa11-2222-3333", `
  <div data-message-author-role="user">Why does login fail?</div>
  <div data-message-author-role="assistant">The cookie expires. Fixed it; all tests pass.</div>`, "Login bug - ChatGPT");
s = AIRuns.read(w.document, w.location);
assert.equal(s.generating, false);
observe(s, 1000); assert.equal(sent.length, 2, "not yet settled");
observe(s, 2600); assert.equal(sent.at(-1).event, "stop");
assert.match(sent.at(-1).reply, /all tests pass/);
observe(s, 4000); assert.equal(sent.length, 3, "no repeats");

// New chat without an address yet: nothing is sent.
w = page("https://chatgpt.com/", `<button data-testid="stop-button">■</button>`, "ChatGPT");
s = AIRuns.read(w.document, w.location);
assert.equal(s.conversation, null); assert.equal(s.title, null);
observe(s, 5000); assert.equal(sent.length, 3);

// Claude, streaming.
w = page("https://claude.ai/chat/0f9e8d7c-1111-2222", `
  <div data-testid="user-message">Plan the release</div>
  <div class="font-claude-response" data-is-streaming="true">Step one…</div>`, "Release plan - Claude");
s = AIRuns.read(w.document, w.location);
assert.equal(s.site, "claude"); assert.equal(s.conversation, "0f9e8d7c-1111-2222");
assert.equal(s.title, "Release plan"); assert.equal(s.generating, true);
assert.equal(s.lastReply(), "Step one…");
console.log("content.js: all checks passed");
