// Data model for a psmux test run: suite states, run-wide snapshot, filters.

use std::collections::HashMap;

/// Status of one test suite, mirroring the states emitted by run_all_tests.ps1.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Status {
    Queued,
    Running,
    Pass,
    Fail,
    Timeout,
    Skip,
    Error,
}

impl Status {
    pub fn from_str(s: &str) -> Option<Status> {
        match s {
            "PASS" => Some(Status::Pass),
            "FAIL" => Some(Status::Fail),
            "TIMEOUT" => Some(Status::Timeout),
            "SKIP" => Some(Status::Skip),
            "ERROR" => Some(Status::Error),
            _ => None,
        }
    }

    /// True once the suite has stopped running (has a final verdict).
    pub fn is_done(self) -> bool {
        !matches!(self, Status::Queued | Status::Running)
    }

    pub fn is_failing(self) -> bool {
        matches!(self, Status::Fail | Status::Timeout | Status::Error)
    }

    pub fn label(self) -> &'static str {
        match self {
            Status::Queued => "QUEUED",
            Status::Running => "RUNNING",
            Status::Pass => "PASS",
            Status::Fail => "FAIL",
            Status::Timeout => "TIMEOUT",
            Status::Skip => "SKIP",
            Status::Error => "ERROR",
        }
    }
}

/// Live state tracked per suite, built up incrementally from progress.log and
/// finalized/overridden by results.jsonl (the authoritative completed record).
#[derive(Debug, Clone)]
pub struct SuiteInfo {
    pub name: String,
    pub status: Status,
    pub queue_index: usize,
    /// Set once START is seen.
    pub started: bool,
    /// Heartbeat elapsed/limit seconds while running (elapsed, limit).
    pub heartbeat: Option<(f64, f64)>,
    pub passed: u32,
    pub failed: u32,
    pub exit_code: Option<i32>,
    pub duration: Option<f64>,
    pub reason: Option<String>,
}

impl SuiteInfo {
    fn new(name: String, queue_index: usize) -> Self {
        SuiteInfo {
            name,
            status: Status::Queued,
            queue_index,
            started: false,
            heartbeat: None,
            passed: 0,
            failed: 0,
            exit_code: None,
            duration: None,
            reason: None,
        }
    }
}

/// Filter tabs shown in the header.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FilterTab {
    All,
    Running,
    Fail,
    Pass,
    Skip,
}

impl FilterTab {
    pub const ALL: [FilterTab; 5] = [
        FilterTab::All,
        FilterTab::Running,
        FilterTab::Fail,
        FilterTab::Pass,
        FilterTab::Skip,
    ];

    pub fn label(self) -> &'static str {
        match self {
            FilterTab::All => "All",
            FilterTab::Running => "Running",
            FilterTab::Fail => "Fail",
            FilterTab::Pass => "Pass",
            FilterTab::Skip => "Skip",
        }
    }

    pub fn matches(self, status: Status) -> bool {
        match self {
            FilterTab::All => true,
            FilterTab::Running => matches!(status, Status::Running | Status::Queued),
            FilterTab::Fail => status.is_failing(),
            FilterTab::Pass => matches!(status, Status::Pass),
            FilterTab::Skip => matches!(status, Status::Skip),
        }
    }
}

/// Whole-run snapshot: every suite seen so far, in first-seen (queue) order.
#[derive(Debug, Clone, Default)]
pub struct RunSnapshot {
    pub run_id: String,
    pub total_suites: usize,
    pub order: Vec<String>,
    pub suites: HashMap<String, SuiteInfo>,
    pub final_result: Option<String>,
}

impl RunSnapshot {
    pub fn new(run_id: String) -> Self {
        RunSnapshot {
            run_id,
            total_suites: 0,
            order: Vec::new(),
            suites: HashMap::new(),
            final_result: None,
        }
    }

    fn ensure(&mut self, name: &str) -> &mut SuiteInfo {
        if !self.suites.contains_key(name) {
            let idx = self.order.len();
            self.order.push(name.to_string());
            self.suites
                .insert(name.to_string(), SuiteInfo::new(name.to_string(), idx));
        }
        self.suites.get_mut(name).unwrap()
    }

