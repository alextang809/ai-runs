# Round 5 brief for Codex: take over AI Runs for a while

Alex is handing day-to-day work on AI Runs to you for a while. Until he says
otherwise you own `Sources/`, `Tests/`, `Scripts/` and the docs, not just probes.
Read first: `CLAUDE.md` (rules, layout, privacy), `collab/DECISIONS.md`, and
`collab/rounds/04-codex-brief.md` (never answered; its questions are folded in below).

## Where things stand (2026-11-18)

Merged to `main`: plan progress (#1), same-repo warning and stall notification (#2),
README updates (#3, #6), one row per Claude project thread + reading Claude's
Threads list through Accessibility + "Ignore for Now" (#4), hover card fix (#5).

Open, not merged: **PR #7, branch `claude/popup-all-threads`** (CI green on macOS 15
and 26; nobody has looked at the UI on a Mac yet except the ↻ button in the panel):

- ↻ refresh in the panel and floating window header: reads events and Claude's
  list now (node budget 20,000 instead of 5,000) and says what it found.
- A hint with an Allow button when Accessibility is missing; Settings now notices
  a grant while its window is open.
- Floating window lists background work too; only done and ignored fold away.
- `Scripts/make_signing_identity.sh` (self-signed "AI Runs Local Signing" in the
  login keychain) and `Scripts/install_local.sh` (build, replace
  `/Applications/AI Runs.app`, open). Ad-hoc builds lost Accessibility after every
  rebuild while System Settings still showed it ticked; three copies of the app
  with one bundle ID made it worse. Keep one copy, in /Applications.
- `~/.airuns/threads-report.json`: counts only (windows, nodes, links, thread
  links, other link shapes, section headings, sightings), written on every look.

**The open bug:** Accessibility is now On on Alex's Mac, yet `sessions.json` has
no row with a `native` sighting: the reader has never found a thread on a real
Mac. Alex was inside a thread page (breadcrumb "Threads › …"), not the Threads
list, which alone explains nothing being read at that moment; whether it works
with the list on screen is unknown.

## Do, in this order

1. **Install PR #7 and keep the permission.**
   ```
   cd ~/ai-runs-build
   git fetch origin claude/popup-all-threads
   git checkout --detach origin/claude/popup-all-threads
   ./Scripts/make_signing_identity.sh      # once; check it prints "Created" or "already exists"
   ./Scripts/install_local.sh               # should print: Signed with "AI Runs Local Signing"
   ```
   Alex grants Accessibility once (Settings → Allow Accessibility…). Rebuild once
   more with `install_local.sh` and confirm Settings still says On without
   re-granting. If the self-signed identity doesn't work (codesign refuses an
   untrusted cert, keychain prompts every time, TCC still drops it), fix the
   script or replace the approach, and say what you found.

2. **Make Claude threads show up.** With Claude's Threads list on screen, press ↻
   and read `~/.airuns/threads-report.json`. Compare with the tree you read
   yourself through AX at the same moment. Find which layer fails: no window, no
   links, links of another shape (the URL format may have changed from
   `https://claude.ai/epitaxy/project/<chan>?thread=<cmsg>`), links but no
   section, or the node budget. Fix `ClaudeThreadsView` / `ClaudeThreadsReader`
   and add a unit test with a made-up tree of the real shape. Report counts and
   role paths only, never titles or ids.

3. **The thread you are inside.** When the Claude window shows one thread (not
   the list), that thread is the one the user cares about most and today it never
   gets a row. Find what in the AX tree identifies it (window title, breadcrumb,
   the web area's `AXURL`, a selected sidebar link) and its state if any is
   shown. Propose before building; Alex decides anything visible.

4. **Round 4 leftovers** (from `04-codex-brief.md`): is `AXManualAccessibility`
   needed; how long one read takes and whether Claude's CPU changes; layouts that
   break the reader (sidebar only, list scrolled, narrow window).

5. When 1–3 work on the Mac, tell Alex PR #7 (plus your fixes) is ready. He merges.

## After that (project priorities)

1. Check the browser extension against the real chatgpt.com and claude.ai pages
   (`BrowserExtension/content.js` selectors, `Tests/BrowserExtension`).
2. Later: usage left per tool; GitHub Copilot as a source.

## Rules that still hold

- Alex approves merges to `main`, releases (he pushes `vX.Y.Z` tags), hook changes,
  anything published outside the repo.
- Visual changes: show a real-size mock first, Alex chooses.
- Simple and clear; say when a feature isn't worth it.
- Public repo: nothing private in commits (no titles, prompts, ids, paths beyond `~`).
- Code, commits, PRs, interface text in English; talk to Alex in Chinese.
- Every PR: `swift test` locally and CI green on macOS 15 and 26.
- Write your note in `collab/rounds/05-codex.md` (Did / Found / Ideas / Asks /
  Needs from Alex) and record decisions in `collab/DECISIONS.md`.
