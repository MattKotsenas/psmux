//! Request handling of the shared server, one request of one session at a time.
//!
//! The arms below marked "copied" are copies of run_server's arms
//! (server/mod.rs at 0145958f; each copy names its source line) so the shared
//! server does exactly what a per session server does for those requests. The
//! owner ruling forbids changing run_server to share them, and copying is the
//! approach the ruling prefers. The arms written for the shared server are
//! marked "shared". Any request without an arm here is dropped: a one shot
//! command is refused before it gets this far (`router`/`reply`), so what can
//! still arrive unhandled is an attached client's request for a feature step 2
//! does not have, which then does nothing, and its reply channel closes.
//!
//! The locals the copied arms use (`state_dirty`, `meta_dirty`, `hook_event`,
//! `notify_events`, `echo_pending_until`, `temp_focus_restore`, `names_pane`)
//! are run_server's per request locals; they are loaded from and stored back
//! to the session's `SessionLoop` around the request.

#![allow(unused_variables, unused_mut, unused_assignments, clippy::all)]

use super::super::*;
use super::server::{Flow, SessionLoop};

pub(crate) fn dispatch(
    // `mut` so the copied arms' `&mut app` / `&app` (run_server owns its
    // AppState by value) coerce to the session's state unchanged.
    mut app: &mut AppState,
    lp: &mut SessionLoop,
    req: CtrlReq,
    pty_system: &dyn portable_pty::PtySystem,
) -> io::Result<Flow> {
    let mut flow = Flow::Continue;
    let mut state_dirty = lp.state_dirty;
    let mut meta_dirty = lp.meta_dirty;
    let mut echo_pending_until = lp.echo_pending_until;
    let mut temp_focus_restore = lp.temp_focus_restore.take();
    #[allow(clippy::never_loop)]
    for req in std::iter::once(req) {
        temp_target::restore_temp_focus(app, &mut temp_focus_restore);
        let names_pane = matches!(&req, CtrlReq::Targeted(t, _)
            if t.win.is_some() || t.win_name.is_some() || t.pane.is_some());
        let req = match req {
            CtrlReq::Targeted(target, inner) => {
                match temp_target::apply_temp_target(app, &mut temp_focus_restore, &target) {
                    Ok(()) => *inner,
                    Err(msg) => {
                        app.status_message = Some((msg, Instant::now(), None));
                        state_dirty = true;
                        continue;
                    }
                }
            }
            other => other,
        };
        let Some(req) = crate::server::options::divert_shadowed_global_request(app, req) else {
            meta_dirty = true;
            state_dirty = true;
            continue;
        };
        let mutates_state = !matches!(&req,
            CtrlReq::DumpState(..)
            | CtrlReq::SendText(_)
            | CtrlReq::SendKey(_)
            | CtrlReq::SendPaste(_)
            | CtrlReq::WindowDump(..)
            | CtrlReq::WindowLayout(..)
            | CtrlReq::PtyWake
            | CtrlReq::ClientActivity(_)
        );
        let mut hook_event: Option<&str> = None;
        let mut notify_events: Vec<&str> = Vec::new();
        let _prev_active_idx = app.active_idx;
        let _req_tag: &str = "";
        crate::format::set_sessionless(false);
        match req {
                // ── shared: session and server lifetime ──
                CtrlReq::KillSession => {
                    if let Some(cmds) = app.hooks.get("session-closed") { let cmds = cmds.clone(); for cmd in &cmds { let _ = execute_command_string(app, cmd); } }
                    flow = Flow::EndSession;
                }
                CtrlReq::KillServer => {
                    flow = Flow::KillServer { scoped_all: None };
                }
                CtrlReq::KillServerScoped(all) => {
                    flow = Flow::KillServer { scoped_all: Some(all) };
                }
                CtrlReq::HasSession(resp) => {
                    // This listener belongs to a live session of this server.
                    let _ = resp.send(true);
                }
                CtrlReq::DumpState(resp, allow_nc, dump_client_id) => {
                    lp.state_dirty = state_dirty;
                    lp.meta_dirty = meta_dirty;
                    super::frame::dump_state(app, lp, resp, allow_nc, dump_client_id)?;
                    state_dirty = lp.state_dirty;
                    meta_dirty = lp.meta_dirty;
                    continue;
                }
                CtrlReq::ClientDetach(cid) => {
                    // shared: run_server's arm, but the destroy-unattached end
                    // ends this session, never the process.
                    lp.dump_state_seen_full.remove(&cid);
                    lp.clients.remove(&cid);
                    if app.reap_client(cid) {
                        if crate::resize_window::refresh_dynamic_window_sizes(app) {
                            resize_all_panes(app);
                        }
                        hook_event = Some("client-detached");
                        if app.attached_clients == 0 && app.destroy_unattached {
                            flow = Flow::EndSession;
                        }
                    }
                }
                // copied from server/mod.rs run_server (line 3223 at 0145958f)
                CtrlReq::NewWindow(cmd, name, detached, start_dir, title, empty, env_sets, placement, outcome) => {
                    if let Some(cmds) = app.hooks.get("before-new-window") { let cmds = cmds.clone(); for cmd in &cmds { let _ = execute_command_string(&mut app, cmd); } }
                    // Expand format variables like #{pane_current_path} (#111)
                    let start_dir = start_dir.map(|d| expand_format(&d, &app)).filter(|d| !d.is_empty());
                    // Issue #630: do NOT chdir the server process into the start
                    // directory. CreatePseudoConsole() spawns the pane's conhost.exe
                    // from THIS process, so the host inherits the server's Win32
                    // current directory and then holds an open handle on it for the
                    // pane's entire life. That blocks deletion of the directory with
                    // Win32 error 32 ("used by another process") long after the pane's
                    // shell has cd'd away, and no `cd` can ever move the host.
                    //
                    // The start directory reaches the pane's SHELL explicitly instead,
                    // which is the only process that should hold it: a cold spawn gets
                    // it as lpCurrentDirectory through CommandBuilder::cwd() (see
                    // pane.rs, usable_start_dir), and a warm transplant gets it through
                    // pane::silent_rehome(). A shell releases the directory as soon as
                    // it cd's elsewhere, which is the tmux behaviour.
                    let result = run_new_window(
                        &mut app, &*pty_system, cmd.as_deref(), name.as_deref(), detached,
                        start_dir.as_deref(), title, empty, &env_sets, &placement, &mut notify_events);
                    crate::resize_window::refresh_dynamic_window_sizes(&mut app);
                    match result {
                        Ok(created) => {
                            // Replenish warm pane pool for next new-window
                            // Warm-pane replenish is deferred OFF the command path — it
                            // runs at the loop top during an idle gap (Tier 3), so a burst
                            // of window-creates never chains blocking spawns that stall
                            // other clients' commands.
                            resize_all_panes(&mut app); meta_dirty = true; state_dirty = true;
                            if created.is_some() { notify_events.push("window-linked"); hook_event = Some("after-new-window"); }
                            if let Some(tx) = outcome { let _ = tx.send(Ok(())); }
                        }
                        Err(msg) => {
                            // An attached client (command prompt, key binding) has
                            // no reply stream: show it like move-window does.
                            app.status_message = Some((msg.clone(), Instant::now(), None));
                            resize_all_panes(&mut app); meta_dirty = true; state_dirty = true;
                            if let Some(tx) = outcome { let _ = tx.send(Err(msg)); }
                        }
                    }
                }
                // copied from server/mod.rs run_server (line 3265 at 0145958f)
                CtrlReq::NewWindowPrint(cmd, name, detached, start_dir, format_str, resp, title, empty, env_sets, placement) => {
                    if let Some(cmds) = app.hooks.get("before-new-window") { let cmds = cmds.clone(); for cmd in &cmds { let _ = execute_command_string(&mut app, cmd); } }
                    let start_dir = start_dir.map(|d| expand_format(&d, &app)).filter(|d| !d.is_empty());
                    // No server chdir here: the pane's start directory is handed to the
                    // shell alone, never to the ConPTY host. See the #630 note on
                    // CtrlReq::NewWindow above.
                    let result = run_new_window(
                        &mut app, &*pty_system, cmd.as_deref(), name.as_deref(), detached,
                        start_dir.as_deref(), title, empty, &env_sets, &placement, &mut notify_events);
                    crate::resize_window::refresh_dynamic_window_sizes(&mut app);
                    match result {
                        Ok(created) => {
                            // Use full format engine for -P output (tmux compatible).
                            // `-S` selecting an existing window prints nothing (tmux
                            // returns before the print).
                            let pane_info = match created {
                                Some(pos) => {
                                    let fmt = format_str.as_deref().unwrap_or("#{session_name}:#{window_index}");
                                    crate::format::expand_format_for_window(fmt, &app, pos)
                                }
                                None => String::new(),
                            };
                            let _ = resp.send(pane_info);
                            resize_all_panes(&mut app); meta_dirty = true; state_dirty = true;
                            if created.is_some() { notify_events.push("window-linked"); hook_event = Some("after-new-window"); }
                        }
                        Err(msg) => {
                            app.status_message = Some((msg.clone(), Instant::now(), None));
                            resize_all_panes(&mut app); meta_dirty = true; state_dirty = true;
                            let _ = resp.send(format!("ERROR: {}", msg));
                        }
                    }
                }
                // copied from server/mod.rs run_server (line 3298 at 0145958f)
                CtrlReq::SplitWindow(k, cmd, detached, start_dir, split_size, resp, title, env_sets, zoom_after_split) => {
                    if let Some(cmds) = app.hooks.get("before-split-window") { let cmds = cmds.clone(); for cmd in &cmds { let _ = execute_command_string(&mut app, cmd); } }
                    // tmux: split-window without -Z permanently unzooms (#82)
                    unzoom_if_zoomed(&mut app);
                    // tmux: split-window INSIDE a floating pane creates ANOTHER
                    // floating pane (offset from it), not a tiled split.
                    let float_src = {
                        let win = &app.windows[app.active_idx];
                        win.floating_focus.and_then(|fi| win.floating.get(fi)).map(|fp| (fp.x, fp.y, fp.w, fp.h, fp.border.clone()))
                    };
                    if let Some((sx, sy, sw, sh, sborder)) = float_src {
                        // Floating panes are overlays, so tiled-window zoom does
                        // not apply to splits created from a floating pane.
                        let win_w = app.last_window_area.width.max(10);
                        let win_h = app.last_window_area.height.max(10);
                        let nx = (sx + 2).min(win_w.saturating_sub(sw));
                        let ny = (sy + 2).min(win_h.saturating_sub(sh));
                        let inner_h = sh.saturating_sub(2).max(1);
                        let inner_w = sw.saturating_sub(2).max(1);
                        let cmdstr = cmd.clone().unwrap_or_default();
                        let sd = start_dir.clone().map(|d| expand_format(&d, &app)).filter(|d| !d.is_empty());
                        let pane_id = app.next_pane_id;
                        if let Some(mut pane) = crate::popup::create_popup_pane(&cmdstr, sd.as_deref(), inner_h, inner_w, pane_id, &app.session_name, &app.environment, &app.env_scopes.child_removals(&app.environment), app.host_colors.as_ref()) {
                            app.next_pane_id += 1;
                            let t = title.clone().unwrap_or_default();
                            if !t.is_empty() { pane.title = t.clone(); pane.title_locked = true; }
                            let win = &mut app.windows[app.active_idx];
                            win.floating.push(crate::types::FloatingPane { pane, x: nx, y: ny, w: sw, h: sh, border: sborder, id: pane_id, title: t, position: None, styles: Default::default() });
                            if !detached { win.floating_focus = Some(win.floating.len() - 1); }
                            state_dirty = true;
                        }
                        let _ = resp.send(String::new());
                    } else {
                    let start_dir = start_dir.map(|d| expand_format(&d, &app)).filter(|d| !d.is_empty());
                    // No server chdir here: the pane's start directory is handed to the
                    // shell alone, never to the ConPTY host. See the #630 note on
                    // CtrlReq::NewWindow above.
                    let prev_pane_id = crate::tree::get_active_pane_id(&app.windows[app.active_idx].root, &app.windows[app.active_idx].active_path);
                    let split_succeeded = match crate::pane::split_active_placed(&mut app, k, cmd.as_deref(), Some(&*pty_system), start_dir.as_deref(), &env_sets, split_size) {
                        Err(e) => {
                            let msg = format!("split-window: {e}");
                            app.status_message = Some((msg.clone(), std::time::Instant::now(), None));
                            let _ = resp.send(format!("psmux: {msg}"));
                            false
                        }
                        Ok(()) => {
                            let _ = resp.send(String::new());
                            true
                        }
                    };
                    // `-l` is applied by the split itself, in cells (tmux
                    // layout_split_sizes); it used to be rewritten here as a
                    // percentage of the WINDOW after a 50/50 split.
                    // -T: the just-created pane is currently active in this
                    // window, so set its title before any detached revert.
                    if let Some(t) = title {
                        let win = &mut app.windows[app.active_idx];
                        if let Some(p) = active_pane_mut(&mut win.root, &win.active_path) {
                            p.title_locked = !t.is_empty();
                            p.title = t;
                        }
                    }
                    if detached {
                        // Capture new pane ID before reverting focus
                        let new_pane_id = crate::tree::get_active_pane_id(
                            &app.windows[app.active_idx].root,
                            &app.windows[app.active_idx].active_path,
                        );
                        // Revert focus to the previously active pane, found
                        // by id: with -b it is no longer child 0, and a split
                        // into a same-kind parent did not nest it at all.
                        let win = &mut app.windows[app.active_idx];
                        if let Some(p) = prev_pane_id.and_then(|id| crate::tree::find_path_by_id(&win.root, id)) {
                            win.active_path = p;
                        }
                        // Detached splits never focus the new pane — remove
                        // from MRU entirely so directional nav tie-breaks by
                        // pane_index among equally-unvisited candidates (#70).
                        if let Some(nid) = new_pane_id {
                            let win = &mut app.windows[app.active_idx];
                            win.pane_mru.retain(|&id| id != nid);
                        }
                    } else {
                        // Non-detached: new pane keeps focus.
                        // Cancel temp_focus_restore so -t doesn't revert (#112).
                        // The temporary focus just became permanent.
                        temp_focus_restore = None;
                        app.temp_focus_saved_active = None;
                    }
                    if zoom_after_split && split_succeeded {
                        // Give every pane its new cell BEFORE zooming: a zoom
                        // skips the hidden panes, so the pane just split stayed
                        // at its old height (tmux layout_fix_panes runs first).
                        resize_all_panes(&mut app);
                        toggle_zoom(&mut app);
                    }
                    // Replenish warm pane for the next new-window/split
                    // Warm-pane replenish is deferred OFF the command path — it
                    // runs at the loop top during an idle gap (Tier 3), so a burst
                    // of window-creates never chains blocking spawns that stall
                    // other clients' commands.
                    resize_all_panes(&mut app); meta_dirty = true; hook_event = Some("after-split-window");
                    }
                }
                // copied from server/mod.rs run_server (line 3402 at 0145958f)
                CtrlReq::SplitWindowPrint(k, cmd, detached, start_dir, split_size, format_str, resp, title, env_sets, zoom_after_split) => {
                    if let Some(cmds) = app.hooks.get("before-split-window") { let cmds = cmds.clone(); for cmd in &cmds { let _ = execute_command_string(&mut app, cmd); } }
                    unzoom_if_zoomed(&mut app);
                    let start_dir = start_dir.map(|d| expand_format(&d, &app)).filter(|d| !d.is_empty());
                    // No server chdir here: the pane's start directory is handed to the
                    // shell alone, never to the ConPTY host. See the #630 note on
                    // CtrlReq::NewWindow above.
                    let prev_pane_id = crate::tree::get_active_pane_id(&app.windows[app.active_idx].root, &app.windows[app.active_idx].active_path);
                    let split_succeeded = match crate::pane::split_active_placed(&mut app, k, cmd.as_deref(), Some(&*pty_system), start_dir.as_deref(), &env_sets, split_size) {
                        Err(e) => {
                            app.status_message = Some((format!("split-window: {e}"), std::time::Instant::now(), None));
                            eprintln!("psmux: split-window error: {e}");
                            false
                        }
                        Ok(()) => true,
                    };
                    // -T: set the new (currently active) pane's title.
                    if let Some(t) = title {
                        let win = &mut app.windows[app.active_idx];
                        if let Some(p) = active_pane_mut(&mut win.root, &win.active_path) {
                            p.title_locked = !t.is_empty();
                            p.title = t;
                        }
                    }
                    // Use full format engine for -P output (tmux compatible)
                    let fmt = format_str.as_deref().unwrap_or("#{session_name}:#{window_index}.#{pane_index}");
                    let pane_info = crate::format::expand_format_for_window(fmt, &app, app.active_idx);
                    if detached {
                        // Capture new pane ID before reverting focus
                        let new_pane_id = crate::tree::get_active_pane_id(
                            &app.windows[app.active_idx].root,
                            &app.windows[app.active_idx].active_path,
                        );
                        let win = &mut app.windows[app.active_idx];
                        if let Some(p) = prev_pane_id.and_then(|id| crate::tree::find_path_by_id(&win.root, id)) {
                            win.active_path = p;
                        }
                        // Detached splits: remove from MRU (#70 pane_index tie-break)
                        if let Some(nid) = new_pane_id {
                            let win = &mut app.windows[app.active_idx];
                            win.pane_mru.retain(|&id| id != nid);
                        }
                    } else {
                        temp_focus_restore = None;
                        app.temp_focus_saved_active = None;
                    }
                    if zoom_after_split && split_succeeded {
                        // Give every pane its new cell BEFORE zooming: a zoom
                        // skips the hidden panes, so the pane just split stayed
                        // at its old height (tmux layout_fix_panes runs first).
                        resize_all_panes(&mut app);
                        toggle_zoom(&mut app);
                    }
                    let _ = resp.send(pane_info);
                    // Replenish warm pane
                    // Warm-pane replenish is deferred OFF the command path — it
                    // runs at the loop top during an idle gap (Tier 3), so a burst
                    // of window-creates never chains blocking spawns that stall
                    // other clients' commands.
                    resize_all_panes(&mut app); meta_dirty = true; hook_event = Some("after-split-window");
                }
                // copied from server/mod.rs run_server (line 3463 at 0145958f)
                CtrlReq::KillPane => {
                    if let Some(cmds) = app.hooks.get("before-kill-pane") { let cmds = cmds.clone(); for cmd in &cmds { let _ = execute_command_string(&mut app, cmd); } }
                    // A focused floating pane is closed by kill-pane instead of a
                    // tiled pane. The child is dropped with the FloatingPane.
                    let closed_float = {
                        let win = &mut app.windows[app.active_idx];
                        if let Some(fi) = win.floating_focus {
                            if fi < win.floating.len() {
                                let mut fp = win.floating.remove(fi);
                                let _ = fp.pane.child.kill();
                                win.floating_focus = if win.floating.is_empty() { None } else { Some(win.floating.len() - 1) };
                                true
                            } else { false }
                        } else { false }
                    };
                    if closed_float {
                        state_dirty = true;
                    } else {
                        let win = &app.windows[app.active_idx];
                        let win_id = win.id;
                        let killed_active = crate::tree::get_active_pane_id(&win.root, &win.active_path)
                            .map_or(false, |pid| temp_target::is_real_active_pane(&app, &temp_focus_restore, app.active_idx, pid));
                        unzoom_if_zoomed(&mut app); let _ = kill_active_pane(&mut app); resize_all_panes(&mut app); meta_dirty = true; hook_event = Some("after-kill-pane");
                        control::emit_pane_closed(&app, win_id, killed_active);
                    }
                }
                // copied from server/mod.rs run_server (line 3489 at 0145958f)
                CtrlReq::KillPaneById(pid) => {
                    if let Some(cmds) = app.hooks.get("before-kill-pane") { let cmds = cmds.clone(); for cmd in &cmds { let _ = execute_command_string(&mut app, cmd); } }
                    // A floating %id closes that float, as `kill-pane` does
                    // for the focused one. kill_pane_by_id walks the tiled
                    // tree only, so `kill-pane -t <float>` used to do nothing
                    // at exit 0 (issue #793 follow up).
                    if let Some((wi, fi)) = crate::tree::find_floating_by_id(&app, pid) {
                        let win = &mut app.windows[wi];
                        let focused_id = win.floating_focus.and_then(|f| win.floating.get(f)).map(|fp| fp.id);
                        let mut fp = win.floating.remove(fi);
                        let _ = fp.pane.child.kill();
                        win.floating_focus = match focused_id {
                            Some(id) if id != pid => win.floating.iter().position(|f| f.id == id),
                            Some(_) if !win.floating.is_empty() => Some(win.floating.len() - 1),
                            _ => None,
                        };
                        state_dirty = true;
                    } else {
                        let win = app.windows.iter()
                            .position(|w| crate::tree::find_path_by_id(&w.root, pid).is_some())
                            .map(|wi| (app.windows[wi].id, temp_target::is_real_active_pane(&app, &temp_focus_restore, wi, pid)));
                        unzoom_if_zoomed(&mut app); let _ = kill_pane_by_id(&mut app, pid); resize_all_panes(&mut app); meta_dirty = true; hook_event = Some("after-kill-pane");
                        if let Some((win_id, killed_active)) = win { control::emit_pane_closed(&app, win_id, killed_active); }
                    }
                }
                // copied from server/mod.rs run_server (line 3514 at 0145958f)
                CtrlReq::CapturePane(resp, pane_id, preserve_trailing) => {
                    // Note: do NOT gate on is_active_pane_squelched here.
                    // Returning empty during the cd+cls squelch window makes
                    // iTerm2's initial attach paint a blank screen, since
                    // capture-pane is only requested once on attach.  Return
                    // current parser screen content; it's just cell text and
                    // any stale frame is harmless (subsequent %output rewrites).
                    if let Some(text) = capture_active_pane_text(&mut app, pane_id, preserve_trailing)? { let _ = resp.send(text); } else { let _ = resp.send(String::new()); }
                }
                // copied from server/mod.rs run_server (line 3523 at 0145958f)
                CtrlReq::CapturePaneStyled(resp, s, e, pane_id, preserve_trailing) => {
                    if let Some(text) = capture_active_pane_styled(&mut app, s, e, pane_id, preserve_trailing)? { let _ = resp.send(text); } else { let _ = resp.send(String::new()); }
                }
                // copied from server/mod.rs run_server (line 3526 at 0145958f)
                CtrlReq::CapturePaneRange(resp, s, e, pane_id, preserve_trailing) => {
                    if let Some(text) = capture_active_pane_range(&mut app, s, e, pane_id, preserve_trailing)? { let _ = resp.send(text); } else { let _ = resp.send(String::new()); }
                }
                // copied from server/mod.rs run_server (line 3529 at 0145958f)
                CtrlReq::CapturePaneSaved { resp, start, end, pane_id, styled, opts } => {
                    // A read that fails answers empty: a ? here would end the server.
                    let text = if styled {
                        crate::copy_mode::capture_pane_styled_from(&mut app, start, end, pane_id, opts, true).unwrap_or(None)
                    } else if start.is_some() || end.is_some() {
                        crate::copy_mode::capture_pane_range_from(&mut app, start, end, pane_id, opts, true).unwrap_or(None)
                    } else {
                        crate::copy_mode::capture_pane_text_from(&mut app, pane_id, opts, true).unwrap_or(None)
                    };
                    let _ = resp.send(text);
                }
                // copied from server/mod.rs run_server (line 3676 at 0145958f)
                CtrlReq::ResolveTarget { kind, spec, resp } => {
                    let result = crate::commands::resolve_in_server_target(&app, kind, &spec);
                    if let Err(ref msg) = result {
                        // The status bar, as for ValidateTarget below.
                        app.status_message = Some((msg.clone(), Instant::now(), None));
                        state_dirty = true;
                    }
                    let _ = resp.send(result);
                }
                // copied from server/mod.rs run_server (line 3685 at 0145958f)
                CtrlReq::ValidateTarget { target, resp } => {
                    match temp_target::resolve_temp_target(&app, &target) {
                        Ok(resolved) => { let _ = resp.send(Ok(resolved)); }
                        Err(msg) => {
                            // Surface in the status bar for attached clients,
                            // same convention as join-pane (#437) and
                            // kill-window (8edd1cb). The Err reply makes the
                            // connection thread skip the command.
                            app.status_message = Some((msg.clone(), Instant::now(), None));
                            state_dirty = true;
                            let _ = resp.send(Err(msg));
                        }
                    }
                }
                // Unwrapped at the top of this loop; TargetedSender never
                // nests one inside another.
                // copied from server/mod.rs run_server (line 3702 at 0145958f)
                CtrlReq::SessionInfo(resp) => {
                    let num_attached = app.client_registry.len();
                    let attached = if num_attached > 0 { " (attached)" } else { "" };
                    let group = if let Some(ref g) = app.session_group {
                        format!(" (group {})", g)
                    } else {
                        String::new()
                    };
                    let windows = app.windows.len();
                    let created = app.created_at.format("%a %b %e %H:%M:%S %Y");
                    let line = format!("{}: {} windows (created {}){}{}\n", app.session_name, windows, created, group, attached);
                    let _ = resp.send(line);
                }
                // copied from server/mod.rs run_server (line 3715 at 0145958f)
                CtrlReq::SessionInfoFormat(resp, fmt) => {
                    let line = crate::format::format_list_sessions(&app, &fmt);
                    let _ = resp.send(format!("{}\n", line));
                }
                // copied from server/mod.rs run_server (line 3719 at 0145958f)
                CtrlReq::ExpandFormat(fmt, resp) => {
                    // Synchronous by design: the caller is a connection thread
                    // that is about to run the expanded string, and it has
                    // already decided the round trip is worth it (it only sends
                    // this when the command actually contains a `#`).
                    // Untimed, like tmux's format_expand: every sender is a
                    // shell command or a set-option -F value, where `%` is
                    // not strftime (issue #734 follow up).
                    let _ = resp.send(crate::format::expand_format_untimed(&fmt, &app));
                }
                // copied from server/mod.rs run_server (line 3729 at 0145958f)
                CtrlReq::ExpandFormatNoTarget(fmt, resp) => {
                    // Untimed, as tmux's format_single_from_target is.
                    let text = crate::format::with_sessionless(true, || crate::format::expand_format_untimed(&fmt, &app));
                    let _ = resp.send(text);
                }
                // copied from server/mod.rs run_server (line 3734 at 0145958f)
                CtrlReq::ClientAttach(cid, pid) => {
                    lp.clients.insert(cid); // shared: frames go to this session's clients only
                    // Registration and the attached counter are one idempotent
                    // operation. A duplicate attach for the same connection
                    // must not leave the session permanently ghost-attached.
                    if app.register_client_with_pid(cid, false, pid) {
                        // A client that attaches here has just changed the
                        // session it is looking at, which is exactly when tmux
                        // fires it: server-client.c:448
                        // `server_client_set_session` calls
                        // `server_client_fire_session_changed(c, old)` at :472
                        // for every set, attach and switch-client alike, and
                        // that fires client-session-changed at :415. psmux runs
                        // one server per session, so the session a client
                        // switches TO is this server and the attach is the
                        // switch (issue #691).
                        notify_events.push("client-session-changed");
                        hook_event = Some("client-attached");
                        // update-environment from the ATTACHING client's
                        // environment (tmux cmd-attach-session.c environ_update
                        // from c->environ, #775), sent as `client-environ` just
                        // before the attach. This used to read the server's own
                        // environment, so it never changed anything, and it
                        // dropped a missing name instead of recording -NAME.
                        if let Some(src) = app.env_scopes.pending_client_environ.take() {
                            let patterns = app.update_environment.clone();
                            crate::environ::update_environment(&mut app.environment, &mut app.env_scopes, &patterns, &src, false);
                        }
                    }
                }
                // copied from server/mod.rs run_server (line 3800 at 0145958f)
                CtrlReq::DumpLayout(resp) => {
                    let json = dump_layout_json(&mut app)?;
                    let _ = resp.send(json);
                }
                // copied from server/mod.rs run_server (line 4161 at 0145958f)
                CtrlReq::SendText(s) => {
                    // A copy-mode prompt is drawn by the client from the
                    // status message, so a key that only edits that prompt
                    // changes no pane cell: the frame diff is empty and
                    // nothing would be pushed until the client's once a
                    // second dump-state poll. Moving the cursor inside the
                    // prompt is exactly that case, so the push is owed
                    // whenever a prompt was open before the key or is open
                    // after it, which also covers the one that opens or
                    // closes it.
                    let prompt_before = crate::copy_mode::copy_prompt_text(&app.mode).is_some();
                    crate::server::helpers::clear_status_message_on_key(&mut app);
                    crate::input::stamp_interactive_text(&mut app);
                    // Typing into a direct-scrolled pane shows its live screen
                    // again, before the key can be taken by a mode it opens.
                    if crate::input::snap_interactive_to_live(&mut app) {
                        state_dirty = true;
                    }
                    send_text_to_active(&mut app, &s)?;
                    if prompt_before || crate::copy_mode::copy_prompt_text(&app.mode).is_some() {
                        state_dirty = true;
                    }
                    echo_pending_until = Some(Instant::now());
                }
                // copied from server/mod.rs run_server (line 4185 at 0145958f)
                CtrlReq::ClientActivity(cid) => {
                    // `#{client_activity}` is the last input from THIS client
                    // (tmux c->activity_time), not its last resize (#724).
                    if let Some(info) = app.client_registry.get_mut(&cid) {
                        info.last_activity = Instant::now();
                    }
                    // Typing, clicking, scrolling: this client is the one in
                    // use, so `window-size latest` must size the window for
                    // it.  The resize only runs when the geometry changes.
                    if crate::resize_window::note_client_activity(&mut app, cid) {
                        resize_all_panes(&mut app);
                        state_dirty = true;
                        meta_dirty = true;
                    }
                }
                // copied from server/mod.rs run_server (line 4200 at 0145958f)
                CtrlReq::PtyWake => { /* the wake itself is the whole point; the
                    PTY_DATA_READY swap above already set state_dirty. */ }
                // copied from server/mod.rs run_server (line 4202 at 0145958f)
                CtrlReq::SendKey(k) => {
                    // Same as SendText above: a prompt edit owes a frame even
                    // though no cell changed.
                    let prompt_before = crate::copy_mode::copy_prompt_text(&app.mode).is_some();
                    crate::pty_trace::mark("g", 0, k.as_bytes());
                    crate::server::helpers::clear_status_message_on_key(&mut app);
                    crate::input::stamp_interactive_key(&mut app, &k);
                    if crate::input::snap_interactive_to_live(&mut app) {
                        state_dirty = true;
                    }
                    send_key_to_active(&mut app, &k)?;
                    if prompt_before || crate::copy_mode::copy_prompt_text(&app.mode).is_some() {
                        state_dirty = true;
                    }
                    echo_pending_until = Some(Instant::now());
                }
                // copied from server/mod.rs run_server (line 4218 at 0145958f)
                CtrlReq::SendPaste(s) => {
                    if crate::input::snap_interactive_to_live(&mut app) {
                        state_dirty = true;
                    }
                    send_paste_to_active(&mut app, &s)?;
                    echo_pending_until = Some(Instant::now());
                }
                // copied from server/mod.rs run_server (line 4238 at 0145958f)
                CtrlReq::ZoomPane => {
                    toggle_zoom(&mut app);
                    // tmux window_zoom makes the zoomed pane its window's
                    // active pane (window_set_active_pane), so a `-t` zoom of
                    // another pane keeps that pane active once the request's
                    // temporary focus is put back; otherwise the window showed
                    // the zoomed pane while another one was active (#824).
                    let win = &mut app.windows[app.active_idx];
                    if win.zoom_saved.is_some() {
                        if let Some(pid) = get_active_pane_id(&win.root, &win.active_path) {
                            crate::tree::touch_mru(&mut win.pane_mru, pid);
                            if let Some(saved) = temp_focus_restore.as_mut() {
                                if saved.active_idx == app.active_idx {
                                    saved.pane_id = pid;
                                }
                            }
                        }
                    }
                    state_dirty = true; meta_dirty = true; hook_event = Some("after-resize-pane");
                }
                // tmux: the prefix forces a switch to the prefix table, which
                // drops any `switch-client -T` latch (issue #640).
                // copied from server/mod.rs run_server (line 4260 at 0145958f)
                CtrlReq::PrefixBegin => { app.client_prefix_active = true; app.current_key_table = None; state_dirty = true; }
                // copied from server/mod.rs run_server (line 4261 at 0145958f)
                CtrlReq::PrefixEnd => { app.client_prefix_active = false; state_dirty = true; }
                // copied from server/mod.rs run_server (line 4290 at 0145958f)
                CtrlReq::ClientSize(cid, w, h) => { 
                    app.client_sizes.insert(cid, (w, h));
                    app.latest_client_id = Some(cid);
                    app.latest_size_client_id = Some(cid);
                    app.client_area = Rect::new(0, 0, w, h);
                    // Update registry with new size and activity timestamp
                    if let Some(info) = app.client_registry.get_mut(&cid) {
                        info.width = w;
                        info.height = h;
                        info.last_activity = std::time::Instant::now();
                    }
                    crate::resize_window::refresh_dynamic_window_sizes(&mut app);
                    resize_all_panes(&mut app);
                    // Reconcile warm pane dimensions through the central
                    // policy module so resize uses the same code path as
                    // every other warm-pane invalidation (#271).
                    let sync = crate::warm_pane_sync::for_resize(
                        &app,
                        app.client_area.height,
                        app.client_area.width,
                    );
                    crate::warm_pane_sync::apply(&mut app, &*pty_system, sync);
                    hook_event = Some("client-resized");
                }
                // copied from server/mod.rs run_server (line 4314 at 0145958f)
                CtrlReq::HostColors(spec) => {
                    // Issue #473: a client reported its host terminal's colors.
                    // Keep the most recent report — the newest attached client
                    // is what the user is actually looking at.
                    let hc = crate::types::HostColors::from_spec(&spec);
                    if hc.has_any() || hc.dark.is_some() {
                        let changed = app.host_colors.as_ref() != Some(&hc);
                        app.host_colors = Some(hc);
                        // Issue #556: pane reader threads answer color queries
                        // synchronously; publish the update where they can see it.
                        crate::types::set_shared_host_colors(app.host_colors.clone());
                        // The palette is also planted on every pane child as
                        // PSMUX_HOST_COLORS at spawn time, so the spares already
                        // sitting in the warm pool are now holding the wrong one
                        // (usually none at all: this report is how the server
                        // learns its colours in the first place). A child's
                        // environment cannot be rewritten from outside, so the
                        // only honest answer is to retire them.
                        if changed {
                            let sync = crate::warm_pane_sync::for_host_colors_change(&app);
                            crate::warm_pane_sync::apply(&mut app, &*pty_system, sync);
                            // Remember it for the next server in this data root,
                            // so its spares are born with this palette and this
                            // retirement does not happen again. See
                            // `paths::host_colors_file`.
                            if let Some(ref hc) = app.host_colors {
                                let _ = std::fs::write(
                                    crate::paths::host_colors_file(),
                                    hc.to_spec(),
                                );
                            }
                        }
                    }
                }
                // copied from server/mod.rs run_server (line 4409 at 0145958f)
                CtrlReq::ListWindows(resp) => { helpers::propagate_osc_titles(&mut app); let json = list_windows_json(&app)?; let _ = resp.send(json); }
                // copied from server/mod.rs run_server (line 4410 at 0145958f)
                CtrlReq::ListWindowsTmux(resp) => { helpers::propagate_osc_titles(&mut app); let text = list_windows_tmux(&app); let _ = resp.send(text); }
                // copied from server/mod.rs run_server (line 4411 at 0145958f)
                CtrlReq::ListWindowsFormat(resp, fmt) => { helpers::propagate_osc_titles(&mut app); let text = format_list_windows(&app, &fmt); let _ = resp.send(text); }
                // copied from server/mod.rs run_server (line 4412 at 0145958f)
                CtrlReq::ListTree(resp) => { let json = list_tree_json(&app)?; let _ = resp.send(json); }
                // copied from server/mod.rs run_server (line 4513 at 0145958f)
                CtrlReq::SendKeys(keys, literal) => {
                    // #828: tmux's send-keys hands its keys to the target
                    // pane (`window_pane_key`, window.c), and a popup, menu
                    // or confirm prompt belongs to a client, which only that
                    // client's own keystrokes reach (server_client_handle_key).
                    // So a send-keys aimed at a window or pane goes past the
                    // overlay to the pane, and the overlay stays open.  An
                    // untargeted or session-only send-keys still drives the
                    // overlay, as psmux scripts have long relied on (closing
                    // a popup with `send-keys Escape`).
                    let overlay = if names_pane && matches!(app.mode,
                        Mode::PopupMode { .. } | Mode::MenuMode { .. } | Mode::ConfirmMode { .. })
                    {
                        Some(std::mem::replace(&mut app.mode, Mode::Passthrough))
                    } else {
                        None
                    };
                    let in_copy = app.mode.in_copy();
                    if in_copy {
                        // In copy/search mode — route through mode-aware handlers
                        if literal {
                            send_text_to_active(&mut app, &keys.join(""))?;
                        } else {
                            // #490: `keys` holds the send-keys arguments as
                            // separate tokens. Match each WHOLE token as a
                            // named key or send it verbatim — never split a
                            // token on whitespace, which destroyed spacing
                            // inside quoted arguments.
                            let parts: Vec<&str> = keys.iter().map(|s| s.as_str()).collect();
                            for key in parts.iter() {
                                let key_upper = key.to_uppercase();
                                let normalized = match key_upper.as_str() {
                                    "ENTER" => "enter",
                                    "TAB" => "tab",
                                    "BTAB" | "BACKTAB" => "btab",
                                    "ESCAPE" | "ESC" => "esc",
                                    "SPACE" => "space",
                                    "BSPACE" | "BACKSPACE" => "backspace",
                                    "UP" => "up",
                                    "DOWN" => "down",
                                    "RIGHT" => "right",
                                    "LEFT" => "left",
                                    "HOME" => "home",
                                    "END" => "end",
                                    "PAGEUP" | "PPAGE" => "pageup",
                                    "PAGEDOWN" | "NPAGE" => "pagedown",
                                    "DELETE" | "DC" => "delete",
                                    "INSERT" | "IC" => "insert",
                                    _ => "",
                                };
                                if !normalized.is_empty() {
                                    send_key_to_active(&mut app, normalized)?;
                                } else if key_upper.starts_with("C-") || key_upper.starts_with("M-") || (key_upper.starts_with("F") && key_upper.len() >= 2 && key_upper[1..].chars().all(|c| c.is_ascii_digit())) {
                                    send_key_to_active(&mut app, &key.to_lowercase())?;
                                } else {
                                    // Plain text char — route through send_text_to_active (handles copy mode chars)
                                    send_text_to_active(&mut app, key)?;
                                }
                            }
                        }
                    } else if literal {
                        send_text_to_active(&mut app, &keys.join(""))?;
                    } else {
                        // #490: `keys` holds the send-keys arguments as
                        // separate tokens. A token either matches a named key
                        // in its entirety or is typed verbatim with its
                        // whitespace intact; a single separator space is
                        // still inserted between adjacent PLAIN tokens for
                        // backward compatibility with multi word scripts
                        // (strict tmux would concatenate them).
                        let parts: Vec<&str> = keys.iter().map(|s| s.as_str()).collect();
                        for (i, key) in parts.iter().enumerate() {
                            let key_upper = key.to_uppercase();
                            let _is_special = matches!(key_upper.as_str(), 
                                "ENTER" | "TAB" | "BTAB" | "BACKTAB" | "ESCAPE" | "ESC" | "SPACE" | "BSPACE" | "BACKSPACE" |
                                "UP" | "DOWN" | "RIGHT" | "LEFT" | "HOME" | "END" |
                                "PAGEUP" | "PPAGE" | "PAGEDOWN" | "NPAGE" | "DELETE" | "DC" | "INSERT" | "IC" |
                                "F1" | "F2" | "F3" | "F4" | "F5" | "F6" | "F7" | "F8" | "F9" | "F10" | "F11" | "F12"
                            ) || key_upper.starts_with("C-") || key_upper.starts_with("M-") || key_upper.starts_with("S-");
                            
                            match key_upper.as_str() {
                                "ENTER" => send_text_to_active(&mut app, "\r")?,
                                "TAB" => send_text_to_active(&mut app, "\t")?,
                                "BTAB" | "BACKTAB" => send_text_to_active(&mut app, "\x1b[Z")?,
                                "ESCAPE" | "ESC" => send_text_to_active(&mut app, "\x1b")?,
                                "SPACE" => send_text_to_active(&mut app, " ")?,
                                "BSPACE" | "BACKSPACE" => send_text_to_active(&mut app, "\x7f")?,
                                // DECCKM app-cursor mode: SS3, not CSI (see crate::input::csi_cursor_to_ss3).
                                "UP" => send_key_to_active(&mut app, "up")?,
                                "DOWN" => send_key_to_active(&mut app, "down")?,
                                "RIGHT" => send_key_to_active(&mut app, "right")?,
                                "LEFT" => send_key_to_active(&mut app, "left")?,
                                "HOME" => send_key_to_active(&mut app, "home")?,
                                "END" => send_key_to_active(&mut app, "end")?,
                                "PAGEUP" | "PPAGE" => send_text_to_active(&mut app, "\x1b[5~")?,
                                "PAGEDOWN" | "NPAGE" => send_text_to_active(&mut app, "\x1b[6~")?,
                                "DELETE" | "DC" => send_text_to_active(&mut app, "\x1b[3~")?,
                                "INSERT" | "IC" => send_text_to_active(&mut app, "\x1b[2~")?,
                                "F1" => send_text_to_active(&mut app, "\x1bOP")?,
                                "F2" => send_text_to_active(&mut app, "\x1bOQ")?,
                                "F3" => send_text_to_active(&mut app, "\x1bOR")?,
                                "F4" => send_text_to_active(&mut app, "\x1bOS")?,
                                "F5" => send_text_to_active(&mut app, "\x1b[15~")?,
                                "F6" => send_text_to_active(&mut app, "\x1b[17~")?,
                                "F7" => send_text_to_active(&mut app, "\x1b[18~")?,
                                "F8" => send_text_to_active(&mut app, "\x1b[19~")?,
                                "F9" => send_text_to_active(&mut app, "\x1b[20~")?,
                                "F10" => send_text_to_active(&mut app, "\x1b[21~")?,
                                "F11" => send_text_to_active(&mut app, "\x1b[23~")?,
                                "F12" => send_text_to_active(&mut app, "\x1b[24~")?,
                                // Modifier + special key combos (C-Left, S-Right, C-M-Up, etc.)
                                // must be checked BEFORE the generic C-x / M-x single-char handlers.
                                s if crate::input::parse_modified_special_key(s).is_some() => {
                                    let seq = crate::input::parse_modified_special_key(s).unwrap();
                                    send_text_to_active(&mut app, &seq)?;
                                }
                                s if s.starts_with("C-M-") || s.starts_with("C-m-") => {
                                    if let Some(c) = key.chars().nth(4) {
                                        if let Some(ctrl) = crate::input::ctrl_char_send_keys_byte(c) {
                                            send_text_to_active(&mut app, &format!("\x1b{}", ctrl as char))?;
                                        }
                                    }
                                }
                                // Ctrl+Shift+<punctuation/digit> that collapses to a single
                                // C0 byte, e.g. Ctrl+/ delivered by ConPTY terminals
                                // (Alacritty, WezTerm) as "C-S--" (VK_OEM_MINUS + Ctrl +
                                // Shift).  It must reach the child as 0x1f (^_), matching
                                // Ctrl+_ and tmux, so neovim's Ctrl+/ comment toggle fires
                                // (issue #394).  This MUST precede the generic C- arm below,
                                // whose nth(2) extraction would otherwise read the 'S' and
                                // mis-send Ctrl+S.
                                s if (s.starts_with("C-S-") || s.starts_with("C-s-"))
                                    && s.chars().count() == 5
                                    && s.chars().nth(4).map_or(false, |c| !c.is_ascii_alphabetic()) =>
                                {
                                    if let Some(c) = s.chars().nth(4) {
                                        // Issue #623: Ctrl+Shift+<digit> (Far's folder
                                        // shortcuts) has no VT encoding either.
                                        #[cfg(windows)]
                                        let handled = match ctrl_key_record_seq_for_active(&mut app, c, true) {
                                            Some(seq) => {
                                                send_text_to_active(&mut app, &seq)?;
                                                crate::input::mark_win32_input_latched(&mut app);
                                                true
                                            }
                                            None => false,
                                        };
                                        #[cfg(not(windows))]
                                        let handled = false;
                                        if !handled {
                                            if let Some(ctrl) = crate::input::ctrl_char_send_keys_byte(c) {
                                                send_text_to_active(&mut app, &String::from(ctrl as char))?;
                                            }
                                        }
                                    }
                                }
                                // Ctrl+Space by name: a space cannot survive as the
                                // third character of "C-x" on a whitespace split
                                // command line, and the generic C- arm below would read
                                // the 'S' of "C-Space" and send Ctrl+S.  tmux byte: NUL.
                                // This match is on `key_upper`, so the only spelling
                                // that can ever arrive is "C-SPACE"; the mixed case
                                // forms alone never matched and `send-keys C-Space`
                                // wrote 0x13, an XOFF (issue #860).
                                "C-SPACE" => {
                                    #[cfg(windows)]
                                    let handled = match ctrl_key_record_seq_for_active(&mut app, ' ', false) {
                                        Some(seq) => {
                                            send_text_to_active(&mut app, &seq)?;
                                            crate::input::mark_win32_input_latched(&mut app);
                                            true
                                        }
                                        None => false,
                                    };
                                    #[cfg(not(windows))]
                                    let handled = false;
                                    if !handled {
                                        send_text_to_active(&mut app, "\x00")?;
                                    }
                                }
                                s if s.starts_with("C-") => {
                                    if let Some(c) = s.chars().nth(2) {
                                        let Some(ctrl) = crate::input::ctrl_char_send_keys_byte(c) else { continue };
                                        // On Windows with Win32 input mode, write the key as
                                        // a Win32 input mode escape sequence so ConPTY generates
                                        // a proper KEY_EVENT with VK + LEFT_CTRL_PRESSED (#305).
                                        #[cfg(windows)]
                                        {
                                            if c.is_ascii_alphabetic() {
                                                // Keep Ctrl+C on the legacy interrupt path:
                                                // raw 0x03 + the interrupt router. The router
                                                // runs BEFORE the byte: when it decides "raw
                                                // 0x03 only" it may strip PROCESSED_INPUT from
                                                // the pane console so conhost delivers the byte
                                                // as input instead of converting it into a
                                                // console-wide CTRL_C_EVENT that aborts a
                                                // booting WSL launch (#579).
                                                if ctrl == 0x03 {
                                                    if let Some(win) = app.windows.get_mut(app.active_idx) {
                                                        // The console signal bypasses the pane
                                                        // writer, so it needs the input-off gate
                                                        // send_text_to_active applies to the byte.
                                                        if let Some(p) = active_pane_mut(&mut win.root, &win.active_path).filter(|p| p.accepts_input()) {
                                                            if p.child_pid.is_none() {
                                                                p.child_pid = crate::platform::mouse_inject::get_child_pid(&*p.child);
                                                            }
                                                            if let Some(pid) = p.child_pid {
                                                                crate::platform::mouse_inject::send_ctrl_c_event(pid, false);
                                                            }
                                                        }
                                                    }
                                                    send_text_to_active(&mut app, &String::from(ctrl as char))?;
                                                } else if !crate::input::active_pane_host_parses_win32_input(&mut app) {
                                                    // Issue #845: this pane's console host
                                                    // predates win32 input mode (it never
                                                    // asked for ?9001h) and would drop or
                                                    // print the record, so the key goes as
                                                    // tmux's control byte.
                                                    send_text_to_active(&mut app, &String::from(ctrl as char))?;
                                                } else {
                                                    let vk = crate::platform::mouse_inject::char_to_vk(c);
                                                    let scan = crate::platform::mouse_inject::vk_to_scan(vk);
                                                    let u_char = (c.to_ascii_lowercase() as u16) & 0x1F;
                                                    const LEFT_CTRL_PRESSED: u32 = 0x0008;
                                                    let seq = crate::input::win32_input_key_seq(
                                                        vk, scan, u_char, LEFT_CTRL_PRESSED,
                                                    );
                                                    send_text_to_active(&mut app, &seq)?;
                                                    // Writing this LATCHES the receiving ConPTY into
                                                    // win32 input mode for good: conhost stops
                                                    // dispatching a dangling ESC as the Escape key,
                                                    // so every later bare 0x1b would vanish (#588).
                                                    // Remember it, so a lone Escape is written in
                                                    // win32 form too from here on.
                                                    crate::input::mark_win32_input_latched(&mut app);
                                                }
                                            } else if let Some(seq) =
                                                ctrl_key_record_seq_for_active(&mut app, c, false)
                                            {
                                                // Issue #623: Ctrl+<digit> has no VT
                                                // encoding at all, so a record reading
                                                // pane (Far Manager) was handed the
                                                // bare digit and could not tell it from
                                                // an unmodified keypress.
                                                send_text_to_active(&mut app, &seq)?;
                                                crate::input::mark_win32_input_latched(&mut app);
                                            } else {
                                                send_text_to_active(&mut app, &String::from(ctrl as char))?;
                                            }
                                        }
                                        #[cfg(not(windows))]
                                        send_text_to_active(&mut app, &String::from(ctrl as char))?;
                                    }
                                }
                                s if s.starts_with("M-") => {
                                    if let Some(c) = key.chars().nth(2) {
                                        send_text_to_active(&mut app, &format!("\x1b{}", c))?;
                                    }
                                }
                                _ => {
                                    // Plain token: typed VERBATIM (#490 — the
                                    // token's own whitespace is untouched).
                                    // Keep the historical single separator
                                    // space between two adjacent plain tokens
                                    // so existing multi word scripts like
                                    // `send-keys echo hi Enter` keep working.
                                    send_text_to_active(&mut app, key)?;
                                    if i + 1 < parts.len() {
                                        let next_upper = parts[i + 1].to_uppercase();
                                        let next_is_special = matches!(next_upper.as_str(),
                                            "ENTER" | "TAB" | "BTAB" | "BACKTAB" | "ESCAPE" | "ESC" | "SPACE" | "BSPACE" | "BACKSPACE" |
                                            "UP" | "DOWN" | "RIGHT" | "LEFT" | "HOME" | "END" |
                                            "PAGEUP" | "PPAGE" | "PAGEDOWN" | "NPAGE" | "DELETE" | "DC" | "INSERT" | "IC" |
                                            "F1" | "F2" | "F3" | "F4" | "F5" | "F6" | "F7" | "F8" | "F9" | "F10" | "F11" | "F12"
                                        ) || next_upper.starts_with("C-") || next_upper.starts_with("M-") || next_upper.starts_with("S-");
                                        if !next_is_special {
                                            send_text_to_active(&mut app, " ")?;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    echo_pending_until = Some(Instant::now());
                    if let Some(m) = overlay {
                        app.mode = m;
                    }
                }
                // copied from server/mod.rs run_server (line 4510 at 0145958f)
                CtrlReq::SendBytes(bytes) => {
                    send_bytes_to_active(&mut app, &bytes)?;
                }
                // copied from server/mod.rs run_server (line 4801 at 0145958f)
                CtrlReq::SendKeysX(cmd) => {
                    // A copy-mode key binding's `send-keys -X` (queued by
                    // input::run_copy_mode_binding, so the pane is in copy mode).
                    let _ = run_send_keys_x(&mut app, &cmd, 1);
                }
                // copied from server/mod.rs run_server (line 4806 at 0145958f)
                CtrlReq::SendKeysXRun { cmd, count, resp } => {
                    let outcome = run_send_keys_x(&mut app, &cmd, count);
                    if let Some(resp) = resp { let _ = resp.send(outcome); }
                }
                // copied from server/mod.rs run_server (line 4810 at 0145958f)
                CtrlReq::SetPaneInputOff { target, off, last, resp } => {
                    // select-pane -d / -e.  No hook: tmux returns from
                    // cmd-select-pane.c right after flipping the flag, before
                    // the activation that fires `after-select-pane`.
                    let outcome = set_pane_input_off(&mut app, target.as_ref(), off, last);
                    match resp {
                        Some(r) => { let _ = r.send(outcome); }
                        None => {
                            if let Err(e) = outcome {
                                app.status_message = Some((e, Instant::now(), None));
                            }
                        }
                    }
                    // `#{pane_input_off}` may be on the status line.
                    meta_dirty = true;
                    state_dirty = true;
                }
                // copied from server/mod.rs run_server (line 4827 at 0145958f)
                CtrlReq::SelectPane(dir, keep_zoom) => {
                    if let Some(cmds) = app.hooks.get("before-select-pane") { let cmds = cmds.clone(); for cmd in &cmds { let _ = execute_command_string(&mut app, cmd); } }
                    let _pane_before = active_pane_identity(&app);
                    // Auto-unzoom when navigating to another pane (tmux behavior).
                    // For directional nav: unzoom first so compute_rects uses
                    // real geometry, then re-zoom only if focus didn't change.
                    // For other cases: only unzoom if focus actually changes.
                    // (fixes #46)
                    match dir.as_str() {
                        "U" | "D" | "L" | "R" => {
                            let focus_dir = match dir.as_str() {
                                "U" => FocusDir::Up, "D" => FocusDir::Down,
                                "L" => FocusDir::Left, _ => FocusDir::Right,
                            };
                            if keep_zoom {
                                let old_path = app.windows[app.active_idx].active_path.clone();
                                switch_with_copy_save(&mut app, |app| {
                                    move_focus_preserving_zoom(app, focus_dir);
                                });
                                if app.windows[app.active_idx].active_path != old_path {
                                    app.last_pane_path = old_path;
                                }
                            } else {
                                let was_zoomed = unzoom_if_zoomed(&mut app);
                                if was_zoomed {
                                // Zoom-aware: check direct neighbor or wrap target (tmux parity: unzoom+wrap).
                                let win = &app.windows[app.active_idx];
                                let mut rects: Vec<(Vec<usize>, ratatui::layout::Rect)> = Vec::new();
                                crate::tree::compute_rects(&win.root, app.last_window_area, &mut rects);
                                let active_idx = rects.iter().position(|(path, _)| *path == win.active_path);
                                let has_target = 
                                    if let Some(ai) = active_idx {
                                        let (_, arect) = &rects[ai];
                                        find_best_pane_in_direction(&rects, ai, arect, focus_dir, &[], &[])
                                            .or_else(|| find_wrap_target(&rects, ai, arect, focus_dir, &[], &[]))
                                            .is_some()
                                    } else { false };
                                    if has_target {
                                        let old_path = app.windows[app.active_idx].active_path.clone();
                                        switch_with_copy_save(&mut app, |app| {
                                            move_focus(app, focus_dir);
                                        });
                                        app.last_pane_path = old_path;
                                    } else {
                                        // No reachable pane (single-pane window) — re-zoom
                                        toggle_zoom(&mut app);
                                    }
                                } else {
                                    let old_path = app.windows[app.active_idx].active_path.clone();
                                    switch_with_copy_save(&mut app, |app| {
                                        move_focus(app, focus_dir);
                                    });
                                    if app.windows[app.active_idx].active_path != old_path {
                                        app.last_pane_path = old_path;
                                    }
                                }
                            }
                        }
                        "last" => {
                            // select-pane -l: switch to last active pane.  The
                            // target (and the `no last pane` refusal) is
                            // decided in one place, `last_pane_path`, which is
                            // tmux's cmd-select-pane.c:165-177; the request
                            // that carries the diagnostic to the caller is
                            // `CtrlReq::LastPane` (#693 item 5).
                            let old_path = app.windows[app.active_idx].active_path.clone();
                            let target = last_pane_path(&app);
                            switch_with_copy_save(&mut app, |app| {
                                if let Some(t) = target {
                                    let win = &mut app.windows[app.active_idx];
                                    let tmp = win.active_path.clone();
                                    win.active_path = t;
                                    app.last_pane_path = tmp;
                                }
                            });
                            if app.windows[app.active_idx].active_path != old_path {
                                // Update MRU for the newly focused pane
                                let win = &mut app.windows[app.active_idx];
                                if let Some(pid) = get_active_pane_id(&win.root, &win.active_path) {
                                    crate::tree::touch_mru(&mut win.pane_mru, pid);
                                }
                                unzoom_if_zoomed(&mut app);
                            }
                        }
                        "mark" => {
                            // select-pane -m: mark the current pane
                            let win = &app.windows[app.active_idx];
                            if let Some(pid) = get_active_pane_id(&win.root, &win.active_path) {
                                app.marked_pane = Some((app.active_idx, pid));
                            }
                        }
                        "next" => {
                            // select-pane next: cycle to next pane (like Prefix+o / tmux -t :.+)
                            let old_path = app.windows[app.active_idx].active_path.clone();
                            switch_with_copy_save(&mut app, |app| {
                                let win = &app.windows[app.active_idx];
                                let mut pane_paths = Vec::new();
                                let mut path = Vec::new();
                                collect_pane_paths_server(&win.root, &mut path, &mut pane_paths);
                                if let Some(cur) = pane_paths.iter().position(|p| *p == win.active_path) {
                                    let next = (cur + 1) % pane_paths.len();
                                    let new_path = pane_paths[next].clone();
                                    let win = &mut app.windows[app.active_idx];
                                    app.last_pane_path = win.active_path.clone();
                                    win.active_path = new_path;
                                }
                            });
                            if app.windows[app.active_idx].active_path != old_path {
                                let win = &mut app.windows[app.active_idx];
                                if let Some(pid) = get_active_pane_id(&win.root, &win.active_path) {
                                    crate::tree::touch_mru(&mut win.pane_mru, pid);
                                }
                                unzoom_if_zoomed(&mut app);
                            }
                        }
                        "prev" => {
                            // select-pane prev: cycle to previous pane (tmux -t :.-)
                            let old_path = app.windows[app.active_idx].active_path.clone();
                            switch_with_copy_save(&mut app, |app| {
                                let win = &app.windows[app.active_idx];
                                let mut pane_paths = Vec::new();
                                let mut path = Vec::new();
                                collect_pane_paths_server(&win.root, &mut path, &mut pane_paths);
                                if let Some(cur) = pane_paths.iter().position(|p| *p == win.active_path) {
                                    let prev = (cur + pane_paths.len() - 1) % pane_paths.len();
                                    let new_path = pane_paths[prev].clone();
                                    let win = &mut app.windows[app.active_idx];
                                    app.last_pane_path = win.active_path.clone();
                                    win.active_path = new_path;
                                }
                            });
                            if app.windows[app.active_idx].active_path != old_path {
                                let win = &mut app.windows[app.active_idx];
                                if let Some(pid) = get_active_pane_id(&win.root, &win.active_path) {
                                    crate::tree::touch_mru(&mut win.pane_mru, pid);
                                }
                                unzoom_if_zoomed(&mut app);
                            }
                        }
                        "unmark" => {
                            // select-pane -M: clear the marked pane
                            app.marked_pane = None;
                        }
                        _ => {}
                    }
                    meta_dirty = true;
                    // tmux fires `after-select-pane` from the activation at
                    // cmd-select-pane.c:276, which line :269 skips when the
                    // pane did not move; `-m` and `-M` return earlier still
                    // (cmd-select-pane.c:100) and never reach it, and neither
                    // do `-e` and `-d` (:180), which are not this request at
                    // all but `CtrlReq::SetPaneInputOff`.
                    if active_pane_identity(&app) != _pane_before {
                        note_pane_focus_change(&app, &mut notify_events);
                        hook_event = Some("after-select-pane");
                    }
                }
                // copied from server/mod.rs run_server (line 5008 at 0145958f)
                CtrlReq::ListPanes(resp) => {
                    helpers::propagate_osc_titles(&mut app);
                    let mut output = String::new();
                    let win = &app.windows[app.active_idx];
                    fn collect_panes(node: &Node, panes: &mut Vec<(usize, u16, u16, vt100::MouseProtocolMode, vt100::MouseProtocolEncoding, bool, usize, usize)>) {
                        match node {
                            Node::Leaf(p) => {
                                let (mode, enc, alt, hist_rows, hist_bytes) = match p.term.lock() {
                                    Ok(term) => {
                                        let screen = term.screen();
                                        (screen.mouse_protocol_mode(), screen.mouse_protocol_encoding(), screen.alternate_screen(), screen.scrollback_filled(), screen.history_bytes())
                                    }
                                    Err(_) => {
                                        // Mutex poisoned — reader thread panicked.  Use safe defaults.
                                        (vt100::MouseProtocolMode::None, vt100::MouseProtocolEncoding::Default, false, 0, 0)
                                    }
                                };
                                panes.push((p.id, p.last_cols, p.last_rows, mode, enc, alt, hist_rows, hist_bytes));
                            }
                            Node::Split { children, .. } => {
                                for c in children { collect_panes(c, panes); }
                            }
                        }
                    }
                    let mut panes = Vec::new();
                    collect_panes(&win.root, &mut panes);
                    // A focused floating pane is the active pane (tmux makes it
                    // w->active), so the tiled pane behind it is not (#767).
                    let focused_float = win.floating_focus.filter(|fi| *fi < win.floating.len());
                    let active_pane_id = match focused_float {
                        Some(fi) => Some(win.floating[fi].id),
                        None => crate::tree::get_active_pane_id(&win.root, &win.active_path),
                    };
                    let tiled_count = panes.len();
                    for (pos, (id, cols, rows, _mode, _enc, _alt, hist_rows, hist_bytes)) in panes.iter().enumerate() {
                        let idx = pos + app.pane_base_index;
                        let active_marker = if active_pane_id == Some(*id) { " (active)" } else { "" };
                        // The rows retained and the bytes they cost, like tmux.
                        // Both used to be faked (the limit, and a literal 0),
                        // which hid the scrollback growth behind issue #641.
                        output.push_str(&format!("{}: [{}x{}] [history {}/{}, {} bytes] %{}{}\n", idx, cols, rows, hist_rows, app.history_limit, hist_bytes, id, active_marker));
                    }
                    // Floating panes follow the tiled ones, in tmux's own
                    // default line: cmd-list-panes.c adds
                    // `#{?pane_floating_flag, #{pane_x},#{pane_y},#{pane_z}}`
                    // inside the size brackets (#767). They were not listed.
                    let nfloat = win.floating.len();
                    for (fi, fp) in win.floating.iter().enumerate() {
                        let idx = tiled_count + fi + app.pane_base_index;
                        let (hist_rows, hist_bytes) = match fp.pane.term.lock() {
                            Ok(term) => (term.screen().scrollback_filled(), term.screen().history_bytes()),
                            Err(_) => (0, 0),
                        };
                        let (ox, oy) = if fp.border == "none" { (fp.x, fp.y) } else { (fp.x + 1, fp.y + 1) };
                        let px = win.area.x + ox;
                        let py = win.area.y + oy;
                        let pz = nfloat - 1 - fi;
                        let active_marker = if active_pane_id == Some(fp.id) { " (active)" } else { "" };
                        output.push_str(&format!("{}: [{}x{} {},{},{}] [history {}/{}, {} bytes] %{}{}\n",
                            idx, fp.pane.last_cols, fp.pane.last_rows, px, py, pz,
                            hist_rows, app.history_limit, hist_bytes, fp.id, active_marker));
                    }
                    let _ = resp.send(output);
                }
                // copied from server/mod.rs run_server (line 5072 at 0145958f)
                CtrlReq::ListPanesFormat(resp, fmt) => {
                    helpers::propagate_osc_titles(&mut app);
                    let text = format_list_panes(&app, &fmt, app.active_idx);
                    let _ = resp.send(text);
                }
                // copied from server/mod.rs run_server (line 5077 at 0145958f)
                CtrlReq::ListAllPanes(resp) => {
                    let mut output = String::new();
                    fn collect_all_panes(node: &Node, panes: &mut Vec<(usize, u16, u16)>) {
                        match node {
                            Node::Leaf(p) => { panes.push((p.id, p.last_cols, p.last_rows)); }
                            Node::Split { children, .. } => { for c in children { collect_all_panes(c, panes); } }
                        }
                    }
                    for (wi, win) in app.windows.iter().enumerate() {
                        let mut panes = Vec::new();
                        collect_all_panes(&win.root, &mut panes);
                        // Floating panes are panes of the window too (#767).
                        panes.extend(win.floating.iter().map(|fp| (fp.id, fp.pane.last_cols, fp.pane.last_rows)));
                        for (id, cols, rows) in panes {
                            output.push_str(&format!("{}:{}: %{} [{}x{}]\n", app.session_name, app.win_display_index(wi), id, cols, rows));
                        }
                    }
                    let _ = resp.send(output);
                }
                // copied from server/mod.rs run_server (line 5096 at 0145958f)
                CtrlReq::ListAllPanesFormat(resp, fmt) => {
                    let mut lines = Vec::new();
                    for wi in 0..app.windows.len() {
                        lines.push(format_list_panes(&app, &fmt, wi));
                    }
                    let _ = resp.send(lines.join("\n"));
                }
                // copied from server/mod.rs run_server (line 5771 at 0145958f)
                CtrlReq::DisplayMessage(resp, fmt, target_pane_idx, set_status_bar, duration_ms, client_sel, flags) => {
                    // Propagate OSC titles so #{pane_title} reflects latest state
                    helpers::propagate_osc_titles(&mut app);
                    // `-c` picks the client the client_* variables describe. A
                    // client tmux cannot find is not an error for this command
                    // (CMD_CLIENT_CANFAIL): the best client answers instead.
                    let client = client_sel.as_ref().and_then(|s| crate::format::resolve_client_sel(&app, s));
                    let result = if flags.literal {
                        fmt.clone()
                    } else {
                        crate::format::with_format_client(client, || if let Some(pane_idx) = target_pane_idx {
                            // -t targeting: evaluate format for the specific pane
                            // using PANE_POS_OVERRIDE so #{pane_active} reflects
                            // the REAL active pane, not the target (#113)
                            match pane_idx.checked_sub(app.pane_base_index) {
                                Some(pos) => crate::format::expand_format_for_pane(&fmt, &app, app.active_idx, pos),
                                None => String::new(),
                            }
                        } else {
                            expand_format(&fmt, &app)
                        })
                    };
                    if set_status_bar {
                        let shown_at = Instant::now();
                        app.status_message = Some((result.clone(), shown_at, duration_ms));
                        app.status_message_ignore_keys = flags.ignore_keys.then_some(shown_at);
                        state_dirty = true;
                    }
                    let _ = resp.send(result);
                }
                // copied from server/mod.rs run_server (line 5801 at 0145958f)
                CtrlReq::DisplayMessageById(resp, fmt, pane_id, set_status_bar, duration_ms, client_sel, flags) => {
                    // Bare %N pane targeting (#332) — resolve the pane ID
                    // globally across all windows and expand the format with
                    // PANE_POS_OVERRIDE pointing at it.
                    helpers::propagate_osc_titles(&mut app);
                    let client = client_sel.as_ref().and_then(|s| crate::format::resolve_client_sel(&app, s));
                    let result = if flags.literal {
                        fmt.clone()
                    } else {
                        crate::format::with_format_client(client, || {
                            crate::format::expand_format_for_pane_by_id(&fmt, &app, pane_id)
                        })
                    };
                    if set_status_bar {
                        let shown_at = Instant::now();
                        app.status_message = Some((result.clone(), shown_at, duration_ms));
                        app.status_message_ignore_keys = flags.ignore_keys.then_some(shown_at);
                        state_dirty = true;
                    }
                    let _ = resp.send(result);
                }
                // copied from server/mod.rs run_server (line 5103 at 0145958f)
                CtrlReq::KillWindow => {
                    let active = app.active_idx;
                    kill_window_at(&mut app, active);
                    // Killing a window changes the active window and the window
                    // list, so resize the now-active window's panes and force a
                    // status-bar/window-list rebuild + push to attached clients.
                    // Without meta_dirty the cached window tabs stay stale and
                    // without state_dirty the no-change fast path skips the frame,
                    // leaving the bottom bar showing the killed window until the
                    // next input (issue #359). Mirrors every other structural
                    // mutation (new-window, kill-pane, select-window) and tmux's
                    // server_kill_window -> server_redraw_session_group.
                    resize_all_panes(&mut app);
                    meta_dirty = true;
                    state_dirty = true;
                    // A killed window leaves the session's window list, which
                    // is what tmux calls unlinking: session.c:349
                    // `session_detach` fires window-unlinked before it removes
                    // the winlink (issue #691).
                    notify_events.push("window-unlinked");
                    hook_event = Some("window-closed");
                }
                // copied from server/mod.rs run_server (line 5125 at 0145958f)
                CtrlReq::KillWindowTarget { win, win_is_id, name, resp } => {
                    // Resolve the target here, on live state. An unresolvable
                    // target must be an error, never a fallback to the active
                    // window: the old temp-focus-then-kill dance silently
                    // no-opped the focus on a bad name/index/@id and then
                    // killed whatever was focused (session death when it was
                    // the last window). tmux: "can't find window: X", kills
                    // nothing, exit 1.
                    let resolved = if let Some(w) = win {
                        if win_is_id {
                            app.windows.iter().position(|x| x.id == w)
                        } else {
                            app.win_pos(w)
                        }
                    } else if let Some(ref n) = name {
                        app.windows.iter().position(|x| x.name == *n)
                    } else {
                        Some(app.active_idx)
                    };
                    match resolved {
                        Some(pos) => {
                            kill_window_at(&mut app, pos);
                            resize_all_panes(&mut app);
                            meta_dirty = true;
                            state_dirty = true;
                            notify_events.push("window-unlinked");
                            hook_event = Some("window-closed");
                            let _ = resp.send(Ok(()));
                        }
                        None => {
                            let spec = if let Some(w) = win {
                                if win_is_id { format!("@{}", w) } else { w.to_string() }
                            } else {
                                name.clone().unwrap_or_default()
                            };
                            let msg = format!("can't find window: {}", spec);
                            // Surface in the status bar for attached clients,
                            // same convention as join-pane (#437).
                            app.status_message = Some((msg.clone(), Instant::now(), None));
                            state_dirty = true;
                            let _ = resp.send(Err(msg));
                        }
                    }
                }
                // copied from server/mod.rs run_server (line 4354 at 0145958f)
                CtrlReq::FocusWindowCmd(wid) => { switch_with_copy_save(&mut app, |app| { if let Some(idx) = find_window_index_by_id(app, wid) { app.active_idx = idx; } }); resize_all_panes(&mut app); meta_dirty = true; }
                // copied from server/mod.rs run_server (line 4348 at 0145958f)
                CtrlReq::FocusPaneCmd(pid) => {
                    let old_path = app.windows[app.active_idx].active_path.clone();
                    switch_with_copy_save(&mut app, |app| { focus_pane_by_id(app, pid); });
                    if app.windows[app.active_idx].active_path != old_path { unzoom_if_zoomed(&mut app); }
                    meta_dirty = true;
                }
                // copied from server/mod.rs run_server (line 3540 at 0145958f)
                CtrlReq::FocusWindow(wid) => {
                    // wid is a display index (same as tmux window number), convert to internal array index
                    if let Some(internal_idx) = app.win_pos(wid) {
                        focus_window_at(&mut app, internal_idx);
                    }
                    meta_dirty = true;
                    hook_event = Some("after-select-window");
                }
                // copied from server/mod.rs run_server (line 3555 at 0145958f)
                CtrlReq::FocusWindowById(id) => {
                    if let Some(internal_idx) = app.windows.iter().position(|w| w.id == id) {
                        focus_window_at(&mut app, internal_idx);
                    }
                    meta_dirty = true;
                    hook_event = Some("after-select-window");
                }
                // One request for the whole `-t` of a `select-pane` (#691).
                // copied from server/mod.rs run_server (line 3548 at 0145958f)
                CtrlReq::FocusWindowByName(ref name) => {
                    if let Some(internal_idx) = app.windows.iter().position(|w| w.name == *name) {
                        focus_window_at(&mut app, internal_idx);
                    }
                    meta_dirty = true;
                    hook_event = Some("after-select-window");
                }
                // copied from server/mod.rs run_server (line 3651 at 0145958f)
                CtrlReq::FocusPane(pid) => {
                    let old_path = app.windows[app.active_idx].active_path.clone();
                    switch_with_copy_save(&mut app, |app| { focus_pane_by_id(app, pid); });
                    if app.windows[app.active_idx].active_path != old_path { unzoom_if_zoomed(&mut app); }
                    meta_dirty = true;
                }
                // copied from server/mod.rs run_server (line 4389 at 0145958f)
                CtrlReq::NextWindow => {
                    if let Some(cmds) = app.hooks.get("before-select-window") { let cmds = cmds.clone(); for cmd in &cmds { let _ = execute_command_string(&mut app, cmd); } }
                    if !app.windows.is_empty() { switch_with_copy_save(&mut app, |app| { app.last_window_idx = app.active_idx; app.active_idx = (app.active_idx + 1) % app.windows.len(); }); resize_all_panes(&mut app); } meta_dirty = true; hook_event = Some("after-select-window");
                }
                // copied from server/mod.rs run_server (line 4393 at 0145958f)
                CtrlReq::PrevWindow => {
                    if let Some(cmds) = app.hooks.get("before-select-window") { let cmds = cmds.clone(); for cmd in &cmds { let _ = execute_command_string(&mut app, cmd); } }
                    if !app.windows.is_empty() { switch_with_copy_save(&mut app, |app| { app.last_window_idx = app.active_idx; app.active_idx = (app.active_idx + app.windows.len() - 1) % app.windows.len(); }); resize_all_panes(&mut app); } meta_dirty = true; hook_event = Some("after-select-window");
                }
                // copied from server/mod.rs run_server (line 5822 at 0145958f)
                CtrlReq::LastWindow { resp } => {
                    match app.last_window_pos() {
                        Some(last) => {
                            switch_with_copy_save(&mut app, |app| {
                                let tmp = app.active_idx;
                                app.active_idx = last;
                                app.last_window_idx = tmp;
                            });
                            meta_dirty = true;
                            hook_event = Some("after-select-window");
                            if let Some(r) = resp { let _ = r.send(Ok(())); }
                        }
                        // cmd-select-window.c:118-120.  psmux exited 0 in
                        // silence here, with no window to go back to.
                        None => {
                            if let Some(r) = resp { let _ = r.send(Err("no last window".to_string())); }
                        }
                    }
                }
                // copied from server/mod.rs run_server (line 5841 at 0145958f)
                CtrlReq::LastPane { resp } => {
                    match last_pane_path(&app) {
                        Some(target) => {
                            switch_with_copy_save(&mut app, |app| {
                                let win = &mut app.windows[app.active_idx];
                                let tmp = win.active_path.clone();
                                win.active_path = target;
                                app.last_pane_path = tmp;
                            });
                            let win = &mut app.windows[app.active_idx];
                            if let Some(pid) = get_active_pane_id(&win.root, &win.active_path) {
                                crate::tree::touch_mru(&mut win.pane_mru, pid);
                            }
                            unzoom_if_zoomed(&mut app);
                            meta_dirty = true;
                            note_pane_focus_change(&app, &mut notify_events);
                            let _ = resp.send(Ok(()));
                        }
                        // cmd-select-pane.c:175-177.  psmux exited 0 in silence
                        // here (issue #693 item 5).
                        None => { let _ = resp.send(Err("no last pane".to_string())); }
                    }
                }
                // copied from server/mod.rs run_server (line 4397 at 0145958f)
                CtrlReq::RenameWindow(name) => {
                    if let Some(cmds) = app.hooks.get("before-rename-window") { let cmds = cmds.clone(); for cmd in &cmds { let _ = execute_command_string(&mut app, cmd); } }
                    // tmux parity (#552): the argument is a format, expanded
                    // against the target window (cmd-rename-window.c runs it
                    // through format_single_from_target). The temporary -t
                    // focus has already made the target the active window
                    // here, so #{window_name} etc. resolve against it —
                    // enabling idioms like `rename-window '#{b:pane_current_path}'`.
                    let name = expand_format(&name, &app);
                    let name = crate::util::clean_name(&name);
                    let win = &mut app.windows[app.active_idx]; win.name = name; win.manual_rename = true; meta_dirty = true; hook_event = Some("after-rename-window");
                }
                // copied from server/mod.rs run_server (line 7703 at 0145958f)
                CtrlReq::ClientEnviron(env) => {
                    app.env_scopes.pending_client_environ = Some(env);
                }
                // copied from server/mod.rs run_server (line 7135 at 0145958f)
                CtrlReq::SetClientReadonly(cid, readonly) => {
                    if let Some(info) = app.client_registry.get_mut(&cid) {
                        info.readonly = readonly;
                    }
                }
                // copied from server/mod.rs run_server (line 7365 at 0145958f)
                CtrlReq::SetClientLastSession(cid, prev) => {
                    if let Some(info) = app.client_registry.get_mut(&cid) {
                        info.last_session = Some(prev);
                    }
                }
                // copied from server/mod.rs run_server (line 4418 at 0145958f)
                CtrlReq::WindowDump(wid, format, resp) => {
                    let result = if format == crate::types::WindowDumpFormat::Layout {
                        crate::layout::dump_window_layout_json(&mut app, wid)
                    } else {
                        crate::layout::dump_window_layout(&mut app, wid)
                            .and_then(|layout| {
                                let border_lines =
                                    options::get_option_value(&app, "pane-border-lines");
                                let border_indicators =
                                    crate::pane_border::PaneBorderIndicators::parse(
                                        &options::get_option_value(
                                            &app,
                                            "pane-border-indicators",
                                        ),
                                    )
                                    .map_err(std::io::Error::other)?;
                                let window_index = app.windows
                                    .iter()
                                    .position(|window| window.id == wid)
                                    .ok_or_else(|| std::io::Error::other("window not found"))?;
                                let _async_fmt = crate::format::AsyncFormatGuard::new();
                                let pane_border_style = if app.pane_border_style.is_empty() {
                                    String::new()
                                } else {
                                    crate::format::expand_format_for_window(
                                        &app.pane_border_style,
                                        &app,
                                        window_index,
                                    )
                                };
                                let pane_active_border_style =
                                    if app.pane_active_border_style.is_empty() {
                                        String::new()
                                    } else {
                                        crate::format::expand_format_for_window(
                                            &app.pane_active_border_style,
                                            &app,
                                            window_index,
                                        )
                                    };
                                let floating_pane_focused =
                                    app.windows[window_index].floating_focus.is_some();
                                serde_json::to_string(&crate::types::PreviewWindowState {
                                    layout,
                                    border_lines,
                                    border_indicators,
                                    pane_border_style: Some(pane_border_style),
                                    pane_active_border_style: Some(pane_active_border_style),
                                    floating_pane_focused,
                                })
                                .map_err(std::io::Error::other)
                            })
                    };
                    let json = result.unwrap_or_else(|_| "{}".to_string());
                    let _ = resp.send(json);
                }
                // copied from server/mod.rs run_server (line 4413 at 0145958f)
                CtrlReq::WindowLayout(wid, resp) => {
                    let json = crate::util::window_layout_json(&app, wid)
                        .unwrap_or_else(|_| "{}".to_string());
                    let _ = resp.send(json);
                }
                // copied from server/mod.rs run_server (line 4475 at 0145958f)
                CtrlReq::SetPaneTitle(title) => {
                    let win = &mut app.windows[app.active_idx];
                    if let Some(p) = active_pane_mut(&mut win.root, &win.active_path) {
                        p.title_locked = !title.is_empty();
                        p.title = title;
                    }
                    meta_dirty = true;
                }
                // copied from server/mod.rs run_server (line 4474 at 0145958f)
                CtrlReq::ToggleSync => { app.sync_input = !app.sync_input; }
                // copied from server/mod.rs run_server (line 4387 at 0145958f)
                CtrlReq::SplitSetSizes(cid, path, sizes) => { if app.mouse_enabled { app.latest_client_id = Some(cid); handle_split_set_sizes(&mut app, &path, &sizes); state_dirty = true; meta_dirty = true; echo_pending_until = Some(Instant::now()); } }
                // copied from server/mod.rs run_server (line 4388 at 0145958f)
                CtrlReq::SplitResizeDone(cid) => { if app.mouse_enabled { app.latest_client_id = Some(cid); handle_split_resize_done(&mut app); state_dirty = true; meta_dirty = true; } }
                // copied from server/mod.rs run_server (line 4984 at 0145958f)
                CtrlReq::SelectWindow(idx) => {
                    if let Some(cmds) = app.hooks.get("before-select-window") { let cmds = cmds.clone(); for cmd in &cmds { let _ = execute_command_string(&mut app, cmd); } }
                    if let Some(internal_idx) = app.win_pos(idx) {
                        if internal_idx != app.active_idx {
                            switch_with_copy_save(&mut app, |app| {
                                app.last_window_idx = app.active_idx;
                                app.active_idx = internal_idx;
                            });
                            // Clear activity/bell/silence flags on the newly
                            // focused window.  This request is now the only one
                            // a `select-window -t <index>` sends (#690), so the
                            // clearing FocusWindow used to do has to happen
                            // here or a selected window would keep its alert.
                            if let Some(win) = app.windows.get_mut(internal_idx) {
                                win.activity_flag = false;
                                win.bell_flag = false;
                                win.silence_flag = false;
                            }
                            resize_all_panes(&mut app);
                        }
                    }
                    meta_dirty = true;
                    hook_event = Some("after-select-window");
                }
                // shared: everything step 2 does not handle (see the module
                // comment). Its reply channel, if any, closes here.
                _ => {}
        }
        // copied from run_server (server/mod.rs at 0145958f, after the match):
        // notification hooks, the after-<command> hook, the focus restore.
        for event in std::mem::take(&mut notify_events) {
            let cmds: Vec<String> = app.hooks.get(event).cloned().unwrap_or_default();
            for cmd in cmds {
                let _ = execute_command_string(&mut app, &cmd);
            }
        }
        if let Some(event) = hook_event {
            let cmds: Vec<String> = app.hooks.get(event).cloned().unwrap_or_default();
            for cmd in cmds {
                let _ = execute_command_string(&mut app, &cmd);
            }
        }
        temp_target::restore_temp_focus(&mut app, &mut temp_focus_restore);
        control::sync_window_changes(&mut app);
        if mutates_state {
            state_dirty = true;
        }
        if app.copy_needs_redraw {
            app.copy_needs_redraw = false;
            state_dirty = true;
        }
    }
    lp.state_dirty = state_dirty;
    lp.meta_dirty = meta_dirty;
    lp.echo_pending_until = echo_pending_until;
    lp.temp_focus_restore = temp_focus_restore;
    Ok(flow)
}
