// Parsing for progress.log lines and results.jsonl records.
//
// progress.log lines look like: "[2026-07-17 22:08:20.700] <message>"
// where <message> is one of a handful of shapes emitted by run_all_tests.ps1
// (Write-Log calls). We parse defensively: anything we don't recognize is
// ignored rather than causing an error, since the log format may gain new
// message kinds over time.

use serde::Deserialize;

/// One completed-suite record from results.jsonl. This is the authoritative
/// record for a finished suite; ExitCode is nullable because SKIP-status
/// suites never set it in the source script (the hash literal omits the key,
/// so ConvertTo-Json serializes it as JSON null).
#[derive(Debug, Clone, Deserialize)]
pub struct ResultRecord {
    #[serde(rename = "Name")]
    pub name: String,
    #[serde(rename = "Status")]
    pub status: String,
    #[serde(rename = "Passed")]
    pub passed: u32,
    #[serde(rename = "Failed")]
    pub failed: u32,
    #[serde(rename = "Duration")]
    pub duration: f64,
    #[serde(rename = "ExitCode")]
    pub exit_code: Option<i32>,
}

pub fn parse_results_jsonl(text: &str) -> Vec<ResultRecord> {
    let mut out = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Ok(rec) = serde_json::from_str::<ResultRecord>(line) {
            out.push(rec);
        }
        // Malformed / partially-written trailing line (crash mid-write):
        // silently skipped, matching "never panic on transient errors".
    }
    out
}

/// One recognized event parsed out of a single progress.log line.
#[derive(Debug, Clone, PartialEq)]
pub enum ProgressEvent {
    Queuing { n: usize, total: usize, name: String },
    Start { name: String },
    Heartbeat { name: String, elapsed: f64, limit: f64 },
    Result { status: String, name: String, passed: u32, failed: u32, exit_code: i32, duration: f64 },
    /// The early "TIMEOUT <name> after Ns, killing process tree" line that
    /// precedes the authoritative padded result line for the same suite.
    TimeoutEarly { name: String },
    Skip { name: String, reason: String },
    Error { name: String, message: String },
    FinalResult { message: String },
}

/// Strip the leading "[timestamp] " prefix, returning the remaining message.
/// Tolerates any bracketed content (we don't validate the timestamp itself).
fn strip_timestamp(line: &str) -> Option<&str> {
    let line = line.trim_end_matches(['\r', '\n']);
    let line = line.trim_start();
    if !line.starts_with('[') {
        return None;
    }
    let close = line.find(']')?;
    Some(line[close + 1..].trim_start())
}

pub fn parse_progress_line(line: &str) -> Option<ProgressEvent> {
    let msg = strip_timestamp(line)?;
    if msg.is_empty() {
        return None;
    }

    if msg.starts_with("--- [") {
        return parse_queuing(msg);
    }
    if let Some(rest) = msg.strip_prefix("START ") {
        let name = rest.trim();
        if name.is_empty() {
            return None;
        }
        return Some(ProgressEvent::Start { name: name.to_string() });
    }
    if let Some(rest) = msg.strip_prefix("HEARTBEAT ") {
        return parse_heartbeat(rest);
    }
    if msg.starts_with("SKIP") {
        return parse_skip(msg);
    }
    if msg.starts_with("=== FINAL RESULT") {
        return Some(ProgressEvent::FinalResult { message: msg.to_string() });
    }
    if let Some(rest) = msg.strip_prefix("TIMEOUT ") {
        if let Some(name) = parse_timeout_early(rest) {
            return Some(ProgressEvent::TimeoutEarly { name });
        }
        // Fall through: try as a normal padded result line below.
    }
    if let Some(rest) = msg.strip_prefix("ERROR ") {
        return parse_error(rest);
    }
    // Try the generic padded result line: "STATUS  NAME  NP/MF  exit=E  Ds"
    parse_result_line(msg)
}

