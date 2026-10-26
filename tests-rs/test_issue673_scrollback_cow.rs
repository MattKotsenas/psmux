// Issue #673 part 1: a copy mode snapshot must SHARE the scrollback rows with
// the live grid, copy on write, instead of deep copying the whole history.
//
// Measured on the merged PR #671 tree, one pane at 200 columns with
// `history-limit 60000` filled to `history_size 49953`:
//
//   BEFORE copy mode : working set 197.1 MB  private 191.9 MB
//   IN     copy mode : working set 378.0 MB  private 378.4 MB
//   AFTER  copy mode : working set 199.6 MB  private 192.0 MB
//
// so opening copy mode cost 186.5 MB of private bytes, and repeated enter and
// leave cycles plateaued 61 MB above the baseline. `Parser::snapshot` cloned
// `Screen`, `Screen` cloned `Grid` and `Grid` deep copied every retained row.
//
// A retained row is immutable: `Grid::scroll_up` compacts it once as it becomes
// history (issue #641) and nothing ever writes to it again, which is exactly
// the shape that wants sharing. tmux copies the grid in `window_copy_init`
// (window-copy.c) too, so the snapshot itself is parity; what is not parity is
// paying for the history twice when neither copy can change a single cell of
// it.
//
// These tests pin the sharing by ADDRESS: a retained row must live at the same
// address in the snapshot as in the live grid. They are written so they also
// compile against the pre fix tree, where the rows sit inline in the deque and
// every address differs.

/// The text of one row, used to compare an indexed read with a walked one.
fn row_text(row: &crate::row::Row) -> String {
    let mut out = String::new();
    row.write_contents(&mut out, 0, 80, false);
    out
}

/// A parser holding `lines` rows of history behind a small visible screen.
fn parser_with_history(lines: usize, scrollback_len: usize) -> crate::Parser {
    let mut parser = crate::Parser::new(5, 40, scrollback_len);
    for i in 0..lines {
        parser.process(format!("line {i}\r\n").as_bytes());
    }
    parser
}

/// The address of every row currently held in the scrollback.
///
/// The `let row: &Row` step is a deref coercion when the rows are shared and a
/// plain reborrow when they are not, so this reads both the fixed and the
/// pre fix layout and answers the same question: where does this row live.
fn scrollback_addrs(parser: &crate::Parser) -> Vec<usize> {
    parser
        .screen()
        .grid()
        .scrollback
        .iter()
        .map(|r| {
            let row: &crate::row::Row = r;
            row as *const crate::row::Row as usize
        })
        .collect()
}

fn visible_text(parser: &crate::Parser) -> String {
    parser.screen().contents()
}

/// The whole point: the snapshot's history is the live grid's history, not a
/// copy of it.
#[test]
fn a_snapshot_shares_every_retained_row_with_the_live_grid() {
    let live = parser_with_history(2000, 60000);
    let retained = live.screen().scrollback_filled();
    assert!(retained >= 1990, "fixture must actually fill the history, got {retained}");

    let snapshot = live.snapshot();

    let live_rows = scrollback_addrs(&live);
    let snap_rows = scrollback_addrs(&snapshot);
    assert_eq!(
        live_rows.len(),
        snap_rows.len(),
        "the snapshot must hold the same history depth as the live grid"
    );
    let shared = live_rows
        .iter()
        .zip(snap_rows.iter())
        .filter(|(a, b)| a == b)
        .count();
    assert_eq!(
        shared,
        live_rows.len(),
        "every retained row must be SHARED with the live grid, not copied: \
         {shared} of {} rows share an address",
        live_rows.len()
    );
}

