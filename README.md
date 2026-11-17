<p align="center"><img src="docs/icon.png" width="128" alt="AI Runs icon"></p>

# AI Runs

A small macOS menu bar app for people who run several AI sessions at once.
It shows which Claude Code and Codex sessions are still working and which are
waiting for you, lets you jump straight back to the right terminal tab, and
keeps a pinned board of the threads and ideas you don't want to lose track of.

Everything stays on your Mac. There is no server and no account.

## What it does

- **Active** — every Claude Code and Codex session appears automatically.
  Sessions that need you (a finished turn, or a permission prompt) sit at the
  top with how long they have been waiting. Click one to bring its Terminal,
  iTerm2 or VS Code window back.
- **Hover for details** — hover a session to see when it started, what it wants
  to run, and its last reply, with Open, Pin to Board, Rename and Resolve.
- **Pinned** — keep the threads you are working on, grouped by project. Each
  card has one line for the next step; when you pin a session, the next step is
  suggested from the AI's last question. Cards nobody touched for three days
  move to "Maybe done".
- **Continue in a New Chat** — copies a short summary of a card so a long,
  crowded conversation can be split into a clean new one.
- **Floating board** — show the pinned board as a small window that stays on
  top, and drag text or links onto it to make cards.
- **Pin Front AI Window** — pins the browser tab (Safari, Chrome, Arc, Brave,
  Edge) or app you were just using.

The menu bar icon shows a number when sessions are waiting for you.

## How it works

AI Runs installs [hooks](https://code.claude.com/docs/en/hooks) for Claude Code
and [Codex](https://developers.openai.com/codex/hooks). Each hook runs
`~/.airuns/bin/airuns-hook`, a tiny helper that appends one line to
`~/.airuns/events.jsonl` and exits. The app reads that file, so it never slows
the agents down and does not miss events while it is closed.

| Tool        | Config file               | Events                                                                  |
| ----------- | ------------------------- | ----------------------------------------------------------------------- |
| Claude Code | `~/.claude/settings.json` | UserPromptSubmit, Stop, PermissionRequest, Notification, PostToolUse, SessionEnd |
| Codex       | `~/.codex/hooks.json`     | UserPromptSubmit, Stop, PermissionRequest, PostToolUse                   |

The installer only adds or removes entries whose command contains
`airuns-hook`, and backs up each file once (`*.airuns-backup`) before the first
change. After installing for Codex, run `/hooks` in Codex once and trust the new
hooks.

## Build and run

Requires macOS 14 or later and Xcode 16 (or the Swift 6 toolchain).

```sh
git clone https://github.com/alextang809/ai-runs.git
cd ai-runs
./Scripts/package_app.sh
open "build/AI Runs.app"
```

On first launch AI Runs opens its settings so you can install the hooks. The
first time you jump to a Terminal or iTerm2 tab, macOS asks whether AI Runs may
control that app; allow it so the right tab comes to the front.

Run the tests with `swift test`.

## Project layout

- `Sources/AIRunsCore` — event parsing, the session state machine, the pinned
  board, the event log and the hook installer. No UI; fully unit tested.
- `Sources/airuns-hook` — the helper the hooks call.
- `Sources/AIRunsApp` — the menu bar app (AppKit + SwiftUI).
- `Scripts/package_app.sh` — builds `AI Runs.app`.

## Known limitations

- Jumping to the exact tab works for Terminal and iTerm2. VS Code and Cursor
  open the project folder; other terminals are brought to the front and the
  `claude --resume` / `codex resume` command is copied to the clipboard.
- GitHub Copilot in VS Code can load hooks from `~/.claude/settings.json`, so
  its agent sessions may appear as Claude Code sessions.
- Desktop chat apps (ChatGPT, Claude) don't report progress; pin them with
  Pin Front AI Window and track them on the board.

## Clicking a session

One click takes you back to where the session lives, in the app you use for it.
You never have to paste a command.

| The session runs in | Click does |
|---|---|
| Terminal or iTerm2 | Selects its tab. If the tab was closed, reopens the session in a new tab, in its folder. |
| VS Code, Cursor | Opens the project window. |
| Codex app | Opens the exact thread (`codex://threads/<id>`). |
| Claude app | Brings Claude forward and selects the thread by its sidebar name (asks once for Accessibility). Otherwise it tells you the thread's name and copies it. |
| claude.ai, chatgpt.com | Pin the browser tab with Pin Front AI Window; the card opens that page. Automatic tracking needs the planned browser extension. |

Terminal users also get **Copy Resume Command** in the session's details.

## Roadmap

- Remaining usage for each tool
- Drop a screenshot to make a card, with the title read from the image
- GitHub Copilot CLI and VS Code agent hooks
- Browser extension for claude.ai and chatgpt.com conversations
- Global shortcut for Pin Front AI Window

## 中文简介

AI Runs 是一个 macOS 菜单栏小工具，给同时开很多个 AI 会话的人用：

- 自动列出 Claude Code 和 Codex 的会话，等你回复或等你批准的排在最上面，并显示等了多久，点一下回到对应的终端标签页；
- 鼠标停在会话上，可以看到开始时间、它想执行的命令和最后一条回复；
- 钉板：按项目分组记录正在推进的线程和碎片想法，每张卡片一句“下一步”，三天没动自动收进“Maybe done”；
- 钉板可以变成屏幕上常驻的小窗，往里拖文字或链接就生成卡片。

所有数据只存在本机的 `~/.airuns`。

## License

MIT
