# Issue #556 timing probe (python3, for the WSL tmux parity oracle).
# Same logic as color_query_timing_probe.js: send OSC 11 + CSI ?996n + DA1
# in yazi's order, timestamp every stdin chunk, report whether the OSC 11
# answer arrived before or after the DA1 answer (which closes yazi's window).
import sys, os, tty, termios, time, json, re, select

out_path = os.environ.get("PROBE_OUT", "/tmp/probe_timing.json")
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
try:
    t0 = time.monotonic()
    sys.stdout.write("\x1b]11;?\x07\x1b[?996n\x1b[c")
    sys.stdout.flush()
    buf = b""
    events = []
    da1_ms = None
    osc11_ms = None
    deadline = t0 + 4.0
    while time.monotonic() < deadline:
        r, _, _ = select.select([fd], [], [], 0.05)
        if not r:
            continue
        chunk = os.read(fd, 4096)
        if not chunk:
            break
        t_ms = round((time.monotonic() - t0) * 1000, 1)
        events.append({"tMs": t_ms, "hex": chunk.hex()})
        buf += chunk
        text = buf.decode("latin1")
        if da1_ms is None and re.search(r"\x1b\[\?[\d;]*c", text):
            da1_ms = t_ms
        if osc11_ms is None and re.search(r"\x1b\]11;rgb:[^\x07\x1b]+(?:\x07|\x1b\\\\)", text):
            osc11_ms = t_ms
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)

result = {
    "da1Ms": da1_ms,
    "osc11Ms": osc11_ms,
    "raceLost": da1_ms is not None and (osc11_ms is None or osc11_ms > da1_ms),
    "events": events,
    "responseHex": buf.hex(),
}
with open(out_path, "w") as f:
    json.dump(result, f)
print("TIMING_PROBE_DONE")
