use std::ffi::OsString;
use std::fmt;

use lexopt::Arg::{Long, Short, Value};

use crate::types::LayoutKind;

/// Parsed split-window arguments.
///
/// Server ingress keeps the first scalar values, gives `-p` precedence over
/// `-l`, and treats any `-h` as horizontal.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SplitWindowCommand {
    directions: Vec<char>,
    start_dirs: Vec<String>,
    formats: Vec<String>,
    sizes: Vec<(char, String)>,
    titles: Vec<String>,
    target: Option<String>,
    environment: Vec<String>,
    positionals: Vec<String>,
    // Direct server input treats the first literal `--` as the command-tail
    // marker, even when process parsing also consumes it as an option value.
    server_argv: Option<Vec<String>>,
    detached: bool,
    print: bool,
    zoom_after_split: bool,
    has_non_direction_arguments: bool,
    // Process parsing recognizes only a `--` that is not consumed as an
    // option value.
    explicit_argv: bool,
}

impl SplitWindowCommand {
    pub fn parse<I, S>(command: &str, args: I) -> Option<Result<Self, ParseError>>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        if !matches!(command, "split-window" | "splitw" | "split-pane" | "splitp") {
            return None;
        }

        Some(Self::parse_args(args))
    }

    fn parse_args<I, S>(args: I) -> Result<Self, ParseError>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let args = crate::cli::normalize_flag_equals(
            args.into_iter()
                .map(|argument| argument.as_ref().to_string())
                .collect(),
        );
        let server_argv = args
            .iter()
            .position(|argument| argument == "--")
            .map(|separator| args[separator + 1..].to_vec());
        let target = routing_target(&args);
        let separator = separator_index(&args);
        let option_end = separator.unwrap_or(args.len());
        let mut parser = lexopt::Parser::from_args(args[..option_end].iter().map(OsString::from));
        let mut command = Self {
            server_argv,
            target,
            ..Self::default()
        };

        while let Some(argument) = parser.next().map_err(|_| ParseError::InvalidArguments)? {
            match argument {
                // Accepted for tmux compatibility but not acted on.
                Short('b' | 'f' | 'I') => command.has_non_direction_arguments = true,
                Short('d') => {
                    command.detached = true;
                    command.has_non_direction_arguments = true;
                }
                Short('h') => command.directions.push('h'),
                Short('v') => command.directions.push('v'),
                Short('P') => {
                    command.print = true;
                    command.has_non_direction_arguments = true;
                }
                Short('Z') => {
                    command.zoom_after_split = true;
                    command.has_non_direction_arguments = true;
                }
                Short(option) if takes_value(option) => {
                    command.has_non_direction_arguments = true;
                    let value = parser
                        .value()
                        .map_err(|_| ParseError::MissingValue(option))?
                        .into_string()
                        .map_err(|_| ParseError::InvalidArguments)?;
                    match option {
                        'c' => command.start_dirs.push(value),
                        'e' => command.environment.push(value),
                        'F' => command.formats.push(value),
                        'l' | 'p' => command.sizes.push((option, value)),
                        'T' => command.titles.push(value),
                        // Routing is derived separately so a `-t` after the
                        // first literal `--` never escapes the command tail.
                        't' => {}
                        _ => unreachable!(),
                    }
                }
                // Preserve leniency for unknown long and short options in this
                // parser-only migration. Rejection is a separate parity change.
                Long(_) => {
                    let _ = parser.optional_value();
                }
                // Unknown short options remain flag-only. Only tmux's
                // documented value options consume the following operand.
                Short(_) => {}
                Value(value) => {
                    command.has_non_direction_arguments = true;
                    command.positionals.push(
                        value
                            .into_string()
                            .map_err(|_| ParseError::InvalidArguments)?,
                    );
                    command.positionals.extend(
                        parser
                            .raw_args()
                            .map_err(|_| ParseError::InvalidArguments)?
                            .map(|value| {
                                value
                                    .into_string()
                                    .map_err(|_| ParseError::InvalidArguments)
                            })
                            .collect::<Result<Vec<_>, _>>()?,
                    );
                    if let Some(separator) = separator {
                        // A positional before `--` makes the separator command
                        // text, so keep it in the process CLI's joined string.
                        command.positionals.push("--".to_string());
                        command
                            .positionals
                            .extend(args[separator + 1..].iter().cloned());
                    }
                    return Ok(command);
                }
            }
        }

        if let Some(separator) = separator {
            command.has_non_direction_arguments |= !args[separator + 1..].is_empty();
            command.explicit_argv = true;
            command
                .positionals
                .extend(args[separator + 1..].iter().cloned());
        }

        Ok(command)
    }

    pub fn kind(&self) -> LayoutKind {
        if self.directions.contains(&'h') {
            LayoutKind::Horizontal
        } else {
            LayoutKind::Vertical
        }
    }

    /// Returns a direct split action only when no argument needs to round-trip
    /// through the full command string.
    pub fn direct_action_kind(&self) -> Option<LayoutKind> {
        (!self.has_non_direction_arguments).then(|| self.kind())
    }

    pub fn start_dir(&self) -> Option<&str> {
        self.start_dirs.first().map(|value| server_value(value))
    }

    pub fn print_format(&self) -> Option<&str> {
        self.formats.first().map(|value| server_value(value))
    }

    pub fn split_size(&self) -> Option<(u16, bool)> {
        self.sizes
            .iter()
            .find(|(option, _)| *option == 'p')
            .and_then(|(_, value)| parse_split_size(server_value(value), true))
            .or_else(|| {
                self.sizes
                    .iter()
                    .find(|(option, _)| *option == 'l')
                    .and_then(|(_, value)| {
                        let value = server_value(value);
                        parse_split_size(value, value.ends_with('%'))
                    })
            })
    }

    pub fn title(&self) -> Option<&str> {
        self.titles.first().map(|value| server_value(value))
    }

    pub fn target(&self) -> Option<&str> {
        self.target.as_deref()
    }

    /// A global process-CLI target chooses the server. Without one, the
    /// command's inline target is used as written rather than composed with a
    /// session target.
    pub fn effective_target<'a>(&'a self, precommand_target: Option<&'a str>) -> Option<&'a str> {
        precommand_target.or(self.target())
    }

    pub fn detached(&self) -> bool {
        self.detached
    }

    pub fn print(&self) -> bool {
        self.print
    }

    pub fn zoom_after_split(&self) -> bool {
        self.zoom_after_split
    }

    pub fn environment(&self) -> Vec<(String, String)> {
        self.environment
            .iter()
            .filter_map(|assignment| {
                server_value(assignment)
                    .split_once('=')
                    .map(|(name, value)| (name.to_string(), value.to_string()))
            })
            .collect()
    }

    /// Converts the parsed command operand to the server's string
    /// representation. A `--` anywhere in direct server input marks the
    /// command tail; multiple tail tokens retain the marker so the spawn path
    /// executes the original argv directly. Without `--`, server ingress keeps
    /// the first positional command string.
    pub fn server_command(&self) -> Option<String> {
        if let Some(argv) = self.server_argv.as_ref() {
            return match argv.as_slice() {
                [] => None,
                [command] => {
                    Some(server_value(command).to_string()).filter(|command| !command.is_empty())
                }
                _ => Some(format!(
                    "-- {}",
                    crate::commands::requote_command_tail(argv)
                )),
            };
        }

        self.positionals
            .first()
            .map(|command| server_value(command).to_string())
            .filter(|command| !command.is_empty())
    }

    /// The target travels in the protocol's `TARGET` line. The process CLI
    /// canonicalizes the remaining options while retaining command argv and
    /// the last scalar, size, and orientation values.
    pub fn to_wire_command(&self, caller_cwd: Option<&str>) -> String {
        let mut line = String::from("split-window");
        line.push_str(match self.directions.last() {
            Some('h') => " -h",
            _ => " -v",
        });
        if self.detached {
            line.push_str(" -d");
        }
        if self.print {
            line.push_str(" -P");
        }
        if self.zoom_after_split {
            line.push_str(" -Z");
        }
        push_value(
            &mut line,
            'F',
            self.formats.last().map(|value| server_value(value)),
        );
        push_value(
            &mut line,
            'c',
            self.start_dirs
                .last()
                .map(|value| server_value(value))
                .or(caller_cwd),
        );
        push_value(
            &mut line,
            'T',
            self.titles.last().map(|value| server_value(value)),
        );
        if let Some((option, value)) = self.sizes.last() {
            push_value(&mut line, *option, Some(server_value(value)));
        }
        for assignment in &self.environment {
            push_value(&mut line, 'e', Some(server_value(assignment)));
        }
        if self.is_multi_token_argv() {
            line.push_str(" --");
            for argument in &self.positionals {
                line.push(' ');
                line.push_str(&crate::util::quote_arg(argument));
            }
        } else if !self.positionals.is_empty() {
            line.push(' ');
            line.push_str(&crate::util::quote_arg(&self.positionals.join(" ")));
        }
        line.push('\n');
        line
    }

    fn is_multi_token_argv(&self) -> bool {
        self.explicit_argv && self.positionals.len() > 1
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ParseError {
    MissingValue(char),
    InvalidArguments,
}

impl fmt::Display for ParseError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingValue(option) => write!(formatter, "-{option} expects an argument"),
            Self::InvalidArguments => write!(formatter, "split-window: invalid arguments"),
        }
    }
}

