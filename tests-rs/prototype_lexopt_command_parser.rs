use std::ffi::{OsStr, OsString};

use lexopt::prelude::*;

#[derive(Clone, Copy, Debug)]
enum Command {
    KillWindow,
    SplitWindow,
    IfShell,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum OptionKind {
    Flag,
    RequiredValue,
    OptionalValue,
}

#[derive(Clone, Copy, Debug)]
struct OptionSpec {
    name: char,
    kind: OptionKind,
}

const fn flag(name: char) -> OptionSpec {
    OptionSpec {
        name,
        kind: OptionKind::Flag,
    }
}

const fn value(name: char) -> OptionSpec {
    OptionSpec {
        name,
        kind: OptionKind::RequiredValue,
    }
}

const fn optional_value(name: char) -> OptionSpec {
    OptionSpec {
        name,
        kind: OptionKind::OptionalValue,
    }
}

const KILL_WINDOW_SPEC: CommandSpec<'static> = CommandSpec {
    options: &[flag('a'), value('t')],
    min_positionals: 0,
    max_positionals: Some(0),
};
const SPLIT_WINDOW_SPEC: CommandSpec<'static> = CommandSpec {
    options: &[
        flag('b'),
        value('c'),
        flag('d'),
        value('e'),
        flag('f'),
        value('F'),
        flag('h'),
        flag('I'),
        value('l'),
        value('p'),
        flag('P'),
        value('t'),
        flag('v'),
        flag('Z'),
    ],
    min_positionals: 0,
    max_positionals: None,
};
const IF_SHELL_SPEC: CommandSpec<'static> = CommandSpec {
    options: &[flag('b'), flag('F'), value('t')],
    min_positionals: 2,
    max_positionals: Some(3),
};

#[derive(Debug, PartialEq, Eq)]
struct OptionOccurrence {
    name: char,
    value: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
struct ParsedCommand {
    options: Vec<OptionOccurrence>,
    positionals: Vec<String>,
}

#[derive(Debug, PartialEq, Eq)]
enum ParseError {
    UnknownOption(char),
    UnexpectedLongOption(String),
    MissingValue(char),
    InvalidUtf8,
    ParserState,
    PositionalCount {
        min: usize,
        max: Option<usize>,
        actual: usize,
    },
}

#[derive(Clone, Copy)]
struct CommandSpec<'a> {
    options: &'a [OptionSpec],
    min_positionals: usize,
    max_positionals: Option<usize>,
}

impl Command {
    fn spec(self) -> CommandSpec<'static> {
        match self {
            Self::KillWindow => KILL_WINDOW_SPEC,
            Self::SplitWindow => SPLIT_WINDOW_SPEC,
            Self::IfShell => IF_SHELL_SPEC,
        }
    }
}

impl CommandSpec<'_> {
    fn option(self, name: char) -> Option<OptionKind> {
        self.options
            .iter()
            .find(|option| option.name == name)
            .map(|option| option.kind)
    }
}

fn parse(command: Command, args: &[&str]) -> Result<ParsedCommand, ParseError> {
    parse_with_spec(command.spec(), args)
}

fn parse_with_spec(spec: CommandSpec<'_>, args: &[&str]) -> Result<ParsedCommand, ParseError> {
    let mut parsed = ParsedCommand {
        options: Vec::new(),
        positionals: Vec::new(),
    };
    let mut parser = lexopt::Parser::from_args(args);
    parser.set_short_equals(false);

    while let Some(argument) = parser.next().map_err(|_| ParseError::ParserState)? {
        match argument {
            Short(option) => {
                let Some(kind) = spec.option(option) else {
                    return Err(ParseError::UnknownOption(option));
                };
                match kind {
                    OptionKind::Flag => parsed.options.push(OptionOccurrence {
                        name: option,
                        value: None,
                    }),
                    OptionKind::RequiredValue => {
                        let value = parser
                            .value()
                            .map_err(|_| ParseError::MissingValue(option))?;
                        parsed.options.push(OptionOccurrence {
                            name: option,
                            value: Some(to_string(value)?),
                        });
                    }
                    OptionKind::OptionalValue => {
                        let value = parser
                            .optional_value()
                            .or_else(|| {
                                parser
                                    .try_raw_args()?
                                    .next_if(|value| !looks_like_option(value))
                            })
                            .map(to_string)
                            .transpose()?;
                        parsed.options.push(OptionOccurrence {
                            name: option,
                            value,
                        });
                    }
                }
            }
            Long(option) => {
                return Err(ParseError::UnexpectedLongOption(option.to_string()));
            }
            Value(value) => {
                parsed.positionals.push(to_string(value)?);
                for value in parser.raw_args().map_err(|_| ParseError::ParserState)? {
                    parsed.positionals.push(to_string(value)?);
                }
                break;
            }
        }
    }

    validate_positionals(spec, &parsed)?;
    Ok(parsed)
}

fn looks_like_option(value: &OsStr) -> bool {
    let value = value.to_string_lossy();
    let mut characters = value.chars();
    characters.next() == Some('-')
        && characters
            .next()
            .is_some_and(|character| character == '-' || character.is_ascii_alphabetic())
}

fn to_string(value: OsString) -> Result<String, ParseError> {
    value.into_string().map_err(|_| ParseError::InvalidUtf8)
}

fn validate_positionals(spec: CommandSpec<'_>, parsed: &ParsedCommand) -> Result<(), ParseError> {
    let actual = parsed.positionals.len();
    if actual < spec.min_positionals || spec.max_positionals.is_some_and(|maximum| actual > maximum)
    {
        return Err(ParseError::PositionalCount {
            min: spec.min_positionals,
            max: spec.max_positionals,
            actual,
        });
    }
    Ok(())
}

