// The client registry and the client connection must die together.
//
// A reader thread that ends (EOF, or any real read error) is the ONLY reader a
// client has. If the server reaps the registry entry without closing the
// connection, the writer thread and the tracked persistent stream stay alive,
// so the client keeps receiving frames and painting a perfectly current screen
// while nothing it types or clicks can ever reach the server again. In
// `list-clients` it is simply absent, and the user sees a client that "does
// nothing" until it is restarted by hand.
//
// These tests pin the teardown helper the reader path now calls: it must shut
// the tracked stream down (so the client sees EOF and reconnects under a fresh
// client id) and drop every registration the connection owned.

use super::*;
use std::io::Read;
use std::net::{TcpListener, TcpStream};
use std::time::Duration;

fn loopback_pair() -> (TcpStream, TcpStream) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback listener");
    let addr = listener.local_addr().expect("local addr");
    let peer = TcpStream::connect(addr).expect("connect to loopback listener");
    let (server_side, _) = listener.accept().expect("accept loopback connection");
    let timeout = Some(Duration::from_secs(2));
    server_side.set_read_timeout(timeout).ok();
    peer.set_read_timeout(timeout).ok();
    (server_side, peer)
}

#[test]
fn teardown_client_connection_closes_the_tracked_stream() {
    const CID: u64 = 987_654_321;

    let (server_side, mut peer) = loopback_pair();
    register_persistent_stream(CID, &server_side);
    assert!(
        has_persistent_stream(CID),
        "the stream must be tracked before the teardown, or this test proves nothing"
    );

    teardown_client_connection(CID);

    assert!(
        !has_persistent_stream(CID),
        "the teardown must drop the tracked clone, or the registry would leak one entry per client"
    );

    // The peer is the client in this picture: it must observe the close
    // instead of blocking on a connection nobody will ever write to again.
    let mut buf = [0u8; 1];
    match peer.read(&mut buf) {
        Ok(0) => {}
        Ok(n) => panic!("expected EOF after the teardown, read {n} byte(s)"),
        Err(e) => assert!(
            matches!(
                e.kind(),
                std::io::ErrorKind::ConnectionReset
                    | std::io::ErrorKind::ConnectionAborted
                    | std::io::ErrorKind::UnexpectedEof
                    | std::io::ErrorKind::BrokenPipe
            ),
            "expected a disconnect, not {e:?}"
        ),
    }
}

#[test]
fn teardown_client_connection_is_safe_for_an_unknown_client() {
    // A duplicate detach (reader EOF and the writer Guard both observing the
    // same dead connection) is expected, so the teardown must be idempotent.
    teardown_client_connection(424_242);
    teardown_client_connection(424_242);
    assert!(!has_persistent_stream(424_242));
}

#[test]
fn reap_client_still_owns_only_the_registry() {
    // Deliberate: reap_client() must NOT touch the connection. User-initiated
    // detaches route through it, and those rely on the client exiting on its
    // own (or on the explicit DETACH directive) rather than on a stream drop,
    // which a client may treat as a transient disconnect and reconnect. The
    // reader path does the closing, immediately before it reports the detach.
    const CID: u64 = 987_654_322;
    let (server_side, _peer) = loopback_pair();
    register_persistent_stream(CID, &server_side);

    let mut app = AppState::new("teardown-test".to_string());
    assert!(!app.reap_client(CID), "an unknown client is not reaped");
    assert!(
        has_persistent_stream(CID),
        "reap_client must leave the connection alone; the reader path closes it"
    );

    deregister_persistent_stream(CID);
    assert!(!has_persistent_stream(CID));
}
