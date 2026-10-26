// A pane process and everything it starts live in a job psmux holds, armed
// with KILL_ON_JOB_CLOSE, so they end when psmux lets go of the pane and when
// the server dies in any way (see portable-pty's PaneJob).  Measured on
// cb783dc: a server killed within about 150 ms of `new-session -d` left the
// warm pool's fresh shells alive with their conhost in 25 of 30 rounds.
//
// These tests start no psmux server: they spawn `cmd /c ping` through a real
// ConPTY exactly as a pane is spawned, and watch the cmd and its PING by PID.
// The pty itself stays open throughout, so only the job can end them.

use crate::platform::process_is_alive;
use std::time::{Duration, Instant};

#[repr(C)]
struct ProcessEntry32W {
    dw_size: u32,
    cnt_usage: u32,
    th32_process_id: u32,
    th32_default_heap_id: usize,
    th32_module_id: u32,
    cnt_threads: u32,
    th32_parent_process_id: u32,
    pc_pri_class_base: i32,
    dw_flags: u32,
    sz_exe_file: [u16; 260],
}

extern "system" {
    fn CreateToolhelp32Snapshot(flags: u32, pid: u32) -> isize;
    fn Process32FirstW(snap: isize, pe: *mut ProcessEntry32W) -> i32;
    fn Process32NextW(snap: isize, pe: *mut ProcessEntry32W) -> i32;
    fn CloseHandle(h: isize) -> i32;
}

/// Child pids of `parent` whose image name is `name` (case insensitive).
fn children_named(parent: u32, name: &str) -> Vec<u32> {
    let mut out = Vec::new();
    unsafe {
        let snap = CreateToolhelp32Snapshot(0x2, 0);
        if snap == -1 || snap == 0 {
            return out;
        }
        let mut pe: ProcessEntry32W = std::mem::zeroed();
        pe.dw_size = std::mem::size_of::<ProcessEntry32W>() as u32;
        let mut ok = Process32FirstW(snap, &mut pe);
        while ok != 0 {
            let len = pe.sz_exe_file.iter().position(|&c| c == 0).unwrap_or(260);
            let exe = String::from_utf16_lossy(&pe.sz_exe_file[..len]);
            if pe.th32_parent_process_id == parent && exe.eq_ignore_ascii_case(name) {
                out.push(pe.th32_process_id);
            }
            ok = Process32NextW(snap, &mut pe);
        }
        CloseHandle(snap);
    }
    out
}

fn wait_until(ms: u64, mut f: impl FnMut() -> bool) -> bool {
    let end = Instant::now() + Duration::from_millis(ms);
    while Instant::now() < end {
        if f() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    f()
}

/// Spawn `cmd /c ping` on a fresh pty; returns (pair, child, cmd pid, ping pid).
fn spawn_cmd_ping() -> (portable_pty::PtyPair, Box<dyn portable_pty::Child + Send + Sync>, u32, u32) {
    let pair = portable_pty::native_pty_system()
        .openpty(portable_pty::PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })
        .expect("openpty");
    let mut cmd = portable_pty::CommandBuilder::new("cmd.exe");
    cmd.args(["/c", "ping -n 30 127.0.0.1"]);
    let child = crate::util::spawn_pty_child(&*pair.slave, cmd).expect("spawn cmd");
    let cmd_pid = child.process_id().expect("cmd pid");
    let mut ping = 0;
    assert!(
        wait_until(5000, || {
            ping = children_named(cmd_pid, "PING.EXE").first().copied().unwrap_or(0);
            ping != 0
        }),
        "cmd never started its ping"
    );
    (pair, child, cmd_pid, ping)
}

#[test]
fn dropping_the_pane_child_ends_the_pane_and_what_it_started() {
    let _env = crate::util::lock_test_env();
    let (pair, child, cmd_pid, ping_pid) = spawn_cmd_ping();
    drop(child);
    // The pty (pair) is still open: only the job can end them.
    let gone = wait_until(3000, || !process_is_alive(cmd_pid) && !process_is_alive(ping_pid));
    drop(pair);
    assert!(gone, "cmd {cmd_pid} alive={} ping {ping_pid} alive={} after the pane child was dropped",
        process_is_alive(cmd_pid), process_is_alive(ping_pid));
}

#[test]
fn a_held_pane_child_keeps_running() {
    let _env = crate::util::lock_test_env();
    let (pair, child, cmd_pid, ping_pid) = spawn_cmd_ping();
    std::thread::sleep(Duration::from_millis(1500));
    let alive = process_is_alive(cmd_pid) && process_is_alive(ping_pid);
    drop(child);
    let _ = wait_until(3000, || !process_is_alive(cmd_pid) && !process_is_alive(ping_pid));
    drop(pair);
    assert!(alive, "the pane's processes must run for as long as psmux holds the pane");
}

#[test]
fn the_pane_job_can_be_turned_off() {
    // PSMUX_NO_PANE_JOB=1 is the diagnosis switch: the child then outlives the
    // drop exactly as it did before the job existed.
    let _env = crate::util::lock_test_env();
    std::env::set_var("PSMUX_NO_PANE_JOB", "1");
    let (pair, child, cmd_pid, ping_pid) = spawn_cmd_ping();
    std::env::remove_var("PSMUX_NO_PANE_JOB");
    drop(child);
    std::thread::sleep(Duration::from_millis(1000));
    let survived = process_is_alive(ping_pid);
    // clean up what this test started, by pid, then the pty
    crate::platform::process_kill::kill_pid_tree(cmd_pid);
    drop(pair);
    assert!(survived, "without the job the dropped child's ping keeps running (old behaviour)");
}

#[test]
fn a_spawn_reports_its_time_inside_create_process() {
    // The surge gate (tests/test_issue686_pool_surge_and_reap.ps1) judges
    // psmux on a spawn's cost MINUS its time inside CreateProcessW, because
    // Windows returns concurrent creations of the Store pwsh in batches.  That
    // only works if the OS share is measured, and never exceeds the spawn.
    let _env = crate::util::lock_test_env();
    let t0 = Instant::now();
    let (pair, child, cmd_pid, _ping) = spawn_cmd_ping();
    let os_us = portable_pty::last_spawn_create_us();
    let wall_us = t0.elapsed().as_micros() as u64;
    drop(child);
    let _ = wait_until(3000, || !process_is_alive(cmd_pid));
    drop(pair);
    assert!(os_us > 0, "the CreateProcessW share was never measured");
    assert!(os_us <= wall_us, "CreateProcessW share {os_us} us exceeds the whole spawn {wall_us} us");
}