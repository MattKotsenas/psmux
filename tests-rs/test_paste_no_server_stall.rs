// A large paste must never hold the server thread.
//
// write_paste_bytes used to write 512 bytes and sleep 5 ms after each slice
// on the server thread, so a 132 KB paste froze every pane, client and CLI
// call for 1.4 s and a 1.3 MB one for 13.6 s.  It now hands the whole paste
// to the pane's queued writer (pane::spawn_pane_write_queue) and returns; the
// pane writer thread does the blocking pipe writes.
//
// These tests drive the real writer pair (write_paste_bytes into a real
// queue) over an inner writer that stands in for the ConPTY input pipe: one
// that is blocked (a child that is not draining), one that records every
// write call.  No PTY, no server.

use super::*;

use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

fn wait_until(mut cond: impl FnMut() -> bool, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if cond() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    cond()
}

/// The pipe: blocked until `open`, then records every byte and the size of
/// every write call.  Flags its own drop (the pane writer thread ended).
#[derive(Clone)]
struct Pipe {
    state: Arc<(Mutex<Vec<u8>>, Condvar)>,
    open: Arc<AtomicBool>,
    sizes: Arc<Mutex<Vec<usize>>>,
    dropped: Arc<AtomicBool>,
}

impl Pipe {
    fn new(open: bool) -> Self {
        Pipe {
            state: Arc::new((Mutex::new(Vec::new()), Condvar::new())),
            open: Arc::new(AtomicBool::new(open)),
            sizes: Arc::new(Mutex::new(Vec::new())),
            dropped: Arc::new(AtomicBool::new(false)),
        }
    }
    fn release(&self) {
        self.open.store(true, Ordering::SeqCst);
        // Lock then notify, so the wakeup cannot fall between the writer's
        // check of `open` and its wait.
        drop(self.state.0.lock().unwrap());
        self.state.1.notify_all();
    }
    fn bytes(&self) -> Vec<u8> {
        self.state.0.lock().unwrap().clone()
    }
}

struct PipeEnd(Pipe);

impl Write for PipeEnd {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let (lock, cv) = &*self.0.state;
        let mut bytes = lock.lock().unwrap();
        while !self.0.open.load(Ordering::SeqCst) {
            bytes = cv.wait(bytes).unwrap();
        }
        bytes.extend_from_slice(buf);
        self.0.sizes.lock().unwrap().push(buf.len());
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Drop for PipeEnd {
    fn drop(&mut self) {
        self.0.dropped.store(true, Ordering::SeqCst);
    }
}

fn payload(n: usize) -> Vec<u8> {
    // Printable lines, LF separated, so normalisation has work to do.
    let mut v = Vec::with_capacity(n);
    let mut i = 0u32;
    while v.len() < n {
        v.extend_from_slice(format!("line {:07} abcdefghijklmnopqrstuvwxyz\n", i).as_bytes());
        i += 1;
    }
    v.truncate(n);
    v
}

fn crlf_to_cr(text: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        if text[i] == b'\r' && text.get(i + 1) == Some(&b'\n') {
            out.push(b'\r');
            i += 2;
        } else if text[i] == b'\n' {
            out.push(b'\r');
            i += 1;
        } else {
            out.push(text[i]);
            i += 1;
        }
    }
    out
}

/// The regression itself: with the pipe not draining at all, a 1.3 MB paste
/// returns to the caller (the server loop) at once.  The old writer slept
/// 5 ms per 512 bytes here, 13 s for this payload.
#[test]
fn large_paste_returns_without_waiting_for_the_pipe() {
    let pipe = Pipe::new(false);
    let mut queue = crate::pane::spawn_pane_write_queue(Box::new(PipeEnd(pipe.clone())));
    let text = payload(1_300 * 1024);
    let t0 = Instant::now();
    super::write_paste_bytes(&mut *queue, &text, true, true);
    let took = t0.elapsed();
    assert!(
        took < Duration::from_millis(1000),
        "a 1.3 MB paste held the caller for {:?}; it must only queue",
        took
    );
    assert!(pipe.bytes().is_empty(), "nothing can have reached a blocked pipe");
    pipe.release();
    let mut want = b"\x1b[200~".to_vec();
    want.extend_from_slice(&crlf_to_cr(&text));
    want.extend_from_slice(b"\x1b[201~");
    assert!(
        wait_until(|| pipe.bytes().len() >= want.len(), Duration::from_secs(10)),
        "the paste must drain once the pipe accepts it"
    );
    assert!(pipe.bytes() == want, "the paste must arrive byte exact");
    drop(queue);
}

