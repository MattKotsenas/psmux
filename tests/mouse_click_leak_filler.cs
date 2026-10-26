// Synthetic reproduction of the discussion #349 click-leak trap WITHOUT podman.
//
// The bug needs a pane whose foreground is a NON-shell, NON-(wsl/ssh) process
// that has filled the screen and echoes whatever bytes psmux writes to its
// PTY (exactly what an interactive container shell does). Local podman machines
// reach the VM over ssh.exe, which trips psmux's foreground_is_shell VT-bridge
// guard and hides the trap — so this standalone filler reproduces the reporter's
// mechanism deterministically:
//
//   1. it is "filler.exe", not a recognized shell and not a VT bridge;
//   2. it fills the screen with output (cursor ends near the bottom);
//   3. it echoes every byte read from stdin back to stdout — so if psmux
//      forwards a mouse CLICK as SGR (ESC[<0;x;yM), it is echoed as visible
//      text, exactly like "0;37;26M0;37;26m" in the report.
using System;
using System.IO;

class Filler {
    static void Main() {
        var outv = Console.Out;
        for (int i = 1; i <= 45; i++) {
            outv.WriteLine("-rw-r--r-- 1 root root {0,6} file{0}.txt", i);
        }
        outv.Write("/ # ");
        outv.Flush();
        // Dumb tty echo loop: read raw bytes and write them straight back.
        var stdin = Console.OpenStandardInput();
        var stdout = Console.OpenStandardOutput();
        byte[] buf = new byte[256];
        int n;
        while ((n = stdin.Read(buf, 0, buf.Length)) > 0) {
            stdout.Write(buf, 0, n);
            stdout.Flush();
        }
    }
}
