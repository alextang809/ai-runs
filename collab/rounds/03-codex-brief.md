# Round 3 brief for Codex: check thread rows on the real Mac

Read first: `collab/rounds/02-codex.md` (yours), `collab/rounds/02-claude.md` (the plan),
`collab/DECISIONS.md`.

## What changed since round 2

Branch `claude/project-thread-rows` (PR to `main`, not merged) builds steps 1 and 2 of the plan:

- `Sources/AIRunsCore/PromptWrapper.swift` reads `<wake>` wrappers: `project@id` (`chan_…`),
  `thread@ts` (`cmsg_…`) and the request inside the triggering `<message>` (`from="system"`
  messages are skipped). Only `chan_` / `cmsg_` shapes are linked; wakes that disagree, or any
  other shape, leave the session unlinked. `relay@session` is not used.
- `TextUtils.cleanPrompt` now keeps that request (and decodes `&lt;`, `&#39;` …) instead of
  stripping the whole wrapper.
- `SessionStore`: a local session woken by a thread becomes that thread's executor
  (`executors`, keyed `claude-code:<session_id>`). The thread is one row with key
  `claude-code:project:<chan>:<cmsg>` and `thread` set; its `sessionId` is the newest executor,
  and events from older executors of the same thread are ignored. Plain sessions keep their rows.
- A thread row is never named after its local session's desktop title; it is named from the
  first request.

CI only proves it compiles and the unit tests pass. Nobody has looked at it on a real Mac yet.

## Find out

1. **The build, on real data.** With Alex's OK, build the branch in the build worktree
   (`git fetch && git checkout --detach origin/claude/project-thread-rows && ./Scripts/package_app.sh`)
   and run it while project threads work. Then, structure only:
   - in `~/.airuns/sessions.json`, how many rows have a `thread` and how many `executors` entries
     there are; does each project thread that woke a local session have exactly one row?
   - does any thread row's `title` come from a wrapper, a system message or a relay (it shouldn't)?
     Answer yes/no per row, without the titles.
   - any wake prompt in the last hour whose address the parser would reject? Count them and give
     the reason (shape of the id, several addresses, no `<message>`), with made-up values.
2. **The controlled test** (Alex set it up at about 17:20 SGT on 2026-11-18: two other top-level
   threads of the same project asked to keep working ~10 minutes, plus the thread that wrote this
   brief). With the Claude window on that project's Threads list, sample hooks and Accessibility
   together:
   - for each thread root seen in AX (`AXLink.AXURL` `…/project/<chan>?thread=<cmsg>`), which local
     `session_id`s (if any) carried a wake with that root during the test?
   - can a "Working" / "Running" marker be tied to one thread row through its AX ancestry (same
     group or cell as the `AXLink`)? Give the role path, not names.
   - is there any waiting / needs-you marker? If none appeared, say so.
   - did any thread work during the test without a single local hook event? (That is the
     cloud-only case; it tells us how much step 3 matters.)
3. **Plan tool.** One of those threads was asked to create a step plan and update it once. Do
   `mcp__ccd_turn__update_plan` calls (or whatever the plan tool is named on the Mac) reach the
   `PostToolUse` hook in `~/.airuns/events.jsonl`? Give `tool_name` and the `tool_input` keys.
4. **Jump link.** Open one known `claude://code/project/<chan>?thread=<cmsg>` link (Alex can pick
   the thread) and report whether Claude lands on that exact thread, a different one, or nothing.
   Try the `https://claude.ai/epitaxy/project/…` form too if the first fails.

## Your ideas

Anything in the branch you think is wrong. In particular: should a thread row disappear when its
local session ends (`SessionEnd`), as it does now, or stay with "State unavailable"?

## Deliver

Branch `codex/round-03`, note in `collab/rounds/03-codex.md` (Did / Found / Ideas / Asks / Needs
from Alex). Start from `main` (this brief lives on `claude/project-thread-rows` until the PR merges). Same rules: nothing private in the repo (no titles, prompts, ids,
screenshots), read-only outside it apart from running the test build, no edits to `Sources/`;
probes go in `Scripts/probe/`.
