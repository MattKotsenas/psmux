//! Request routing of the shared server (#798 step 2). Pure: no sockets.
//!
//! A shared server gives each of its sessions its own listener, so the
//! listener a connection arrives on already says which session it is for.
//! What is left to decide per connection is whether the shared server serves
//! the request at all: the step 2 server handles a subset of commands (it
//! carries a copy of the per session handlers for those only), and anything
//! else is answered by `reply` in the per session server's unknown command
//! shape, before the connection reaches the shared protocol handler.

/// Commands (and their aliases) a one shot connection may run on a shared
/// server in step 2. The attach protocol lines an attached client sends are
/// listed too, because a client can send them on a one shot connection.
pub const SUPPORTED: &[&str] = &[
    // windows and panes
    "new-window", "neww",
    "split-window", "splitw", "split-pane", "splitp",
    "kill-pane", "killp",
    "kill-window", "killw",
    "select-window", "selectw",
    "select-pane", "selectp",
    "next-window", "next",
    "previous-window", "prev",
    "last-window", "last",
    "last-pane", "lastp",
    "rename-window", "renamew",
    "set-pane-title",
    // input and output
    "send-keys", "send",
    "send-text", "send-key", "send-paste",
    "capture-pane", "capturep",
    "display-message", "display",
    // listings
    "list-windows", "lsw",
    "list-panes", "lsp",
    "list-tree",
    "window-layout",
    "window-dump",
    "dump-layout",
    "dump-state", "dump",
    // sessions and the server
    "session-info",
    "list-sessions", "ls",
    "has-session",
    "kill-session", "kill-ses",
    "kill-server",
    // the attach handshake
    "client-attach", "client-detach", "client-size", "client-flags",
    "client-environ", "client-last-session", "host-colors",
    "prefix-begin", "prefix-end",
    "focus-window", "focus-pane",
];

/// True when `name` is a command the step 2 shared server runs.
pub fn is_supported(name: &str) -> bool {
    SUPPORTED.contains(&name)
}

/// The first command of a command line (or of a `;` list) the shared server
/// does not run, if any. tmux parses the whole list before it runs any of it,
/// so one unsupported command anywhere refuses the whole line.
pub fn first_unsupported(line: &str) -> Option<String> {
    for part in crate::config::split_chained_commands_pub(line.trim()) {
        let words = crate::commands::parse_command_line(&part);
        let Some(name) = words.into_iter().next() else { continue };
        if !is_supported(&name) {
            return Some(name);
        }
    }
    None
}

/// How a connection opens: the second line after `AUTH`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Opening {
    /// `AUTH <key>` then `PERSISTENT`: an attached client.
    Persistent { key: String },
    /// `AUTH <key>` then `CONTROL`, `CONTROL_QUIET` or `CONTROL_NOECHO`.
    Control { key: String },
    /// `AUTH <key>`, an optional `TARGET <spec>` line, then a command line.
    /// `lines` is how many lines the opening takes, command line included.
    Command { key: String, line: String, lines: usize },
    /// Not enough bytes yet, or no `AUTH` line: leave it to the protocol
    /// handler, which answers exactly as the per session server does.
    Undecided,
}

/// Read the opening of a connection from the bytes peeked off its socket.
pub fn parse_opening(peeked: &[u8]) -> Opening {
    let text = String::from_utf8_lossy(peeked);
    // Only lines whose newline has arrived count.
    let mut lines: Vec<&str> = text.split('\n').collect();
    lines.pop();
    let Some(first) = lines.first() else { return Opening::Undecided };
    let Some(key) = first.trim_end_matches('\r').strip_prefix("AUTH ") else {
        return Opening::Undecided;
    };
    let key = key.trim().to_string();
    let Some(second) = lines.get(1).map(|l| l.trim_end_matches('\r').trim()) else {
        return Opening::Undecided;
    };
    match second {
        "PERSISTENT" => Opening::Persistent { key },
        "CONTROL" | "CONTROL_QUIET" | "CONTROL_NOECHO" => Opening::Control { key },
        s if s.starts_with("TARGET ") => match lines.get(2) {
            Some(l) => Opening::Command { key, line: l.trim_end_matches('\r').trim().to_string(), lines: 3 },
            None => Opening::Undecided,
        },
        line => Opening::Command { key, line: line.to_string(), lines: 2 },
    }
}

