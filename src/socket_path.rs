//! `-S <socket-path>` and `#{socket_path}` (issue #730).
//!
//! tmux names a server by the path of its Unix socket: `-L label` is shorthand
//! for `-S $TMUX_TMPDIR/tmux-UID/label`, `-S path` names the socket directly,
//! and `#{socket_path}` is the path of the server that answered (tmux.c
//! `main()` and `make_label()`, format.c).
//!
//! psmux has no socket. A server is a TCP listener whose port lives in
//! `<psmux_dir>/<base>.port`, and `-L ns` selects the namespace of files named
//! `<ns>__<session>`. So `-S` is mapped onto a namespace:
//!
//! * a path inside the data dir (`<psmux_dir>/<label>`, exactly what
//!   `#{socket_path}` prints for the default and `-L` servers) selects that
//!   label, `default` being the default namespace, just as `-L label` and
//!   `-S <dir>/label` name the same socket in tmux;
//! * the legacy `/tmp/psmux-<pid>/<label>` first field of `$TMUX` selects
//!   `<label>` the same way, so `tmux -S "${TMUX%%,*}"` from any pane reaches
//!   the server that pane belongs to;
//! * any other path selects the namespace `sock-<hash>`, where the hash is
//!   64 bit FNV-1a over the normalized absolute path. A hash rather than an
//!   encoding of the path because the namespace is a file name prefix and a
//!   path can be longer than a file name may be and is full of characters a
//!   file name may not hold. FNV-1a rather than `DefaultHasher` because the
//!   value must be identical for every psmux build that ever shares a data
//!   dir, and std documents no such promise for SipHash's keys. Normalizing
//!   (absolute, one separator, case folded) makes every spelling Windows
//!   treats as one file reach one server.
//!
//! The server learns the exact path its first client was given from
//! [`SOCKET_PATH_ENV`], which that client exports before it spawns anything.
//! The value is trusted only when it hashes to the server's own namespace, so a
//! stale copy inherited from some other environment can never mislabel it.

use std::sync::OnceLock;

/// Carries the `-S` path from the client to the server it spawns.
pub const SOCKET_PATH_ENV: &str = "PSMUX_SOCKET_PATH";

/// Prefix of a namespace derived from a `-S` path.
pub const HASHED_NS_PREFIX: &str = "sock-";

/// 64 bit FNV-1a: tiny, fixed forever, and identical on every build.
fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        h ^= *b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

/// The comparison key of a path: absolute, backslash separated, case folded,
/// no `\\?\` prefix and no trailing separator.
pub fn normalize(path: &str) -> String {
    let raw = std::path::Path::new(path);
    let abs = std::path::absolute(raw).unwrap_or_else(|_| raw.to_path_buf());
    let mut s = abs.to_string_lossy().replace('/', "\\");
    if let Some(rest) = s.strip_prefix("\\\\?\\") {
        s = rest.to_string();
    }
    while s.len() > 3 && s.ends_with('\\') {
        s.pop();
    }
    s.to_lowercase()
}

/// The namespace a foreign `-S` path selects.
pub fn hashed_namespace(path: &str) -> String {
    format!("{}{:016x}", HASHED_NS_PREFIX, fnv1a64(normalize(path).as_bytes()))
}

/// True for a namespace [`hashed_namespace`] produced.
pub fn is_hashed_namespace(ns: &str) -> bool {
    ns.strip_prefix(HASHED_NS_PREFIX)
        .is_some_and(|h| h.len() == 16 && h.bytes().all(|b| b.is_ascii_hexdigit()))
}

fn label_namespace(label: &str) -> Option<String> {
    if label == "default" { None } else { Some(label.to_string()) }
}

/// `/tmp/psmux-<pid>/<label>`, the first field of `$TMUX` in panes.
fn legacy_tmux_label(path: &str) -> Option<&str> {
    let rest = path.strip_prefix("/tmp/psmux-")?;
    let (pid, label) = rest.split_once('/')?;
    if pid.is_empty() || !pid.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    if label.is_empty() || label.contains('/') || label.contains('\\') {
        return None;
    }
    Some(label)
}

