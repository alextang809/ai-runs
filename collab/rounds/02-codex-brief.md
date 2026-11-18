# Round 2 brief for Codex: show Claude *threads*, not just local sessions

## The problem

Alex had 2–3 Claude threads running at once; AI Runs showed one row. What AI Runs received
(from `~/.airuns`, 2026-11-18 ~16:27–16:41 SGT): events from exactly **one** Claude Code
`session_id`, host `com.anthropic.claudefordesktop`, whose desktop title is the generic
"Local session (from a project)". Its prompts are not typed by Alex: earlier ones started with
`<wake reason="mention" …> <project id="chan_…" type="project"> <thread ts="cmsg_…" …>` or
`<relay from="coordinator" session="session_…" …>`.

So in Claude a **thread** (what Alex sees under a project's Threads) is not the same thing as a
local Claude Code session. Our working guess, unverified:

- a project's threads live in the cloud; a coordinator ("task distributor") hands work to them;
- one local session on the Mac is woken or relayed to for several threads, so they collapse
  into one row;
- threads that do all their work in the cloud never fire a local hook, so they are invisible.

Alex wants one row per thread, named as Claude names it.

## Find out (structure only — tag names, attribute names, field names, counts)

Claude (cloud) cannot read `~/.claude` or `~/Library/Application Support/Claude`; you can.

1. **Prompt wrappers.** In the transcript of a local session driven by a project, list the
   wrapper tags of user messages (`wake`, `relay`, `project`, `thread`, `task-notification`, …)
   with their attribute names and nesting. Which attribute identifies the thread? Is the
   thread's name anywhere in the wrapper? Where does the wrapper end and the actual request
   begin? Give a made-up example with the same shape.
2. **One session or many?** While two project threads are working, how many local Claude Code
   sessions exist (distinct transcript files being written, distinct `session_id`s in
   `~/.airuns/events.jsonl`)? Does one session serve several threads in turn?
3. **Where threads are stored.** Does the Claude desktop app keep a list of project threads on
   disk (name, thread ID like `cmsg_…`, project ID like `chan_…`, running / waiting / done,
   last activity, which local session serves it)? Look under
   `~/Library/Application Support/Claude/` beyond `claude-code-sessions/`. Field names only.
4. **Cloud-only threads.** Is there any local trace of a thread that works only in the cloud
   (no local session)? If not, say so plainly.
5. **Accessibility.** With Claude's window open on a project's Threads list, does its
   accessibility tree expose each thread's name and a running/waiting indicator? Report roles
   and which attribute holds the name; no thread names. (AI Runs already presses sidebar rows
   through Accessibility in `Sources/AIRunsApp/SidebarClicker.swift`.)
6. **Jumping.** Is there a link or other way to open a specific project thread in the app?

## Your ideas

How would you model "thread" so that a Claude project thread, a plain local Claude Code session,
a Codex thread and a web chat each get one honest row? What should a row say when we know a
thread exists but can't see its state?

## Deliver

Branch `codex/round-02`, note in `collab/rounds/02-codex.md` (the five headings). Pull `main`
first. Same rules as before: nothing private in the repo, read-only outside it, no edits to
`Sources/`.