fn count(parsed: &ParsedCommand, option: char) -> usize {
    parsed
        .options
        .iter()
        .filter(|occurrence| occurrence.name == option)
        .count()
}

fn values(parsed: &ParsedCommand, option: char) -> Vec<&str> {
    parsed
        .options
        .iter()
        .filter(|occurrence| occurrence.name == option)
        .filter_map(|occurrence| occurrence.value.as_deref())
        .collect()
}

fn minimum_positionals(spec: CommandSpec<'_>) -> Vec<String> {
    (0..spec.min_positionals)
        .map(|index| format!("arg{index}"))
        .collect()
}

#[test]
fn kill_window_fixtures() {
    let parsed = parse(Command::KillWindow, &["-aat", "@22"]).unwrap();
    assert_eq!(count(&parsed, 'a'), 2);
    assert_eq!(values(&parsed, 't'), ["@22"]);

    let strict_equals = parse(Command::KillWindow, &["-t=@22"]).unwrap();
    assert_eq!(values(&strict_equals, 't'), ["=@22"]);

    assert_eq!(
        parse(Command::KillWindow, &["-t"]),
        Err(ParseError::MissingValue('t'))
    );
    assert_eq!(
        parse(Command::KillWindow, &["-f", "filter"]),
        Err(ParseError::UnknownOption('f'))
    );
}

#[test]
fn split_window_fixtures() {
    let parsed = parse(
        Command::SplitWindow,
        &[
            "-dZh",
            "-p50",
            "-t",
            "%3",
            "--",
            "tuicr",
            "-r",
            "HEAD~1..HEAD",
        ],
    )
    .unwrap();
    assert_eq!(count(&parsed, 'd'), 1);
    assert_eq!(count(&parsed, 'Z'), 1);
    assert_eq!(count(&parsed, 'h'), 1);
    assert_eq!(
        parsed
            .options
            .iter()
            .map(|occurrence| occurrence.name)
            .collect::<Vec<_>>(),
        ['d', 'Z', 'h', 'p', 't']
    );
    assert_eq!(values(&parsed, 'p'), ["50"]);
    assert_eq!(values(&parsed, 't'), ["%3"]);
    assert_eq!(parsed.positionals, ["tuicr", "-r", "HEAD~1..HEAD"]);

    let implicit = parse(Command::SplitWindow, &["-h", "tuicr", "-r", "HEAD~1..HEAD"]).unwrap();
    assert_eq!(implicit.positionals, ["tuicr", "-r", "HEAD~1..HEAD"]);

    let ordered = parse(Command::SplitWindow, &["-h", "-v", "-p30", "-l10"]).unwrap();
    assert_eq!(
        ordered
            .options
            .iter()
            .map(|occurrence| occurrence.name)
            .collect::<Vec<_>>(),
        ['h', 'v', 'p', 'l']
    );
}

#[test]
fn if_shell_fixtures() {
    let parsed = parse(
        Command::IfShell,
        &[
            "-b",
            "-t",
            "%4",
            "true",
            "display-message ok",
            "display-message no",
        ],
    )
    .unwrap();
    assert_eq!(count(&parsed, 'b'), 1);
    assert_eq!(values(&parsed, 't'), ["%4"]);
    assert_eq!(
        parsed.positionals,
        ["true", "display-message ok", "display-message no"]
    );

    assert!(matches!(
        parse(Command::IfShell, &["true"]),
        Err(ParseError::PositionalCount { actual: 1, .. })
    ));
}

#[test]
fn every_declared_option_has_a_contract() {
    for command in [Command::KillWindow, Command::SplitWindow, Command::IfShell] {
        let spec = command.spec();
        for option in spec.options {
            let token = format!("-{}", option.name);
            let mut args = vec![token.as_str()];
            if option.kind == OptionKind::RequiredValue {
                args.push("value");
            }
            let positionals = minimum_positionals(spec);
            args.extend(positionals.iter().map(String::as_str));
            let parsed = parse(command, &args).unwrap();
            assert_eq!(count(&parsed, option.name), 1, "{command:?} {option:?}");

            if option.kind == OptionKind::RequiredValue {
                let isolated = CommandSpec {
                    options: std::slice::from_ref(option),
                    min_positionals: 0,
                    max_positionals: None,
                };
                assert_eq!(
                    parse_with_spec(isolated, &[token.as_str()]),
                    Err(ParseError::MissingValue(option.name)),
                    "{command:?} {option:?}"
                );
            }
        }
    }
}

#[test]
fn optional_value_contract() {
    let options = [optional_value('D')];
    let spec = CommandSpec {
        options: &options,
        min_positionals: 0,
        max_positionals: None,
    };
    let absent = parse_with_spec(spec, &["-D"]).unwrap();
    assert_eq!(count(&absent, 'D'), 1);
    assert!(values(&absent, 'D').is_empty());

    let absent = parse_with_spec(spec, &["-D", "-x"]).unwrap_err();
    assert_eq!(absent, ParseError::UnknownOption('x'));

    let attached = parse_with_spec(spec, &["-Dvalue"]).unwrap();
    assert_eq!(count(&attached, 'D'), 1);
    assert_eq!(values(&attached, 'D'), ["value"]);

    let separate = parse_with_spec(spec, &["-D", "value"]).unwrap();
    assert_eq!(values(&separate, 'D'), ["value"]);
}
