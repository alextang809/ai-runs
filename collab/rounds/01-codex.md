# Round 1 — Codex

## Did

- Pulled `main` first (fast-forward to `a4b6747`), then created `codex/round-01`.
- Read the collaboration README and brief. Saved the eight independent ideas below
  before opening `01-claude-ideas.md` or `01-claude.md`; compared them afterward.
- Inspected local metadata/schema and aggregate event counts read-only; ran the
  brief's tiny Codex delivery test. A read-only source-review agent checked the
  app's assumptions, and a separate agent built/tested the optional inventory probe.
- Added `Scripts/probe/list_threads` (zsh + JXA + system SQLite; no dependencies).
  It inventories Claude desktop and Codex metadata, omits archived/delegated Codex
  rows, and emits one JSON object per thread. Native Codex `name` wins; missing
  names remain `Untitled`. It never reads transcripts and never infers idle from silence.
- Usage: `Scripts/probe/list_threads --redact` for shareable output, or omit
  `--redact` to see native titles/project paths locally. **Do not commit default
  output.** JSONL fields: `tool`, `name`, `project`, `state`, `last_activity`.
  `--home` accepts a synthetic fixture root. This is an inventory, not a list of
  currently open windows or a live status monitor; Codex requires the observed DB schema.
- Validation: fixture tests were written/run RED before implementation and then
  GREEN; they cover native-name precedence, no prompt-title fallback, filtering,
  metadata-only output, redaction, bad/missing inputs, sanitized errors, and an
  unchanged fixture database checksum. A real redacted smoke test returned
  **35 Claude + 124 Codex** rows, all `unknown`, with no diagnostics. Legacy rows
  with null `thread_source` explain why the Codex count exceeds 82 explicit user rows.
  No instrumented coverage percentage was measured. No product source changed.

## Found

Investigation snapshot: **2026-11-18, approximately 00:20–00:27 Asia/Singapore**.
Counts below are snapshots of live, changing files. Only schema, aggregate counts, and
sanitized command results are recorded here; no real titles, prompts, session IDs, or home paths.

### 1. Menu bar: known identity problem, permission state unverified

- `sw_vers` returned macOS **26.5.2**, build **25F84**. The installed app's
  `Info.plist` reports AI Runs **0.1.0**, bundle ID `io.github.alextang809.airuns`.
- `/Applications/Bartender 5.app/Contents/Info.plist` reports **5.5.8**;
  `/Applications/Bartender 6.app/Contents/Info.plist` reports **6.4.2**. A filtered
  `ps -axo comm=` check found **Bartender 6** and its service running, alongside AIRuns.
  The presence of both installed versions does not establish duplicate AI Runs entries.
- Relevant output of `defaults read io.github.alextang809.airuns` was exactly:

  ```text
  "NSStatusItem Preferred Position Item-0" = 10513;
  ```

  No other `NSStatusItem` key appeared. `Sources/AIRunsApp/StatusBarController.swift:40`
  creates the item without setting `autosaveName`. Give it a stable name, but treat
  that as an identity/placement fix to validate, not proof of the Bartender root cause.
- **Unverified:** whether AI Runs is enabled in System Settings → Menu Bar → Allow
  in the Menu Bar, and whether that UI lists it twice. The read-only
  `AXIsProcessTrusted()` check returned `false`. Preference inspection did not establish
  those UI states. I did not grant Accessibility, change settings, move the icon,
  or infer a permission value from the preferred-position key.

### 2. Claude sidebar titles: a direct join exists

- Desktop metadata lives at:

  ```text
  ~/Library/Application Support/Claude/claude-code-sessions/<id>/<id>/local_<id>.json
  ```

  Observed fields include `sessionId`, `cliSessionId`, `title`, `titleSource`, `cwd`,
  `originCwd`, `lastActivityAt`, `isArchived`, `lastAssistantCliSessionId`,
  `interruptedAwaitingPerson`, and `completedTurns`. These are ordinary JSON objects.
  Of **36** records, **35** have a title and **34** have `cliSessionId`.
  Populated `lastActivityAt` values are milliseconds since the Unix epoch;
  `titleSource` is `auto` in 35 records. Do not ingest the other fields wholesale:
  the same files also contain private prompt/configuration material.
- Evidence for identity mapping: comparing the one hook-observed Claude session ID
  against those JSON fields gave **1 match on `cliSessionId`**, **0 on `sessionId`**.
  The hook's `transcript_path` exists under `~/.claude/projects/`, and its filename
  stem equals the hook `session_id`. Use `(provider, cliSessionId)` to enrich that
  hook session with desktop `title`; retain desktop `sessionId` separately.
  Historical/session-restart remapping via `lastAssistantCliSessionId` is **unverified**.
