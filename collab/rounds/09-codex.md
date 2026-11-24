# Round 9 — Hold timeline acceptance on the Mac

## Did

- Read the approved design and the round 9 brief. Built the Release binary from `claude/hold-timeline` at `9e9938d` on Apple silicon, macOS 26.5.2. Installed it at `/Applications/AI Runs.app` with AI Runs Local Signing and confirmed that it launched. The installed executable's Mach-O UUID matches the Release build.
- The first build in Documents picked up Finder metadata on the bundle and failed at signing. Packaging the same source from a clean temporary directory signed and installed successfully.
- Exercised the real menu and floating panel classes in an isolated XCTest process using synthetic sessions, native events, and the accessibility tree. Another app remained frontmost in the panel probes. The probes used the same source as the installed build and a separate temporary data directory. Release installation and native probe execution were separate checks.
- The original Swift suite passed all 453 tests locally. The temporary acceptance harness is outside the branch. This commit contains the acceptance note.

## Found

### Brief checklist

| Check | Observation |
|---|---|
| 1. Day, Today and Waiting drag | Main menu Today lowered Needs You from 12 to 11, kept the menu open and left hover details hidden while the drag was active. Its height change measured 0 pt. Floating accepted Waiting, a named date 2 pt inside its right edge, and Today, bringing the fixture count from 6 to 3. The date measured 42 pt on Tuesday. The floating panel shrank by 2 pt as an empty dock entered its drag state. The floating probe delivered events directly to the panel; installed-app input routing and physical mouse/trackpad precision remain unverified. |
| 2. Scroll then drag | Successfully scrolled the native main-menu list with 16 fixtures and dragged a newly visible row 2 pt inside the left edge of the next date (52.5 pt wide). The deadline matched the chosen date and the count dropped to 15. The scroll probe used the native scroll view programmatically. |
| 3. Escape and drop outside | In the menu, Escape during a drag made no change, left the panel open, and a later drag still worked. An outside drop also made no change. With another app key, physical Escape in the float remains unverified; the float's handler is a local key-event monitor (`HoldViews.swift:105–111`). |
| 4. Pin and bring back | Drag-to-Pin and dragging a held tray row to Bring back now both worked in the main menu. The held row returned to the original count. Floating top-target gestures remain unverified. |
| 5. Waiting editor | The field appeared in the correct surface. The menu was key, the field reported focus immediately, and typing followed by Return saved the name. After the floating drop, the float was still non-key and the visible field reported no focus. Immediate typing, click-away commit and leaving the field empty need a physical-input pass on the float. |
| 6. Approval | A fixture approval rejected a new Hold. Feeding a synthetic approval event to a held row immediately cleared the hold and restored the approval state. The branch's AlertPlanner test covers the normal approval alert path; OS notification delivery was not exercised in the fixture. |
| 7. Coming due and open | A short real deadline followed by refresh moved the fixture count from 2 to 3 and set Back from hold. Core tests cover a missed deadline, the silent notification path, and the before-due/open and acknowledgement rules. I left the system clock and power state alone. Physical sleep/wake, visible status-item and capsule updates at expiry, and opening a real source client were not tested end to end. |
| 8. Menu flyout | AX-pressing Hold Until… in the live menu flyout opened an AppKit menu containing the Tomorrow item. The panel stayed open when the popup was dismissed. |
| 9. VoiceOver actions | The native AX action for Tomorrow successfully held a row, and the tray exposed Bring Back Now. The same AX inspection revealed actions offered in ineligible states (below). VoiceOver speech and navigation were not run. |
| 10. Legacy Ignore | The legacy fixture appeared under Ignored, with the ignored state readable in the native tree. Hold then Undo did not restore its previous ignored status. See below. |

### Corrections before merging

1. **Floating Waiting does not get keyboard focus in the native probe.** `HoldViews.swift:702–714` selects the field with FocusState, but `FloatingPanel.swift:55–58` leaves the panel nonactivating and key only when needed. The field appeared with both the panel key flag and AX focused flag false. Arrange temporary keyboard focus for an explicit name edit, then verify the float returns focus after Return or clicking away.
2. **A weekend deadline is displayed under Monday.** A controlled Friday 10:00 calendar probe produced a real Saturday 09:00 deadline for Tomorrow, but the label was Mon and the full-date fallback was false. `Hold.swift:78–85,121–151` falls back to the last visible segment. `HoldViews.swift:671–675,722–727` can omit the deadline on the first row. Show the actual weekend date in the timeline or in an explicitly labelled weekend segment.
3. **Waiting again after a return silently fails.** Reproduced from an expired waiting hold. `AppModel.swift:542–547` reuses its elapsed deadline and `SessionStore.swift:707–712` rejects it. For a returned hold, choose a new deadline and retain the waiting label.
4. **Undo loses a legacy Ignore.** Reproduced with three rows. Before Hold, two required attention. After converting the ignored row and undoing, all three counted. `SessionStore.swift:710` clears the legacy flag and `AppModel.swift:574–589` saves only the previous hold. Restore the previous ignore value along with the previous hold.
5. **AX exposes actions that silently do nothing.** A normal native row exposed Bring Back Now before being held, and an approval row exposed Hold Until. `HoldViews.swift:809–817` registers both and only checks eligibility in the handlers. Expose each action only when available.
6. **The floating click path repeats Hold.** Confirmed by source inspection. Both the inline details and the hover capsule wrap `HoldMenuItems` in a menu even though those items already contain a Hold Until submenu. Keep one menu level. See `FloatingWindow.swift:478–481,549–553` and `HoldViews.swift:228–244`.

### Additional source risks to check

- `HoldViews.swift:61–64,156–164` commits the last hover rather than hit-testing the release position. Test rapid releases at day boundaries. The same file's empty placeholder changes padding on drag (`383–394,430`), consistent with the 2 pt float measurement.
- The expanded tray is outside the main scrollers and uses an unbounded stack (`HoldViews.swift:438–443,648–668`). Verify that a heavily populated date can still be opened and scrolled on a short screen.
- `AppModel.swift:515–520,568–571` acknowledges the current returned hold by session ID when an async open finishes. Match the marker opened by the user, so a later hold on the same session cannot be acknowledged by an older callback. Also decide whether intentional Holds should contribute to Agents waited on you. The current span logic still counts held input waits (`SessionStore.swift:707–712`, `Timeline.swift:37,89–92`).

## Ideas

Keep the shared dock at the bottom for the next pass. The empty overlay makes the drop path easy to find without a large layout change. Give the placeholder and its drag state exactly the same height. The existing menu path is a practical fallback for either panel if physical drag accuracy is inadequate.

Prioritise the focus and date fixes, then verify the transition edges. The user should be able to trust exactly when an item will come back, with the same deadline in the menu, timeline and tray.

## Asks

Claude owns the implementation files. Please address the reproduced cases above before the next acceptance pass, then send a buildable commit for physical mouse and trackpad testing and an installed-app sleep/wake and source-opening pass. Keep the branch's independent silent-return policy.

## Needs from Alex

The Hold build is installed for trying on the Mac. The main checks that benefit from a physical pass are dropping close to the edge of a date and typing immediately after dropping onto Waiting in the float. The accepted bottom dock can stay in both windows for that pass.
