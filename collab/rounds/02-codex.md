# Round 2 — Codex

## Did

- Ran `git checkout main` and `git pull` first, reaching `a59f9ac`, then created
  `codex/round-02`. Read the collaboration README and round-2 brief.
- Recorded the independent ideas below before further investigation. Used read-only
  subagents for source-model review and local storage/static-route investigation.
- Inspected wrapper structure, historical identity mappings, bounded live transcript
  and hook activity, raw storage/cache schemas, and the actual Accessibility tree.
  Repeated the UI/activity checks after Alex restarted thread activity.
- Kept all private values out of this note. No real titles, prompts, IDs, screenshots,
  draft contents, tokens, or personal paths are included. No third-party messages,
  replayed Claude API requests, settings changes, or `Sources/` edits were made.
- Delivered findings only; no new production/probe code was needed. Verification
  consists of structural cross-checks and bounded read-only observations, with
  unverified inferences explicitly separated below.

## Found

Snapshot: **2026-11-18, approximately 16:51–17:08 Asia/Singapore**;
Claude Desktop **5.11492.5** (`Info.plist`). Counts describe bounded observations of
changing files/UI, not a complete account-wide inventory. All examples below are invented.

### 1. Wrappers contain thread identity; the request is inside them

The transcript selected by the current Claude hook's `payload.transcript_path` is
under `~/.claude/projects/<project>/<session>.jsonl`. I streamed JSON records,
selected `type == "user"`, then examined textual `message.content` only; tool-result
records were excluded. In the later snapshot this transcript contained **26** user
text records: **10 wake**, **4 relay**, **3 task-notification**, and **9 plain-text**
starts. Its last observed wrapped user message was at **16:55:57 SGT**.

Observed structure and attribute names:

| Element | Attributes | Observed nesting/body |
| --- | --- | --- |
| `wake` | `reason`, `current-time` | Contains `project` |
| `project` | `id`, `type` | Inside `wake`; contains `thread` |
| `thread` | `ts` | Inside `project`; contains `message` |
| `message` | `trigger`, `from`, `trust`, `author-id`, `id`, `sent-at`, `mention` | Actual request text inside this element |
| `relay` | `from`, `session`, `current-time`; sometimes `reason` | Direct request text and a child `note` |
| `task-notification` | None | Children `task-id`, `tool-use-id`, `status`, `summary`; optional `output-file` or `note` |

A made-up example with the observed wake shape (all values and request text fake):

```xml
<wake reason="example" current-time="2026-01-01T00:00:00Z">
  <project id="chan_example123" type="example">
    <thread ts="cmsg_root123456">
      <message trigger="example" from="example_sender" trust="example"
               author-id="example_author" id="cmsg_message789"
               sent-at="2026-01-01T00:00:00Z" mention="example">
        Example task.
      </message>
    </thread>
  </project>
</wake>
```

- `project.id` had a `chan_` prefix; `thread.ts` had a `cmsg_` prefix. These are
  separate from nested `message.id`. No `name` or `title` attribute appeared on
  these wrapper elements. The wrapper is an address, not a native title source.
- The ten wake requests had nonempty text at `wake/project/thread/message`.
  All ten closed at `</wake>` with **no non-whitespace request after that close**.
  The request begins after the nested opening `message` tag and ends before its
  closing tag. Stripping the entire paired wrapper would remove the request.
- The four relay messages closed at `</relay>` with no trailing request either;
  their request was direct text inside `relay`, alongside `note`.
  Made-up shape: `<relay from="example_coordinator" session="session_example123"
  current-time="…"><note>Example metadata.</note>Example task.</relay>`.
  A relay's `session` attribute is not a proven project-thread key.
- The inspected current transcript had **one** distinct project ID, thread root,
  and relay-session value. None of those three address values joined desktop
  metadata `sessionId` or `cliSessionId`. Do not equate their namespaces.

### 2. Historical evidence does not support the proposed single-worker multiplexing explanation

A broader streaming pass over **34** `.jsonl` files in `~/.claude/projects/` found
**292** leading wake messages and **89** leading relay messages. **26** transcript
files contained a parseable `(project.id, thread.ts)` pair, representing **19**
distinct pairs. No inspected transcript contained multiple such pairs.

The mapping in the opposite direction was:

```text
16 project/thread pairs -> 1 local transcript/session ID each
 1 project/thread pair  -> 4 distinct local transcript/session IDs
 2 project/thread pairs -> 3 distinct local transcript/session IDs each
```

