//! The ONE place the shared server turns a result into the reply it writes
//! (#798 step 2; owner's instruction on #865).
//!
//! Today a client reads the reply text: a line starting with `ERROR` is a
//! failure (connection.rs `is_error_reply`, the CLI's exit code). The planned
//! error flag change will carry tmux's error flag instead; when it lands, this
//! helper is the only part of the shared server that has to change.
//!
//! A command the shared server does not run yet is answered exactly as the
//! per session server answers a command it does not know: the line
//! `ERROR: unknown command: <name>` (connection.rs, the `_` arm of the command
//! dispatch), so the CLI's exit code logic sees nothing new.

/// What a request of the shared server came to.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Outcome {
    /// Done; the text (possibly empty) is the command's output.
    Done(String),
    /// Refused with tmux's message for it.
    Failed(String),
    /// A command the shared server does not run (yet).
    Unsupported(String),
}

/// The bytes written to the client for an outcome. Empty output writes
/// nothing, as a per session command with no output does.
pub fn reply_text(outcome: &Outcome) -> String {
    match outcome {
        Outcome::Done(text) if text.is_empty() => String::new(),
        Outcome::Done(text) => {
            if text.ends_with('\n') {
                text.clone()
            } else {
                format!("{}\n", text)
            }
        }
        Outcome::Failed(msg) => format!("ERROR: {}\n", msg),
        Outcome::Unsupported(name) => format!("ERROR: unknown command: {}\n", name),
    }
}