/// Map a `-S` path to the namespace it names: `Ok(None)` is the default
/// namespace, `Ok(Some(ns))` a named one. `Err` only for a path that names
/// nothing at all, so the caller fails loudly instead of falling through to
/// the default server.
pub fn namespace_for_socket_path(path: &str, psmux_dir: &str) -> Result<Option<String>, String> {
    if path.trim().is_empty() {
        return Err("-S needs a non-empty socket path".to_string());
    }
    if let Some(label) = legacy_tmux_label(path) {
        return Ok(label_namespace(label));
    }
    let norm = normalize(path);
    let dir = normalize(psmux_dir);
    if let Some(label) = norm.strip_prefix(&dir).and_then(|r| r.strip_prefix('\\')) {
        if !label.is_empty() && !label.contains('\\') {
            // Keep the caller's spelling of the label: -L names are case
            // sensitive and the namespace is a file name prefix.
            let original = path.rsplit(['/', '\\']).next().unwrap_or(label);
            return Ok(label_namespace(original));
        }
    }
    Ok(Some(hashed_namespace(path)))
}

/// `#{socket_path}` of a server in namespace `ns`: `<psmux_dir>/default`,
/// `<psmux_dir>/<label>`, or the `-S` path that created a hashed namespace
/// (`recorded`, when it is known and really hashes to `ns`).
pub fn socket_path_for(ns: Option<&str>, psmux_dir: &str, recorded: Option<&str>) -> String {
    match ns {
        None => format!("{}/default", psmux_dir),
        Some(n) => {
            if is_hashed_namespace(n) {
                if let Some(p) = recorded.filter(|p| hashed_namespace(p) == n) {
                    return p.to_string();
                }
            }
            format!("{}/{}", psmux_dir, n)
        }
    }
}

/// First field of `$TMUX` in a pane. Default and `-L` servers keep the
/// documented `/tmp/psmux-<pid>/<label>` shape; a `-S` server carries the
/// exact path, as tmux does, so `-S "${TMUX%%,*}"` reaches it.
pub fn tmux_env_path_for(ns: Option<&str>, server_pid: u32, recorded: Option<&str>) -> String {
    if let Some(n) = ns {
        if is_hashed_namespace(n) {
            if let Some(p) = recorded.filter(|p| hashed_namespace(p) == n) {
                return p.to_string();
            }
        }
    }
    format!("/tmp/psmux-{}/{}", server_pid, ns.unwrap_or("default"))
}

static SERVER_SOCKET_PATH: OnceLock<Option<String>> = OnceLock::new();

/// The `-S` path this server process was started for, read once from
/// [`SOCKET_PATH_ENV`] and kept only if it belongs to `ns`.
pub fn server_recorded_path(ns: Option<&str>) -> Option<&'static str> {
    SERVER_SOCKET_PATH
        .get_or_init(|| {
            let p = std::env::var(SOCKET_PATH_ENV).ok()?;
            let n = ns?;
            (is_hashed_namespace(n) && hashed_namespace(&p) == n).then_some(p)
        })
        .as_deref()
}

/// `#{socket_path}` as this server process reports it.
pub fn server_socket_path(ns: Option<&str>) -> String {
    socket_path_for(ns, &crate::paths::psmux_dir(), server_recorded_path(ns))
}

/// The `$TMUX` first field this server process gives its panes.
pub fn server_tmux_env_path(ns: Option<&str>) -> String {
    tmux_env_path_for(ns, std::process::id(), server_recorded_path(ns))
}

static CLI_SOCKET_PATH: OnceLock<String> = OnceLock::new();

/// Record the `-S` path this client was given, for its error messages.
pub fn set_cli_socket_path(path: &str) {
    let _ = CLI_SOCKET_PATH.set(path.to_string());
}

/// The `-S` path this client was given, if any.
pub fn cli_socket_path() -> Option<&'static str> {
    CLI_SOCKET_PATH.get().map(String::as_str)
}

#[cfg(test)]
#[path = "../tests-rs/test_issue730_socket_path.rs"]
mod tests_issue730_socket_path;
