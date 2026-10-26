// conpty_echolat.cs - measure keystroke echo latency at the PSEUDOCONSOLE
// BOUNDARY, with no psmux in the picture at all.
//
// This process IS the pseudoconsole consumer. It creates a ConPTY, spawns a
// shell inside it, writes ONE character byte into the ConPTY input pipe, and
// timestamps EVERY ReadFile return on the ConPTY output pipe until the echoed
// character appears as ground text. Both timestamps come from one Stopwatch in
// one process, exactly like tests/keylat.cs.
//
// It answers, independently of psmux:
//   * how long does shell+conhost take to produce the echo of one keystroke
//   * does that echo really arrive split across several read chunks
//   * how far apart are those chunks, and which one carries the character
//
// Whatever this reports is the FLOOR for any ConPTY consumer, psmux included.
// Anything psmux measures above this number is psmux's; anything at or below
// it is upstream.
//
// The character is located with a real (small) escape-sequence state machine,
// so a letter appearing inside a CSI/OSC sequence is never mistaken for the
// echo. Only ground-state printable text counts.
//
// Usage:
//   conpty_echolat.exe --cmd "pwsh -NoLogo -NoProfile" --n 40 --gap 120
//                      --settle 4000 --out FILE [--label NAME] [--dump 3]
//                      [--erase 7f|08|none] [--cols 120] [--rows 30]
//
// Output (to --out, and stdout):
//   TRIAL <i> char=<c> first_chunk_ms=<f> char_chunk_ms=<t> chunks_before=<k> sizes=<a,b,c>
//   DUMP  <i> <chunk hex/printable ...>      (first --dump trials)
//   SUMMARY <label> n= min= p25= median= mean= p90= p99= max=      (char_chunk_ms)
//   SUMMARY_FIRSTCHUNK <label> ...                                 (first_chunk_ms)
//   SPLIT <label> trials_with_char_in_first_chunk=<a> of <n>
//
// Compile: csc /nologo /optimize /out:conpty_echolat.exe conpty_echolat.cs

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class ConPtyEchoLat
{
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreatePipe(out IntPtr hRead, out IntPtr hWrite, IntPtr sa, int size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern int CreatePseudoConsole(COORD size, IntPtr hInput, IntPtr hOutput, uint flags, out IntPtr phPC);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr h, byte[] buf, uint toRead, out uint read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(IntPtr h, byte[] buf, uint toWrite, out uint written, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetStdHandle(int which, IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr l, int c, int f, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr l, uint f, IntPtr attr, IntPtr val, IntPtr cb, IntPtr prev, IntPtr ret);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit,
        uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);

    [StructLayout(LayoutKind.Sequential)]
    struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFO
    {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }

    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    const int PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016;

    sealed class Chunk
    {
        public double Ms;
        public byte[] Bytes;
        public string Ground;   // ground-state printable text only
    }

    static readonly object gate = new object();
    static readonly List<Chunk> chunks = new List<Chunk>();
    static readonly List<string> Log = new List<string>();

    // Escape-sequence state carried ACROSS chunks, so a sequence split by a
    // read boundary still does not leak its letters into ground text.
    static int escState = 0;   // 0 ground, 1 after ESC, 2 in CSI, 3 in OSC, 4 OSC saw ESC
    static readonly StringBuilder groundBuf = new StringBuilder();

    static void FeedGround(byte[] b, int n)
    {
        groundBuf.Length = 0;
        for (int i = 0; i < n; i++)
        {
            byte c = b[i];
            switch (escState)
            {
                case 0:
                    if (c == 0x1b) escState = 1;
                    else if (c >= 0x20 && c < 0x7f) groundBuf.Append((char)c);
                    break;
                case 1:
                    if (c == '[') escState = 2;
                    else if (c == ']') escState = 3;
                    else if (c == 'P' || c == 'X' || c == '^' || c == '_') escState = 3; // string-ish
                    else escState = 0;                                                    // 2-byte escape
                    break;
                case 2:
                    if (c >= 0x40 && c <= 0x7e) escState = 0;                             // CSI final
                    break;
                case 3:
                    if (c == 0x07) escState = 0;
                    else if (c == 0x1b) escState = 4;
                    break;
                case 4:
                    escState = (c == '\\') ? 0 : 3;
                    break;
            }
        }
    }

    static string Hex(byte[] b)
    {
        var sb = new StringBuilder();
        foreach (var c in b)
        {
            if (c >= 0x20 && c < 0x7f) sb.Append((char)c);
            else if (c == 0x1b) sb.Append("<ESC>");
            else if (c == 0x0d) sb.Append("<CR>");
            else if (c == 0x0a) sb.Append("<LF>");
            else sb.Append("<" + c.ToString("X2") + ">");
        }
        return sb.ToString();
    }

    static double Pct(List<double> s, double p)
    {
        if (s.Count == 0) return 0;
        double idx = (s.Count - 1) * p;
        int lo = (int)Math.Floor(idx), hi = (int)Math.Ceiling(idx);
        return lo == hi ? s[lo] : s[lo] + (s[hi] - s[lo]) * (idx - lo);
    }

    static void Summarize(string tag, string label, List<double> samples)
    {
        var s = new List<double>(samples);
        s.Sort();
        double sum = 0; foreach (var v in s) sum += v;
        Log.Add(string.Format(CultureInfo.InvariantCulture,
            "{0} {1} n={2} min={3:F2} p25={4:F2} median={5:F2} mean={6:F2} p90={7:F2} p99={8:F2} max={9:F2}",
            tag, label, s.Count, s.Count > 0 ? s[0] : 0, Pct(s, .25), Pct(s, .50),
            s.Count > 0 ? sum / s.Count : 0, Pct(s, .90), Pct(s, .99), s.Count > 0 ? s[s.Count - 1] : 0));
    }

    static int Main(string[] argv)
    {
        var a = new Dictionary<string, string>();
        for (int i = 0; i < argv.Length; i++)
        {
            if (!argv[i].StartsWith("--")) continue;
            string k = argv[i].Substring(2);
            string v = (i + 1 < argv.Length && !argv[i + 1].StartsWith("--")) ? argv[++i] : "1";
            a[k] = v;
        }
        string cmd = a.ContainsKey("cmd") ? a["cmd"] : "pwsh -NoLogo -NoProfile";
        string label = a.ContainsKey("label") ? a["label"] : "conpty";
        string outFile = a.ContainsKey("out") ? a["out"] : Path.Combine(Path.GetTempPath(), "conpty_echolat.txt");
        int n = a.ContainsKey("n") ? int.Parse(a["n"]) : 40;
        int warmup = a.ContainsKey("warmup") ? int.Parse(a["warmup"]) : 5;
        double gap = a.ContainsKey("gap") ? double.Parse(a["gap"], CultureInfo.InvariantCulture) : 120;
        int settle = a.ContainsKey("settle") ? int.Parse(a["settle"]) : 4000;
        int dump = a.ContainsKey("dump") ? int.Parse(a["dump"]) : 3;
        int timeoutMs = a.ContainsKey("timeout") ? int.Parse(a["timeout"]) : 3000;
        string erase = a.ContainsKey("erase") ? a["erase"] : "7f";
        short cols = a.ContainsKey("cols") ? short.Parse(a["cols"]) : (short)120;
        short rows = a.ContainsKey("rows") ? short.Parse(a["rows"]) : (short)30;
        // 0x2 RESIZE_QUIRK | 0x4 WIN32_INPUT_MODE | 0x8 PASSTHROUGH_MODE, the
        // same flag set psmux asks for, so the floor measured here is the floor
        // psmux is actually standing on.
        uint ptyFlags = a.ContainsKey("ptyflags") ? Convert.ToUInt32(a["ptyflags"], 16) : 0u;

        Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.High;
        Thread.CurrentThread.Priority = ThreadPriority.Highest;

        IntPtr inRead, inWrite, outRead, outWrite;
        CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0);
        CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0);

        IntPtr hPC;
        int hr = CreatePseudoConsole(new COORD { X = cols, Y = rows }, inRead, outWrite, ptyFlags, out hPC);
        if (hr != 0) { File.WriteAllText(outFile, "ERROR CreatePseudoConsole 0x" + hr.ToString("X") + "\n"); return 1; }

        IntPtr attrSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrSize);
        IntPtr attrList = Marshal.AllocHGlobal(attrSize);
        InitializeProcThreadAttributeList(attrList, 1, 0, ref attrSize);
        UpdateProcThreadAttribute(attrList, 0, (IntPtr)PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hPC, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero);

        // This host owns a real console when launched from a shell, and
        // CreateProcess would propagate those console std handle VALUES into the
        // ConPTY child, where they bypass the pseudoconsole entirely: only the
        // title OSC reaches the pipe and the shell never echoes. NULL them so
        // the child binds fresh handles to the pseudoconsole. Same fix as
        // tests/conptycap.cs.
        SetStdHandle(-10, IntPtr.Zero);
        SetStdHandle(-11, IntPtr.Zero);
        SetStdHandle(-12, IntPtr.Zero);

        var si = new STARTUPINFOEX();
        si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        si.lpAttributeList = attrList;

        var sw = Stopwatch.StartNew();
        var reader = new Thread(() =>
        {
            var buf = new byte[16384];
            while (true)
            {
                uint got;
                if (!ReadFile(outRead, buf, (uint)buf.Length, out got, IntPtr.Zero) || got == 0) break;
                double ms = sw.Elapsed.TotalMilliseconds;
                var copy = new byte[got];
                Buffer.BlockCopy(buf, 0, copy, 0, (int)got);
                lock (gate)
                {
                    FeedGround(copy, copy.Length);
                    chunks.Add(new Chunk { Ms = ms, Bytes = copy, Ground = groundBuf.ToString() });
                }
            }
        });
        reader.IsBackground = true;
        reader.Priority = ThreadPriority.Highest;
        reader.Start();

        PROCESS_INFORMATION pi;
        bool ok = CreateProcess(null, cmd, IntPtr.Zero, IntPtr.Zero, false,
                                EXTENDED_STARTUPINFO_PRESENT, IntPtr.Zero, null, ref si, out pi);
        if (!ok) { File.WriteAllText(outFile, "ERROR CreateProcess " + Marshal.GetLastWin32Error() + "\n"); return 1; }

        // Wait for the shell to settle: fixed floor, then quiet for 400ms.
        Thread.Sleep(settle);
        double quietStart = sw.Elapsed.TotalMilliseconds;
        int lastCount = -1;
        while (sw.Elapsed.TotalMilliseconds - quietStart < 5000)
        {
            int c; double lastMs;
            lock (gate) { c = chunks.Count; lastMs = c > 0 ? chunks[c - 1].Ms : 0; }
            if (c == lastCount && sw.Elapsed.TotalMilliseconds - lastMs > 400) break;
            lastCount = c;
            Thread.Sleep(30);
        }

        lock (gate)
        {
            Log.Add("SETTLED " + label + " chunks=" + chunks.Count + " escState=" + escState);
            for (int i = Math.Max(0, chunks.Count - 3); i < chunks.Count; i++)
                Log.Add("SETTLE_TAIL [" + chunks[i].Ms.ToString("F2", CultureInfo.InvariantCulture) + " " + chunks[i].Bytes.Length + "B] " + Hex(chunks[i].Bytes));
        }

        var charSamples = new List<double>();
        var firstSamples = new List<double>();
        string alphabet = "abcdefghijklmnopqrstuvwxyz";
        int inFirst = 0, timeouts = 0;
        byte[] one = new byte[1];
        int total = n + warmup;

        for (int t = 0; t < total; t++)
        {
            char ch = alphabet[t % alphabet.Length];
            int from;
            lock (gate) { from = chunks.Count; }

            double t0 = sw.Elapsed.TotalMilliseconds;
            one[0] = (byte)ch;
            uint wr;
            if (!WriteFile(inWrite, one, 1, out wr, IntPtr.Zero) || wr != 1)
            {
                Log.Add("ERROR WriteFile input " + Marshal.GetLastWin32Error());
                break;
            }

            double firstMs = -1, charMs = -1;
            int chunksBefore = 0;
            var sizes = new List<int>();
            var dumps = new List<string>();
            for (; ; )
            {
                int cnt;
                lock (gate) { cnt = chunks.Count; }
                while (from < cnt)
                {
                    Chunk c;
                    lock (gate) { c = chunks[from]; }
                    from++;
                    sizes.Add(c.Bytes.Length);
                    if (t < warmup + dump && t >= warmup) dumps.Add("[" + c.Ms.ToString("F2", CultureInfo.InvariantCulture) + " +" + (c.Ms - t0).ToString("F2", CultureInfo.InvariantCulture) + "ms " + c.Bytes.Length + "B] " + Hex(c.Bytes));
                    if (firstMs < 0) firstMs = c.Ms;
                    if (c.Ground.IndexOf(ch) >= 0) { charMs = c.Ms; break; }
                    chunksBefore++;
                }
                if (charMs >= 0) break;
                if (sw.Elapsed.TotalMilliseconds - t0 > timeoutMs) break;
                Thread.SpinWait(200);
            }

            if (charMs < 0) timeouts++;
            else if (t >= warmup)
            {
                charSamples.Add(charMs - t0);
                firstSamples.Add(firstMs - t0);
                if (chunksBefore == 0) inFirst++;
                Log.Add(string.Format(CultureInfo.InvariantCulture,
                    "TRIAL {0} char={1} first_chunk_ms={2:F2} char_chunk_ms={3:F2} chunks_before={4} sizes={5}",
                    t - warmup, ch, firstMs - t0, charMs - t0, chunksBefore, string.Join(",", sizes.ToArray())));
                foreach (var d in dumps) Log.Add("DUMP " + (t - warmup) + " " + d);
            }

            if (erase != "none")
            {
                one[0] = erase == "08" ? (byte)0x08 : (byte)0x7f;
                WriteFile(inWrite, one, 1, out wr, IntPtr.Zero);
            }
            double until = sw.Elapsed.TotalMilliseconds + gap;
            while (sw.Elapsed.TotalMilliseconds < until) Thread.Sleep(1);
        }

        Log.Add("TIMEOUTS " + label + " " + timeouts);
        Log.Add("SPLIT " + label + " trials_with_char_in_first_chunk=" + inFirst + " of " + charSamples.Count);
        Summarize("SUMMARY", label, charSamples);
        Summarize("SUMMARY_FIRSTCHUNK", label, firstSamples);

        string body = string.Join("\n", Log.ToArray()) + "\n";
        File.WriteAllText(outFile, body);
        Console.Write(body);
        Console.Out.Flush();

        try { TerminateProcess(pi.hProcess, 0); } catch { }
        try { WaitForSingleObject(pi.hProcess, 500); } catch { }
        Environment.Exit(charSamples.Count == 0 ? 5 : 0);
        return 0;
    }
}
