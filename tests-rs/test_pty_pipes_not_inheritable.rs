// The ConPTY pipe ends the server keeps must not be inheritable.
//
// std::process::Command creates every child with bInheritHandles=TRUE, so an
// inheritable handle in the server rides along into each pipe-pane, run-shell,
// if-shell, `#()` and hook child, and from there into that child's children.
// On cb783dc a server with three panes held 22 inheritable pipe handles and a
// `pipe-pane` child (pwsh, then its PING) held copies of 6 of them.
//
// These tests start no psmux server.  The second one starts `ping` with no
// console window for about two seconds.

use portable_pty::win::conpty::create_pipe_with_buffer;
use std::io::Read;
use std::os::windows::io::AsRawHandle;
use std::time::{Duration, Instant};

const HANDLE_FLAG_INHERIT: u32 = 0x1;

extern "system" {
    fn GetHandleInformation(h: *mut core::ffi::c_void, flags: *mut u32) -> i32;
}

fn inherit_flag(h: std::os::windows::io::RawHandle) -> u32 {
    let mut flags = 0u32;
    let ok = unsafe { GetHandleInformation(h as _, &mut flags) };
    assert!(ok != 0, "GetHandleInformation failed: {}", std::io::Error::last_os_error());
    flags & HANDLE_FLAG_INHERIT
}

#[test]
fn conpty_pipe_ends_are_created_without_the_inherit_flag() {
    let (read, write) = create_pipe_with_buffer(64 * 1024).expect("pipe");
    assert_eq!(inherit_flag(read.as_raw_handle()), 0, "the read end is inheritable");
    assert_eq!(inherit_flag(write.as_raw_handle()), 0, "the write end is inheritable");
}

#[test]
fn a_command_child_does_not_keep_a_pty_pipe_open() {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let (mut read, write) = create_pipe_with_buffer(64 * 1024).expect("pipe");
    // A child spawned the way the server spawns its job children
    // (std Command, which always passes bInheritHandles=TRUE).
    let mut child = std::process::Command::new("ping")
        .args(["-n", "3", "127.0.0.1"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .expect("spawn ping");
    drop(write);
    // With the write end inherited the child holds a copy, so the read only
    // returns when ping exits (about 2 s).  Without it, EOF is immediate.
    let t = Instant::now();
    let mut buf = [0u8; 16];
    let n = read.read(&mut buf).unwrap_or(0);
    let waited = t.elapsed();
    let _ = child.kill();
    let _ = child.wait();
    assert_eq!(n, 0, "expected EOF");
    assert!(
        waited < Duration::from_millis(1000),
        "EOF took {:?}: the child inherited the pipe's write end",
        waited
    );
}
