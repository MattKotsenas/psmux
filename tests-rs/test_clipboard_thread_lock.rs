// The Win32 clipboard lock does not keep two threads of one process apart.
//
// `OpenClipboard(NULL)` on a second thread succeeds while the first thread
// still has the clipboard open, so a read on one thread (GetClipboardData,
// GlobalLock, GlobalSize) could run while another thread's EmptyClipboard
// freed the very handle it was reading. Under full page heap that is a
// verifier stop in USER32!GetClipboardData (block already freed); without it,
// an occasional STATUS_HEAP_CORRUPTION of the whole process. The server reads
// the clipboard on a connection thread while its main loop writes it, so this
// is not test only. clipboard.rs now serializes every Win32 clipboard section
// in the process on one mutex.

use super::*;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Barrier};

/// The OS does not serialize threads of one process: a second thread opens
/// the clipboard while the first holds it. This is what made the mutex
/// necessary, so if Windows ever starts refusing, this test says so.
#[cfg(windows)]
#[test]
fn a_second_thread_of_the_process_can_open_a_clipboard_the_first_holds() {
    let _g = CLIPBOARD_SECTION.lock().unwrap_or_else(|e| e.into_inner());
    let opened = unsafe { OpenClipboard(std::ptr::null_mut()) };
    if opened == 0 {
        // Another process holds it right now; nothing can be learned.
        return;
    }
    let other = std::thread::spawn(|| {
        let r = unsafe { OpenClipboard(std::ptr::null_mut()) };
        if r != 0 {
            unsafe { CloseClipboard() };
        }
        r != 0
    })
    .join()
    .unwrap();
    unsafe { CloseClipboard() };
    assert!(
        other,
        "Windows now refuses a second thread of the same process; the in process lock is still harmless"
    );
}

/// Reads and writes from several threads at once must never touch a freed
/// clipboard handle. Before the mutex this crashed the test process under
/// page heap within a few hundred rounds; the assertion is that every read
/// returns one of the strings some thread wrote.
#[cfg(windows)]
#[test]
fn concurrent_reads_and_writes_never_see_a_freed_handle() {
    let _g = TEST_CLIPBOARD_CONTENTS.lock().unwrap_or_else(|e| e.into_inner());
    let before = read_from_system_clipboard();
    let words: Vec<String> = (0..4).map(|i| format!("PSMUX_CLIP_RACE_{i}")).collect();
    let stop = Arc::new(AtomicBool::new(false));
    let start = Arc::new(Barrier::new(words.len() + 2));
    let mut handles = Vec::new();
    for w in words.clone() {
        let (stop, start) = (stop.clone(), start.clone());
        handles.push(std::thread::spawn(move || {
            start.wait();
            for _ in 0..150 {
                if stop.load(Ordering::Relaxed) {
                    break;
                }
                copy_to_system_clipboard(&w);
            }
        }));
    }
    let reader = {
        let (stop, start, words) = (stop.clone(), start.clone(), words.clone());
        std::thread::spawn(move || {
            start.wait();
            let mut odd = Vec::new();
            for _ in 0..600 {
                if let Ok(Some(t)) = try_read_from_system_clipboard() {
                    if t.starts_with("PSMUX_CLIP_RACE_") && !words.contains(&t) {
                        odd.push(t);
                    }
                }
            }
            stop.store(true, Ordering::Relaxed);
            odd
        })
    };
    start.wait();
    for h in handles {
        h.join().unwrap();
    }
    let odd = reader.join().unwrap();
    if let Some(prev) = before {
        copy_to_system_clipboard(&prev);
    }
    assert!(odd.is_empty(), "torn clipboard reads: {odd:?}");
}