- Across **34** local Claude transcript `.jsonl` files I found **39** records shaped
  `{type: "custom-title", customTitle, sessionId}` and **no** top-level `summary`
  records. The hook-observed session's transcript contains neither title record type.
  Absence in this dataset does not mean `summary` is unsupported elsewhere.
- `TranscriptReader.swift:23` only examines transcript title/summary records.
  `AppModel.swift:107` skips refresh when the last reply is unchanged, and its later
  fallback uses the last reply as a title. A desktop-metadata adapter plus independent
  rename refresh is necessary; wrapper stripping does not solve this source mismatch.

### 3. Codex inventory, native names, state, and child threads

- CLI and desktop metadata share `~/.codex/state_5.sqlite` on this Mac. Read-only
  `sqlite_master`/`PRAGMA table_info(threads)` inspection found:

  ```text
  threads: id, name, title, cwd, rollout_path, source, thread_source,
           archived, updated_at, updated_at_ms, recency_at_ms,
           agent_nickname, agent_role, attached_thread_parent_id, ...
  thread_spawn_edges: parent_thread_id, child_thread_id, status
  ```

  At one snapshot there were **954** thread rows, including **423** with
  `thread_source = guardian_review`, **404** with `subagent`, and **82** with `user`.
  Raw row counts would badly overstate Alex's sidebar threads. The spawn-edge table
  also contains explicit parent/child links; its `open` status is not proof a child
  is currently executing. Scope/filter inventory before rendering it.
- `~/.codex/session_index.jsonl` records have `id`, `thread_name`, `updated_at`.
  Taking the last index record for each ID and joining to `threads.id` produced
  **453 matches**: all **453** index names equaled `threads.name`; only **365** equaled
  `threads.title`. **Use `name` for the native name, not blindly `title`.**
  Among the 82 user rows, 64 had a native `name`; 40 `title` fields were longer than
  200 characters. A missing native name should remain untitled under my privacy proposal.
- `~/.codex/.codex-global-state.json` contains sidebar/project-order and pinned-thread
  metadata, rather than the native-name authority established by that join.
  `~/Library/Application Support/Codex/` also contains Electron application data;
  reading cookies or auth files is unnecessary for this adapter.
- `~/.codex/thread_history_1.sqlite` has `thread_turns(thread_id, turn_id, status,
  started_at, completed_at, ...)`. Observed status values were `inProgress`,
  `completed`, `failed`, and `interrupted`. `thread_items` includes `item_type`
  and `item_json`; no explicit plan item type was present in the inspected database.
  An unfinished historical turn is a hint, not a live process/approval guarantee.
- Local rollouts under `~/.codex/sessions/` are JSONL with `session_meta`,
  `response_item`, and `event_msg` envelopes. Observed event payload types include
  `task_started`, `task_complete`, and `turn_aborted`. No structured approval or plan
  event was found in the 132 inspected rollout files. Disk modification time alone
  cannot distinguish active, idle, and waiting for approval.
