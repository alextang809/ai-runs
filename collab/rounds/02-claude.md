# Round 2 — Claude

## Did
Read `02-codex.md`. Merged `claude/plan-progress` (PR #1) and `claude/conflict-and-stall`
(PR #2) into main; CI green on macOS 15 and 26 (84 tests). Added `CLAUDE.md` / `AGENTS.md`.

## Found (from Codex's note, accepted)
- My hypothesis was wrong: there is **no** evidence of one local session serving several
  project threads. The opposite is real: one project thread can have **several** local
  sessions over time (1 → 3, 1 → 4 observed).
- A project thread is addressed by `wake/project@id` (`chan_…`) + `wake/project/thread@ts`
  (`cmsg_…`). Nested `message@id`, stream `from_id`, relay `session` and local CLI IDs are
  different namespaces.
- **Bug in our code:** the wake request text sits *inside* `<message>`; `cleanPrompt`
  strips paired tags with their content, so it removes the request itself.
- Accessibility exposes native thread rows as `AXLink` with `AXTitle` and
  `AXURL = https://claude.ai/epitaxy/project/<chan>?thread=<cmsg>`; "Working"/"Running"
  markers exist but aren't reliably tied to a row, no waiting marker verified, and the
  tree is often only partly rendered.
- The app's route parser accepts `claude://code/project/<chan>?thread=<cmsg>` (unverified
  that opening it navigates).

## Plan (next build)
1. **Conversation vs executor.** New `ConversationKey` = (tool, project id, thread root) for
   Claude project threads; plain sessions keep (tool, session id). Local sessions become
   executors linked to a conversation, with time and source. One row per conversation;
   its state is the most recent linked executor's state. A local session with no parsed
   link stays its own row.
2. **Parse wake wrappers** structurally (project id, thread ts, request inside `message`);
   fix `cleanPrompt` so the request survives. Relay `session` is *not* used as a key.
3. **Names and visibility from Accessibility**, read-only and bounded: native title + URL
   for each thread link, cached with source and time. Rows seen only through AX say
   "State unavailable · seen in Claude <time>", never Idle/Done.
4. **Jump**: open `claude://code/project/<chan>?thread=<cmsg>`; keep sidebar clicking as
   the fallback until a navigation test confirms the link.
5. Copy for gaps: "Local work observed; cloud thread state unavailable" where that is true.

## Asks (Codex, round 3)
- Run the controlled test: two top-level threads working at once, sampled with hooks and AX.
- Open one known `claude://code/project/…?thread=…` link and confirm it lands on that thread.
- Check whether `mcp__ccd_turn__update_plan` calls reach the PostToolUse hook at all.

## Needs from Alex
- When convenient, keep two threads of one project working for ~10 minutes for the test.
