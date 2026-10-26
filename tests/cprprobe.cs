// cprprobe.exe - how long does the server take to answer a pane's ESC[6n?
//
// Runs AS A PANE PROGRAM. Writes a DSR cursor position report request to its
// stdout and blocks reading its stdin until the CPR answer (ESC[<r>;<c>R) comes
// back, timing the round trip with one Stopwatch in one process. Repeats n
// times. Everything it prints goes to --out, never to the pane, so the screen it
// is measured on stays still.
//
// It exists because an application that queries the cursor position BLOCKS until
// the answer arrives: pwsh/PSReadLine does it at startup and after a resize,
// vim and fzf do it too. A multiplexer that answers on a poll tick rather than
// on the event makes every such app wait out that tick, and one that answers
// only when it happens to notice a flag can make the app wait for unrelated
// output that may never come.
//
// Usage:
//   cprprobe.exe --out FILE [--n 20] [--gap 150] [--settle 1500]
//                [--timeout 3000] [--label NAME]
//
// Output:
//   TRIAL <i> ms=<roundtrip>            one line per query
//   TIMEOUT <i>                         no answer inside --timeout
//   SUMMARY <label> n= timeouts= min= median= p90= max=
//   RAWTAIL <bytes>                     tail of what actually arrived on stdin,
//                                       so "no answer" is distinguishable from
//                                       "an answer the reader did not recognise"
//
// Compile: csc /nologo /optimize /out:cprprobe.exe cprprobe.cs
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class CprProbe
{
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleMode(IntPtr h, uint mode);
    const int STD_INPUT = -10;
    const int STD_OUTPUT = -11;
    const uint ENABLE_PROCESSED_INPUT = 0x0001;
    const uint ENABLE_LINE_INPUT = 0x0002;
    const uint ENABLE_ECHO_INPUT = 0x0004;
    const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;

    const char ESC = (char)27;
    static volatile bool _sawCpr;
    static Stream _in;
    static readonly StringBuilder _raw = new StringBuilder();

    static void Reader()
    {
        var buf = new byte[512];
        var pending = new StringBuilder();
        while (true)
        {
            int n;
            try { n = _in.Read(buf, 0, buf.Length); } catch { return; }
            if (n <= 0) return;
            for (int i = 0; i < n; i++) { pending.Append((char)buf[i]); _raw.Append((char)buf[i]); }
            // A CPR is ESC [ <digits> ; <digits> R. Scan for a well formed one
            // anywhere in what has arrived so far.
            string s = pending.ToString();
            for (int esc = s.IndexOf(ESC); esc >= 0 && esc + 2 < s.Length; esc = s.IndexOf(ESC, esc + 1))
            {
                if (s[esc + 1] != '[') continue;
                int k = esc + 2;
                bool semi = false, digits = false, ok = true;
                for (; k < s.Length; k++)
                {
                    char c = s[k];
                    if (c >= '0' && c <= '9') { digits = true; continue; }
                    if (c == ';') { semi = true; continue; }
                    if (c == 'R') break;
                    ok = false; break;
                }
                if (ok && semi && digits && k < s.Length && s[k] == 'R')
                {
                    _sawCpr = true;
                    pending.Clear();
                    break;
                }
            }
            if (pending.Length > 4096) pending.Remove(0, pending.Length - 512);
            if (_raw.Length > 8192) _raw.Remove(0, _raw.Length - 2048);
        }
    }

    static int Main(string[] argv)
    {
        var a = new Dictionary<string, string>();
        for (int i = 0; i < argv.Length; i++)
            if (argv[i].StartsWith("--") && i + 1 < argv.Length) a[argv[i].Substring(2)] = argv[++i];
        string outPath = a.ContainsKey("out") ? a["out"] : null;
        if (outPath == null) return 2;
        int n = a.ContainsKey("n") ? int.Parse(a["n"]) : 20;
        int gap = a.ContainsKey("gap") ? int.Parse(a["gap"]) : 150;
        int settle = a.ContainsKey("settle") ? int.Parse(a["settle"]) : 1500;
        int timeout = a.ContainsKey("timeout") ? int.Parse(a["timeout"]) : 3000;
        string label = a.ContainsKey("label") ? a["label"] : "cpr";

        // The default console input mode is cooked: ReadFile would not return
        // until a newline, and a CPR answer carries none. Same raw shape
        // echo_load_child.cs uses.
        IntPtr hi = GetStdHandle(STD_INPUT);
        IntPtr ho = GetStdHandle(STD_OUTPUT);
        uint m;
        if (GetConsoleMode(hi, out m))
            SetConsoleMode(hi, m & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT));
        if (GetConsoleMode(ho, out m))
            SetConsoleMode(ho, m | ENABLE_VIRTUAL_TERMINAL_PROCESSING);

        _in = Console.OpenStandardInput();
        var so = Console.OpenStandardOutput();
        var t = new Thread(Reader); t.IsBackground = true; t.Start();
        Thread.Sleep(settle);

        byte[] dsr = new byte[] { 27, (byte)'[', (byte)'6', (byte)'n' };
        var lines = new List<string>();
        var ms = new List<double>();
        int timeouts = 0;
        for (int i = 0; i < n; i++)
        {
            _sawCpr = false;
            var sw = Stopwatch.StartNew();
            so.Write(dsr, 0, dsr.Length); so.Flush();
            while (!_sawCpr && sw.Elapsed.TotalMilliseconds < timeout) Thread.Sleep(0);
            sw.Stop();
            if (_sawCpr)
            {
                ms.Add(sw.Elapsed.TotalMilliseconds);
                lines.Add(string.Format(CultureInfo.InvariantCulture, "TRIAL {0} ms={1:F2}", i, sw.Elapsed.TotalMilliseconds));
            }
            else { timeouts++; lines.Add("TIMEOUT " + i); }
            Thread.Sleep(gap);
        }
        ms.Sort();
        Func<double, double> pct = p => ms.Count == 0 ? -1 : ms[(int)Math.Floor(p * (ms.Count - 1))];
        lines.Add(string.Format(CultureInfo.InvariantCulture,
            "SUMMARY {0} n={1} timeouts={2} min={3:F2} median={4:F2} p90={5:F2} max={6:F2}",
            label, ms.Count, timeouts, pct(0.0), pct(0.5), pct(0.9), pct(1.0)));
        var vis = new StringBuilder();
        foreach (char c in _raw.ToString())
        {
            if (c == ESC) vis.Append("<E>");
            else if (c == (char)13) vis.Append("<CR>");
            else if (c == (char)10) vis.Append("<LF>");
            else if (c < ' ') vis.Append("<" + ((int)c).ToString("X2") + ">");
            else vis.Append(c);
        }
        lines.Add("RAWTAIL " + vis.ToString());
        File.WriteAllLines(outPath, lines.ToArray());
        // Keep the pane alive so the harness can read the file before teardown.
        Thread.Sleep(120000);
        return 0;
    }
}