- Current official protocol documentation exposes `thread/status/changed` with runtime
  status and flags such as `waitingOnApproval`. That describes the connected server's
  loaded threads; attaching a separate process to the desktop's live server was
  **not verified**. Do not launch another app-server and assume its in-memory status
  describes the existing desktop process. [OpenAI app-server documentation](https://learn.chatgpt.com/docs/app-server)

### 4. Codex delivery now works; the historical cause is not established

- `codex --version` returned **codex-cli 0.133.0**. `codex features list` reports
  `hooks stable true`; the user config does not override that feature. The existing
  `~/.codex/hooks.json` registers `PermissionRequest`, `PostToolUse`, `Stop`, and
  `UserPromptSubmit`, each running `~/.airuns/bin/airuns-hook codex` (home abbreviated
  here). `~/.codex/config.toml` has four corresponding `[hooks.state."..."]` sections
  containing `trusted_hash`. I did not modify them or bypass hook trust.
- Before the tiny CLI test, the aggregate log already contained **219 records**:
  **205 Claude**, **14 Codex**. The first observed Codex record was at
  **00:20:14 Singapore time on November 18**. At a later pre-test snapshot Codex
  had **16 PostToolUse + 1 PermissionRequest**, from one session.
  Therefore the brief's "zero Codex" baseline is stale. The desktop round itself
  is delivering Codex events. The historical reason for zero is **unverified**;
  existing trust records do not tell us when trust was granted.
- Ran a tiny task from a temporary empty directory, using the existing user hook
  configuration, `--ephemeral --skip-git-repo-check --sandbox read-only --json`,
  a no-tools instruction, and invocation-only overrides disabling MCP servers and
  the unrelated `notify` callback. No settings were edited. The first sandboxed
  attempt failed before startup with `Operation not permitted` and added no events.
  Retrying with normal local execution reached `thread.started`, `turn.started`,
  then `turn.failed` (exit 1). Stderr additionally reported a model-catalog decoding
  error: unrecognized reasoning variant `max`. Successful inference remains
  **unverified**; I did not upgrade the CLI or change model settings.
- The retry's appended slice contained **one new-session `UserPromptSubmit`** plus
  two `PostToolUse` records from the ongoing desktop investigation. Hook delivery
  succeeded even though the tiny task's inference failed. `Stop` was not proven by
  this test; error/interrupt termination needs its own state handling.
- The observed Codex hook payload uses the parser's required `session_id` and
  `hook_event_name`, plus fields including `turn_id`, `model`, `permission_mode`,
  `tool_name`, `tool_input`, `tool_response`, and `transcript_path`. At this point
  no schema change is needed merely to receive those observed event types.
- To make a fresh installation deliver: confirm executable/writable-log access,
  supported events, hooks enabled, and review the installed definitions in `/hooks`
  or desktop Settings → Hooks. Current documentation says new/changed non-managed
  hooks are skipped until trusted. AI Runs' marker-string installation check does
  not verify this. A measured delivery check must supplement it; do not silently
  grant trust or overwrite the existing `notify` command. [OpenAI hooks documentation](https://learn.chatgpt.com/docs/hooks)

### 5. Progress: the visible checklist has more than one possible owner

- Across local Claude transcripts I found **13** calls to
  `message.content[]` tool uses named **`mcp__ccd_turn__update_plan`**:
  **4** with `input = {items, scope}` and **9** with `{advance}`.
  `items[]` has `{content, status}`; observed statuses include `pending` and
  `in_progress`. An `advance` call is a delta, not a fresh complete checklist.
  Its exact state transition semantics need verification before counting steps.
- Crucially, these were **other sessions**: the hook-observed session had no
  `TodoWrite`, `TaskCreate`, `TaskUpdate`, or `update_plan` tool calls, no nested
  `todos`/`plan`/`tasks` fields, and no plan tool appears in its hook records.
  The installed Claude `PostToolUse` matcher is omitted (not a restrictive tool
  filter). It is therefore **unverified** that the screenshot's checklist belongs
  to this local hook-observed worker; it could belong to the driving/coordinator
  thread. Do not promise checklist recovery for that exact thread yet.
- A nested Claude local-agent-mode task JSON format was also observed with
  `id`, `subject`, `description`, `activeForm`, `status`, `blocks`, `blockedBy`.
  Its relationship to this Claude Code thread is **unverified**. Avoid treating
  arbitrary Cowork task files as Claude Code progress without an identity join.
- For Codex, no direct persisted `update_plan` call or plan event was found in the
  inspected rollouts. The official live protocol documents `turn/plan/updated`
  with `turnId`, optional `explanation`, and `plan[] = {step, status}` where status
  is `pending`, `inProgress`, or `completed`. Persistence and passive subscription
  from AI Runs are **unverified**. Proposed plan prose is not a completed/total
  checklist. [OpenAI app-server documentation](https://learn.chatgpt.com/docs/app-server)

### 6. Other agents: Copilot is worth tracking; Gemini has partial inventory

- `~/.copilot/data.db` is substantial desktop metadata, not just CLI cache. Read-only
  schema inspection found `sessions(id, title, title_source, is_running,
  was_interrupted, updated_at, archived_at, ...)`, `workspaces(session_id,
  project_id, source_path, explicitly_opened, ...)`, and explicit child/coordinator
  links in `chat_parent_links` and `session_side_chats`. Snapshot: **11 sessions**,
  all titled, none marked running. These flags describe stored state; liveness is
  not independently established.
- `~/.copilot/session-store.db` separately indexes CLI sessions with
  `id`, `cwd`, `repository`, `summary`, `created_at`, `updated_at`.
  `~/.copilot/session-state/<id>/events.jsonl` has structured `type`/`data` events.
  In 13 files I observed `assistant.turn_start`, `assistant.turn_end`,
  `tool.execution_start`, `tool.execution_complete`, `permission.requested`,
  `permission.completed`, `session.task_complete`, `abort`, and `session.shutdown`.
  This offers a promising read-only inventory plus event adapter; match request
  and completion identities instead of treating every old permission request as live.
- `~/.github-copilot-cli` had cache/endpoint/log directories, **9 `.log` files** and
  **0 `.jsonl` files**. No useful thread index was established there; prioritize
  modern `~/.copilot` over scraping legacy logs.
- `~/.gemini/tmp/<project>/chats/session-*.json` contains `sessionId`, `projectHash`,
  `startTime`, `lastUpdated`, `messages`, and sometimes `kind`.
  `messages[]` includes `id`, `timestamp`, `type`, `content`. No top-level native
  title or authoritative running/approval flag was found in the inspected chat
  schemas. Basic discovery is possible; sidebar naming, project-hash resolution,
  and live state remain **unverified**. Do not substitute message content for a name.

### Implementation order and validation boundaries

1. Add metadata inventory and native-title refresh, independent of reply changes.
2. Make hook delivery/trust health observable; preserve unknown state where live
   evidence is missing. Add error/interrupt coverage before claiming reliable liveness.
3. Add explicit plan adapters only for identified sources; then investigate a live
   desktop-server subscription with its own compatibility and permission checks.
4. Set stable menu-item identity and verify placement on the actual Menu Bar UI.

`Sources/` and personal configuration were not edited. No auth/cookie files were
read. The only intended external-data writes were the brief's tiny task's normal
runtime/hook effects. No raw probe output is included in this public repository.

## Ideas

Written independently before opening `01-claude-ideas.md`:

1. **A thread is a durable identity; a run is a temporary lease on attention.** Discover threads from each tool's own index even when no hooks fired. Model run state separately, with its source and observation time. A quiet transcript is not proof that a thread is idle.
2. **Make uncertainty visible.** Show working, waiting, finished, and unknown only when the evidence supports them. Expire stale working evidence to unknown, not completed. Clicking an unknown state could offer a read-only source diagnostic.
3. **Follow the human's attention graph.** Distinguish threads Alex opened from delegated child work, and collapse child runs under their coordinator when an explicit parent link exists. A coordinator waiting on children can still represent useful activity without generating five extra top-level rows. Never infer parentage from prompt text.
4. **Treat names as provenance-bearing metadata.** Prefer the title displayed by the originating tool, retain an optional AI Runs alias, and show which source supplied the name. Never use the last assistant reply as the thread's name. An untitled thread should stay untitled rather than expose a private prompt in the menu bar.
5. **Use an inventory/event reconciliation loop.** A read-only startup scan seeds identities and names; incremental events add low-latency state; periodic reconciliation repairs missed events and renames. A tiny adapter capability report should say whether a tool supports discovery, naming, live state, progress, and deep links.
6. **Show progress as a revisioned plan snapshot.** Render completed/total only for explicit checklist items. A replanned checklist starts a new revision; do not present a changed denominator as regression or invent percentage from elapsed time.
7. **A privacy preview is part of onboarding.** Show exactly the title/project metadata that would appear, with title hiding available before enabling collection. Keep raw transcripts out of AI Runs storage; track offsets and normalized metadata instead.
8. **Separate source health from run health.** A tool with no events should produce a connector warning, not an empty board that implies there are no threads. Make the last successful inventory and event times inspectable.


After reading Claude's sealed ideas:

- We independently agree on native names, discovery plus events, and connector health.
- I disagree with "discovered means Idle": an inventory establishes existence,
  not liveness. The prototype deliberately says `unknown` for every disk-only row.
- I disagree with first-request fallback as the default name. Native `name` and
  generic `Untitled` avoid exposing wrapped prompts or entire request text.
- "Via coordinator" needs an explicit identity/parent link, not a guess from relay
  text. Codex's stored guardian/subagent population makes that distinction urgent.
- Keep durable thread identity even if the default view groups by project. A
  24-hour cutoff should be a view filter, not the identity/discovery boundary.
- Stable `autosaveName` is sensible, but the actual Menu Bar permission/placement
  problem still needs UI verification on this Mac.


## Asks

- Claude: implement title enrichment using the direct Claude `cliSessionId` join
  and Codex native `name`, with rename refresh independent of the last reply.
- Claude: separate inventory, live observation, and connector delivery state before
  adding more state heuristics. Please add compatibility fixtures for missing/new
  fields rather than treating these private schemas as stable APIs.
- Claude: identify the owner/session of the screenshot checklist before promising
  worker progress; support the observed desktop plan tool only after its delta
  semantics and session mapping are verified.
- Claude: review the probe's narrow scope before porting it. In particular, decide
  how legacy Codex rows, remote threads, and explicit child/coordinator links enter
  the UI. A new app-server must not be mistaken for a passive desktop observer.

## Needs from Alex

- Manually verify whether AI Runs is enabled, and whether it appears twice, in
  System Settings → Menu Bar → Allow in the Menu Bar. Accessibility is unavailable
  to this process, so those two facts remain unverified; no permission/configuration
  change was made to work around that.
- Product decision: approve or revise the proposed `unknown` state and `Untitled`
  fallback. They preserve uncertainty and privacy, but differ from Claude's
  discovered-as-idle / stripped-first-request defaults.
- No additional permission is needed for this round's commit/push: both were
  explicitly requested. Successful tiny-task inference remains unverified because
  the installed CLI failed; updating it is a separate scoped change.
