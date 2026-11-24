# AI Runs — notes for agents working on this repo

AI Runs is an open-source macOS menu bar app (MIT) for people who run many AI
agent sessions at once. It shows which sessions need the user, what the others
are doing, and jumps back to any of them in one click. Owner: Alex. The repo is
**public**.

## What it follows and how

| Source | How AI Runs hears about it |
|---|---|
| Claude Code (terminal, VS Code, Claude desktop) | Hooks in `~/.claude/settings.json` call `~/.airuns/bin/airuns-hook claude-code` |
| Codex (CLI and the Codex / ChatGPT desktop app) | Hooks in `~/.codex/hooks.json`; Codex shows **Review hooks** and the user must **Allow all** before anything arrives |
| chatgpt.com, claude.ai | `BrowserExtension/` (MV3, Chromium browsers) → native messaging → `airuns-hook chrome-extension://<id>/` |

Every source appends one JSON line to `~/.airuns/events.jsonl`. The app polls it
once a second (`EventLogReader`, offset in `cursor.json`), folds events into
`SessionStore`, saves `sessions.json` and `pins.json`.

Names come from the tools themselves: Claude desktop's session list
(`ClaudeDesktopIndex`, joined on `cliSessionId`), Codex's `~/.codex/state_5.sqlite`
(`CodexThreadIndex`, `threads.name`; `user`, `voice_chat` and
`agent_created_thread` are user conversations; other nonempty sources are
internal helpers and are ignored),
the web page title for web chats.

**Claude project threads:** a project thread runs in the cloud and fires no
local hooks itself. When it wakes a local Claude Code session, the prompt is
wrapped in `<wake><project id="chan_…"><thread ts="cmsg_…"><message …>request</message>`.
`PromptWrapper` reads that address; `SessionStore` then shows one row per thread
(`Session.thread`, key `claude-code:project:<chan>:<cmsg>`) and treats local
sessions as its executors (`SessionStore.executors`); the newest one speaks for
the row. Clicking the row opens `claude://code/project/<chan>?thread=<cmsg>`.

Threads that work only in the cloud are read from the Claude app's window:
`ClaudeThreadsReader` (app, Accessibility, read-only, every 5 s while Claude
runs) copies the tree, `ClaudeThreadsView` (core) finds thread links
(`AXLink.AXURL`) and the section heading each sits under (Working, Waiting on
you, Ready for review, Idle), and `SessionStore.observe` gives active ones a row
(`Session.native`). Rules: the pill uses Claude's own word; a hook event within
two minutes outranks the list; a thread missing from the tree is left alone
(the list is often partly drawn); after 10 minutes unseen a row says LAST SEEN
instead of a state, except Waiting on you, which is kept; idle threads AI Runs
never saw active get no row.

**Opened conversations:** `ClaudeCurrentView` also reads validated
`AXWebArea.AXURL` routes for an opened child thread and a project's main
conversation. A main uses its own `Session.projectMainId` and `:main` row key;
child keys and hook executor links remain unchanged. Both appear in One list.
`Session.nativeView` records identity observation separately from
`Session.native` state observation. An open page never refreshes an older state
or supplies a guessed one. Newly identified conversations without state are
`SessionState.unknown`: no Working/Needs you/Done counts, alerts or activity
spans. Unknown and stale rows remain visible. Pin/open links address the main
or child conversation directly. Titles come from scoped project/thread headers,
not conversation messages.

## Layout

- `Sources/AIRunsCore` — no UI, unit tested. Models, `EventParser`,
  `SessionStore` (the state machine), `TurnClassifier` (done vs needs input),
  `Timeline` (lifelines and header stats), `AlertPlanner`, `PinBoard`,
  `HookInstaller`, `WebBridge` + `BrowserConnector`, `TextUtils`.
- `Sources/airuns-hook` — tiny CLI the hooks and browsers call. Must never slow
  down or break an agent: silent on failure, always exits 0.
- `Sources/AIRunsApp` — AppKit + SwiftUI. `StatusBarController` (menu bar item,
  panel), `PanelViews` / `RunViews` (rows, header dashboard, flyout),
  `FloatingWindow`, `Notifier`, `Jumper` (go back to a session),
  `SidebarClicker` and `ClaudeThreadsReader` (Accessibility), `SettingsView`, `TitleModel` (on-device model,
  macOS 26 only, behind `#if canImport(FoundationModels)`).
- `BrowserExtension/` — content script (`content.js`), relay worker, popup.
  Fixed `key` in the manifest keeps the extension ID stable; it must match
  `WebBridge.extensionID`.
- `Tests/` — XCTest for the core; `Tests/BrowserExtension/content.test.js` (jsdom).
- `collab/` — notes between Claude and Codex (see below). `docs/` — README images.

## Build, test, release

