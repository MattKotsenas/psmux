# Program status (OSC 7501)

Programs can report their state with [OSC 7501](https://www.superlogical.com/rex/docs/build/program-status), revision 0.4. Support is off by default; `set -g program-status on` enables collection and capability replies. psmux provides both the complete records for custom consumers and a representative status for each pane and window.

## Which status is shown

psmux picks one report to represent each pane, then one of those to represent the window. All panes count, including floating panes and panes kept after their program exits. Reports are picked in this order:

1. Waiting for input (`blocked`).
2. An error you haven't seen (`error`).
3. A successful completion you haven't seen (`done`).
4. Work still running (`working`).
5. Idle programs and results you've already seen.

If several reports have the same priority, the one whose contents changed most recently wins. Sending the same report again doesn't move it ahead or mark it unseen. For changes at exactly the same time, record ids break ties within a pane and pane ids break ties across panes. The selected pane gets no special treatment: a task in another pane can represent the window.

The summary keeps the chosen report's state and details, along with its pane, record id, and whether you've seen it. Reports don't set output-activity flags, ring a bell, or trigger desktop notifications. A window with no reports has no summary.

## When a result is seen

Selecting a pane, or switching to a window, marks that pane's current done/error results as seen. Other clients see the same flag. The reported state stays done/error. After a result is marked seen, another report can take its place in the summary, such as a task still running in a sibling pane.

Blocked reports remain until the program updates them or they expire. A result that arrives while you stay in a pane stays unseen until you leave and return. Selecting the pane you're already in doesn't mark anything seen.

Only results already recorded when you return are marked seen. Results recorded afterward stay unseen. Status continues to update while copy mode freezes the pane's contents.

## Formats and inspection

Both `pane_ps_` and `window_ps_` formats use the same selection policy. Pane formats select across the pane's root and child records; window formats select across the entire window.

| Format suffix | Meaning |
|---|---|
| `state` | Reported state: idle, working, blocked, done, or error |
| `id` | Selected record id; empty for the root |
| `kind` | Blocked kind |
| `progress` | Percentage; empty for indeterminate, `0` for zero |
| `app` | Application identifier inherited from the nearest explicit ancestor |
| `seen` | `1` for an acknowledged result, otherwise `0` |

`window_ps_pane` identifies the source pane, such as `%12`. Absent summaries or fields expand to empty; test `state` to distinguish absence from a root record with an empty id. Titles and messages have no format variables. These names are psmux extensions, not a claim of tmux OSC 7501 support.

The window objects in `dump-state` frames include optional `ps_status` with the selected pane, id, state, kind, progress, app, and seen flag. It includes working, idle, and acknowledged results. `list-windows -J` adds `ps_panes`: every pane's records with id, state, kind, progress, inherited app, title, msg, and seen. No records are discarded by aggregation; custom consumers can implement their own ordering. Frames omit `ps_panes`, titles, and messages so application text is not pushed to every client on every redraw.

Titles and messages remain literal, untrusted JSON text. Inspection tools must never execute them as markup or commands.

## Opt in to presentation

The default tab formats match tmux and show no program status. A font-independent example that shows every selected state is:

```tmux
set -g program-status on
set -g window-status-format '#I:#W#{?window_flags,#{window_flags},#{?window_ps_state,, }}#{?window_ps_state, [#{window_ps_state}],}'
set -g window-status-current-format '#I:#W#{?window_flags,#{window_flags},#{?window_ps_state,, }}#{?window_ps_state, [#{window_ps_state}],}'
```

Without records this matches the stock tab. With a report it reads `1:pwsh [working]` or `1:pwsh* [blocked]`, without a double space. An acknowledged done/error remains a reported result in this simple example. Custom formats can use `window_ps_seen` to choose how to style a result you've seen. Configure both active and inactive formats, including window-local overrides.

Output and silence monitoring are separate. Configure `monitor-activity off` and `monitor-silence 0` if you only want program status in your tabs.

## Reporting and lifetime

`program-status` is the single switch. While off, OSC 7501 is an unknown sequence: reports are not stored and the `OSC 7501 ; ?` capability query draws no reply. Format variables alone do not turn it on. Turning it off, or `set -gu program-status`, withdraws all stored records.

For example, a shell script can send:

```sh
printf '\033]7501;state=working:app=build\033\\'
# Run the work, then report its result.
printf '\033]7501;state=done:app=build\033\\'
# Withdraw all records when they are no longer relevant.
printf '\033]7501;state=clear\033\\'
```

BEL is also accepted as a terminator. With `program-status` on, psmux replies to `OSC 7501 ; ? ST` through the pane input pipe before a following primary-device-attributes reply. Reports are consumed locally, not forwarded to the outer terminal.

The root record has no id. Children use slash-separated ids, replace their own record completely, and inherit app from their nearest ancestor with an explicit app. A hierarchical clear removes the addressed record and its descendants. Each pane holds at most 64 records, evicting the least recently updated record when full.

Primary/alternate screen switches and soft resets preserve records. Full reset (RIS) clears them. A new shell prompt (`OSC 133 A`) or attached-process exit removes idle, working, and blocked records; done/error survive. Respawning the pane clears records and acknowledgement. Records are not persisted across server restarts.

Validation runs before record mutation and checks field limits, ids, base64, UTF-8, and decoded control characters. Completed reports use a 4096-byte dispatched-sequence budget, including standard OSC/terminator framing. Existing OSC intake behavior is unchanged, including ignored control bytes, termination semantics, and temporary buffering of unterminated sequences. This feature adds no general OSC or clipboard memory limit.

## Windows console detection

Certain versions of ConPTY swallow the OSC reply and answer DA1 themselves, so programs can fail to detect support even when psmux implements the protocol. With psmux's default console host, updating Windows Terminal alone does not replace the ConPTY version used for its panes.