/// Keys typed after a paste arrive after it, never inside the brackets, and
/// the brackets stay contiguous with their payload, even while the pipe is
/// blocked when both are queued.
#[test]
fn keys_after_a_paste_arrive_after_its_closing_bracket() {
    let pipe = Pipe::new(false);
    let mut queue = crate::pane::spawn_pane_write_queue(Box::new(PipeEnd(pipe.clone())));
    queue.write_all(b"before").unwrap();
    let text = payload(300 * 1024);
    super::write_paste_bytes(&mut *queue, &text, true, false);
    queue.write_all(b"typed-after").unwrap();
    pipe.release();

    let mut want = b"before\x1b[200~".to_vec();
    want.extend_from_slice(&text);
    want.extend_from_slice(b"\x1b[201~typed-after");
    assert!(wait_until(|| pipe.bytes().len() >= want.len(), Duration::from_secs(10)));
    let got = pipe.bytes();
    assert_eq!(got.len(), want.len());
    assert!(got == want, "order must be: earlier keys, ESC[200~, paste, ESC[201~, later keys");
    drop(queue);
}

/// No write the pane writer thread makes is a second full copy of the paste:
/// the paste is queued in PASTE_SLICE pieces and the thread's coalescing
/// stops at WRITE_COALESCE_MAX.
#[test]
fn a_large_paste_is_written_in_bounded_slices() {
    let pipe = Pipe::new(false);
    let mut queue = crate::pane::spawn_pane_write_queue(Box::new(PipeEnd(pipe.clone())));
    // One long run with no line break, so normalisation cannot split it.
    let text = vec![b'x'; 1024 * 1024 + 123];
    super::write_paste_bytes(&mut *queue, &text, true, true);
    pipe.release();
    let total = text.len() + 12;
    assert!(wait_until(|| pipe.bytes().len() >= total, Duration::from_secs(10)));
    let max = pipe.sizes.lock().unwrap().iter().copied().max().unwrap_or(0);
    assert!(
        max < super::PASTE_SLICE + crate::pane::WRITE_COALESCE_MAX,
        "largest pipe write was {} bytes",
        max
    );
    assert!(pipe.sizes.lock().unwrap().len() > 1, "a 1 MB paste must not be one write");
    drop(queue);
}

/// A CRLF split exactly across a slice boundary is still one line break.
#[test]
fn crlf_on_a_slice_boundary_is_one_line_break() {
    let mut text = vec![b'a'; super::PASTE_SLICE - 1 - 6]; // brackets take 6
    text.extend_from_slice(b"\r\nb");
    let mut out: Vec<u8> = Vec::new();
    super::write_paste_bytes(&mut out, &text, true, true);
    let mut want = b"\x1b[200~".to_vec();
    want.extend_from_slice(&vec![b'a'; super::PASTE_SLICE - 1 - 6]);
    want.extend_from_slice(b"\rb\x1b[201~");
    assert!(out == want);
}

/// Pane killed or respawned during a paste: the queue is dropped while most
/// of the paste is still queued.  What is left is discarded, not written to
/// the pane that is going away, and the writer thread ends (the inner
/// writer, the ConPTY handle, is released).
#[test]
fn pane_dropped_mid_paste_discards_the_rest_and_ends_the_thread() {
    let pipe = Pipe::new(false);
    let mut queue = crate::pane::spawn_pane_write_queue(Box::new(PipeEnd(pipe.clone())));
    let text = payload(2 * 1024 * 1024);
    super::write_paste_bytes(&mut *queue, &text, true, true);
    // Give the writer thread time to pick up its first slice and block on it.
    std::thread::sleep(Duration::from_millis(100));
    drop(queue);
    pipe.release();
    assert!(
        wait_until(|| pipe.dropped.load(Ordering::SeqCst), Duration::from_secs(10)),
        "the pane writer thread must end once the pane drops its writer"
    );
    let got = pipe.bytes().len();
    assert!(
        got <= super::PASTE_SLICE + crate::pane::WRITE_COALESCE_MAX,
        "only the slice already in flight may reach a dropped pane, got {} bytes",
        got
    );
}

/// The writer thread already gone (write fails): the paste stops at the
/// first failure instead of retrying or panicking.
#[test]
fn a_failing_writer_stops_the_paste_at_the_first_error() {
    struct Broken(Arc<AtomicUsize>);
    impl Write for Broken {
        fn write(&mut self, _buf: &[u8]) -> std::io::Result<usize> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "pane writer thread exited"))
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let calls = Arc::new(AtomicUsize::new(0));
    let mut w = Broken(calls.clone());
    let text = payload(1024 * 1024);
    super::write_paste_bytes(&mut w, &text, true, true);
    assert_eq!(calls.load(Ordering::SeqCst), 1, "one failed write ends the paste");
}
