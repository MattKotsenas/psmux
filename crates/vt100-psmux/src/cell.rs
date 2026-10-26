
// 22 content bytes keep the cell compact; the struct is 44 bytes once the
// Attrs OSC 8 hyperlink id (u32), the SGR 58 underline colour, the extended
// underline style and alignment padding are included.  It was 40 before the
// styled-underscore support (issue #589) added those last two; tmux carries
// the same pair on every grid_cell (`us` plus the UNDERSCORE_2..5 attr bits).
const CONTENT_BYTES: usize = 22;

/// The most UTF-8 bytes one cell holds, combining characters included
/// (tmux's `UTF8_SIZE`). An emoji ZWJ family of four people is 25 bytes, so
/// the inline 22 bytes are not enough (#749).
use crate::width::MAX_CELL_BYTES;

const IS_WIDE: u8 = 0b1000_0000;
const IS_WIDE_CONTINUATION: u8 = 0b0100_0000;
/// The contents live in the process wide cluster table and `contents[..4]`
/// holds their index there instead of the text itself.
const IS_INTERNED: u8 = 0b0010_0000;
const LEN_BITS: u8 = 0b0001_1111;

/// Text too long for a cell's inline bytes: a ZWJ sequence such as a family
/// or a flag sequence (#749).  Growing every cell to `MAX_CELL_BYTES` would
/// add twelve bytes to each of the 44 the cell costs today, across all of
/// scrollback, for text that is rare; tmux faces the same trade and stores any
/// character over three bytes as an index into a process wide table
/// (`utf8_from_data` and `utf8_put_item` in utf8.c) whose entries are never
/// freed.  This is that table, used only for what does not fit inline.
/// Entries are deduplicated, so equal text always gets the same index and
/// `Cell`'s byte comparison stays a text comparison.
struct ClusterTable {
    by_text: std::collections::HashMap<&'static str, u32>,
    by_index: Vec<&'static str>,
}

static CLUSTERS: std::sync::RwLock<Option<ClusterTable>> =
    std::sync::RwLock::new(None);

/// tmux stops issuing indexes at `0xffffff + 1` (`utf8_put_item`) and the
/// character is then not combined; the same bound keeps a hostile stream of
/// distinct sequences from growing the table without limit.
const MAX_CLUSTERS: usize = 0x00ff_ffff;

fn intern_cluster(text: &str) -> Option<u32> {
    if let Some(&index) = CLUSTERS
        .read()
        .ok()?
        .as_ref()
        .and_then(|t| t.by_text.get(text))
    {
        return Some(index);
    }
    let mut guard = CLUSTERS.write().ok()?;
    let table = guard.get_or_insert_with(|| ClusterTable {
        by_text: std::collections::HashMap::new(),
        by_index: Vec::new(),
    });
    if let Some(&index) = table.by_text.get(text) {
        return Some(index);
    }
    if table.by_index.len() >= MAX_CLUSTERS {
        return None;
    }
    let index = u32::try_from(table.by_index.len()).ok()?;
    let leaked: &'static str = Box::leak(text.to_owned().into_boxed_str());
    table.by_index.push(leaked);
    table.by_text.insert(leaked, index);
    drop(guard);
    Some(index)
}

fn interned_cluster(index: u32) -> &'static str {
    CLUSTERS
        .read()
        .ok()
        .and_then(|t| {
            t.as_ref()?
                .by_index
                .get(usize::try_from(index).ok()?)
                .copied()
        })
        .unwrap_or(" ")
}

/// Represents a single terminal cell.
#[derive(Clone, Debug, Eq)]
pub struct Cell {
    contents: [u8; CONTENT_BYTES],
    len: u8,
    attrs: crate::attrs::Attrs,
}
const _: () = assert!(std::mem::size_of::<Cell>() == 44);

