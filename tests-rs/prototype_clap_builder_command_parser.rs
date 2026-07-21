use std::ffi::OsString;

use clap::builder::StringValueParser;
use clap::error::ErrorKind;
use clap::{Arg, ArgAction, Command as ClapCommand};

const MISSING_VALUE: &str = "\u{0}PSMUX_MISSING\u{0}";

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

#[derive(Clone, Copy)]
struct CommandSpec<'a> {
    options: &'a [OptionSpec],
    min_positionals: usize,
    max_positionals: Option<usize>,
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

impl Command {
    fn spec(self) -> CommandSpec<'static> {
        match self {
            Self::KillWindow => KILL_WINDOW_SPEC,
            Self::SplitWindow => SPLIT_WINDOW_SPEC,
            Self::IfShell => IF_SHELL_SPEC,
        }
    }
}

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
    Clap(ErrorKind),
}

fn parse(command: Command, args: &[&str]) -> Result<ParsedCommand, ParseError> {
    parse_with_spec(command.spec(), args)
}

fn parse_with_spec(spec: CommandSpec<'_>, args: &[&str]) -> Result<ParsedCommand, ParseError> {
    let mut parser = ClapCommand::new("prototype")
        .no_binary_name(true)
        .disable_help_flag(true)
        .disable_version_flag(true);
    for option in spec.options {
        let id = option.name.to_string();
        let argument = match option.kind {
            OptionKind::Flag => Arg::new(id)
                .short(option.name)
                .action(ArgAction::Append)
                .num_args(0)
                .default_missing_value(MISSING_VALUE)
                .value_parser(StringValueParser::new()),
            OptionKind::RequiredValue => Arg::new(id)
                .short(option.name)
                .action(ArgAction::Append)
                .num_args(1)
                .allow_hyphen_values(true)
                .value_parser(StringValueParser::new()),
            OptionKind::OptionalValue => Arg::new(id)
                .short(option.name)
                .action(ArgAction::Append)
                .num_args(0..=1)
                .default_missing_value(MISSING_VALUE)
                .value_parser(StringValueParser::new()),
        };
        parser = parser.arg(argument);
    }
    if spec.max_positionals != Some(0) {
        let mut positionals = Arg::new("positionals")
            .index(1)
            .action(ArgAction::Append)
            .trailing_var_arg(true)
            .value_parser(StringValueParser::new());
        positionals = match spec.max_positionals {
            Some(maximum) => positionals.num_args(spec.min_positionals.max(1)..=maximum),
            None => positionals.num_args(spec.min_positionals.max(1)..),
        };
        positionals = positionals.required(spec.min_positionals > 0);
        parser = parser.arg(positionals);
    }

    let normalized = preserve_short_equals(spec, args);
    let matches = parser
        .try_get_matches_from(normalized)
        .map_err(|error| ParseError::Clap(error.kind()))?;
    let mut ordered = Vec::new();
    for option in spec.options {
        let id = option.name.to_string();
        let indices = matches
            .indices_of(&id)
            .map(Iterator::collect::<Vec<_>>)
            .unwrap_or_default();
        let values = matches
            .get_many::<String>(&id)
            .map(|values| values.cloned().collect::<Vec<_>>())
            .unwrap_or_default();
        for (index, value) in indices.into_iter().zip(values) {
            ordered.push((
                index,
                OptionOccurrence {
                    name: option.name,
                    value: (value != MISSING_VALUE).then_some(value),
                },
            ));
        }
    }
    ordered.sort_by_key(|(index, _)| *index);
    let positionals = if spec.max_positionals == Some(0) {
        Vec::new()
    } else {
        matches
            .get_many::<String>("positionals")
            .map(|values| values.cloned().collect())
            .unwrap_or_default()
    };
    Ok(ParsedCommand {
        options: ordered
            .into_iter()
            .map(|(_, occurrence)| occurrence)
            .collect(),
        positionals,
    })
}

fn preserve_short_equals(spec: CommandSpec<'_>, args: &[&str]) -> Vec<OsString> {
    let mut normalized = Vec::new();
    let mut parsing_options = true;
    for argument in args {
        if !parsing_options {
            normalized.push(OsString::from(argument));
            continue;
        }
        if *argument == "--" {
            parsing_options = false;
            normalized.push(OsString::from(argument));
            continue;
        }
        if *argument == "-" || !argument.starts_with('-') {
            parsing_options = false;
            normalized.push(OsString::from(argument));
            continue;
        }

        let Some(equals) = argument.find('=') else {
            normalized.push(OsString::from(argument));
            continue;
        };
        let prefix = &argument[1..equals];
        let split = prefix.chars().last().is_some_and(|name| {
            spec.options
                .iter()
                .any(|option| option.name == name && option.kind != OptionKind::Flag)
        });
        if split {
            normalized.push(OsString::from(format!("-{prefix}")));
            normalized.push(OsString::from(&argument[equals..]));
        } else {
            normalized.push(OsString::from(argument));
        }
    }
    normalized
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

    assert!(parse(Command::KillWindow, &["-t"]).is_err());
    assert!(parse(Command::KillWindow, &["-f", "filter"]).is_err());
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

    assert!(parse(Command::IfShell, &["true"]).is_err());
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
                assert!(
                    parse_with_spec(isolated, &[token.as_str()]).is_err(),
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

    let attached = parse_with_spec(spec, &["-Dvalue"]).unwrap();
    assert_eq!(values(&attached, 'D'), ["value"]);

    let separate = parse_with_spec(spec, &["-D", "value"]).unwrap();
    assert_eq!(values(&separate, 'D'), ["value"]);
}
