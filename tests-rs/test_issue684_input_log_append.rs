// Issue #684 follow up: input_debug.log is written by TWO processes.
//
// The client decides whether a burst of characters is a paste; the server
// decides which channel carries that paste into the pane.  Both write
// input_debug.log, each through its own LazyLock that opens the file on its
// first line, and each keeps its own file offset.  With truncate(true) that
// meant:
//
//   * whichever process wrote second erased everything the first had written,
//     which is how every client [paste] line went missing from gabri-ns's
//     first pair of runs, and
//   * the first process's next write landed at its old offset and re-extended
//     the file over the hole, leaving 106,367 NUL bytes in the middle of it.
//
// Both halves are asserted here against a temporary directory, with two file
// handles standing in for the two processes.

use std::io::Write;

use crate::debug_log::{open_log_in, LogMode};

fn scratch(tag: &str) -> String {
    let dir = std::env::temp_dir().join(format!(
        "psmux_i684_log_{}_{}_{}",
        tag,
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    let _ = std::fs::create_dir_all(&dir);
    dir.to_string_lossy().into_owned()
}

#[test]
fn truncate_mode_lets_the_second_opener_erase_the_first() {
    let dir = scratch("trunc");
    let mut first = open_log_in(&dir, "t.log", LogMode::Truncate).expect("first open");
    writeln!(first, "client line").unwrap();
    first.flush().unwrap();

    // A second process opens the same path.
    let _second = open_log_in(&dir, "t.log", LogMode::Truncate).expect("second open");

    let body = std::fs::read(format!("{}/t.log", dir)).unwrap();
    assert!(
        body.is_empty(),
        "truncate is exactly the defect: the first writer's line is gone, got {:?}",
        String::from_utf8_lossy(&body)
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn append_mode_keeps_both_writers_and_leaves_no_hole() {
    let dir = scratch("append");
    let path = format!("{}/a.log", dir);

    // The client opens the file and writes for a while.
    let mut client = open_log_in(&dir, "a.log", LogMode::Append).expect("client open");
    for i in 0..200 {
        writeln!(client, "[client] event {}", i).unwrap();
    }
    client.flush().unwrap();
    let after_client = std::fs::metadata(&path).unwrap().len();
    assert!(after_client > 0);

    // The server opens the same file later and writes its paste decision.
    let mut server = open_log_in(&dir, "a.log", LogMode::Append).expect("server open");
    writeln!(server, "[server] route=pipe bracket=true text_len=490").unwrap();
    server.flush().unwrap();

    // The client keeps writing: with append this lands at the end, not at the
    // offset it held before, so no NUL hole is punched in the middle.
    writeln!(client, "[client] event after the server wrote").unwrap();
    client.flush().unwrap();

    let body = std::fs::read(&path).unwrap();
    let text = String::from_utf8_lossy(&body);
    assert!(text.contains("[client] event 0"), "the client's first line survived");
    assert!(text.contains("[client] event 199"), "the client's later lines survived");
    assert!(text.contains("[server] route=pipe"), "the server's line is there too");
    assert!(
        text.contains("[client] event after the server wrote"),
        "the client can still write after the server opened the file"
    );
    assert!(
        !body.contains(&0u8),
        "append must not leave a hole of NUL bytes behind"
    );
    assert!(
        body.len() as u64 > after_client,
        "the file grew, it was not rewound"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