impl PartialEq<Self> for Cell {
    fn eq(&self, other: &Self) -> bool {
        if self.len != other.len {
            return false;
        }
        if self.attrs != other.attrs {
            return false;
        }
        let len = self.len();
        self.contents[..len] == other.contents[..len]
    }
}

/// The one blank cell every row shares for the columns it does not store.
/// `Row` keeps only the columns up to the last one that differs from this, so
/// reads past that point hand out a reference to this instead of to a cell that
/// would have to be allocated first.  It is tmux's `grid_default_cell`, which
/// `grid_get_cell` copies out for any column at or past the line's `cellsize`
/// (tmux grid.c:650).
static BLANK: std::sync::OnceLock<Cell> = std::sync::OnceLock::new();

impl Cell {
    pub(crate) fn new() -> Self {
        Self {
            contents: Default::default(),
            len: 0,
            attrs: crate::attrs::Attrs::default(),
        }
    }

    /// A shared reference to the default blank cell.  Compares equal to
    /// `Cell::new()` and renders as nothing, so it is indistinguishable from a
    /// stored untouched cell on every read path.
    pub(crate) fn blank() -> &'static Self {
        BLANK.get_or_init(Self::new)
    }

    fn len(&self) -> usize {
        usize::from(self.len & LEN_BITS)
    }

    pub(crate) fn set(&mut self, c: char, a: crate::attrs::Attrs) {
        self.len = 0;
        self.append_char(0, c);
        // strings in this context should always be an arbitrary character
        // followed by zero or more zero-width characters, so we should only
        // have to look at the first character
        // Routed through the shared width function so a `codepoint-widths`
        // override decides the wide flag too. If this used unicode-width
        // directly while `Screen::text` honoured the override, the flag and
        // the column advance would disagree and strand a cell (#639).
        self.set_wide(crate::width::char_width(c).unwrap_or(1) > 1);
        self.attrs = a;
    }

    /// UTF-8 bytes the cell's text takes, which is what tmux compares against
    /// `UTF8_SIZE` before combining.
    pub(crate) fn content_bytes(&self) -> usize {
        self.contents().len()
    }

    /// Fold `c` into this cell's text.  Returns false, leaving the cell as it
    /// was, when the result would be longer than `MAX_CELL_BYTES`.
    pub(crate) fn append(&mut self, c: char) -> bool {
        let len = self.len();
        if len == 0 && !self.is_interned() {
            self.contents[0] = b' ';
            self.len += 1;
        }
        if !self.is_interned() && self.len() + c.len_utf8() <= CONTENT_BYTES {
            self.append_char(self.len(), c);
            return true;
        }

        let mut text = String::with_capacity(MAX_CELL_BYTES);
        text.push_str(self.contents());
        text.push(c);
        if text.len() > MAX_CELL_BYTES {
            return false;
        }
        let Some(index) = intern_cluster(&text) else {
            return false;
        };
        self.contents[..4].copy_from_slice(&index.to_le_bytes());
        self.len = (self.len & (IS_WIDE | IS_WIDE_CONTINUATION)) | IS_INTERNED | 4;
        true
    }

    fn is_interned(&self) -> bool {
        self.len & IS_INTERNED != 0
    }

    // Writes bytes representing c at start
    // Requires caller to verify start <= CODEPOINTS_IN_CELL * 4
    fn append_char(&mut self, start: usize, c: char) {
        c.encode_utf8(&mut self.contents[start..]);
        self.len += u8::try_from(c.len_utf8()).unwrap();
    }

    pub(crate) fn clear(&mut self, attrs: crate::attrs::Attrs) {
        self.len = 0;
        self.attrs = attrs;
    }

    /// Returns the text contents of the cell.
    ///
    /// Can include multiple unicode characters if combining characters are
    /// used, but will contain at most one character with a non-zero character
    /// width.
    // Since contents has been constructed by appending chars encoded as UTF-8 it will be valid UTF-8
    #[allow(clippy::missing_panics_doc)]
    #[must_use]
    pub fn contents(&self) -> &str {
        if self.is_interned() {
            let mut index = [0u8; 4];
            index.copy_from_slice(&self.contents[..4]);
            return interned_cluster(u32::from_le_bytes(index));
        }
        std::str::from_utf8(&self.contents[..self.len()]).unwrap()
    }

    /// Returns whether the cell contains any text data.
    #[must_use]
    pub fn has_contents(&self) -> bool {
        self.len() > 0
    }

    /// Returns whether the text data in the cell represents a wide character.
    #[must_use]
    pub fn is_wide(&self) -> bool {
        self.len & IS_WIDE != 0
    }

    /// Returns whether the cell contains the second half of a wide character
    /// (in other words, whether the previous cell in the row contains a wide
    /// character)
    #[must_use]
    pub fn is_wide_continuation(&self) -> bool {
        self.len & IS_WIDE_CONTINUATION != 0
    }

    pub(crate) fn set_wide(&mut self, wide: bool) {
        if wide {
            self.len |= IS_WIDE;
        } else {
            self.len &= !IS_WIDE;
        }
    }

    pub(crate) fn set_wide_continuation(&mut self, wide: bool) {
        if wide {
            self.len |= IS_WIDE_CONTINUATION;
        } else {
            self.len &= !IS_WIDE_CONTINUATION;
        }
    }

    pub(crate) fn attrs(&self) -> &crate::attrs::Attrs {
        &self.attrs
    }

    /// Returns the foreground color of the cell.
    #[must_use]
    pub fn fgcolor(&self) -> crate::Color {
        self.attrs.fgcolor
    }

    /// Returns the background color of the cell.
    #[must_use]
    pub fn bgcolor(&self) -> crate::Color {
        self.attrs.bgcolor
    }

    /// Returns the OSC 8 hyperlink id of the cell (0 = no hyperlink). Resolve
    /// it to a URI via `Screen::hyperlink_uri`.
    #[must_use]
    pub fn hyperlink_id(&self) -> u32 {
        self.attrs.link
    }

    /// Returns whether the cell should be rendered with the bold text
    /// attribute.
    #[must_use]
    pub fn bold(&self) -> bool {
        self.attrs.bold()
    }

    /// Returns whether the cell should be rendered with the dim text
    /// attribute.
    #[must_use]
    pub fn dim(&self) -> bool {
        self.attrs.dim()
    }

    /// Returns whether the cell should be rendered with the italic text
    /// attribute.
    #[must_use]
    pub fn italic(&self) -> bool {
        self.attrs.italic()
    }

    /// Returns whether the cell should be rendered with the underlined text
    /// attribute.
    #[must_use]
    pub fn underline(&self) -> bool {
        self.attrs.underline()
    }

    /// Returns the extended underline style the cell should be rendered with
    /// (single, double, curly, dotted or dashed).
    #[must_use]
    pub fn underline_style(&self) -> crate::attrs::UnderlineStyle {
        self.attrs.underline_style()
    }

    /// Returns the underline colour (SGR 58) the cell should be rendered
    /// with.  `Color::Default` means "use the foreground colour".
    #[must_use]
    pub fn underline_color(&self) -> crate::Color {
        self.attrs.ulcolor()
    }

    /// Returns whether the cell should be rendered with the inverse text
    /// attribute.
    #[must_use]
    pub fn inverse(&self) -> bool {
        self.attrs.inverse()
    }

    /// Returns whether the cell should be rendered with the blink text
    /// attribute.
    #[must_use]
    pub fn blink(&self) -> bool {
        self.attrs.blink()
    }

    /// Returns whether the cell should be rendered with the hidden/invisible
    /// text attribute.
    #[must_use]
    pub fn hidden(&self) -> bool {
        self.attrs.hidden()
    }

    /// Returns whether the cell should be rendered with the strikethrough
    /// text attribute.
    #[must_use]
    pub fn strikethrough(&self) -> bool {
        self.attrs.strikethrough()
    }
}
