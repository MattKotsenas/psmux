//! Copy-mode line numbers (tmux `copy-mode-line-numbers`).
//!
//! Pure logic for the left gutter shown in copy mode. The rendering side
//! (client.rs) asks this module for the gutter width and the number to print
//! on each visible row; all the mode arithmetic lives here so it can be unit
//! tested against tmux's formulas (window-copy.c).
//!
//! Row/offset conventions match tmux `window_copy_write_line`:
//! - `py`    visible row index, 0 = top of the pane.
//! - `oy`    scroll offset, 0 = scrolled to the live bottom.
//! - `cy`    the copy cursor's visible row.
//! - `hsize` number of scrollback (history) rows above the visible area.
//!
//! Modes:
//! - `off`       no gutter.
//! - `default`   distance of the row from the scroll offset: `|py - oy|`.
//! - `absolute`  1-based absolute line in the full grid: `hsize - oy + py + 1`.
//! - `relative`  distance from the cursor row: `|py - cy|` (cursor line = 0).
//! - `hybrid`    cursor line shows `absolute`; every other row shows `relative`.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CopyLnMode {
    Off,
    Default,
    Absolute,
    Relative,
    Hybrid,
}

/// The valid choice values (tmux order), for validation / customize-mode.
pub const CHOICES: &[&str] = &["off", "default", "absolute", "relative", "hybrid"];

/// The default value (tmux `default_num = 0` -> first choice `off`).
pub const DEFAULT: &str = "off";

impl CopyLnMode {
    /// Parse an option value. Unknown values are treated as `off`.
    pub fn parse(name: &str) -> CopyLnMode {
        match name.trim() {
            "default" => CopyLnMode::Default,
            "absolute" => CopyLnMode::Absolute,
            "relative" => CopyLnMode::Relative,
            "hybrid" => CopyLnMode::Hybrid,
            _ => CopyLnMode::Off,
        }
    }

    pub fn is_active(self) -> bool {
        self != CopyLnMode::Off
    }
}

/// Total gutter width in columns, including the trailing space separator.
/// Returns 0 when the gutter is inactive. Mirrors
/// `window_copy_line_number_width`: digits of `hsize + height + 1`, minimum 3,
/// plus 1 for the separating space.
pub fn gutter_width(mode: CopyLnMode, hsize: usize, height: usize) -> usize {
    if !mode.is_active() {
        return 0;
    }
    let mut lines = hsize + height + 1;
    let mut digits = 1;
    while lines >= 10 {
        lines /= 10;
        digits += 1;
    }
    if digits < 3 {
        digits = 3;
    }
    digits + 1
}

/// The number to print on visible row `py`.
pub fn line_number(mode: CopyLnMode, py: usize, oy: usize, cy: usize, hsize: usize) -> usize {
    match mode {
        CopyLnMode::Off => 0,
        CopyLnMode::Default => py.abs_diff(oy),
        CopyLnMode::Absolute => (hsize + py + 1).saturating_sub(oy),
        CopyLnMode::Relative => py.abs_diff(cy),
        CopyLnMode::Hybrid => {
            if py == cy {
                (hsize + py + 1).saturating_sub(oy)
            } else {
                py.abs_diff(cy)
            }
        }
    }
}

/// Format the gutter cell for row `py`: the number right-aligned in
/// `width - 1` columns followed by a single space, exactly `width` columns.
pub fn gutter_text(mode: CopyLnMode, width: usize, py: usize, oy: usize, cy: usize, hsize: usize) -> String {
    if width == 0 {
        return String::new();
    }
    let n = line_number(mode, py, oy, cy, hsize);
    format!("{:>w$} ", n, w = width - 1)
}

