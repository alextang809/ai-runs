# Round 3 — Codex

## Did

- Ran `git checkout main` and `git pull` first, reaching `5a49a3e`, then read
  `CLAUDE.md`, `AGENTS.md`, the collaboration README and Claude's round-3 asks.
  Created `codex/round-03`.
- Coordinated the initial two-thread setup with Alex, observed hooks/transcripts and
  the native Accessibility tree, and stopped sampling when Alex requested it.
- Performed the one authorized sidebar-derived deep-link open, and correlated
  historical plan calls with PostToolUse attachments and retained AI Runs events.
  Read-only subagents reviewed hook evidence, sampling methodology and additional
  AX attributes/section structure.
- This branch changes only this note. No `Sources/`, hooks, private data files,
  permissions, or app settings were edited. UI navigation was limited to showing
  the Threads list and the requested deep link; no tasks were started, resumed,
  approved, cancelled, or messaged. No private values or screenshots are committed.

## Found

Investigation on **2026-11-18**, Claude Desktop **5.11492.5**.
All timestamps below are **Asia/Singapore** unless stated otherwise. Real project,
root, session and tool-call IDs were compared privately; only scope-local aliases
are published. No title, request text, screenshot, raw payload, or private path is included.

### 1. Controlled observation: useful partial results, not ten minutes of proven concurrency

Alex initially confirmed two independent top-level threads working in one project.
The first UI preflight was a single-thread view, so it was not counted. I used the
unique **Threads** navigation control to expose the list, then selected two distinct
native `AXLink` addresses in the same project as **T1** and **T2**. Identity was the
parsed `(project/channel ID, native thread root)`, not the displayed title.

The observation ran from **17:24:41** until Alex asked to stop at **17:33:13**.
The last completed checkpoint was at **510.2 seconds**, with **52 AX snapshots**
at a nominal **10-second cadence**: about **8 minutes 30 seconds of samples**.
It was not extended to ten minutes after the stop request.

Midway, Alex confirmed that a thread had ended or the two-working condition could
not be maintained. The displayed state groups also changed. Therefore this was
**not** a completed ten-minute test of two continuously working top-level threads.
The measurements below remain useful; they must not be described as proof of
sustained simultaneous execution.

| Initial native thread alias | Local executor/session association established in this run | Row-marker observation |
| --- | --- | --- |
| T1 | No complete contemporaneous session mapping established | At the **390.2-second** printed checkpoint, `Working` was structurally associated with T1 |
| T2 | No complete contemporaneous session mapping established | No association was established in the printed checkpoints; this does not prove that T2 had no state |

The row association rule was intentionally bounded: inspect the link and up to
**three parents**, require exactly one native thread root in the candidate
container, and reject a container spanning a web area or composer. The T1 result
is a positive association under that rule. Global `Running` text without such a
join was kept unassigned; proximity alone was not used to label either row.

Both links were present in printed checkpoints through **210 seconds**, absent
at **240–300**, present again at **330–420**, and absent at **450–510**. This describes
the printed 30-second summaries, not every intermediate snapshot. Tree size changed
substantially; a missing link was never classified as finished or idle.

**Instrumentation limitation:** interrupting the probe did not export its final
in-memory per-thread accumulator. This is a probe limitation, not an inference
about Claude. I report printed checkpoints and retained-log replays only; a
complete original T1/T2-to-session-ID table was not recovered. The initial aliases
must not be reassigned based on a later list's sort order.

#### Retained local-hook replay

The collector tailed `~/.airuns/events.jsonl` with byte offsets, checked for
replacement/truncation, and separately streamed appended local transcript records.
An independent replay of the exact **17:24:41–17:33:13** window found:

```text
Claude events:        7
Distinct sessions:    1 (published as S1)
PostToolUse:          6
Stop:                1
Actual new plan calls: 0
Plan hook payloads:    0
```

For S1, transcript user-record `sessionId` plus a structurally parsed prior
`wake/project@id` and `wake/project/thread@ts` gave **one** root address. Every event
had a preceding wake; there were no later wakes in that file that could accidentally
be used to attribute an earlier event. The last wake was approximately
**1,816–1,854 seconds** before these events. That is a historical routing link,
not a fresh per-event thread identity supplied by the hook.

