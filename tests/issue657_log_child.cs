// Issue #657 stand-in for the reporter's Spring Boot / Java application.
//
// The pane's foreground process must be:
//   1. NOT a shell (so psmux's shell exemption from #381 does not apply),
//   2. a process that has filled the whole pane with non blank log lines and
//      left the cursor on the last row,
//   3. a process that NEVER asks for mouse reporting and NEVER switches to the
//      alternate screen, and never touches the console mode (a plain Java
//      console app leaves stdin in the cooked shape it inherited).
//
// It then parks on a raw stdin read and appends every byte it receives to a log
// file, which is the ground truth for "did psmux forward the wheel into the
// application instead of scrolling the pane".
//
// Build: csc /nologo /out:issue657_log_child.exe issue657_log_child.cs
// Usage: issue657_log_child.exe [lines] [logpath]
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;

class Issue657LogChild {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr h, byte[] buf, uint n, out uint read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleMode(IntPtr h, out uint mode);

    const int STD_INPUT_HANDLE = -10;

    static int Main(string[] args) {
        int lines = 60;
        if (args.Length > 0) { int.TryParse(args[0], out lines); if (lines <= 0) lines = 60; }
        string log = args.Length > 1 && !string.IsNullOrWhiteSpace(args[1])
            ? args[1]
            : Path.Combine(Environment.GetEnvironmentVariable("TEMP"), "psmux_i657_child.txt");

        File.WriteAllText(log, "I657 CHILD START\n");

        // Fill the pane with non blank log lines, exactly like a Spring Boot boot
        // log. No escape sequences of any kind are written.
        var outv = Console.Out;
        for (int i = 1; i <= lines; i++) {
            outv.WriteLine("{0,5} INFO 12345 --- [  main] c.e.demo.DemoApplication : startup step {1} ready",
                           i, i);
        }
        outv.Flush();

        IntPtr hIn = GetStdHandle(STD_INPUT_HANDLE);
        uint mode;
        if (GetConsoleMode(hIn, out mode)) {
            File.AppendAllText(log, string.Format("stdin console mode 0x{0:X4} (untouched)\n", mode));
        } else {
            File.AppendAllText(log, "stdin is not a console\n");
        }

        byte[] buf = new byte[512];
        while (true) {
            uint read;
            if (!ReadFile(hIn, buf, (uint)buf.Length, out read, IntPtr.Zero)) {
                System.Threading.Thread.Sleep(30);
                continue;
            }
            if (read == 0) { System.Threading.Thread.Sleep(20); continue; }

            var txt = new StringBuilder();
            var hex = new StringBuilder();
            for (int i = 0; i < read; i++) {
                byte b = buf[i];
                hex.AppendFormat("{0:X2} ", b);
                if (b == 0x1b) txt.Append("<ESC>");
                else if (b >= 0x20 && b < 0x7f) txt.Append((char)b);
                else txt.AppendFormat("<{0:X2}>", b);
            }
            File.AppendAllText(log, string.Format("RECV {0}  |  {1}\n", txt.ToString(), hex.ToString().Trim()));
        }
    }
}