impl std::error::Error for ParseError {}

fn parse_split_size(value: &str, is_percent: bool) -> Option<(u16, bool)> {
    value
        .trim_end_matches('%')
        .parse()
        .ok()
        .map(|value| (value, is_percent))
}

/// Removes the outer quotes retained by whitespace-split server aliases.
fn server_value(value: &str) -> &str {
    value.trim_matches('"')
}

fn push_value(command: &mut String, name: char, value: Option<&str>) {
    if let Some(value) = value {
        if value == "--" {
            // Keep an option value from becoming the server's argv separator
            // after command-line tokenization removes quotes.
            command.push_str(&format!(" -{name}--"));
        } else {
            command.push_str(&format!(" -{name} {}", crate::util::quote_arg(value)));
        }
    }
}

fn takes_value(option: char) -> bool {
    matches!(option, 'c' | 'e' | 'F' | 'l' | 'p' | 'T' | 't')
}

/// Finds the last routing target before the first command operand or literal
/// `--`.
///
/// The separator is included in the scan so `-t --` still treats it as the
/// option value, but no later token can become a routing target.
fn routing_target(args: &[String]) -> Option<String> {
    let parse_end = args
        .iter()
        .position(|argument| argument == "--")
        .map_or(args.len(), |separator| separator + 1);
    let mut parser = lexopt::Parser::from_args(args[..parse_end].iter().map(OsString::from));
    let mut target = None;

    loop {
        match parser.next() {
            Ok(Some(Short(option))) if takes_value(option) => {
                let Ok(value) = parser.value() else {
                    break;
                };
                if option == 't' {
                    let Ok(value) = value.into_string() else {
                        break;
                    };
                    target = Some(value);
                }
            }
            Ok(Some(Long(_))) => {
                let _ = parser.optional_value();
            }
            Ok(Some(Short(_))) => {}
            Ok(Some(Value(_))) | Ok(None) | Err(_) => break,
        }
    }

    target
}