- Swift package, macOS 14+, swift-tools 5.10. `swift test`; `./Scripts/package_app.sh`
  builds `build/AI Runs.app` (local identity when available, otherwise ad hoc; bundle ID `io.github.alextang809.airuns`,
  `LSUIElement`), copying `Resources/AppIcon.icns` and `BrowserExtension/`.
- Cloud sessions have **no Swift toolchain**. Push and let CI compile:
  GitHub Actions on macOS 15 (Swift 6.1) and macOS 26 (Swift 6.3) run
  `swift test`, signing-script tests and the extension test on every push. Read failures from the job
  logs. Write Swift that compiles under strict concurrency on both.
- Release: bump `VERSION` and `BrowserExtension/manifest.json`, then push a tag
  `vX.Y.Z`; `.github/workflows/release.yml` builds and attaches `AI-Runs.zip`.
  Pushing tags is refused from Claude cloud sessions; Alex pushes them from his Mac.
- `gh` GraphQL is blocked in Claude cloud sessions: open PRs with the REST API
  (`gh api repos/alextang809/ai-runs/pulls -f title=… -f head=… -f base=main -f body=…`).
- On Alex's Mac, `~/ai-runs` is Codex's working copy; builds happen in the
  worktree `~/ai-runs-build` (`git fetch && git checkout --detach origin/main &&
  ./Scripts/install_local.sh`). Keep one copy only, `/Applications/AI Runs.app`:
  several copies with the same bundle ID confuse macOS permissions.
- Signing: `./Scripts/make_signing_identity.sh` creates or reuses the self-signed
  "AI Runs Local Signing" identity and signs a temporary probe to check key access.
  If macOS asks, enter the login keychain password in its dialog and choose
  **Always Allow** for `codesign`. The script never reads that password. Keep
  the same identity; do not recreate it merely because it is self-signed.
  `install_local.sh` requires this identity and validates the built signature
  before stopping the installed app. Default `package_app.sh` still supports
  ad-hoc packaging for CI; those builds can lose Accessibility after updates.

## Design rules

- Simple and clear; everything important visible without hovering.
- **Colour means the tool**: Claude clay `#D97757`, OpenAI ink (black, white in
  dark mode) for Codex and ChatGPT. Everything else grey. State is told by words
  (APPROVE, NEEDS INPUT, REPLIED, WORKING, SCHEDULED, BACKGROUND, DONE) and by how
  the colour is applied: solid = needs you, outline = working, light = replied,
  grey = done or background.
- Logo: a **fermata** (arc over a dot), "hold until the conductor gives the cue".
  Menu bar: arc alone = idle, arc + dot = working, amber dot + count = holding
  for you. Amber `#E8890C` belongs to the logo only. No traditional Chinese
  cultural motifs in branding.
- When unsure, say so rather than guess: REPLIED instead of a wrong DONE.
- Interface text is English. Alex talks to agents in Chinese.

## Behaviour decisions worth keeping

- Keep the provider title for navigation. Display the current topic from user prompts in session lists. A name chosen by the user in AI Runs takes precedence. Pinning follows the live session. Save Reply captures the visible reply independently of later turns.
- "Remove" hides a session until the user prompts it again or it asks for
  approval; Undo for 6 s.
- Notifications: APPROVE and NEEDS INPUT on by default; REPLIED and DONE off;
  one reminder after 15 min; withdrawn when the moment ends; none while the user
  is in that session's app.
- Floating window: auto-expand is off by default.
- Hooks are only ever added or removed by entries whose command contains
  `airuns-hook`; each config file is backed up once as `*.airuns-backup`.
  Codex hook changes need the user's approval again, so don't change them lightly.

- "Hold until…" (replaces "Ignore for Now" for new actions): a held run leaves
  Needs you and the count and sits on the On hold line until its time (Today +3 h,
  a day at 9:00, or Waiting: check back in two days). When due it comes back to
  Needs you with "Back from hold" and counts until opened; no notification. APPROVE
  can't be held, and an approval ends a hold. Rows ignored by earlier versions keep
  their Ignored section and "Stop Ignoring".

## Privacy

The repo is public. Never commit conversation text, thread titles, prompts,
anything read from `~/.claude`, `~/.codex` or `~/Library`, tokens, or personal
paths beyond `~`. Describe formats with field names and made-up values. AI Runs
keeps session tracking and token-history processing local. Optional managed
ChatGPT, Claude, and Qwen Subscription connections use isolated CLI profiles.
DeepSeek and Qwen API connections
store API keys in the macOS Keychain and query read-only endpoints over HTTPS.
Account connections do not import native credentials or send conversations to
an AI Runs service. Keep account quota distinct from recorded local token totals.

## Working with Codex

Codex runs on Alex's Mac and can read what cloud sessions can't. Exchange happens
through `collab/`: one note per agent per round in `collab/rounds/NN-<agent>.md`
with the headings Did / Found / Ideas / Asks / Needs from Alex; Codex delivers on
`codex/round-NN`. Decisions go in `collab/DECISIONS.md`. Don't edit files Codex is
told to own in a round.
