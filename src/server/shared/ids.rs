//! The shared server's own id allocator (#798 step 2).
//!
//! tmux hands out window ids `@N` and pane ids `%N` from one counter per
//! server (`next_window_id` / `next_window_pane_id`, window.c), so a bare `%N`
//! names one pane in the whole server. psmux keeps the counters in `AppState`
//! (`next_win_id`, `next_pane_id`), one per session, and the per session code
//! that creates windows and panes reads and bumps them there. Rather than
//! change that code (owner ruling: the default path stays untouched), the
//! shared server lends the server wide counters to a session for exactly the
//! span of one request: `lend` copies them into the session before the request
//! runs and `take_back` reads them out after it. Every request of every
//! session runs on the one loop thread, so no two sessions ever hold the
//! counters at once and the ids stay unique and dense across the server.

/// Server wide window and pane id counters.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ServerIds {
    next_window: usize,
    next_pane: usize,
}

impl Default for ServerIds {
    fn default() -> Self {
        Self::new()
    }
}

impl ServerIds {
    /// A fresh server: the first window is `@1` and the first pane `%1`,
    /// exactly the first ids a per session server hands out.
    pub fn new() -> Self {
        ServerIds { next_window: 1, next_pane: 1 }
    }

    /// The next window id that would be handed out.
    pub fn next_window(&self) -> usize {
        self.next_window
    }

    /// The next pane id that would be handed out.
    pub fn next_pane(&self) -> usize {
        self.next_pane
    }

    /// Lend the counters to a session's own fields before its request runs.
    pub fn lend(&self, next_win_id: &mut usize, next_pane_id: &mut usize) {
        *next_win_id = self.next_window;
        *next_pane_id = self.next_pane;
    }

    /// Take the counters back after the request. A counter never moves
    /// backwards, even if the session's field was lowered meanwhile, so an id
    /// once handed out is never handed out again.
    pub fn take_back(&mut self, next_win_id: usize, next_pane_id: usize) {
        self.next_window = self.next_window.max(next_win_id);
        self.next_pane = self.next_pane.max(next_pane_id);
    }

    /// Hand out one window id directly (used by tests and by code that
    /// allocates outside a lent span).
    pub fn alloc_window(&mut self) -> usize {
        let id = self.next_window;
        self.next_window += 1;
        id
    }

    /// Hand out one pane id directly.
    pub fn alloc_pane(&mut self) -> usize {
        let id = self.next_pane;
        self.next_pane += 1;
        id
    }
}