/// The view column a content column `cx` is drawn at, in a pane `sx` columns
/// wide whose gutter is `width` columns. The gutter pushes the content right
/// and the last columns clip, so the content a pane can show is `sx - width`
/// columns and anything past it sits on the final column. Mirrors tmux
/// `window_copy_cursor_offset` (window-copy.c).
pub fn cursor_offset(width: usize, cx: usize, sx: usize) -> usize {
    if width == 0 {
        return cx;
    }
    let content = if width >= sx { 1 } else { sx - width };
    if cx >= content {
        return sx.saturating_sub(1);
    }
    width + cx
}

/// The content column under view column `vx`, the inverse of `cursor_offset`.
/// A column inside the gutter itself reads as the first content column, and a
/// column past the clipped content reads as the last one. Mirrors tmux
/// `window_copy_cursor_unoffset` (window-copy.c), which every tmux mouse entry
/// point runs the pointer column through before it becomes a copy-mode
/// position.
pub fn cursor_unoffset(width: usize, vx: usize, sx: usize) -> usize {
    if width == 0 {
        return vx;
    }
    let content = if width >= sx { 1 } else { sx - width };
    if vx < width {
        return 0;
    }
    let vx = vx - width;
    if vx >= content {
        return content - 1;
    }
    vx
}

/// Whether the line number mode counts from the top of the grid, so the
/// position indicator has to agree with the gutter beside it. Mirrors tmux
/// `window_copy_line_number_is_absolute` (window-copy.c).
pub fn is_absolute(mode: CopyLnMode) -> bool {
    matches!(mode, CopyLnMode::Absolute | CopyLnMode::Relative | CopyLnMode::Hybrid)
}

/// The `(copy_position, copy_position_limit)` pair tmux builds in
/// `window_copy_formats` (window-copy.c):
/// - `off` / `default`: the scroll offset over the scrollback rows.
/// - `absolute` / `relative` / `hybrid`: the 1 based absolute line at the top
///   of the view over the total lines (scrollback plus the pane height).
pub fn copy_position(mode: CopyLnMode, oy: usize, hsize: usize, height: usize) -> (usize, usize) {
    if is_absolute(mode) {
        ((hsize + 1).saturating_sub(oy), hsize + height)
    } else {
        (oy, hsize)
    }
}

/// The copy mode position indicator text, tmux's default
/// `copy-mode-position-format` minus its alignment, time and search parts:
/// `[#{copy_position}/#{copy_position_limit}]`.
pub fn position_indicator(mode: CopyLnMode, oy: usize, hsize: usize, height: usize) -> String {
    let (position, limit) = copy_position(mode, oy, hsize, height);
    format!("[{}/{}]", position, limit)
}