Both filename stems and user-record `sessionId` fields confirmed those distinct
local IDs. This is evidence that one project thread can have several historical
local sessions. It does **not** establish that those sessions ran simultaneously.
It provides **no evidence that one local session serves multiple project threads**;
that working guess from the brief remains unverified and should not drive a fix.

Across these pairs, **15** thread roots had multiple distinct nested `message.id`
values; one had **113**. There were **283** distinct nested message IDs in total,
and none equaled its enclosing root. This directly supports using `thread.ts`
for the root, rather than each new message ID, when interpreting these wrappers.

Live observations were narrower:

- At **16:51**, the then-current `~/.airuns/events.jsonl` contained **41 Claude
  events**, all `PostToolUse`, from **one** distinct `session_id` and one transcript.
  Host bundle was `com.anthropic.claudefordesktop`. This log snapshot is not a
  lifetime session count; logs can be replaced/truncated between investigations.
- Two separate **30-second** samples, starting **17:00:17** and **17:05:58**, compared
  sizes/mtimes of all 34 transcripts and read only newly appended hook bytes.
  Each found **0 changed transcripts, 0 new Claude hook events, 0 newly observed
  hook session IDs**. These are activity observations, not a claim that no local
  session/process existed.
- The later sample followed Alex restarting thread activity. AX exposed two
  distinct thread links in one project, but I did not establish two independent
  top-level thread roots both working throughout a common measurement interval.
  **That controlled concurrency test remains unverified.** Background child jobs
  must not be counted as separate top-level conversations without explicit identity.

### 3. Project traces exist on disk, but I did not find a current named thread index

Read-only raw-file inspection covered Claude's Local Storage, HTTP cache, and
local-session metadata. LevelDB was **not** opened through a database library,
repaired, compacted, or written. Raw recovered versions can be obsolete; the
latest decoded record is not a guarantee of an authoritative current view.

`~/Library/Application Support/Claude/Local Storage/leveldb/` contained these key families:

| Key shape | Observed structure / scope |
| --- | --- |
| `projects.lastThread.<chan_id>` | 6 recovered set keys; navigation hints, not an inventory |
| `projects.lastPaneView.<chan_id>` | 1 recovered set key |
| `composer-draft:epitaxy-chan-thread:<cmsg_id>` | 83 distinct recovered keys; latest decoded records left 1 nonempty value, with JSON fields `text`, `files`, `snippets` |
| `epitaxy:code-session-durability:v1` | 50 map entries with values `{at, uuid}`; keys had `session_` or `local_` prefixes, no `cmsg_` keys |
| `react-query-cache-ls` | Historical `{buster, timestamp, clientState: {mutations, queries}}`; latest recovered version was a deletion/tombstone |

Drafts are private input, not an acceptable title feed. The durability map did not
establish a project-thread-to-local-worker join. One historical React Query cache
version had **9** queries, including **3** `chat_conversation_list` entries whose
`data` lists were all empty. Query objects had `state`, `queryKey`, `queryHash`;
`state.status`, `fetchStatus`, and `dataUpdatedAt` describe fetching/cache state,
**not running/waiting/done thread state**. No native project-thread title item
schema was established there.

`~/Library/Application Support/Claude/Cache/Cache_Data/<hex>_0` held **529** historical
stream-request entries for this endpoint shape:

```text
/v1/code/channels/<chan_id>/messages/stream
query shapes:
  {from_id}
  {caught_up, from, from_id}
  {from_id, scope, thread_id}
  {scope, thread_id}
```

These covered **7** channel IDs, **33** distinct `thread_id=cmsg_…` references, and
**511** distinct `from_id=cmsg_…` references. `scope=thread` occurred in **245**
requests. A `cmsg_` prefix alone cannot tell a root address from a message/cursor.
No endpoint was requested or replayed during this investigation.

A separate full-body cache snapshot parsed **524** historical activity payloads
with exactly these fields (not an atomic snapshot with the request-header count above):

```text
at: string
session_id: string
thread_root_id: null
working: boolean
```

All observed `working` values were false. The **60** opaque session IDs did not
join desktop `sessionId`, `cliSessionId`, or `lastAssistantCliSessionId`.
These cached values establish a format, **not current inactivity**, and a null
root cannot supply the missing executor/conversation link. No title field appeared.

A separate pass over **35** `local_*.json` desktop metadata files found native local
session titles, but zero `projectId`, `project_id`, `channelId`, `threadId`,
`thread_id`, or `thread_root_id` fields. These local-session titles still do not
constitute the project's native Threads inventory.

### 4. Cloud-only: local traces yes; execution location not proven

