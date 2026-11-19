# Round 5 — Codex

## Current conversation follow-up — approved and implemented

- Alex selected **One list** and explicitly included project main conversations.
  `ClaudeCurrentView` reads validated project routes from AXWebArea; child
  identities reuse existing thread keys, while a main conversation has its
  own `:main` key. A visible project header alongside a child identifies both.
- Child titles come from a scoped Threads breadcrumb. Project headers match
  full document titles at observed separator boundaries; the document title
  is not borrowed as a child name. No message text supplies titles or state.
- Identity observations are stored separately from state observations. New
  identity-only rows show **STATE UNKNOWN**, have no activity spans or alerts,
  and count as neither Working, Needs you nor Done. Known hook/list state and
  its observation time remain intact; stale state becomes unknown, not Done.
- The same list contains mains and children. Urgent rows keep priority, current
  idle rows remain visible, hook progress bars remain intact, and open/pin links
  address the correct main or child. Removal and custom titles are preserved.
- Exact submitted snapshot: **167 Swift tests passed**, including **39 new
  regressions**; AIRunsCore line coverage **92.80%**, current-view parser
  **99.43%**. The signing suite's **59 checks** and browser extension tests
  passed; the isolated test dependency audit reported **0 vulnerabilities**.
  The full shared workspace additionally contained six independent AppKit
  tests from another task; those changes are not part of this submission.
- Live AX checks established that the project heading is a prefix of the
  document title with a recognized separator, while the child breadcrumb is
  distinct. Only flags and role paths were recorded. Later Claude exposed no
  actual window, so new main/child presentation in the installed application
  remains **unverified**. Empty live-reader results created no false rows.
- Parallel floating-panel persistence edits were preserved in the working
  tree and excluded from this feature's commit. The original round checkpoint
  below remains historical where its installation observations differ.

## Did

- Took day-to-day ownership of `Sources/`, `Tests/`, `Scripts/`, and docs under
  Alex's round 5 handover. Read the shared rules, decisions and both briefs;
  fetched PR #7 and based `codex/round-05` on `c270f2f`.
- Installed PR #7 using the local identity in the login keychain. After Alex
  granted Accessibility, replaced the release executable with a different
  debug executable, then restored release. Both retained working AX reads.
- Compared the visible Threads list with an independent, read-only AX probe,
  verified the stored native row, pressed the real panel refresh, and visually
  checked the row in both the panel and floating window. Restored the floating
  window's original hidden state and Claude's original window size.
- Fixed a separate refresh bug: an explicit 20,000-node request arriving during
  a regular 5,000-node read was discarded and the smaller result announced.
  `ThreadReadQueue` now serializes reads, coalesces one pending refresh and
  announces that request's own result. Empty, unchanged and unavailable
  completions all drain pending work. No interface wording or styling changed.
- Added three synthetic live-structure integration tests and seven scheduling
  tests. No real conversation values appear in their fixtures.
- Added local signing setup checks and installation guards, with isolated
  command-stub tests. Setup checks the existing key instead of recreating it;
  it explains the macOS password/Always Allow dialog before a temporary signing
  probe. Local installation requires the identity and verifies the bundle
  before quitting the installed app. Default CI ad-hoc packaging remains.
- Updated existing build/collaboration docs and added signing tests to the
  macOS 15/26 CI workflow. Alex authorized GitHub submission as `alextang809`;
  local commits use that name and the account's configured GitHub noreply email.

Validation:

- Full `swift test --enable-code-coverage`: **128 tests, zero failures** on
  macOS 26 / Swift 6.2.1. AIRunsCore line coverage: **91.79%**; new queue:
  **100%** lines/functions/regions. AppModel callback wiring was compiled and
  reviewed; it is not measured by the core unit tests.
- Browser extension baseline: `content.js: all checks passed`; isolated jsdom
  test dependencies: `npm audit` reported **0 vulnerabilities**. Real website
  selector verification remains a later priority.
