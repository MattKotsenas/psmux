// An injected paste (the #684 WriteConsoleInputW route) is an item on the
// pane's own input queue, delivered by the pane writer thread when it reaches
// it, never by the server thread.
//
// It used to run synchronously on the server thread with the process wide
// console lock held for the whole paste: 0.35 s of total server freeze for
// 132 KB, a 3 s CLI timeout for 1.3 MB.  These tests drive the real queue
// (spawn_pane_write_queue_with) and the real chunking (drive_paste_inject)
// with a stand in for the console, writing pipe bytes and console records into
// ONE shared stream so their order is what the pane child would see.

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
        std::thread::sleep(Duration::from_millis(5));
    }
    cond()
}

/// What the child reads, from either channel, tagged by channel.
#[derive(Clone, Default)]
struct Child {
    stream: Arc<Mutex<Vec<(char, u8)>>>,
    pipe_dropped: Arc<AtomicBool>,
}

impl Child {
    fn bytes(&self) -> Vec<u8> {
        self.stream.lock().unwrap().iter().map(|&(_, b)| b).collect()
    }
    fn channel_of(&self) -> String {
        // Runs of channels, e.g. "PCP": pipe, console, pipe.
        let s = self.stream.lock().unwrap();
        let mut out = String::new();
        for &(ch, _) in s.iter() {
            if !out.ends_with(ch) {
                out.push(ch);
            }
        }
        out
    }
}

struct PipeEnd(Child);

