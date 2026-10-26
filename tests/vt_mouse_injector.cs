using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

// Injects a raw VT byte string (e.g. an SGR mouse report) into a console process
// via WriteConsoleInput KEY_EVENT records. This is the path a VT terminal such as
// Windows Terminal or WezTerm drives: the terminal writes SGR mouse sequences and
// psmux decodes them from the input stream rather than from MOUSE_EVENT records.
//
// Usage: vt_mouse_injector.exe <pid> <sequence> [repeat]
//   sequence supports \e for ESC, e.g. "\e[<64;90;10M" = SGR wheel up at col 90 row 10
//
// SGR mouse encoding: ESC [ < Cb ; Cx ; Cy M      (Cb 64 = wheel up, 65 = wheel down)
class VtMouseInjector
{
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AttachConsole(uint pid);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share,
        IntPtr sec, uint disp, uint flags, IntPtr tmpl);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteConsoleInput(IntPtr h, INPUT_RECORD[] buf, uint len, out uint written);

    const ushort KEY_EVENT = 0x0001;
    const uint GENERIC_WRITE = 0x40000000;
    const uint GENERIC_READ = 0x80000000;
    const uint FILE_SHARE_READ = 0x00000001;
    const uint FILE_SHARE_WRITE = 0x00000002;
    const uint OPEN_EXISTING = 3;

    [StructLayout(LayoutKind.Sequential)]
    struct KEY_EVENT_RECORD
    {
        public int bKeyDown;
        public ushort wRepeatCount;
        public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode;
        public ushort UnicodeChar;
        public uint dwControlKeyState;
    }

    [StructLayout(LayoutKind.Explicit, Size = 20)]
    struct INPUT_RECORD
    {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
    }

    static INPUT_RECORD CharRecord(char c, bool down)
    {
        var r = new INPUT_RECORD();
        r.EventType = KEY_EVENT;
        r.KeyEvent.bKeyDown = down ? 1 : 0;
        r.KeyEvent.wRepeatCount = 1;
        r.KeyEvent.wVirtualKeyCode = 0;
        r.KeyEvent.wVirtualScanCode = 0;
        r.KeyEvent.UnicodeChar = c;
        r.KeyEvent.dwControlKeyState = 0;
        return r;
    }

    static int Main(string[] args)
    {
        string logPath = Path.Combine(Path.GetTempPath(), "psmux_vtmouse_inject.log");

        if (args.Length < 2)
        {
            Console.Error.WriteLine("Usage: vt_mouse_injector.exe <pid> <sequence> [repeat]");
            return 1;
        }

        uint pid = uint.Parse(args[0]);
        string seq = args[1].Replace("\\e", "\x1b").Replace("\\E", "\x1b");
        int repeat = args.Length > 2 ? int.Parse(args[2]) : 1;

        var log = new System.Text.StringBuilder();
        log.AppendLine(string.Format("VtMouseInjector: pid={0} len={1} repeat={2}", pid, seq.Length, repeat));
        log.AppendLine("seq bytes: " + BitConverter.ToString(System.Text.Encoding.ASCII.GetBytes(seq)));

        FreeConsole();
        if (!AttachConsole(pid))
        {
            log.AppendLine("AttachConsole FAILED: " + Marshal.GetLastWin32Error());
            File.WriteAllText(logPath, log.ToString());
            return 2;
        }

        IntPtr hInput = CreateFileW("CONIN$",
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);

        if (hInput == IntPtr.Zero || hInput == (IntPtr)(-1))
        {
            log.AppendLine("CreateFile CONIN$ FAILED: " + Marshal.GetLastWin32Error());
            File.WriteAllText(logPath, log.ToString());
            FreeConsole();
            return 3;
        }

        for (int r = 0; r < repeat; r++)
        {
            foreach (char c in seq)
            {
                var recs = new INPUT_RECORD[] { CharRecord(c, true), CharRecord(c, false) };
                uint written;
                bool ok = WriteConsoleInput(hInput, recs, 2, out written);
                if (!ok) log.AppendLine(string.Format("  write '{0}' FAILED err={1}", (int)c, Marshal.GetLastWin32Error()));
            }
            log.AppendLine(string.Format("  sent repeat {0}", r));
            Thread.Sleep(60);
        }

        FreeConsole();
        File.WriteAllText(logPath, log.ToString());
        return 0;
    }
}