A **post-observation**, current-view comparison found **five** visible native
thread roots in one project. None matched the S1 file's wake root, and its project
ID also differed. Thus these six local tool events were not evidence of work for
any of those five currently displayed threads. This current-view check does not
reconstruct the discarded initial T1/T2 identity map, so it is not presented as one.

No local session is assigned to a native row by title, relay `session`, or by the
fact that its hook happened at the same time as a visible thread.

### 2. Waiting state can be associated through native status-section membership

The narrow per-row marker check was not sufficient for every layout. A supplemental
read-only check looked at `AXHelp`, `AXDescription`, `AXElementBusy`, and `AXSelected`
in single-root row containers. It found no additional fixed status there.
`AXElementBusy=false` describes the accessibility element; it does **not** establish
that its agent is idle.

After sampling stopped, reopening the Threads list exposed a stronger structure:
status-section headings with native thread links inside their enclosing groups.
In that snapshot, **all five visible roots** could be partitioned into disjoint
sections. These are new snapshot aliases **R1–R5**, not a relabeling of T1/T2:

| Native section heading | Header role / attribute | Distinct native roots in its section | Snapshot row aliases |
| --- | --- | --- | --- |
| Ready for review | `AXHeading.AXTitle` | 1 | R1 |
| Waiting on you | `AXHeading.AXTitle` | 2 | R2, R3 |
| Idle | `AXHeading.AXTitle` | 2 | R4, R5 |

The heading strings included their counts. Corresponding labels also appeared via
`AXButton.AXTitle` and, for some sections, `AXStaticText.AXValue`. Each enclosing
**AXGroup** was reached after **three ancestor steps**, contained only one known
status-section label, contained no composer/web area, and held the stated native
link roots. The embedded counts matched membership. The section sets were disjoint,
and their union covered all five visible native roots.

**This is positive evidence that native Waiting on you can be tied to specific
thread addresses through section membership**, even when no status is attached to
the link itself. Preserve the source label; it is not automatically equivalent
to a local `PermissionRequest` or proof of a particular approval operation.
The screenshot supplied during sampling had a different section distribution;
these counts describe the later live AX snapshot, not the screenshot.

Visibility is still a constraint. Earlier supplemental snapshots had no native
links or recognized section headings. Do not infer an account-wide inventory,
state transitions between unobserved frames, or the absence of waiting from a
partial tree.

### 3. One real custom-scheme project-thread jump succeeded

After sampling ended, I performed **one** actual custom-scheme open. Earlier
preflights with no visible native links opened nothing.

Procedure:

1. Read a visible native `AXLink.AXURL` matching
   `https://claude.ai/epitaxy/project/<chan>?thread=<root>`.
2. Validate its host, route and ID shapes in memory, then construct
   `claude://code/project/<chan>?thread=<root>` from those same IDs.
3. Confirm that the exact target was **absent** from the pre-open native
   `AXWebArea` routes. The list view did not identify a different selected thread;
   the meaningful before/after comparison was list/view → exact target route.
4. Open that URL once. `/usr/bin/open` returned **0**, with no stderr.
5. Approximately **one second** later, read the native `AXWebArea` route and compare
   **both project ID and thread root** against the target. Both matched exactly.

Sanitized result:

```text
Target came from a visible native thread link: true
Exact target route present before open:       false
Open exit status:                            0
Exact native target route after open:         true
First successful check:                      about 1 second
```

This confirms navigation to the selected native thread address in this installed
app/account, beyond merely bringing Claude forward or having a registered scheme.
**No feature gate or failure was observed for this one target.** Other accounts,
reference types, app versions, and feature policies were not tested. No preference
or link template was changed. No guessed URL candidate or stored link template was used.

### 4. Plan calls do reach the PostToolUse lifecycle; AI Runs delivery is a separate question

The historical check streamed **34** local transcript files and selected actual
`type == "assistant"` records, then `message.content[]` entries with
`type == "tool_use"` and `name == "mcp__ccd_turn__update_plan"`. It deduplicated
`(sessionId, tool_use.id)` and joined them to the same session's hook attachments.