- Signing-script regression suite: **59 checks passed, zero failures**. Shell
  syntax checks and `git diff --check` passed. New branch CI is recorded below
  after submission.
- Original PR #7 commit `c270f2f`: both macOS jobs succeeded in
  [CI run 44375648506](https://github.com/alextang809/ai-runs/actions/runs/44375648506).

## Found

### Signing and installation

- The previous installed app was ad-hoc signed; the local identity did not
  exist. Setup printed `Created`, and a second invocation reused it.
- Initial installs printed `Signed with "AI Runs Local Signing"` and passed
  `codesign --verify --deep --strict` with normal keychain access. The
  designated requirement stayed identical while the executable digest changed.
  Fresh counts-only reports after replacement proved that the app's actual
  `AXIsProcessTrusted()` check still passed without another grant.
- The self-signed identity is listed as `CSSMERR_TP_NOT_TRUSTED`, yet real
  signing and installed-bundle verification succeeded. Do not add broad trust
  or replace the identity merely because of this listing. Apple's
  [code-signing note](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
  explains that certificate trust and subsystem identity checks are separate.
- A later attempt to install the refresh fix stopped at a SecurityAgent dialog
  requesting key access for `codesign`, with a secure password field and
  Allow/Always Allow/Deny buttons. The login keychain had no timeout. I canceled
  only this task's signing process and removed its incomplete build bundle;
  the existing installed release remained valid and kept reading threads.
- Consequently, the installed app is still the verified **original PR #7**,
  not the later local fixes. Unattended signing is **not yet verified** after
  Always Allow. A macOS credential decision is required from Alex; no password
  was read, stored, or supplied by these changes.
- Only `/Applications/AI Runs.app` remains among the three expected install/build
  locations. Temporary builds are removed after installation or cancellation.
  This is not a claim that every backup location on the Mac was searched.
- Copy failure after removal of an old installed bundle is an existing recovery
  limitation. This patch adds signature checks before that point, but does not
  introduce a staging/rollback redesign.

### Threads list: verified on the Mac

- First aligned app snapshot: **1 window, 719 nodes, 11 links, 3 thread links,
  3 sightings, all 3 with state**, `complete=true`. Independent full traversal:
  **730 nodes, 11 links, 3 distinct thread addresses**, about **0.163 seconds**.
  Different counts are expected: the app prunes children of irrelevant links.
- Independent state association matched **1 Ready for review + 2 Idle**.
  The report's two heading occurrences per state were an AXHeading and its
  child AXButton, not two separate sections.
- The relevant role structure was:
  `AXLink <- AXGroup <- AXGroup <- AXGroup (section)`; that section contained
  `AXHeading -> AXButton` repeating the same state. The synthetic fixture uses
  this all-group, nested-button shape instead of the previous AXList fixture.
- `sessions.json` contained **one native row**, readyForReview. Its identity
  matched one visible link in memory; only the match count was printed.
  The two previously unseen Idle threads correctly received no row under the
  existing rule. The native review row was visible in both real app surfaces.
- No thread-list URL-format or state-parser fix was justified by this evidence.
  The tree was far below both node budgets.
- Activity observed in the project's main conversation had a project route
  without a thread parameter, while the right-hand child-thread states did
  not change. A main-conversation activity indicator must not be attributed
  to an unrelated child thread.

### The opened thread: identity found, state unavailable

- Opened one existing thread by pressing its visible link; posted nothing.
  Its `AXWebArea.AXURL` carried a valid project/thread pair that matched the
  selected link. No selected AX element was reported.
- Identity role path: `AXApplication / AXWindow / AXGroup (7) /
  AXScrollArea / AXWebArea`. The Threads breadcrumb appeared through an
  AXStaticText and an AXToolbar/AXGroup/AXButton.
- The identified web-area subtree had **no recognized state label**. This
  supplies identity, not evidence of Working, Done, or any other state.
- The app copies URLs only from AXLink, so it loses this opened-view identity.
  Current-thread support was initially a proposal; the approved implementation is described in the follow-up above.

### Layout and cost

| View | Independent result | Limit |
|---|---|---|
| Threads list | 3 links; all states resolved | Small list only |
| Window narrowed to 900 points | 3 links; state headings retained | Restored original size afterward |
| Side panel hidden | 0 thread links | Restored list; existing stored row retained |
| List scrolled in a 500-point-high window | 3 thread links; stored row still matches | Does not establish long-list virtualization behavior |
| One existing thread open | 1 thread address on AXWebArea; 0 state headings | AXLink-only reader misses identity |

- Five passive reads of the restored list: **0.148–0.166 s**, median
  **0.150 s**, 811 nodes and 3 thread addresses each. No write to
  `AXManualAccessibility` was made by the independent probe.
- Claude's tree was already warmed by AI Runs, which sets that attribute.
  Cold-start necessity remains **unverified**; Claude was not restarted.
- Aggregate Claude process CPU over three 12-second windows: app running
  **2.90%** of one core, AI Runs temporarily paused **0.58%**, restored
  **3.15%**. All 10 Claude processes were included. This is a short before/after
  estimate; pausing AI Runs stops its other polling too, so the difference
  does not isolate AX work alone. AI Runs was resumed automatically.
- Existing limitations not changed: depth-60 truncation is not reflected in
  `complete`; a per-message timeout is not a whole-read deadline. Neither
  limit was reached in these measurements.

## Ideas

The following proposal was accepted as One list and is now implemented:

1. Read the exact current project/thread pair from AXWebArea.AXURL. Merge with
   an existing row by identity; a repeated sighting must not create a second row.
2. Keep identity-seen time separate from state-seen time. Seeing an open page
   must not make an old state fresh. Preserve a previous state's age unless
   the page provides explicit state evidence.
3. For a newly identified thread with no state, show a neutral **STATE UNKNOWN**
   row with **Open in Claude**. It should contribute to neither Working nor
   Needs you. Keep it visible rather than folding it into Done.
4. Alex selected **One list** from the rendered proposals. The implementation
   retains one row per conversation and uses the existing row components.
5. Alex included project main conversations. They use a distinct project-main
   address; a running indicator never supplies a child-thread identity.

Stale native rows now use unknown state and remain visible as LAST SEEN.
Opening a page never resets their state observation time.

## Asks

- Review the focused refresh and signing changes. The current-thread proposal
  is separate from these internal fixes.

## Needs from Alex

1. Run the commands below. If macOS requests key access, enter the login
   keychain password in its own dialog and choose **Always Allow** for codesign.
   Do not send a password to an agent. Repeat installation once to verify that
   signing is unattended and AI Runs Settings remains On without another grant.
2. One list and project main conversations are approved and implemented.
   Verify the installed UI with a main conversation and a child thread open;
   both should appear once, with unknown state unless actual state is known.
3. Approve merges when satisfied. PR #7 is list-reading/UI verified, but the
   full round 5 acceptance still needs the installed current-view UI check.
   No merge to main or release has been performed.

```sh
cd ~/ai-runs-build
git fetch origin codex/round-05
git checkout --detach origin/codex/round-05
./Scripts/make_signing_identity.sh
./Scripts/install_local.sh
```

After the first successful install, repeat `./Scripts/install_local.sh` and
check AI Runs Settings → Claude project threads stays On. With the list
visible, press refresh and confirm the thread count. Keep just the installed
copy in `/Applications/AI Runs.app`.

### Submission checkpoint

- Submission branch: [`codex/round-05`](https://github.com/alextang809/ai-runs/tree/codex/round-05).
- Review target: `claude/popup-all-threads` (PR #7), keeping the new fixes
  separate from the unmerged base work. No merge is authorized by submission.
- [Branch CI](https://github.com/alextang809/ai-runs/actions?query=branch%3Acodex%2Fround-05)
  is the source of truth for macOS 15 and 26 after each push. Check both jobs
  before merging. The original base run and local results are recorded above.
