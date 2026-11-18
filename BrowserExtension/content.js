// Watches a ChatGPT or Claude conversation page and reports to AI Runs:
//   start  – it began writing a reply (with your last message)
//   stop   – the reply is finished (with the end of the reply)
//   title  – the conversation's title or address changed
// Nothing leaves your Mac: messages go to the AI Runs app through the browser.

const AIRuns = (() => {
  const sites = {
    chatgpt: {
      conversation: /\/c\/([0-9a-zA-Z-]{8,})/,
      titleSuffix: /\s*[-|–]\s*ChatGPT\s*$/i,
      bareTitle: /^ChatGPT$/i,
      assistant: ['[data-message-author-role="assistant"]'],
      user: ['[data-message-author-role="user"]'],
      stop: ['[data-testid="stop-button"]', 'button[aria-label*="Stop" i]', 'button[aria-label*="停止"]'],
    },
    claude: {
      conversation: /\/chat\/([0-9a-zA-Z-]{8,})/,
      titleSuffix: /\s*[-|–]\s*Claude\s*$/i,
      bareTitle: /^Claude$/i,
      assistant: ['[data-testid="assistant-message"]', ".font-claude-response", ".font-claude-message"],
      user: ['[data-testid="user-message"]'],
      stop: ['button[aria-label*="Stop" i]', 'button[aria-label*="停止"]', '[data-is-streaming="true"]'],
    },
  };

  function siteFor(hostname) {
    return /(^|\.)claude\.ai$/.test(hostname) ? "claude" : "chatgpt";
  }

  function visible(element) {
    return !!element && element.getClientRects().length > 0 && getComputedStyle(element).visibility !== "hidden";
  }

  function lastText(doc, selectors) {
    for (const selector of selectors) {
      const nodes = doc.querySelectorAll(selector);
      if (nodes.length) return (nodes[nodes.length - 1].innerText || nodes[nodes.length - 1].textContent || "").trim();
    }
    return "";
  }

  /** What the page shows right now. */
  function read(doc, location) {
    const site = siteFor(location.hostname);
    const rules = sites[site];
    const match = location.pathname.match(rules.conversation);
    let title = (doc.title || "").replace(rules.titleSuffix, "").trim();
    if (!title || rules.bareTitle.test(title)) title = null;
    const generating = rules.stop.some((selector) =>
      Array.from(doc.querySelectorAll(selector)).some((element) =>
        element.matches('[data-is-streaming="true"]') || visible(element)));
    return {
      site,
      conversation: match ? match[1] : null,
      url: location.origin + location.pathname,
      title,
      generating,
      lastUser: () => lastText(doc, rules.user).slice(0, 1000),
      lastReply: () => lastText(doc, rules.assistant).slice(-4000),
    };
  }

  /**
   * Turns page snapshots into messages. A reply counts as finished once the
   * page has stopped writing for `settleMs`, so a flickering stop button
   * doesn't split one reply in two.
   */
  function createTracker(send, settleMs = 1500) {
    let current = { conversation: null, writing: false, title: null, url: null, quietSince: null };
    return function observe(page, now) {
      if (!page.conversation) return; // a new chat gets its address once you send the first message
      if (page.conversation !== current.conversation) {
        current = { conversation: page.conversation, writing: false, title: null, url: null, quietSince: null };
      }
      const base = { site: page.site, conversation: page.conversation, url: page.url, title: page.title };
      if (page.generating) {
        current.quietSince = null;
        if (!current.writing) {
          current.writing = true;
          send({ ...base, event: "start", prompt: page.lastUser() });
        }
      } else if (current.writing) {
        if (current.quietSince === null) current.quietSince = now;
        if (now - current.quietSince >= settleMs) {
          current.writing = false;
          current.quietSince = null;
          send({ ...base, event: "stop", reply: page.lastReply() });
        }
      }
      if ((page.title && page.title !== current.title) || page.url !== current.url) {
        current.title = page.title || current.title;
        current.url = page.url;
        send({ ...base, event: "title" });
      }
    };
  }

  return { read, createTracker, siteFor };
})();

if (typeof module !== "undefined") {
  module.exports = AIRuns; // for tests
} else {
  const send = (message) => {
    try {
      chrome.runtime.sendMessage(message).catch(() => {});
    } catch (_) {
      // The extension was reloaded; this page's script is stale until refresh.
    }
  };
  const observe = AIRuns.createTracker(send);
  const check = () => observe(AIRuns.read(document, location), Date.now());
  let scheduled = false;
  new MutationObserver(() => {
    if (scheduled) return;
    scheduled = true;
    setTimeout(() => { scheduled = false; check(); }, 300);
  }).observe(document.documentElement, { subtree: true, childList: true, attributes: true,
    attributeFilter: ["aria-label", "data-is-streaming", "data-testid"] });
  setInterval(check, 1000);
  check();
}