    pub fn on_queue(&mut self, n: usize, total: usize, name: &str) {
        self.total_suites = self.total_suites.max(total);
        let s = self.ensure(name);
        s.queue_index = n;
    }

    pub fn on_start(&mut self, name: &str) {
        let s = self.ensure(name);
        s.started = true;
        s.status = Status::Running;
    }

    pub fn on_heartbeat(&mut self, name: &str, elapsed: f64, limit: f64) {
        let s = self.ensure(name);
        s.status = Status::Running;
        s.heartbeat = Some((elapsed, limit));
    }

    pub fn on_result_line(
        &mut self,
        status: Status,
        name: &str,
        passed: u32,
        failed: u32,
        exit_code: i32,
        duration: f64,
    ) {
        let s = self.ensure(name);
        s.status = status;
        s.passed = passed;
        s.failed = failed;
        s.exit_code = Some(exit_code);
        s.duration = Some(duration);
        s.heartbeat = None;
    }

    pub fn on_skip(&mut self, name: &str, reason: &str) {
        let s = self.ensure(name);
        s.status = Status::Skip;
        s.reason = Some(reason.to_string());
        s.heartbeat = None;
    }

    pub fn on_error_line(&mut self, name: &str, reason: &str) {
        let s = self.ensure(name);
        s.status = Status::Error;
        s.reason = Some(reason.to_string());
        s.heartbeat = None;
    }

    pub fn on_result_record(&mut self, rec: &crate::parse::ResultRecord) {
        let s = self.ensure(&rec.name);
        if let Some(status) = Status::from_str(&rec.status) {
            s.status = status;
        }
        s.passed = rec.passed;
        s.failed = rec.failed;
        s.exit_code = rec.exit_code;
        s.duration = Some(rec.duration);
        s.heartbeat = None;
    }

    pub fn filtered_order(&self, filter: FilterTab) -> Vec<&str> {
        self.order
            .iter()
            .filter(|n| {
                self.suites
                    .get(*n)
                    .map(|s| filter.matches(s.status))
                    .unwrap_or(false)
            })
            .map(|s| s.as_str())
            .collect()
    }

    pub fn stats(&self) -> Stats {
        let mut st = Stats::default();
        st.total = self.total_suites.max(self.order.len());
        let mut durations = Vec::new();
        let mut completed: Vec<(String, f64)> = Vec::new();
        for name in &self.order {
            let Some(s) = self.suites.get(name) else { continue };
            match s.status {
                Status::Queued => st.queued += 1,
                Status::Running => st.running += 1,
                Status::Pass => st.pass += 1,
                Status::Fail => st.fail += 1,
                Status::Timeout => st.timeout += 1,
                Status::Skip => st.skip += 1,
                Status::Error => st.error += 1,
            }
            st.tests_passed += s.passed as u64;
            st.tests_failed += s.failed as u64;
            if s.status.is_done() {
                if let Some(d) = s.duration {
                    durations.push(d);
                    if s.status != Status::Skip {
                        completed.push((s.name.clone(), d));
                    }
                }
            }
        }
        st.done = st.pass + st.fail + st.timeout + st.skip + st.error;
        st.avg_duration = crate::parse::rolling_average(&durations);
        st.p90_duration = crate::parse::p90(&durations);
        completed.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
        completed.truncate(10);
        st.slowest = completed;
        st
    }
}

/// Aggregate metrics over a whole run, recomputed each frame from the
/// current snapshot (cheap: run sizes are in the hundreds, not thousands).
#[derive(Debug, Clone, Default)]
pub struct Stats {
    pub total: usize,
    pub done: usize,
    pub queued: usize,
    pub running: usize,
    pub pass: usize,
    pub fail: usize,
    pub timeout: usize,
    pub skip: usize,
    pub error: usize,
    pub tests_passed: u64,
    pub tests_failed: u64,
    pub avg_duration: Option<f64>,
    pub p90_duration: Option<f64>,
    pub slowest: Vec<(String, f64)>,
}