/// Sharing must not make the snapshot follow the live grid. Rows pushed after
/// the snapshot belong to the live grid alone, and rows the live grid evicts
/// stay readable through the snapshot that still holds them.
#[test]
fn the_shared_history_is_still_frozen_for_the_reader() {
    let mut live = parser_with_history(300, 500);
    let snapshot = live.snapshot();
    let depth_at_snapshot = snapshot.screen().scrollback_filled();
    let frozen_addrs = scrollback_addrs(&snapshot);
    let frozen_text = visible_text(&snapshot);

    // The application keeps printing, far past the cap, so the live grid both
    // appends and evicts.
    for i in 0..2000 {
        live.process(format!("after {i}\r\n").as_bytes());
    }

    assert_eq!(
        snapshot.screen().scrollback_filled(),
        depth_at_snapshot,
        "the snapshot's history depth must not move with the live grid"
    );
    assert_eq!(
        scrollback_addrs(&snapshot),
        frozen_addrs,
        "the snapshot must keep exactly the rows it captured, including the \
         ones the live grid has since evicted"
    );
    assert_eq!(
        visible_text(&snapshot),
        frozen_text,
        "the snapshot's visible screen must not move with the live grid"
    );
    assert!(
        visible_text(&live).contains("after 1999"),
        "the live screen must keep running underneath the snapshot"
    );
}

/// The visible rows are the part the application still writes to, so they are
/// copied, not shared: drawing into the live screen must not reach the frozen
/// one.
#[test]
fn the_visible_rows_are_a_private_copy() {
    let mut live = parser_with_history(50, 1000);
    live.process(b"VISIBLE MARKER\r\n");
    let snapshot = live.snapshot();
    assert!(visible_text(&snapshot).contains("VISIBLE MARKER"));

    live.process(b"\x1b[2J\x1b[HOVERWRITTEN\r\n");

    assert!(
        visible_text(&snapshot).contains("VISIBLE MARKER"),
        "clearing the live screen must not clear the snapshot the user reads"
    );
    assert!(
        !visible_text(&snapshot).contains("OVERWRITTEN"),
        "the snapshot must not show what was drawn after it was taken"
    );
}

/// Reading the visible region row by row is what `capture-pane -S` does, and it
/// must stay a direct index into the history.
///
/// Handing the shared rows out through an iterator adaptor cost that its O(1)
/// `nth`, which turned a capture over a 50000 line history into a quadratic
/// walk: the real server answered `capture-pane -p -S -1000` in 363 ms before
/// and then timed out entirely. This walks a deep history the way a capture
/// does and pins the answers against the iterator.
#[test]
fn every_visible_row_is_reachable_by_index_without_walking_the_history() {
    let mut parser = crate::Parser::new(24, 80, 60000);
    for i in 0..20000 {
        parser.process(format!("line {i}\r\n").as_bytes());
    }

    for offset in [0usize, 1, 23, 24, 25, 1000, 19000] {
        parser.screen_mut().set_scrollback(offset);
        let walked: Vec<String> = parser
            .screen()
            .grid()
            .visible_rows()
            .map(row_text)
            .collect();
        let indexed: Vec<String> = (0..walked.len() as u16)
            .map(|r| {
                parser
                    .screen()
                    .grid()
                    .visible_row(r)
                    .map(row_text)
                    .unwrap_or_else(|| panic!("row {r} missing at offset {offset}"))
            })
            .collect();
        assert_eq!(
            indexed, walked,
            "indexed reads must answer exactly what the iterator yields at offset {offset}"
        );
    }

    // A capture of the whole history, one row at a time, the way the server
    // serialises it. On the quadratic path this does not finish in minutes.
    parser.screen_mut().set_scrollback(19000);
    let started = std::time::Instant::now();
    let mut seen = 0usize;
    for _ in 0..500 {
        for r in 0..24u16 {
            if parser.screen().grid().visible_row(r).is_some() {
                seen += 1;
            }
        }
    }
    assert_eq!(seen, 500 * 24);
    assert!(
        started.elapsed() < std::time::Duration::from_secs(2),
        "reading {seen} rows out of a deep history took {:?}: the read is walking the scrollback",
        started.elapsed()
    );
}

/// Two readers of the same pane (psmux allows several panes in copy mode, and
/// the same pane can be snapshotted again after leaving) must still share one
/// copy of the history between them.
#[test]
fn several_snapshots_share_one_copy_of_the_history() {
    let live = parser_with_history(1000, 60000);
    let first = live.snapshot();
    let second = live.snapshot();

    let live_rows = scrollback_addrs(&live);
    assert_eq!(scrollback_addrs(&first), live_rows);
    assert_eq!(scrollback_addrs(&second), live_rows);
}
