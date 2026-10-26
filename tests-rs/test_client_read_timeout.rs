// A client read that did not complete is not a client that died.
//
// Every client connection is read with a `set_read_timeout` budget, and the
// three reader loops in `handle_connection` treat the expiry of that budget as
// "nothing arrived yet, keep waiting". Only `WouldBlock`/`TimedOut` were
// treated that way. On Windows the same expiry can surface as
// `WSA_IO_PENDING` (os error 997, "overlapped I/O operation is in progress"),
// because Rust opens its sockets with `WSA_FLAG_OVERLAPPED`; that maps to
// `ErrorKind::Uncategorized`, fell through to the fatal branch, and the server
// closed the connection of a healthy idle client. Measured here, from
// `~/.psmux/server_debug.log` on the reporter's box, three times in one
// session:
//
//   [06:20:42.200][client-reader] client 1732: batching read error
//     Os { code: 997, kind: Uncategorized,
//          message: "overlapped I/O operation is in progress." }
//     (attached_sent=true), closing the connection
//
// immediately followed by the client's own reconnect trace, and then by a
// window whose size could no longer be recovered.
//
// These tests pin the classification, including the exact shape the field log
// printed, so the fatal branch stays reserved for a connection that really is
// gone.

use super::*;
use std::io;

#[test]
fn would_block_and_timed_out_are_retries() {
    assert!(is_read_retry(&io::Error::new(io::ErrorKind::WouldBlock, "again")));
    assert!(is_read_retry(&io::Error::new(io::ErrorKind::TimedOut, "expired")));
}

#[test]
fn an_interrupted_read_is_a_retry() {
    // EINTR/WSAEINTR: the read was cancelled, not the connection. Rust maps
    // neither 10004 nor `ErrorKind::Interrupted` on Windows, so the raw code is
    // what actually fires there.
    assert!(is_read_retry(&io::Error::new(io::ErrorKind::Interrupted, "signal")));
    assert!(is_read_retry(&io::Error::from_raw_os_error(10004)));
}

#[test]
fn wsa_io_pending_is_a_retry() {
    assert!(is_read_retry(&io::Error::from_raw_os_error(997)));
}

#[test]
fn a_timed_out_receive_is_a_retry() {
    // 10060 already decodes to TimedOut on this toolchain; the raw code is kept
    // so the classification does not depend on that mapping staying.
    let e = io::Error::from_raw_os_error(10060);
    assert_eq!(e.kind(), io::ErrorKind::TimedOut);
    assert!(is_read_retry(&e));
}

#[test]
fn the_error_the_field_log_printed_is_a_retry() {
    // Exactly what the reader logged: os error 997 with a kind that is not
    // WouldBlock and not TimedOut. This is the regression, stated as the
    // reader sees it.
    let e = io::Error::from_raw_os_error(997);
    assert_eq!(e.raw_os_error(), Some(997));
    assert_ne!(e.kind(), io::ErrorKind::WouldBlock);
    assert_ne!(e.kind(), io::ErrorKind::TimedOut);
    assert!(
        is_read_retry(&e),
        "os error 997 must be retried, not treated as a dead client"
    );
}

#[test]
fn a_real_disconnect_is_not_a_retry() {
    // The peer actually went away. These must still close the connection, or
    // the reap path that keeps `attached_clients` honest would never run.
    assert!(!is_read_retry(&io::Error::from_raw_os_error(10054))); // WSAECONNRESET
    assert!(!is_read_retry(&io::Error::new(io::ErrorKind::ConnectionReset, "reset")));
    assert!(!is_read_retry(&io::Error::new(io::ErrorKind::ConnectionAborted, "aborted")));
    assert!(!is_read_retry(&io::Error::new(io::ErrorKind::UnexpectedEof, "eof")));
    assert!(!is_read_retry(&io::Error::new(io::ErrorKind::BrokenPipe, "pipe")));
    assert!(!is_read_retry(&io::Error::from_raw_os_error(10061))); // WSAECONNREFUSED
}
