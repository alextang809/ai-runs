# Round 2a brief for Codex: why Bartender keeps moving AI Runs to Always Hidden

Alex drags AI Runs into Shown Items in Bartender 6 (6.4.2, macOS 26.5.2); Bartender later puts it
back into Always Hidden. Find out why, with evidence. Read-only except where noted.

## Suspects (Claude's, unverified)
1. **Identity change.** Builds before `cd0873a` had no `autosaveName` (macOS called it `Item-0`);
   newer builds use `AIRunsStatusItem`. Each change looks like a brand-new item, and Bartender puts
   new items wherever its "new menu bar items" setting says.
2. **Image churn.** Until commit `aadfb35` the app replaced the status item's image on every
   store update (about once a second while a session works), and switches between a template image
   and an orange one when something needs Alex. Bartender on macOS 26 matches items partly by what
   they look like; churn may make it lose the match.
3. **Bartender 6.4.2 itself.** Later 6.x releases list layout fixes.

## Find out
- Bartender 6's preferences (`defaults read com.surteesstudios.Bartender` or the plist under
  `~/Library/Preferences/`; check the actual domain): how is AI Runs stored (key, identifier,
  section)? Is there more than one AI Runs entry (old `Item-0`, new `AIRunsStatusItem`)? What is the
  setting for where new menu bar items go?
- Reproduce with Alex's help: drag AI Runs to Shown, then (a) wait while a session works,
  (b) let a session finish so the orange count appears, (c) quit and reopen AI Runs. Which one sends
  it back to Always Hidden?
- Does Bartender 5 run, or have a login item, alongside Bartender 6?

## Rules
Don't edit Bartender's preferences yourself; tell Alex what to change. Write findings in
`collab/rounds/02a-codex.md` on branch `codex/round-02a`. Pull `main` first.