fn parse_queuing(msg: &str) -> Option<ProgressEvent> {
    // "--- [N/TOTAL] Queuing <suite> ---"
    let rest = msg.strip_prefix("--- [")?;
    let close = rest.find(']')?;
    let bracket = &rest[..close];
    let (n_str, total_str) = bracket.split_once('/')?;
    let n: usize = n_str.trim().parse().ok()?;
    let total: usize = total_str.trim().parse().ok()?;
    let after = rest[close + 1..].trim();
    let after = after.strip_prefix("Queuing ")?;
    let name = after.strip_suffix("---")?.trim();
    if name.is_empty() {
        return None;
    }
    Some(ProgressEvent::Queuing { n, total, name: name.to_string() })
}

fn parse_heartbeat(rest: &str) -> Option<ProgressEvent> {
    // "<suite> <elapsed>s/<limit>s"
    let mut parts = rest.split_whitespace();
    let name = parts.next()?;
    let times = parts.next()?;
    let (elapsed_str, limit_str) = times.split_once('/')?;
    let elapsed: f64 = elapsed_str.trim_end_matches('s').parse().ok()?;
    let limit: f64 = limit_str.trim_end_matches('s').parse().ok()?;
    Some(ProgressEvent::Heartbeat { name: name.to_string(), elapsed, limit })
}

fn parse_timeout_early(rest: &str) -> Option<String> {
    // "<name> after Ns, killing process tree"
    let (name, tail) = rest.split_once(" after ")?;
    if !tail.contains("killing process tree") {
        return None;
    }
    let name = name.trim();
    if name.is_empty() {
        return None;
    }
    Some(name.to_string())
}

fn parse_skip(msg: &str) -> Option<ProgressEvent> {
    // "SKIP  <name>  (<reason>)"  (variable padding after SKIP and before name)
    let rest = msg.strip_prefix("SKIP")?.trim_start();
    let (name, tail) = split_first_token(rest)?;
    let tail = tail.trim();
    let reason = tail.strip_prefix('(').unwrap_or(tail);
    let reason = reason.strip_suffix(')').unwrap_or(reason);
    Some(ProgressEvent::Skip { name: name.to_string(), reason: reason.to_string() })
}

fn parse_error(rest: &str) -> Option<ProgressEvent> {
    // "<name>  <arbitrary error message>"
    let (name, tail) = split_first_token(rest)?;
    Some(ProgressEvent::Error { name: name.to_string(), message: tail.trim().to_string() })
}

fn parse_result_line(msg: &str) -> Option<ProgressEvent> {
    // "STATUS  NAME  NP/MF  exit=E  Ds" - fields are whitespace-separated
    // once collapsed (source pads with spaces via {0,-N} format specs, so
    // there may be a run of spaces between tokens).
    let mut parts = msg.split_whitespace();
    let status = parts.next()?;
    if !matches!(status, "PASS" | "FAIL" | "TIMEOUT") {
        return None;
    }
    let name = parts.next()?;
    let pf = parts.next()?;
    let (p_str, f_str) = pf.split_once("P/")?;
    let f_str = f_str.strip_suffix('F')?;
    let passed: u32 = p_str.parse().ok()?;
    let failed: u32 = f_str.parse().ok()?;
    let exit_tok = parts.next()?;
    let exit_str = exit_tok.strip_prefix("exit=")?;
    let exit_code: i32 = exit_str.parse().ok()?;
    let dur_tok = parts.next()?;
    let dur_str = dur_tok.strip_suffix('s')?;
    let duration: f64 = dur_str.parse().ok()?;
    Some(ProgressEvent::Result {
        status: status.to_string(),
        name: name.to_string(),
        passed,
        failed,
        exit_code,
        duration,
    })
}

/// Split `s` at the first whitespace run, returning (first_token, remainder).
fn split_first_token(s: &str) -> Option<(&str, &str)> {
    let s = s.trim_start();
    let idx = s.find(char::is_whitespace)?;
    Some((&s[..idx], &s[idx..]))
}

// ---------------------------------------------------------------------
// ETA / rolling average math
// ---------------------------------------------------------------------

/// Rolling average of suite durations, used for ETA projection.
pub fn rolling_average(durations: &[f64]) -> Option<f64> {
    if durations.is_empty() {
        return None;
    }
    Some(durations.iter().sum::<f64>() / durations.len() as f64)
}

/// Estimated seconds remaining given completed/total suites and the average
/// duration observed so far.
pub fn eta_seconds(done: usize, total: usize, avg_duration: f64) -> f64 {
    let remaining = total.saturating_sub(done) as f64;
    remaining * avg_duration
}