/// Whether row `py` is the current (cursor) line, which is styled distinctly.
pub fn is_current_row(py: usize, cy: usize) -> bool {
    py == cy
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_and_off() {
        assert_eq!(CopyLnMode::parse("off"), CopyLnMode::Off);
        assert_eq!(CopyLnMode::parse("bogus"), CopyLnMode::Off);
        assert_eq!(CopyLnMode::parse(DEFAULT), CopyLnMode::Off);
        assert!(!CopyLnMode::Off.is_active());
        assert!(CopyLnMode::Relative.is_active());
        assert_eq!(gutter_width(CopyLnMode::Off, 1000, 40), 0);
    }

    #[test]
    fn width_min_three_plus_space() {
        // hsize+height+1 = 41 -> 2 digits -> min 3 -> +1 = 4
        assert_eq!(gutter_width(CopyLnMode::Absolute, 0, 40), 4);
        // 10000 -> 5 digits -> +1 = 6
        assert_eq!(gutter_width(CopyLnMode::Absolute, 9959, 40), 6);
    }

    #[test]
    fn absolute_counts_from_history_top() {
        // At the live bottom (oy = 0): absolute = hsize + py + 1.
        assert_eq!(line_number(CopyLnMode::Absolute, 0, 0, 5, 100), 101);
        assert_eq!(line_number(CopyLnMode::Absolute, 3, 0, 5, 100), 104);
        // Scrolled up 10: absolute shifts down by 10.
        assert_eq!(line_number(CopyLnMode::Absolute, 0, 10, 5, 100), 91);
    }

    #[test]
    fn relative_is_distance_from_cursor() {
        assert_eq!(line_number(CopyLnMode::Relative, 5, 0, 5, 100), 0); // cursor line
        assert_eq!(line_number(CopyLnMode::Relative, 2, 0, 5, 100), 3);
        assert_eq!(line_number(CopyLnMode::Relative, 9, 0, 5, 100), 4);
    }

    #[test]
    fn default_is_distance_from_offset() {
        // oy = 0: number equals the row index.
        assert_eq!(line_number(CopyLnMode::Default, 0, 0, 5, 100), 0);
        assert_eq!(line_number(CopyLnMode::Default, 7, 0, 5, 100), 7);
        // oy = 3: |py - 3|
        assert_eq!(line_number(CopyLnMode::Default, 1, 3, 5, 100), 2);
    }

    #[test]
    fn hybrid_cursor_absolute_others_relative() {
        // Cursor row shows absolute...
        assert_eq!(line_number(CopyLnMode::Hybrid, 5, 0, 5, 100), 106);
        // ...others show relative distance.
        assert_eq!(line_number(CopyLnMode::Hybrid, 2, 0, 5, 100), 3);
        assert_eq!(line_number(CopyLnMode::Hybrid, 8, 0, 5, 100), 3);
    }

    #[test]
    fn the_gutter_shifts_a_content_column_right() {
        // No gutter: the two columns are the same thing.
        assert_eq!(cursor_offset(0, 7, 80), 7);
        assert_eq!(cursor_unoffset(0, 7, 80), 7);
        // A 4-wide gutter: content column 0 is painted at view column 4.
        assert_eq!(cursor_offset(4, 0, 80), 4);
        assert_eq!(cursor_offset(4, 7, 80), 11);
        assert_eq!(cursor_unoffset(4, 11, 80), 7);
    }

    #[test]
    fn a_click_in_the_gutter_is_the_first_content_column() {
        for vx in 0..4 {
            assert_eq!(cursor_unoffset(4, vx, 80), 0, "view column {}", vx);
        }
        assert_eq!(cursor_unoffset(4, 4, 80), 0);
        assert_eq!(cursor_unoffset(4, 5, 80), 1);
    }

    #[test]
    fn the_clipped_columns_fold_onto_the_last_one() {
        // 80 columns with a 4-wide gutter shows 76 content columns, so the
        // last of them, 75, is painted on the last view column...
        assert_eq!(cursor_offset(4, 75, 80), 79);
        // ...and anything past it has nowhere to go but that same column.
        assert_eq!(cursor_offset(4, 76, 80), 79);
        assert_eq!(cursor_offset(4, 200, 80), 79);
        // ...and the last view column reads back as the last content column.
        assert_eq!(cursor_unoffset(4, 79, 80), 75);
        // A gutter as wide as the pane leaves one content column.
        assert_eq!(cursor_unoffset(6, 5, 6), 0);
        assert_eq!(cursor_offset(6, 3, 6), 5);
    }

    #[test]
    fn unoffset_undoes_offset_for_every_visible_column() {
        for width in [0usize, 4, 6] {
            let content = if width >= 80 { 1 } else { 80 - width };
            for cx in 0..content {
                assert_eq!(
                    cursor_unoffset(width, cursor_offset(width, cx, 80), 80),
                    cx,
                    "gutter {}, content column {}",
                    width, cx
                );
            }
        }
    }

    #[test]
    fn gutter_text_is_right_aligned_with_trailing_space() {
        // width 4 -> 3-wide number + space.
        assert_eq!(gutter_text(CopyLnMode::Relative, 4, 2, 0, 5, 100), "  3 ");
        assert_eq!(gutter_text(CopyLnMode::Absolute, 6, 0, 0, 5, 9959), " 9960 ");
    }
}

#[cfg(test)]
#[path = "../tests-rs/test_issue702_copy_position_indicator.rs"]
mod tests_issue702_copy_position_indicator;
