fn required_value_options(command: &str) -> Option<&'static [char]> {
    match command {
        "new-window" | "neww" => Some(&['c', 'e', 'F', 'n', 't', 'S', 'T']),
        "split-window" | "splitw" | "split-pane" | "splitp" => {
            Some(&['c', 'e', 'F', 'l', 'p', 't', 'T'])
        }
        "kill-window" | "killw" => Some(&['t']),
        _ => None,
    }
}

pub fn validate_required_values<S: AsRef<str>>(
    command: &str,
    args: &[S],
) -> Result<(), String> {
    let Some(required) = required_value_options(command) else {
        return Ok(());
    };

    let mut i = 0;
    while i < args.len() {
        let token = args[i].as_ref();
        if token == "--" || !token.starts_with('-') || token == "-" {
            break;
        }
        if token.starts_with("--") {
            i += 1;
            continue;
        }

        let cluster = &token[1..];
        for (offset, option) in cluster.char_indices() {
            if required.contains(&option) {
                let attached = &cluster[offset + option.len_utf8()..];
                if attached.is_empty() {
                    i += 1;
                    if i >= args.len() {
                        return Err(format!("{command}: -{option} expects an argument"));
                    }
                }
                break;
            }
        }
        i += 1;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_missing_required_value() {
        assert_eq!(
            validate_required_values("kill-window", &["-t"]),
            Err("kill-window: -t expects an argument".to_string()),
        );
        assert_eq!(
            validate_required_values("split-window", &["-dZc"]),
            Err("split-window: -c expects an argument".to_string()),
        );
    }

    #[test]
    fn accepts_attached_separate_and_dash_values() {
        assert!(validate_required_values("kill-window", &["-t0"]).is_ok());
        assert!(validate_required_values("kill-window", &["-t", "0"]).is_ok());
        assert!(validate_required_values("kill-window", &["-t", "-a"]).is_ok());
    }

    #[test]
    fn stops_at_command_tail() {
        assert!(validate_required_values("split-window", &["--", "pwsh", "-t"]).is_ok());
        assert!(validate_required_values("split-window", &["pwsh", "-t"]).is_ok());
    }

    #[test]
    fn validates_every_migrated_command_alias() {
        for command in ["new-window", "neww"] {
            assert!(validate_required_values(command, &["-n"]).is_err());
        }
        for command in ["split-window", "splitw", "split-pane", "splitp"] {
            assert!(validate_required_values(command, &["-p"]).is_err());
        }
        for command in ["kill-window", "killw"] {
            assert!(validate_required_values(command, &["-t"]).is_err());
        }
    }
}
