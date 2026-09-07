/// Validates the typed window-command family at deferred-command boundaries.
pub fn validate<S: AsRef<str>>(command: &str, args: &[S]) -> Result<(), String> {
    if let Some(parsed) = crate::kill_window::KillWindowCommand::parse(command, args.iter()) {
        parsed.map_err(|error| error.to_string())?;
    }
    if let Some(parsed) = crate::new_window::NewWindowCommand::parse(command, args.iter()) {
        parsed.map_err(|error| error.to_string())?;
    }
    if let Some(parsed) = crate::split_window::SplitWindowCommand::parse(command, args.iter()) {
        parsed.map_err(|error| error.to_string())?;
    }
    Ok(())
}
