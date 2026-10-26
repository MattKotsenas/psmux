// Issue #507 probe: read the GROUND TRUTH console cursor state of a running
// psmux client, plus a text dump of what is on screen.
//
// "Is the cursor visible?" on Windows is not a matter of interpreting a VT
// stream: the console host owns a cursor visibility flag and a cursor cell, and
// that is literally what the user sees blinking. GetConsoleCursorInfo /
// GetConsoleScreenBufferInfo report exactly that state.
//
// We attach to the target process's console (AttachConsole) and open CONOUT$,
// then sample the cursor N times so a transient hide-during-redraw cannot be
// mistaken for a persistently invisible cursor.
//
// Usage: cursorprobe.exe <pid> <outJsonFile> [samples] [intervalMs] [dumpScreen]
//
// Compile: csc /nologo /optimize /out:cursorprobe.exe cursorprobe.cs

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class CursorProbe
{
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(int pid);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleCursorInfo(IntPtr h, out CONSOLE_CURSOR_INFO info);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CONSOLE_SCREEN_BUFFER_INFO info);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool ReadConsoleOutputCharacterW(IntPtr h, [Out] char[] buf, uint len, COORD pos, out uint read);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);

    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SMALL_RECT { public short Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    struct CONSOLE_CURSOR_INFO { public uint dwSize; public int bVisible; }
    [StructLayout(LayoutKind.Sequential)]
    struct CONSOLE_SCREEN_BUFFER_INFO
    {
        public COORD dwSize; public COORD dwCursorPosition; public ushort wAttributes;
        public SMALL_RECT srWindow; public COORD dwMaximumWindowSize;
    }

    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2;
    const uint OPEN_EXISTING = 3;

    static string Esc(string s)
    {
        var sb = new StringBuilder();
        foreach (char c in s)
        {
            if (c == '"') sb.Append("\\\"");
            else if (c == '\\') sb.Append("\\\\");
            else if (c < 32 || c == 127) sb.Append("\\u").Append(((int)c).ToString("x4"));
            else sb.Append(c);
        }
        return sb.ToString();
    }

    static void Main(string[] args)
    {
        if (args.Length < 2)
        {
            Console.Error.WriteLine("usage: cursorprobe.exe <pid> <outJson> [samples] [intervalMs] [dumpScreen]");
            Environment.Exit(2);
        }
        int pid = int.Parse(args[0]);
        string outFile = args[1];
        int samples = args.Length > 2 ? int.Parse(args[2]) : 20;
        int interval = args.Length > 3 ? int.Parse(args[3]) : 100;
        bool dumpScreen = args.Length > 4 && args[4] == "1";

        var sb = new StringBuilder();
        FreeConsole();
        if (!AttachConsole(pid))
        {
            File.WriteAllText(outFile, "{\"error\":\"AttachConsole failed\",\"err\":" + Marshal.GetLastWin32Error() + "}");
            Environment.Exit(3);
        }
        IntPtr hOut = CreateFile("CONOUT$", GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (hOut == new IntPtr(-1))
        {
            File.WriteAllText(outFile, "{\"error\":\"CONOUT$ open failed\",\"err\":" + Marshal.GetLastWin32Error() + "}");
            Environment.Exit(4);
        }

        int visibleCount = 0, hiddenCount = 0, failCount = 0;
        var positions = new List<string>();
        var sizes = new List<uint>();
        CONSOLE_SCREEN_BUFFER_INFO lastInfo = new CONSOLE_SCREEN_BUFFER_INFO();

        for (int i = 0; i < samples; i++)
        {
            CONSOLE_CURSOR_INFO ci;
            CONSOLE_SCREEN_BUFFER_INFO bi;
            bool ok1 = GetConsoleCursorInfo(hOut, out ci);
            bool ok2 = GetConsoleScreenBufferInfo(hOut, out bi);
            if (!ok1 || !ok2) { failCount++; }
            else
            {
                if (ci.bVisible != 0) visibleCount++; else hiddenCount++;
                sizes.Add(ci.dwSize);
                positions.Add("[" + bi.dwCursorPosition.X + "," + bi.dwCursorPosition.Y + "," + (ci.bVisible != 0 ? 1 : 0) + "]");
                lastInfo = bi;
            }
            if (i < samples - 1) Thread.Sleep(interval);
        }

        sb.Append("{");
        sb.Append("\"pid\":").Append(pid).Append(",");
        sb.Append("\"samples\":").Append(samples).Append(",");
        sb.Append("\"visible\":").Append(visibleCount).Append(",");
        sb.Append("\"hidden\":").Append(hiddenCount).Append(",");
        sb.Append("\"failed\":").Append(failCount).Append(",");
        sb.Append("\"cursorX\":").Append(lastInfo.dwCursorPosition.X).Append(",");
        sb.Append("\"cursorY\":").Append(lastInfo.dwCursorPosition.Y).Append(",");
        sb.Append("\"bufW\":").Append(lastInfo.dwSize.X).Append(",");
        sb.Append("\"bufH\":").Append(lastInfo.dwSize.Y).Append(",");
        sb.Append("\"winLeft\":").Append(lastInfo.srWindow.Left).Append(",");
        sb.Append("\"winTop\":").Append(lastInfo.srWindow.Top).Append(",");
        sb.Append("\"winRight\":").Append(lastInfo.srWindow.Right).Append(",");
        sb.Append("\"winBottom\":").Append(lastInfo.srWindow.Bottom).Append(",");
        uint lastSize = sizes.Count > 0 ? sizes[sizes.Count - 1] : 0;
        sb.Append("\"cursorSize\":").Append(lastSize).Append(",");
        sb.Append("\"trace\":[").Append(string.Join(",", positions.ToArray())).Append("]");

        if (dumpScreen)
        {
            int w = lastInfo.dwSize.X;
            int h = lastInfo.srWindow.Bottom - lastInfo.srWindow.Top + 1;
            short top = lastInfo.srWindow.Top;
            var lines = new List<string>();
            for (int y = 0; y < h; y++)
            {
                char[] buf = new char[w];
                uint read;
                COORD p; p.X = 0; p.Y = (short)(top + y);
                if (ReadConsoleOutputCharacterW(hOut, buf, (uint)w, p, out read))
                    lines.Add("\"" + Esc(new string(buf, 0, (int)read).TrimEnd()) + "\"");
                else
                    lines.Add("\"<read failed>\"");
            }
            sb.Append(",\"screen\":[").Append(string.Join(",", lines.ToArray())).Append("]");
        }
        sb.Append("}");

        CloseHandle(hOut);
        File.WriteAllText(outFile, sb.ToString());
        Environment.Exit(0);
    }
}