/// True when enough bytes were peeked to decide.
pub fn opening_complete(peeked: &[u8]) -> bool {
    parse_opening(peeked) != Opening::Undecided
}

/// A `new-session` the shared CLI sends to the server's control listener.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct NewSessionArgs {
    pub name: Option<String>,
    pub window_name: Option<String>,
    pub start_dir: Option<String>,
    /// The directory the CLI ran in: where the session's panes start when no
    /// `-c` is given, as a per session server inherits it.
    pub cwd: Option<String>,
    pub width: Option<u16>,
    pub height: Option<u16>,
    pub command: Option<String>,
    pub raw: Option<Vec<String>>,
    pub env: Vec<(String, String)>,
    pub print: bool,
    pub format: Option<String>,
}

/// Escape a field value for one line of the control protocol.
pub fn encode_field(v: &str) -> String {
    let mut out = String::with_capacity(v.len());
    for c in v.chars() {
        match c {
            '%' => out.push_str("%25"),
            '\n' => out.push_str("%0A"),
            '\r' => out.push_str("%0D"),
            _ => out.push(c),
        }
    }
    out
}

/// Undo `encode_field`.
pub fn decode_field(v: &str) -> String {
    let mut out = String::with_capacity(v.len());
    let mut rest = v;
    while let Some(i) = rest.find('%') {
        out.push_str(&rest[..i]);
        let code = rest.get(i + 1..i + 3);
        match code {
            Some("25") => out.push('%'),
            Some("0A") => out.push('\n'),
            Some("0D") => out.push('\r'),
            _ => {
                out.push('%');
                rest = &rest[i + 1..];
                continue;
            }
        }
        rest = &rest[i + 3..];
    }
    out.push_str(rest);
    out
}

/// The `field=value` lines (values escaped) for a new-session request.
pub fn new_session_fields(a: &NewSessionArgs) -> Vec<String> {
    let mut out = Vec::new();
    let mut put = |k: &str, v: &str| out.push(format!("{}={}", k, encode_field(v)));
    if let Some(ref v) = a.name { put("name", v); }
    if let Some(ref v) = a.window_name { put("window_name", v); }
    if let Some(ref v) = a.start_dir { put("start_dir", v); }
    if let Some(ref v) = a.cwd { put("cwd", v); }
    if let Some(v) = a.width { put("width", &v.to_string()); }
    if let Some(v) = a.height { put("height", &v.to_string()); }
    if let Some(ref v) = a.command { put("command", v); }
    if let Some(ref raw) = a.raw {
        put("raw", "");
        for r in raw { put("raw_arg", r); }
    }
    for (k, v) in &a.env { put("env", &format!("{}={}", k, v)); }
    if a.print { put("print", "1"); }
    if let Some(ref v) = a.format { put("format", v); }
    out
}

/// Read the decoded `field=value` pairs back into a request.
pub fn new_session_args_from_fields(fields: &[(String, String)]) -> NewSessionArgs {
    let mut a = NewSessionArgs::default();
    for (k, v) in fields {
        match k.as_str() {
            "name" => a.name = Some(v.clone()),
            "window_name" => a.window_name = Some(v.clone()),
            "start_dir" => a.start_dir = Some(v.clone()),
            "cwd" => a.cwd = Some(v.clone()),
            "width" => a.width = v.parse().ok(),
            "height" => a.height = v.parse().ok(),
            "command" => a.command = Some(v.clone()),
            "raw" => a.raw = Some(Vec::new()),
            "raw_arg" => a.raw.get_or_insert_with(Vec::new).push(v.clone()),
            "env" => {
                if let Some((ek, ev)) = v.split_once('=') {
                    a.env.push((ek.to_string(), ev.to_string()));
                }
            }
            "print" => a.print = v == "1",
            "format" => a.format = Some(v.clone()),
            _ => {}
        }
    }
    a
}
