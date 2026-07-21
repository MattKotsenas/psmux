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
    PositionalCount {
        min: usize,
        max: Option<usize>,
        actual: usize,
    },
}

#[derive(Clone, Copy)]
struct CommandSpec<'a> {
    options: &'a str,
    min_positionals: usize,
    max_positionals: Option<usize>,
}

impl Command {
    fn spec(self) -> CommandSpec<'static> {
        match self {
            Self::KillWindow => CommandSpec {
                options: "at:",
                min_positionals: 0,
                max_positionals: Some(0),
            },
            Self::SplitWindow => CommandSpec {
                options: "bc:de:fF:hIl:p:Pt:vZ",
                min_positionals: 0,
                max_positionals: None,
            },
            Self::IfShell => CommandSpec {
                options: "bFt:",
                min_positionals: 2,
                max_positionals: Some(3),
            },
        }
    }
}

fn option_kinds(template: &str) -> Vec<(char, OptionKind)> {
    let mut options = Vec::new();
    let mut characters = template.chars().peekable();
    while let Some(option) = characters.next() {
        let kind = if characters.next_if_eq(&':').is_some() {
            if characters.next_if_eq(&':').is_some() {
                OptionKind::OptionalValue
            } else {
                OptionKind::RequiredValue
            }
        } else {
            OptionKind::Flag
        };
        options.push((option, kind));
    }
    options
}

fn parse(command: Command, args: &[&str]) -> Result<ParsedCommand, ParseError> {
    parse_with_spec(command.spec(), args)
}

fn parse_with_spec(spec: CommandSpec<'_>, args: &[&str]) -> Result<ParsedCommand, ParseError> {
    let options = option_kinds(spec.options);
    let mut parsed = ParsedCommand {
        options: Vec::new(),
        positionals: Vec::new(),
    };
    let mut index = 0;

    while index < args.len() {
        let argument = args[index];
        if argument == "--" {
            parsed
                .positionals
                .extend(args[index + 1..].iter().map(|value| (*value).to_string()));
            break;
        }
        if argument == "-" || !argument.starts_with('-') {
            parsed
                .positionals
                .extend(args[index..].iter().map(|value| (*value).to_string()));
            break;
        }
        if argument.starts_with("--") {
            return Err(ParseError::UnexpectedLongOption(argument.to_string()));
        }

        let body = &argument[1..];
        for (offset, option) in body.char_indices() {
            let Some(kind) = options
                .iter()
                .find(|(name, _)| *name == option)
                .map(|(_, kind)| *kind)
            else {
                return Err(ParseError::UnknownOption(option));
            };
            match kind {
                OptionKind::Flag => parsed.options.push(OptionOccurrence {
                    name: option,
                    value: None,
                }),
                OptionKind::RequiredValue | OptionKind::OptionalValue => {
                    let value_start = offset + option.len_utf8();
                    let attached =
                        (value_start < body.len()).then(|| body[value_start..].to_string());
                    let value = match (kind, attached) {
                        (_, Some(value)) => Some(value),
                        (OptionKind::RequiredValue, None) => {
                            index += 1;
                            if index >= args.len() {
                                return Err(ParseError::MissingValue(option));
                            }
                            Some(args[index].to_string())
                        }
                        (OptionKind::OptionalValue, None) => args
                            .get(index + 1)
                            .filter(|value| !looks_like_option(value))
                            .map(|value| {
                                index += 1;
                                (*value).to_string()
                            }),
                        (OptionKind::Flag, _) => unreachable!(),
                    };
                    parsed.options.push(OptionOccurrence {
                        name: option,
                        value,
                    });
                    break;
                }
            }
        }
        index += 1;
    }

    validate_positionals(spec, &parsed)?;
    Ok(parsed)
}

fn looks_like_option(value: &str) -> bool {
    let mut characters = value.chars();
    characters.next() == Some('-')
        && characters
            .next()
            .is_some_and(|character| character == '-' || character.is_ascii_alphabetic())
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
        for (option, kind) in option_kinds(spec.options) {
            let token = format!("-{option}");
            let mut args = vec![token.as_str()];
            if kind == OptionKind::RequiredValue {
                args.push("value");
            }
            let positionals = minimum_positionals(spec);
            args.extend(positionals.iter().map(String::as_str));
            let parsed = parse(command, &args).unwrap();
            assert_eq!(count(&parsed, option), 1, "{command:?} -{option}");

            if kind == OptionKind::RequiredValue {
                let template = format!("{option}:");
                let isolated = CommandSpec {
                    options: &template,
                    min_positionals: 0,
                    max_positionals: None,
                };
                assert_eq!(
                    parse_with_spec(isolated, &[token.as_str()]),
                    Err(ParseError::MissingValue(option)),
                    "{command:?} -{option}"
                );
            }
        }
    }
}

#[test]
fn optional_value_contract() {
    let spec = CommandSpec {
        options: "D::",
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