fn separator_index(args: &[String]) -> Option<usize> {
    args.iter()
        .enumerate()
        .filter(|(_, argument)| *argument == "--")
        .find_map(|(separator, _)| {
            (!separator_is_option_value(args, separator)).then_some(separator)
        })
}

/// Returns true when `args[separator]` is consumed as the value of a preceding
/// value-taking option, as in `-p --`.
fn separator_is_option_value(args: &[String], separator: usize) -> bool {
    let mut index = 0;
    while index < separator {
        let argument = &args[index];
        if argument.starts_with("--") {
            // Long options and earlier literal separators cannot consume this
            // candidate as a short-option value.
            index += 1;
            continue;
        }
        let Some(options) = argument
            .strip_prefix('-')
            .filter(|options| !options.is_empty())
        else {
            return false;
        };
        let mut options = options.chars().peekable();
        let mut consumes_next = false;
        while let Some(option) = options.next() {
            if takes_value(option) {
                // An earlier value-taking option consumes the rest of its
                // cluster as the attached value.
                consumes_next = options.peek().is_none();
                break;
            }
        }
        if consumes_next {
            if index + 1 == separator {
                return true;
            }
            index += 2;
        } else {
            index += 1;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<SplitWindowCommand, ParseError> {
        SplitWindowCommand::parse("split-window", args.iter().copied()).unwrap()
    }

    #[test]
    fn aliases_share_the_parser() {
        for command in ["split-window", "splitw", "split-pane", "splitp"] {
            assert_eq!(
                SplitWindowCommand::parse(command, ["-p"]).unwrap(),
                Err(ParseError::MissingValue('p'))
            );
        }
        assert!(SplitWindowCommand::parse("join-pane", ["-p"]).is_none());
    }

    #[test]
    fn every_value_option_rejects_a_missing_value() {
        for option in ['c', 'e', 'F', 'l', 'p', 'T', 't'] {
            assert_eq!(
                parse(&[&format!("-{option}")]),
                Err(ParseError::MissingValue(option)),
                "-{option}"
            );
        }
    }

    #[test]
    fn accepts_compatibility_flags_and_clustered_options() {
        let command = parse(&["-bfdZh", "-p50", "-c=C:\\repo", "-eA=1"]).unwrap();

        assert_eq!(command.kind(), LayoutKind::Horizontal);
        assert!(command.detached());
        assert!(command.zoom_after_split());
        assert_eq!(command.split_size(), Some((50, true)));
        assert_eq!(command.start_dir(), Some("C:\\repo"));
        assert_eq!(command.environment(), [("A".to_string(), "1".to_string())]);
    }

    #[test]
    fn path_specific_precedence_is_preserved() {
        let command = parse(&[
            "-h",
            "-v",
            "-p",
            "30",
            "-l",
            "10",
            "-c",
            "one",
            "-c",
            "two",
            "-F",
            "first",
            "-F",
            "second",
            "-T",
            "first-title",
            "-T",
            "second-title",
        ])
        .unwrap();

        assert_eq!(command.kind(), LayoutKind::Horizontal);
        assert_eq!(command.split_size(), Some((30, true)));
        assert_eq!(command.start_dir(), Some("one"));
        assert_eq!(command.print_format(), Some("first"));
        assert_eq!(command.title(), Some("first-title"));
        assert_eq!(
            command.to_wire_command(None),
            "split-window -v -F \"second\" -c \"two\" -T \"second-title\" -l \"10\"\n"
        );
    }

    #[test]
    fn precommand_target_takes_routing_precedence() {
        let command = parse(&["-t", ":2"]).unwrap();

        assert_eq!(command.effective_target(Some("work")), Some("work"));
        assert_eq!(command.effective_target(None), Some(":2"));
    }

    #[test]
    fn repeated_environment_assignments_keep_order() {
        let command = parse(&["-e", "A=1", "-eB=two", "-e", "invalid"]).unwrap();

        assert_eq!(
            command.environment(),
            [
                ("A".to_string(), "1".to_string()),
                ("B".to_string(), "two".to_string())
            ]
        );
        assert_eq!(
            command.to_wire_command(None),
            "split-window -v -e \"A=1\" -e \"B=two\" -e \"invalid\"\n"
        );
    }

    #[test]
    fn explicit_multi_token_argv_preserves_empty_entries() {
        let command = parse(&["--", "tool", "", "wide arg"]).unwrap();

        assert_eq!(
            command.server_command().as_deref(),
            Some("-- tool '' 'wide arg'")
        );
        assert_eq!(
            command.to_wire_command(Some("C:\\repo")),
            "split-window -v -c \"C:\\\\repo\" -- \"tool\" \"\" \"wide arg\"\n"
        );
    }

    #[test]
    fn command_operands_stop_option_and_target_parsing() {
        let command = parse(&["tool", "-h", "-t", "child"]).unwrap();

        assert_eq!(command.kind(), LayoutKind::Vertical);
        assert_eq!(command.target(), None);
        assert_eq!(
            command.to_wire_command(None),
            "split-window -v \"tool -h -t child\"\n"
        );
    }

    #[test]
    fn double_dash_can_be_an_option_value() {
        let command = parse(&["-c", "--", "tool", "arg"]).unwrap();

        assert_eq!(command.start_dir(), Some("--"));
        assert_eq!(command.server_command().as_deref(), Some("-- tool arg"));
        assert_eq!(
            command.to_wire_command(None),
            "split-window -v -c-- \"tool arg\"\n"
        );
    }

    #[test]
    fn unknown_options_keep_the_old_leniency() {
        // Pins migration compatibility without endorsing leniency as the
        // long-term command contract.
        let command = parse(&["--future=value", "-x", "tool"]).unwrap();

        assert_eq!(command.server_command().as_deref(), Some("tool"));
    }
}
