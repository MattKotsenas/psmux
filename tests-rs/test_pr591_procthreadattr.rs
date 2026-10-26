//! PR #591: `ProcThreadAttributeList::with_capacity` now allocates
//! `vec![0; bytes_required]` instead of `Vec::with_capacity` + `set_len`.
//! Pin three facts so a future "optimisation" cannot silently regress:
//!   1. construction succeeds for the attribute counts psmux uses (1),
//!   2. the buffer has the size Win32 asked for (non-zero) and Win32 wrote
//!      into that exact buffer (some byte is non-zero after init),
//!   3. `as_mut_ptr()` returns the address of the owned buffer.
use super::ProcThreadAttributeList;

#[test]
fn with_capacity_one_succeeds_and_win32_wrote_into_the_zeroed_buffer() {
    let mut list = ProcThreadAttributeList::with_capacity(1).expect("init attribute list");
    assert!(!list.data.is_empty(), "InitializeProcThreadAttributeList asked for 0 bytes");
    // Win32 fills a header (flags, count, size) into the storage it was
    // handed, so a fully-zero buffer would mean it wrote somewhere else.
    assert!(
        list.data.iter().any(|&b| b != 0),
        "Win32 did not initialise the buffer we own: {:?}",
        list.data
    );
    let ptr = list.as_mut_ptr() as *const u8;
    assert_eq!(ptr, list.data.as_ptr(), "as_mut_ptr must alias the owned Vec");
}

#[test]
fn with_capacity_two_is_larger_than_one() {
    let one = ProcThreadAttributeList::with_capacity(1).expect("one");
    let two = ProcThreadAttributeList::with_capacity(2).expect("two");
    assert!(two.data.len() > one.data.len(), "one={} two={}", one.data.len(), two.data.len());
}
