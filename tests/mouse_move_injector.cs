using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

// Injects mouse MOVE (and optional click) events into a console process via
// WriteConsoleInput. Simulates a user moving the mouse across the psmux TUI
// window, which is what triggers mouse-motion forwarding into panes.
//
// Usage: mouse_move_injector.exe <pid> move <count> <startX> <startY> [stepX] [stepY] [delayMs]
//        mouse_move_injector.exe <pid> click <x> <y>
class MouseMoveInjector
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

    const ushort MOUSE_EVENT = 0x0002;
    const uint MOUSE_MOVED = 0x0001;
    const uint FROM_LEFT_1ST_BUTTON_PRESSED = 0x0001;
    const uint GENERIC_WRITE = 0x40000000;
    const uint GENERIC_READ = 0x80000000;
    const uint FILE_SHARE_READ = 0x00000001;
    const uint FILE_SHARE_WRITE = 0x00000002;
    const uint OPEN_EXISTING = 3;

    [StructLayout(LayoutKind.Sequential)]
    struct COORD
    {
        public short X;
        public short Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MOUSE_EVENT_RECORD
    {
        public COORD dwMousePosition;
        public uint dwButtonState;
        public uint dwControlKeyState;
        public uint dwEventFlags;
    }

    [StructLayout(LayoutKind.Explicit, Size = 20)]
    struct INPUT_RECORD
    {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public MOUSE_EVENT_RECORD MouseEvent;
    }

    static int Main(string[] args)
    {
        string configuredLog = Environment.GetEnvironmentVariable("PSMUX_MOUSE_MOVE_LOG");
        string logPath = string.IsNullOrWhiteSpace(configuredLog)
            ? Path.Combine(Path.GetTempPath(), "psmux_mouse_move_inject.log")
            : configuredLog;

        if (args.Length < 2)
        {
            Console.Error.WriteLine("Usage: mouse_move_injector.exe <pid> move <count> <startX> <startY> [stepX] [stepY] [delayMs]");
            Console.Error.WriteLine("       mouse_move_injector.exe <pid> click <x> <y>");
            return 1;
        }

        uint pid = uint.Parse(args[0]);
        string mode = args[1].ToLower();

        var log = new System.Text.StringBuilder();
        log.AppendLine(string.Format("MouseMoveInjector: pid={0} mode={1}", pid, mode));

        FreeConsole();
        if (!AttachConsole(pid))
        {
            int err = Marshal.GetLastWin32Error();
            log.AppendLine(string.Format("AttachConsole FAILED: error={0}", err));
            File.WriteAllText(logPath, log.ToString());
            return 2;
        }
        log.AppendLine("AttachConsole OK");

        IntPtr hInput = CreateFileW("CONIN$",
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);

        if (hInput == IntPtr.Zero || hInput == (IntPtr)(-1))
        {
            int err = Marshal.GetLastWin32Error();
            log.AppendLine(string.Format("CreateFile CONIN$ FAILED: error={0}", err));
            File.WriteAllText(logPath, log.ToString());
            FreeConsole();
            return 3;
        }
        log.AppendLine(string.Format("CONIN$ handle={0}", hInput));

        if (mode == "move")
        {
            int count = args.Length > 2 ? int.Parse(args[2]) : 20;
            short x = args.Length > 3 ? short.Parse(args[3]) : (short)10;
            short y = args.Length > 4 ? short.Parse(args[4]) : (short)10;
            short stepX = args.Length > 5 ? short.Parse(args[5]) : (short)2;
            short stepY = args.Length > 6 ? short.Parse(args[6]) : (short)1;
            int delayMs = args.Length > 7 ? int.Parse(args[7]) : 20;

            for (int i = 0; i < count; i++)
            {
                var rec = new INPUT_RECORD();
                rec.EventType = MOUSE_EVENT;
                rec.MouseEvent.dwMousePosition.X = x;
                rec.MouseEvent.dwMousePosition.Y = y;
                rec.MouseEvent.dwButtonState = 0;       // no buttons held: pure motion
                rec.MouseEvent.dwControlKeyState = 0;
                rec.MouseEvent.dwEventFlags = MOUSE_MOVED;

                uint written;
                bool ok = WriteConsoleInput(hInput, new INPUT_RECORD[] { rec }, 1, out written);
                int err = Marshal.GetLastWin32Error();
                log.AppendLine(string.Format("  move[{0}] pos=({1},{2}) ok={3} written={4} err={5}", i, x, y, ok, written, err));
                x += stepX;
                y += stepY;
                Thread.Sleep(delayMs);
            }
        }
        else if (mode == "click")
        {
            short x = args.Length > 2 ? short.Parse(args[2]) : (short)10;
            short y = args.Length > 3 ? short.Parse(args[3]) : (short)10;

            var press = new INPUT_RECORD();
            press.EventType = MOUSE_EVENT;
            press.MouseEvent.dwMousePosition.X = x;
            press.MouseEvent.dwMousePosition.Y = y;
            press.MouseEvent.dwButtonState = FROM_LEFT_1ST_BUTTON_PRESSED;
            press.MouseEvent.dwControlKeyState = 0;
            press.MouseEvent.dwEventFlags = 0; // button press/release use flags=0

            uint w1;
            bool ok1 = WriteConsoleInput(hInput, new INPUT_RECORD[] { press }, 1, out w1);
            log.AppendLine(string.Format("  press ok={0} w={1}", ok1, w1));
            Thread.Sleep(60);

            var release = new INPUT_RECORD();
            release.EventType = MOUSE_EVENT;
            release.MouseEvent.dwMousePosition.X = x;
            release.MouseEvent.dwMousePosition.Y = y;
            release.MouseEvent.dwButtonState = 0;
            release.MouseEvent.dwControlKeyState = 0;
            release.MouseEvent.dwEventFlags = 0;

            uint w2;
            bool ok2 = WriteConsoleInput(hInput, new INPUT_RECORD[] { release }, 1, out w2);
            log.AppendLine(string.Format("  release ok={0} w={1}", ok2, w2));
        }
        else
        {
            log.AppendLine("Unknown mode: " + mode);
            File.WriteAllText(logPath, log.ToString());
            FreeConsole();
            return 4;
        }

        FreeConsole();
        log.AppendLine("Done");
        File.WriteAllText(logPath, log.ToString());
        return 0;
    }
}