There **are** local traces of project/thread addresses in navigation keys, draft
keys, historical stream requests, and the live AX links below. It would be wrong
to say that projects or cloud-visible threads leave no local trace.

In the later AX snapshot, neither of the **two** visible thread roots, nor their
project ID, matched the wake addresses in any of the 34 inspected local transcripts.
This demonstrates visible thread records without a known local transcript join.
It does **not** prove that their execution was exclusively cloud-side, or that
there was never a local worker elsewhere. No authoritative complete inventory,
execution-location flag, or cloud-thread-to-worker mapping was established.

### 5. Accessibility can expose native names and addresses; status coverage is partial

Initial sandboxed `AXIsProcessTrusted()` returned false. A normal-access subprocess
returned **true**, and `AXUIElementCopyAttributeNames` succeeded. No permission was
granted, no `AXManualAccessibility` value was set, and no AX action was performed.
The already-running Claude window was brought forward once for inspection.

Read-only, bounded walks of `AXWindows` / `AXChildren` observed:

- `AXHeading.AXTitle == "Threads"`, with an `AXStaticText.AXValue` child.
- In full snapshots, native project-thread entries were **AXLink** elements carrying
  **AXTitle**, **AXDescription**, and **AXURL**. In the later snapshot there were
  **2 distinct thread query references in 1 project**.
- Their `AXTitle` and `AXDescription` were equal. The first descendant
  `AXStaticText.AXValue` was the prefix carrying the visible name; one snapshot had
  one static child with the same value, while others had a second child, so the
  link's accessible name can include additional text. Do not assume it is always
  the bare native title. No real values were printed or saved in the repo.
- The native links exposed this route shape:
  `https://claude.ai/epitaxy/project/<chan_id>?thread=<cmsg_id>`.
  Use the address to identify a row, rather than its title alone.
- Working text appeared as **AXStaticText.AXValue == "Working"**; other regions
  exposed **AXGroup.AXTitle / AXDescription == "Running"**. A first full snapshot
  contained two Working texts; after the restart another contained one. Later
  snapshots no longer contained Working. These changing markers were **not
  reliably joined to each individual thread row**, and no waiting indicator was
  verified. There is no evidence here for a complete per-thread state feed.
- Tree availability varied: a full walk had **554** nodes, some intervening walks
  only **34** shell nodes with no thread links, and a later full walk **644** nodes.
  Visibility/rendering/virtualization and stale elements must be handled. A missing
  AX row or marker is **unknown**, not finished or absent from the account.

`SidebarClicker.swift:66` already matches `AXTitle`, `AXValue`, or `AXDescription`
by normalized text. It does not read the thread URL or associate status markers,
and duplicate names can be ambiguous. That existing clicker is not yet a thread
inventory/state adapter.

### 6. A specific project-thread link grammar exists in the installed app

Static code in `/Applications/Claude.app/Contents/Resources/app.asar`, member
`.vite/build/index.chunk-xV3fJhc7.js`, establishes more than a guessed Code-session URL.
Zero-based JS character offsets observed in this installed version:

| Offset | Code evidence |
| --- | --- |
| 3336394 | Project/thread ID validators |
| 3336827 | Parses `/code/project/<id>` or `/epitaxy/project/<id>` with `thread`, optional `msg` |
| 3337381 | Serializes those query parameters |
| 3823156 | The `nu.Code` custom-scheme branch prepends `/code` |
| 3833581 | Navigates to the corresponding `/epitaxy/project/…` route |

Supported-by-code, made-up candidate:

```text
claude://code/project/chan_example123?thread=cmsg_example123
claude://code/project/chan_example123?thread=cmsg_example123&msg=cmsg_example456
```

The route parser accepts `cmsg_`, `session_`, `ses_`, and `cse_` thread references,
normalizing `cse_` to `session_`. Preserve these namespaces rather than assuming
all accepted references are identical. Feature/policy gates still apply.

The AX-observed HTTPS route independently agrees with this project/thread routing
shape. **Opening a custom-scheme link and confirming navigation to the exact target
remains unverified.** I did not open candidate links or modify `claudeSessionLink`.
The existing `Scripts/probe/try_claude_links` tests local-session guesses and writes
a preference after confirmation, so it was intentionally not run under this brief.

### Why the current code collapses the observed data

At base `a59f9ac`, `SessionStore.swift:62` keys a row only by `tool:sessionId`.
`Models.swift:106` has no separate project/thread/message address; `EventParser.swift:80`
keeps prompt/driver information without extracting those identities.
`Activity.swift:177` recognizes a leading relay driver only, not wake identity.
`ClaudeDesktopIndex.swift:49` joins local `cliSessionId` to hook session ID.
Those are local-executor models, not the native project-thread model above.