Result: **7 actual calls, 7 unique tool IDs, 2 local session IDs**, between
**2026-11-16 18:10:53.648 and 18:18:14.746 Asia/Singapore**. Inputs had **2**
`{items, scope}` lists and **5** `{advance}` updates. For **all seven**, a matching
`attachment.toolUseID` had:

```text
attachment.type = hook_success
attachment.hookEvent = PostToolUse
attachment.exitCode = 0
```

None of the matched command strings contained `airuns-hook`. Therefore **yes,
this plan tool has reached the PostToolUse lifecycle historically**; these records
do not demonstrate delivery to AI Runs' particular handler.

**Correction to round 2:** its total of 13 included **6 `api-request-blob` mirrors**.
Filtering actual assistant records and deduplicating tool IDs leaves **7 calls**.
The correct full-list/advance split is 2/5, rather than the earlier 4/9.

At the 17:19 SGT retention check, `~/.airuns/events.jsonl` contained no plan payloads
and neither historical plan-session ID; its retained records were from November 18.
That retention window does not overlap the November 16 calls. Absence there is
not evidence that a configured AI Runs handler dropped those calls.
The current Claude `PostToolUse` registration's matcher is omitted, so there is
no current configured tool-name filter excluding `update_plan`.

At base `5a49a3e`, `EventParser.swift:104` already passes `PostToolUse` tool input
through the plan parser; `Activity.swift:103` identifies this exact desktop tool.
A failed inference about delivery cannot be fixed merely by recognizing the tool
name again. Verify an actual contemporaneous handler receipt or use a read-only,
properly deduplicated transcript fallback with explicit provenance.


During this round's retained live window there were **zero** newly appended actual
plan calls and **zero** plan hook payloads, so this window cannot establish a
contemporaneous plan-call-to-AI-Runs receipt or a dropped-call rate. A cloud-visible
plan without a corresponding local call must not be treated as an omitted local
hook. Existing configuration was inspected, not edited, and no synthetic hook was
injected into AI Runs' real event log.

## Ideas

- Keep conversation identity separate from executor identity. A per-thread activity aggregate needs freshness and all linked executor observations; choosing the latest executor's state alone can hide another executor still working or waiting.
- A successful custom-scheme handoff must be verified against the resulting native project/root address, not app activation or an accepted URL alone.
- Correlate plan tool call IDs to hook events within the retained observation window. Historical absence in a replaced event log does not establish that an eligible call was dropped.


- Prefer native section membership when status is reported by grouped lists.
  A header plus its bounded subtree can be a stronger identity/state join than
  searching for a nearby word or using `AXElementBusy`.
- The successful native route check is enough to prefer the observed project-thread
  deep-link grammar for this app version, retaining a truthful fallback on failures.
- Make observation probes interruption-safe: emit anonymized per-thread counters
  and routing provenance at each checkpoint, and flush them on a stop request.
  Correlate events to the most recent **preceding** wake by timestamp, never to an
  arbitrary later wake in the same polling batch.


## Asks

- Claude: support native Waiting on you / Ready for review / Idle section membership
  as an AX observation, with native URL identities, explicit view scope and time.
  Keep these native labels separate from local approval/completion inferences.
- Claude: treat the tested `claude://code/project/…?thread=…` route as locally
  verified navigation, while handling unavailable routes/feature gates honestly.
- Claude: correct the round-2 plan-call count to seven actual calls, and distinguish
  the PostToolUse lifecycle from delivery to the specific `airuns-hook` handler.
- Claude: do not assign a global Running marker, unrelated session's hooks, or a
  late wake to a thread. Several executors can coexist; the latest executor's
  state alone is not a safe aggregate.

## Needs from Alex

- No additional permission is needed for this round's commit and push.
- The requested observation was stopped at Alex's request after about 8.5 minutes.
  A strict ten-minute period with two continuously working top-level threads remains
  unverified; this round should not be cited as that stronger result.
- AI Runs-specific plan delivery needs a future eligible local plan call and a
  contemporaneous retained receipt. No further task or sampling run was started
  to force that result after sampling was ended.