/// p90 (90th percentile) of a set of durations, using nearest-rank method.
pub fn p90(durations: &[f64]) -> Option<f64> {
    if durations.is_empty() {
        return None;
    }
    let mut sorted: Vec<f64> = durations.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let idx = ((sorted.len() as f64) * 0.9).ceil() as usize;
    let idx = idx.saturating_sub(1).min(sorted.len() - 1);
    Some(sorted[idx])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_queuing_line() {
        let line = "[2026-07-17 22:08:20.700] --- [52/542] Queuing test_docker_ssh_lib ---";
        let ev = parse_progress_line(line).unwrap();
        assert_eq!(
            ev,
            ProgressEvent::Queuing { n: 52, total: 542, name: "test_docker_ssh_lib".to_string() }
        );
    }

    #[test]
    fn parses_start_line() {
        let line = "[2026-07-17 22:08:20.710] START test_docker_ssh_lib";
        let ev = parse_progress_line(line).unwrap();
        assert_eq!(ev, ProgressEvent::Start { name: "test_docker_ssh_lib".to_string() });
    }

    #[test]
    fn parses_heartbeat_line() {
        let line = "[2026-07-17 22:09:55.672] HEARTBEAT test_env_shim 61s/240s";
        let ev = parse_progress_line(line).unwrap();
        assert_eq!(
            ev,
            ProgressEvent::Heartbeat { name: "test_env_shim".to_string(), elapsed: 61.0, limit: 240.0 }
        );
    }

    #[test]
    fn parses_pass_result_line_padded() {
        // Real sample: status padded to 7 cols, name padded to 45.
        let line = "[2026-07-17 22:08:55.150] PASS    test_e2e_latency                              0P/0F  exit=0  28.6s";
        let ev = parse_progress_line(line).unwrap();
        assert_eq!(
            ev,
            ProgressEvent::Result {
                status: "PASS".to_string(),
                name: "test_e2e_latency".to_string(),
                passed: 0,
                failed: 0,
                exit_code: 0,
                duration: 28.6,
            }
        );
    }

    #[test]
    fn parses_fail_result_line() {
        let line = "[2026-07-17 22:08:26.554] FAIL    test_docker_ssh_mouse457                      0P/0F  exit=1  5.6s";
        let ev = parse_progress_line(line).unwrap();
        assert_eq!(
            ev,
            ProgressEvent::Result {
                status: "FAIL".to_string(),
                name: "test_docker_ssh_mouse457".to_string(),
                passed: 0,
                failed: 0,
                exit_code: 1,
                duration: 5.6,
            }
        );
    }

    #[test]
    fn parses_pass_result_line_with_counts() {
        let line = "[2026-07-17 22:10:34.694] PASS    test_env_shim                                 21P/0F  exit=0  99.5s";
        let ev = parse_progress_line(line).unwrap();
        assert_eq!(
            ev,
            ProgressEvent::Result {
                status: "PASS".to_string(),
                name: "test_env_shim".to_string(),
                passed: 21,
                failed: 0,
                exit_code: 0,
                duration: 99.5,
            }
        );
    }

    #[test]
    fn parses_timeout_early_line() {
        let line = "[2026-07-17 22:08:26.554] TIMEOUT test_long_thing after 240s, killing process tree";
        let ev = parse_progress_line(line).unwrap();
        assert_eq!(ev, ProgressEvent::TimeoutEarly { name: "test_long_thing".to_string() });
    }

    #[test]
    fn parses_timeout_result_line() {
        let line = "[2026-07-17 22:08:26.554] TIMEOUT test_long_thing                              0P/0F  exit=-2  240.1s";
        let ev = parse_progress_line(line).unwrap();
        assert_eq!(
            ev,
            ProgressEvent::Result {
                status: "TIMEOUT".to_string(),
                name: "test_long_thing".to_string(),
                passed: 0,
                failed: 0,
                exit_code: -2,
                duration: 240.1,
            }
        );
    }

    #[test]
    fn parses_skip_line_real_shape() {
        let line = "[2026-07-17 21:55:50.105] SKIP  test_claude_cursor_diag  (Interactive TUI required)";
        let ev = parse_progress_line(line).unwrap();
        assert_eq!(
            ev,
            ProgressEvent::Skip {
                name: "test_claude_cursor_diag".to_string(),
                reason: "Interactive TUI required".to_string(),
            }
        );
    }

    #[test]
    fn parses_error_line() {
        let line = "[2026-07-17 22:00:00.000] ERROR test_something  boom: something broke";
        let ev = parse_progress_line(line).unwrap();
        assert_eq!(
            ev,
            ProgressEvent::Error {
                name: "test_something".to_string(),
                message: "boom: something broke".to_string(),
            }
        );
    }

    #[test]
    fn parses_final_result_line() {
        let line = "[2026-07-17 23:00:00.000] === FINAL RESULT: ALL TESTS PASSED (123 tests across 45 suites) ===";
        let ev = parse_progress_line(line).unwrap();
        assert_eq!(
            ev,
            ProgressEvent::FinalResult {
                message: "=== FINAL RESULT: ALL TESTS PASSED (123 tests across 45 suites) ===".to_string()
            }
        );
    }

    #[test]
    fn ignores_unknown_lines() {
        assert_eq!(parse_progress_line("[2026-07-17 21:40:02.479] === psmux test run started ==="), None);
        assert_eq!(parse_progress_line("[2026-07-17 21:40:03.114] Found 542 test files"), None);
        assert_eq!(parse_progress_line("garbage no timestamp at all"), None);
        assert_eq!(parse_progress_line(""), None);
    }

    #[test]
    fn parses_results_jsonl_row() {
        let text = r#"{"Passed":21,"Failed":0,"Duration":99.5,"Name":"test_env_shim","ExitCode":0,"Status":"PASS"}"#;
        let recs = parse_results_jsonl(text);
        assert_eq!(recs.len(), 1);
        assert_eq!(recs[0].name, "test_env_shim");
        assert_eq!(recs[0].status, "PASS");
        assert_eq!(recs[0].passed, 21);
        assert_eq!(recs[0].exit_code, Some(0));
        assert_eq!(recs[0].duration, 99.5);
    }

    #[test]
    fn parses_results_jsonl_null_exit_code_for_skip() {
        // SKIP suites never set ExitCode in the source script's hash literal,
        // so ConvertTo-Json -Compress serializes it as JSON null.
        let text = r#"{"Name":"test_claude_mouse","Status":"SKIP","Passed":0,"Failed":0,"Duration":0,"ExitCode":null}"#;
        let recs = parse_results_jsonl(text);
        assert_eq!(recs.len(), 1);
        assert_eq!(recs[0].exit_code, None);
    }

    #[test]
    fn parses_results_jsonl_multiple_lines_and_skips_garbage() {
        let text = "{\"Name\":\"a\",\"Status\":\"PASS\",\"Passed\":1,\"Failed\":0,\"Duration\":1.0,\"ExitCode\":0}\n\
                    not json at all\n\
                    {\"Name\":\"b\",\"Status\":\"FAIL\",\"Passed\":0,\"Failed\":2,\"Duration\":2.0,\"ExitCode\":1}\n";
        let recs = parse_results_jsonl(text);
        assert_eq!(recs.len(), 2);
        assert_eq!(recs[0].name, "a");
        assert_eq!(recs[1].name, "b");
    }

    #[test]
    fn eta_and_rolling_average() {
        let durations = vec![10.0, 20.0, 30.0];
        let avg = rolling_average(&durations).unwrap();
        assert!((avg - 20.0).abs() < 1e-9);
        let eta = eta_seconds(3, 10, avg);
        assert!((eta - 140.0).abs() < 1e-9);
        assert_eq!(eta_seconds(10, 10, avg), 0.0);
        assert_eq!(eta_seconds(15, 10, avg), 0.0); // saturating, no negative ETA
    }

    #[test]
    fn rolling_average_empty() {
        assert_eq!(rolling_average(&[]), None);
    }

    #[test]
    fn p90_basic() {
        let durations: Vec<f64> = (1..=10).map(|x| x as f64).collect(); // 1..10
        let v = p90(&durations).unwrap();
        assert_eq!(v, 9.0);
        assert_eq!(p90(&[]), None);
        assert_eq!(p90(&[5.0]), Some(5.0));
    }
}