The evidence supports adding a separate conversation identity and observation
layer. It does not support changing a generic local-session title into a guessed
cloud-thread title, splitting every message into its own row, or declaring all
unobserved threads idle. No `Sources/` changes were made in this round.

## Ideas

Independent proposals, recorded before further investigation:

1. **Conversation identity and execution identity must be separate.** Give each provider-native conversation a durable key; represent local sessions, cloud workers, browser tabs, and delegated tasks as observations or executors linked to that key. A worker session must not become the conversation's identity by accident.
2. **One executor may serve several conversations, and one conversation may have several executors.** Store explicit links with their source, time range, and confidence. Aggregate activity only when the link is established; an ambiguous worker should stay a separate, visibly unassigned observation.
3. **Existence, visibility, activity, and reachability are different facts.** A row can truthfully say “State unavailable · last observed …” and still offer a verified jump. A visible sidebar row does not prove execution, and a live local worker does not reveal every cloud conversation.
4. **Do not mistake a message address for a conversation address.** Wrapper IDs may identify a message, thread root, delivery, or bridge session. Preserve their namespace and prove which ones remain stable across multiple turns before deduplicating rows or building links.
5. **Make observation coverage explicit.** Offer a compact “Local workers observed; cloud thread inventory unavailable” explanation when that is the actual connector capability. Do not manufacture the missing rows from the first prompt or claim that the observed subset is complete.
6. **Use separate title and state authorities.** Prefer the originating UI's native title; allow a state source to be absent or stale independently. Avoid publishing a private request as a fallback name.
7. **Let the user choose the display surface without changing identity.** Project grouping, local-session views, and all-conversation views should be filters over the same entities, with worker links available for diagnostics.


Evidence-informed proposal:

| Conversation type | Proposed durable identity | Link to execution / display observation |
| --- | --- | --- |
| Claude project thread | Provider/account scope + project/channel ID + native root reference | Parsed wake address with local session ID and observation time; native AX URL/name when visible |
| Plain Claude Code session | Provider/account scope + local CLI session ID | Local-session metadata and hooks; retain as its own row until an explicit project-thread link is known |
| Codex thread | Provider/account scope + native thread ID | Runtime turns, local rollouts, and explicitly linked children belong underneath it |
| Web conversation | Provider/account scope + canonical native conversation address | Browser tab is an observer; merge with desktop only when the same native identity is established |

Represent workers and delegated child jobs as linked execution records, not new
conversation rows automatically. The observed three project threads with several
local session IDs are an immediate reason to support several executors per thread.
Keep the reverse relationship available in the design, but label it unproven here.

Store `observedAt`, `source`, and observation scope independently of native
`lastActivity`. When the UI supplies a title/address but no trustworthy state,
show **“State unavailable · seen in Claude …”**. When no native name was observed,
use **“Untitled”** rather than a request/relay body. A cached `working=false`, quiet
log, missing virtualized row, or failed AX scan must not become Idle or Done.

Prefer native URLs over title-based clicking for identity. Cache visible names
only with their source/time, and mark the inventory as the visible project/view,
not all Claude threads. Parse wrappers structurally with validated namespaces;
unknown shapes should leave an unassigned executor, not silently merge threads.


## Asks

- Claude: revise the one-worker/many-project-threads hypothesis in light of the
  historical mapping. Please separate conversation IDs from execution IDs before
  implementing discovery or deriving state from local hooks.
- Claude: use `thread.ts` / route `thread` for the observed root, and keep nested
  `message.id`, stream `from_id`, relay `session`, and local CLI IDs distinct.
- Claude: prototype an AX adapter that reads native link URLs and the first name
  text, with a bounded visible-view scope. Verify status-to-row ancestry and
  waiting indicators before promising per-thread state.
- Claude: validate the custom-scheme grammar through an explicit target-navigation
  test, including feature gates. Registration/open success alone is insufficient.
- Claude: do not build discovery around deleted/empty React Query caches, drafts,
  or historical HTTP cache activity. A supported live connector would be preferable
  to treating private cache formats as a production API.

## Needs from Alex

- No further permission is needed for this round's requested commit and push.
- A future controlled test should keep two independent top-level project threads
  working long enough to associate each native root with its own UI state while
  sampling local hooks. This round observed two visible roots and activity markers,
  but did not verify that full simultaneous-state mapping.
- Exact custom-scheme jumping remains to be tested by opening a known target and
  confirming it. This round stayed read-only apart from focusing the existing
  window; it did not open links, press threads, or change app settings.
