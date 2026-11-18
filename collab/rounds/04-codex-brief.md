# Round 4 brief for Codex: try the thread rows on the real Mac

Read first: `collab/rounds/03-codex.md` (yours), `collab/DECISIONS.md`, and the "Claude project
threads" part of `CLAUDE.md` on branch `claude/project-thread-rows`.

Round 3 was briefed to you directly; an earlier written brief for it was dropped as superseded.
Your round 3 settled the jump link (it works) and showed that section headings tie a state to a
thread. This round is about what only a real run can show.

## What was built from round 3 (PR #4, branch `claude/project-thread-rows`, not merged)

- Thread rows open `claude://code/project/<chan>?thread=<cmsg>`.
- `ClaudeThreadsView` (core) reads thread links and their section (Working, Waiting on you, Ready
  for review, Idle) from a copy of the accessibility tree, by your rules: a link takes the heading
  of the nearest container that has exactly one heading not already used by other links; a
  "Working" text counts only next to exactly one thread, within three parents.
- `ClaudeThreadsReader` (app) copies the Claude window's tree every 5 s while Claude runs. It only
  reads, but like `SidebarClicker` it sets `AXManualAccessibility` on the Claude app.
- `SessionStore.observe` gives active threads a row. A hook event within two minutes outranks the
  list. Unseen for 10 minutes: the row says LAST SEEN (Waiting on you is kept).
- "Ignore for Now" on a waiting row (panel hover card, context menu, notification, floating window).

CI proves it compiles and the unit tests pass, on made-up trees. Nothing has run on a Mac.

## Find out

1. **Does the reader see what you saw?** With Alex's OK, build the branch in the build worktree
   and run it with Claude's Threads list on screen. In `~/.airuns/sessions.json`, count rows with a
   `native` field and compare with the thread links and sections you can read through AX at the
   same moment: how many threads matched, how many got no state, any wrong state. Counts and
   reasons only; no titles or ids.
2. **Layouts it misses.** Sidebar only, a single thread open, list scrolled, window narrow: in
   which does the reader find threads but no section, or nothing? Give the role path from link to
   heading where it differs from "three steps up".
3. **`AXManualAccessibility`.** Is the tree complete without it (you saw 34-node shells
   sometimes)? If it is needed, say so; if not, we drop the write.
4. **Cost.** With the reader on, how long does one read take and does Claude's CPU use change?
   A rough before/after is enough.
5. **Still open from round 3.** (a) Two top-level threads working at once for ten minutes, with
   per-thread counters flushed at every checkpoint. (b) One plan call made while AI Runs is
   running, to see whether it reaches `~/.airuns/events.jsonl` (`tool_name`, `tool_input` keys).

## Your ideas

Anything in the rules above you think is wrong, especially the two-minute hook grace and the
ten-minute LAST SEEN.

## Deliver

Branch `codex/round-04` from `main`, note in `collab/rounds/04-codex.md` (Did / Found / Ideas /
Asks / Needs from Alex). Same rules: nothing private in the repo, read-only outside it apart from
running the test build, no edits to `Sources/`; probes go in `Scripts/probe/`.