impl Write for PipeEnd {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.stream.lock().unwrap().extend(buf.iter().map(|&b| ('P', b)));
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Drop for PipeEnd {
    fn drop(&mut self) {
        self.0.pipe_dropped.store(true, Ordering::SeqCst);
    }
}

/// A console that takes ASCII records into the child stream.  `fail_after`
/// chunks succeed, then every write fails (an attach refused mid paste).
/// `gate` holds every write until opened, standing in for a slow console.
#[derive(Clone)]
struct Console {
    child: Child,
    fail_after: Option<usize>,
    chunks: Arc<AtomicUsize>,
    calls: Arc<AtomicUsize>,
    gate: Arc<(Mutex<bool>, Condvar)>,
}

impl Console {
    fn new(child: &Child, fail_after: Option<usize>, open: bool) -> Self {
        Console {
            child: child.clone(),
            fail_after,
            chunks: Arc::new(AtomicUsize::new(0)),
            calls: Arc::new(AtomicUsize::new(0)),
            gate: Arc::new((Mutex::new(open), Condvar::new())),
        }
    }
    fn open(&self) {
        *self.gate.0.lock().unwrap() = true;
        self.gate.1.notify_all();
    }
    fn injector(&self) -> crate::pane::PasteInjector {
        let me = self.clone();
        Arc::new(move |_pid, text, abort| {
            me.calls.fetch_add(1, Ordering::SeqCst);
            crate::pane::drive_paste_inject(text, abort, Duration::ZERO, |units| {
                {
                    let mut g = me.gate.0.lock().unwrap();
                    while !*g {
                        g = me.gate.1.wait(g).unwrap();
                    }
                }
                let n = me.chunks.fetch_add(1, Ordering::SeqCst);
                if let Some(f) = me.fail_after {
                    if n >= f {
                        return None;
                    }
                }
                let mut s = me.child.stream.lock().unwrap();
                s.extend(units.iter().map(|&u| ('C', u as u8)));
                Some(units.len())
            })
        })
    }
}

fn job(text: &str, normalize: bool) -> crate::pane::InjectPaste {
    crate::pane::InjectPaste { pid: 4242, text: text.to_string(), normalize }
}

fn bracketed_cr(text: &str) -> Vec<u8> {
    let mut v = b"\x1b[200~".to_vec();
    v.extend_from_slice(text.replace("\r\n", "\r").replace('\n', "\r").as_bytes());
    v.extend_from_slice(b"\x1b[201~");
    v
}

fn text_of(n: usize) -> String {
    let mut s = String::with_capacity(n + 64);
    let mut i = 0;
    while s.len() < n {
        s.push_str(&format!("line {:06} abcdefghijklmnopqrstuvwxyz\r\n", i));
        i += 1;
    }
    s.truncate(n);
    s
}

/// Keys typed before a paste, the paste, keys typed after: the child reads
/// them in exactly that order, the paste contiguous inside its brackets.
#[test]
fn bytes_inject_bytes_arrive_in_order() {
    let child = Child::default();
    let console = Console::new(&child, None, true);
    let mut q = crate::pane::spawn_pane_write_queue_with(Box::new(PipeEnd(child.clone())), console.injector());
    let text = text_of(20_000);
    q.write_all(b"BEFORE").unwrap();
    assert!(q.queue_inject_paste(job(&text, true)).is_ok());
    q.write_all(b"AFTER").unwrap();
    let mut want = b"BEFORE".to_vec();
    want.extend_from_slice(&bracketed_cr(&text));
    want.extend_from_slice(b"AFTER");
    assert!(wait_until(|| child.bytes().len() >= want.len(), Duration::from_secs(10)));
    assert_eq!(child.bytes(), want, "order: keys before, the whole paste, keys after");
    assert_eq!(child.channel_of(), "PCP", "keys on the pipe, the paste on the console, nothing interleaved");
}

/// Queuing an injected paste returns at once even when the console is not
/// taking anything: the server thread is never held by it.  Keys queued after
/// it wait behind it.
#[test]
fn queuing_an_inject_never_waits_for_the_console() {
    let child = Child::default();
    let console = Console::new(&child, None, false);
    let mut q = crate::pane::spawn_pane_write_queue_with(Box::new(PipeEnd(child.clone())), console.injector());
    let text = text_of(1_300 * 1024);
    let t0 = Instant::now();
    assert!(q.queue_inject_paste(job(&text, true)).is_ok());
    q.write_all(b"AFTER").unwrap();
    let took = t0.elapsed();
    assert!(took < Duration::from_millis(200), "queuing held the caller for {:?}", took);
    std::thread::sleep(Duration::from_millis(100));
    assert!(child.bytes().is_empty(), "nothing overtakes the paste while the console is stuck");
    console.open();
    let mut want = bracketed_cr(&text);
    want.extend_from_slice(b"AFTER");
    assert!(wait_until(|| child.bytes().len() >= want.len(), Duration::from_secs(20)));
    assert_eq!(child.bytes().len(), want.len());
    assert!(child.bytes() == want, "1.3 MB paste then AFTER, byte exact");
}

/// An injection refused from the first record (an attach that fails) falls
/// back to the pipe, whole and in place.
#[test]
fn failed_inject_falls_back_to_the_pipe_in_order() {
    let child = Child::default();
    let console = Console::new(&child, Some(0), true);
    let mut q = crate::pane::spawn_pane_write_queue_with(Box::new(PipeEnd(child.clone())), console.injector());
    let text = "one\ntwo\r\nthree";
    q.write_all(b"A").unwrap();
    assert!(q.queue_inject_paste(job(text, true)).is_ok());
    q.write_all(b"B").unwrap();
    let mut want = b"A".to_vec();
    want.extend_from_slice(&bracketed_cr(text));
    want.extend_from_slice(b"B");
    assert!(wait_until(|| child.bytes().len() >= want.len(), Duration::from_secs(5)));
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(child.bytes(), want);
    assert_eq!(child.channel_of(), "P", "all of it through the pipe");
}

/// The console takes some chunks and then refuses: the pipe carries exactly
/// the rest, nothing twice, nothing lost, the closing marker last.
#[test]
fn inject_failing_mid_paste_sends_only_the_rest_to_the_pipe() {
    let child = Child::default();
    let console = Console::new(&child, Some(3), true);
    let mut q = crate::pane::spawn_pane_write_queue_with(Box::new(PipeEnd(child.clone())), console.injector());
    // CRLF line breaks so a chunk boundary can fall on one.
    let text = text_of(30_000);
    assert!(q.queue_inject_paste(job(&text, true)).is_ok());
    q.write_all(b"AFTER").unwrap();
    let mut want = bracketed_cr(&text);
    want.extend_from_slice(b"AFTER");
    assert!(wait_until(|| child.bytes().len() >= want.len(), Duration::from_secs(10)));
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(child.bytes().len(), want.len(), "no byte duplicated or lost");
    assert!(child.bytes() == want);
    assert_eq!(child.channel_of(), "CP", "three chunks on the console, the rest on the pipe");
}

/// A CR at the very end of a chunk whose LF starts the next: the console took
/// the CRLF as one CR, and a fallback must not send that LF again.
#[test]
fn a_chunk_ending_on_the_cr_of_a_crlf_is_not_resent() {
    let child = Child::default();
    let console = Console::new(&child, Some(1), true);
    let mut q = crate::pane::spawn_pane_write_queue_with(Box::new(PipeEnd(child.clone())), console.injector());
    // 6 marker units, then text so that unit 2048 is a CR followed by LF.
    let mut text = "x".repeat(crate::pane::INJECT_CHUNK - 6 - 1);
    text.push_str("\r\nrest");
    assert!(q.queue_inject_paste(job(&text, true)).is_ok());
    let want = bracketed_cr(&text);
    assert!(wait_until(|| child.bytes().len() >= want.len(), Duration::from_secs(5)));
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(child.bytes(), want);
}

/// The pane dropped its writer (kill-pane, respawn-pane -k) while a paste was
/// being injected: the injection stops at its next chunk, nothing queued
/// after it is delivered, and the writer thread ends (the pipe is dropped).
#[test]
fn pane_dropped_mid_inject_stops_and_the_thread_ends() {
    let child = Child::default();
    let console = Console::new(&child, None, false);
    let q = {
        let mut q = crate::pane::spawn_pane_write_queue_with(Box::new(PipeEnd(child.clone())), console.injector());
        assert!(q.queue_inject_paste(job(&text_of(200_000), true)).is_ok());
        q.write_all(b"NEVER").unwrap();
        q
    };
    assert!(wait_until(|| console.calls.load(Ordering::SeqCst) == 1, Duration::from_secs(5)));
    drop(q);
    console.open();
    assert!(wait_until(|| child.pipe_dropped.load(Ordering::SeqCst), Duration::from_secs(5)), "the writer thread ended");
    let chunks = console.chunks.load(Ordering::SeqCst);
    assert!(chunks <= 1, "the injection stopped at its next chunk, {} chunks were written", chunks);
    assert!(!child.channel_of().contains('P'), "nothing went to the pipe of a dropped pane");
}

/// A paste still waiting in the queue when the pane goes is never injected.
#[test]
fn pane_dropped_with_inject_queued_never_injects() {
    let child = Child::default();
    let console = Console::new(&child, None, true);
    // The pipe write is held so the paste stays queued behind it.
    struct SlowPipe(PipeEnd, Arc<(Mutex<bool>, Condvar)>);
    impl Write for SlowPipe {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            let mut g = self.1.0.lock().unwrap();
            while !*g {
                g = self.1.1.wait(g).unwrap();
            }
            drop(g);
            self.0.write(buf)
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let gate = Arc::new((Mutex::new(false), Condvar::new()));
    let mut q = crate::pane::spawn_pane_write_queue_with(
        Box::new(SlowPipe(PipeEnd(child.clone()), gate.clone())),
        console.injector(),
    );
    q.write_all(b"first").unwrap();
    std::thread::sleep(Duration::from_millis(50));
    assert!(q.queue_inject_paste(job("never", true)).is_ok());
    drop(q);
    *gate.0.lock().unwrap() = true;
    gate.1.notify_all();
    assert!(wait_until(|| child.pipe_dropped.load(Ordering::SeqCst), Duration::from_secs(5)));
    assert_eq!(console.calls.load(Ordering::SeqCst), 0, "the queued paste was discarded with the pane");
}

/// A writer that is not a pane queue refuses the paste and hands it back, so
/// the caller can send it through the pipe instead of losing it.
#[test]
fn a_plain_writer_hands_the_paste_back() {
    struct Plain;
    impl Write for Plain {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> { Ok(b.len()) }
        fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
    }
    impl crate::pane::PaneInputSink for Plain {}
    let mut w: Box<dyn crate::pane::PaneInputSink> = Box::new(Plain);
    let back = w.queue_inject_paste(job("abc", true));
    assert_eq!(back.err().map(|j| j.text), Some("abc".to_string()));
}

/// The units and offsets an injection is made of: markers, CRLF and LF made
/// one CR, a CR keeping its offset past its LF, a surrogate pair completing
/// only on its second half.
#[test]
fn inject_units_normalise_and_track_offsets() {
    let text = "a\r\nb\nc\r\u{1F600}";
    let units: Vec<(u16, usize)> = crate::pane::paste_inject_units(text).collect();
    let s: Vec<u16> = units.iter().map(|u| u.0).collect();
    let mut want: Vec<u16> = "\x1b[200~a\rb\rc\r".encode_utf16().collect();
    want.extend("\u{1F600}".encode_utf16());
    want.extend("\x1b[201~".encode_utf16());
    assert_eq!(s, want);
    // offsets: 6 marker bytes, then "a"=7, CR of CRLF=9 (past LF), "b"=10,
    // LF=11, "c"=12, lone CR=13, surrogate halves 13 then 17.
    let ends: Vec<usize> = units.iter().map(|u| u.1).collect();
    assert_eq!(&ends[6..13], &[7, 9, 10, 11, 12, 13, 13]);
    assert_eq!(ends[13], 17);
    assert_eq!(*ends.last().unwrap(), 6 + text.len() + 6);
}

/// The pipe remainder for every place an injection can stop.
#[test]
fn pipe_remainder_slices_the_payload() {
    fn rem(text: &str, consumed: usize, normalize: bool) -> Vec<u8> {
        let mut v = Vec::new();
        assert!(crate::input::write_paste_remainder(&mut v, text, consumed, normalize));
        v
    }
    assert_eq!(rem("ab\ncd", 0, true), b"\x1b[200~ab\rcd\x1b[201~");
    assert_eq!(rem("ab\ncd", 6, true), b"ab\rcd\x1b[201~");
    assert_eq!(rem("ab\ncd", 9, true), b"cd\x1b[201~");
    assert_eq!(rem("ab\ncd", 9, false), b"cd\x1b[201~");
    assert_eq!(rem("ab\ncd", 8, false), b"\ncd\x1b[201~");
    assert_eq!(rem("ab\ncd", 11, true), b"\x1b[201~");
    assert_eq!(rem("ab\ncd", 14, true), b"01~");
    assert_eq!(rem("ab\ncd", 17, true), b"");
}

/// drive_paste_inject resumes a short write with what was not taken, and
/// pauses only between full chunks.
#[test]
fn drive_resumes_short_writes() {
    let text = "z".repeat(5000);
    let abort = AtomicBool::new(false);
    let mut got: Vec<u16> = Vec::new();
    let mut calls = 0;
    let r = crate::pane::drive_paste_inject(&text, &abort, Duration::ZERO, |u| {
        calls += 1;
        let n = (u.len() / 2).max(1);
        got.extend_from_slice(&u[..n]);
        Some(n)
    });
    assert!(r.complete);
    assert_eq!(r.consumed, 5012);
    let want: Vec<u16> = format!("\x1b[200~{}\x1b[201~", text).encode_utf16().collect();
    assert_eq!(got, want);
    assert!(calls > 3);
}