impl Stats {
    pub fn pass_rate(&self) -> f64 {
        let counted = self.pass + self.fail + self.timeout + self.error;
        if counted == 0 {
            return 0.0;
        }
        self.pass as f64 / counted as f64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_with(statuses: &[(&str, Status)]) -> RunSnapshot {
        let mut run = RunSnapshot::new("test-run".to_string());
        for (name, status) in statuses {
            match status {
                Status::Queued => run.on_queue(1, statuses.len(), name),
                Status::Running => run.on_start(name),
                Status::Pass => run.on_result_line(Status::Pass, name, 1, 0, 0, 1.0),
                Status::Fail => run.on_result_line(Status::Fail, name, 0, 1, 1, 1.0),
                Status::Timeout => run.on_result_line(Status::Timeout, name, 0, 0, -2, 240.0),
                Status::Skip => run.on_skip(name, "reason"),
                Status::Error => run.on_error_line(name, "boom"),
            }
        }
        run
    }

    #[test]
    fn filter_all_matches_everything() {
        for s in [
            Status::Queued,
            Status::Running,
            Status::Pass,
            Status::Fail,
            Status::Timeout,
            Status::Skip,
            Status::Error,
        ] {
            assert!(FilterTab::All.matches(s));
        }
    }

    #[test]
    fn filter_running_matches_queued_and_running_only() {
        assert!(FilterTab::Running.matches(Status::Running));
        assert!(FilterTab::Running.matches(Status::Queued));
        assert!(!FilterTab::Running.matches(Status::Pass));
        assert!(!FilterTab::Running.matches(Status::Fail));
    }

    #[test]
    fn filter_fail_matches_fail_timeout_error_only() {
        assert!(FilterTab::Fail.matches(Status::Fail));
        assert!(FilterTab::Fail.matches(Status::Timeout));
        assert!(FilterTab::Fail.matches(Status::Error));
        assert!(!FilterTab::Fail.matches(Status::Pass));
        assert!(!FilterTab::Fail.matches(Status::Skip));
    }

    #[test]
    fn filter_pass_and_skip_are_exclusive() {
        assert!(FilterTab::Pass.matches(Status::Pass));
        assert!(!FilterTab::Pass.matches(Status::Fail));
        assert!(FilterTab::Skip.matches(Status::Skip));
        assert!(!FilterTab::Skip.matches(Status::Pass));
    }

    #[test]
    fn filtered_order_preserves_queue_order_and_excludes_non_matching() {
        let run = run_with(&[
            ("a_pass", Status::Pass),
            ("b_fail", Status::Fail),
            ("c_pass", Status::Pass),
            ("d_running", Status::Running),
        ]);
        let passes = run.filtered_order(FilterTab::Pass);
        assert_eq!(passes, vec!["a_pass", "c_pass"]);
        let all = run.filtered_order(FilterTab::All);
        assert_eq!(all, vec!["a_pass", "b_fail", "c_pass", "d_running"]);
    }

    #[test]
    fn stats_counts_each_status_bucket_once() {
        let run = run_with(&[
            ("s1", Status::Pass),
            ("s2", Status::Fail),
            ("s3", Status::Timeout),
            ("s4", Status::Skip),
            ("s5", Status::Error),
            ("s6", Status::Running),
        ]);
        let stats = run.stats();
        assert_eq!(stats.pass, 1);
        assert_eq!(stats.fail, 1);
        assert_eq!(stats.timeout, 1);
        assert_eq!(stats.skip, 1);
        assert_eq!(stats.error, 1);
        assert_eq!(stats.running, 1);
        assert_eq!(stats.done, 5); // running suite is not "done"
    }

    #[test]
    fn results_jsonl_record_overrides_progress_log_state() {
        let mut run = RunSnapshot::new("r".to_string());
        run.on_start("test_x");
        assert_eq!(run.suites["test_x"].status, Status::Running);
        let rec = crate::parse::ResultRecord {
            name: "test_x".to_string(),
            status: "PASS".to_string(),
            passed: 5,
            failed: 0,
            duration: 12.3,
            exit_code: Some(0),
        };
        run.on_result_record(&rec);
        let s = &run.suites["test_x"];
        assert_eq!(s.status, Status::Pass);
        assert_eq!(s.passed, 5);
        assert_eq!(s.duration, Some(12.3));
    }
}
