using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

// Injects a left-button DRAG that ends with a DWELL: press at (x1,y1), held
// moves to (x2,y2), then the pointer parks at (x2,y2) with the button still
// down for holdMs, then release. This is the gesture a user makes when they
// drag a selection to the pane edge and wait for it to auto-scroll (PR #590).
//
// jitter=0  : no events during the hold (the console never reports a MOUSE_MOVED
//             for a stationary pointer), so only a client-side repeat timer can
//             keep the drag alive.
// jitter=1  : re-emit the identical held MOUSE_MOVED every 50ms during the hold,
//             which is what some terminals do when the pointer rests on the edge.
//
// Usage: mouse_drag_hold_injector.exe <pid> <x1> <y1> <x2> <y2> <steps> <delayMs> <holdMs> [jitter]
class MouseDragHoldInjector
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
    struct COORD { public short X; public short Y; }

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

    static INPUT_RECORD Rec(short x, short y, uint buttons, uint flags)
    {
        var rec = new INPUT_RECORD();
        rec.EventType = MOUSE_EVENT;
        rec.MouseEvent.dwMousePosition.X = x;
        rec.MouseEvent.dwMousePosition.Y = y;
        rec.MouseEvent.dwButtonState = buttons;
        rec.MouseEvent.dwControlKeyState = 0;
        rec.MouseEvent.dwEventFlags = flags;
        return rec;
    }

    static int Main(string[] args)
    {
        string logPath = Path.Combine(Path.GetTempPath(), "psmux_mouse_drag_hold_inject.log");
        if (args.Length < 8)
        {
            Console.Error.WriteLine("Usage: mouse_drag_hold_injector.exe <pid> <x1> <y1> <x2> <y2> <steps> <delayMs> <holdMs> [jitter]");
            return 1;
        }
        uint pid = uint.Parse(args[0]);
        short x1 = short.Parse(args[1]);
        short y1 = short.Parse(args[2]);
        short x2 = short.Parse(args[3]);
        short y2 = short.Parse(args[4]);
        int steps = int.Parse(args[5]);
        int delayMs = int.Parse(args[6]);
        int holdMs = int.Parse(args[7]);
        bool jitter = args.Length > 8 && args[8] == "1";

        var log = new System.Text.StringBuilder();
        log.AppendLine(string.Format("MouseDragHoldInjector: pid={0} ({1},{2})->({3},{4}) steps={5} hold={6}ms jitter={7}",
            pid, x1, y1, x2, y2, steps, holdMs, jitter));

        FreeConsole();
        if (!AttachConsole(pid))
        {
            log.AppendLine("AttachConsole FAILED: " + Marshal.GetLastWin32Error());
            File.WriteAllText(logPath, log.ToString());
            return 2;
        }
        IntPtr hInput = CreateFileW("CONIN$", GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (hInput == IntPtr.Zero || hInput == (IntPtr)(-1))
        {
            log.AppendLine("CreateFile CONIN$ FAILED: " + Marshal.GetLastWin32Error());
            File.WriteAllText(logPath, log.ToString());
            FreeConsole();
            return 3;
        }

        uint w;
        bool ok = WriteConsoleInput(hInput, new INPUT_RECORD[] { Rec(x1, y1, FROM_LEFT_1ST_BUTTON_PRESSED, 0) }, 1, out w);
        log.AppendLine(string.Format("  press ({0},{1}) ok={2} w={3}", x1, y1, ok, w));
        Thread.Sleep(delayMs);

        for (int i = 1; i <= steps; i++)
        {
            short x = (short)(x1 + (x2 - x1) * i / steps);
            short y = (short)(y1 + (y2 - y1) * i / steps);
            ok = WriteConsoleInput(hInput, new INPUT_RECORD[] { Rec(x, y, FROM_LEFT_1ST_BUTTON_PRESSED, MOUSE_MOVED) }, 1, out w);
            log.AppendLine(string.Format("  drag[{0}] ({1},{2}) ok={3} w={4}", i, x, y, ok, w));
            Thread.Sleep(delayMs);
        }

        var sw = System.Diagnostics.Stopwatch.StartNew();
        int reps = 0;
        while (sw.ElapsedMilliseconds < holdMs)
        {
            if (jitter)
            {
                ok = WriteConsoleInput(hInput, new INPUT_RECORD[] { Rec(x2, y2, FROM_LEFT_1ST_BUTTON_PRESSED, MOUSE_MOVED) }, 1, out w);
                reps++;
            }
            Thread.Sleep(50);
        }
        log.AppendLine(string.Format("  hold {0}ms done, jitter events={1}", holdMs, reps));

        ok = WriteConsoleInput(hInput, new INPUT_RECORD[] { Rec(x2, y2, 0, 0) }, 1, out w);
        log.AppendLine(string.Format("  release ({0},{1}) ok={2} w={3}", x2, y2, ok, w));

        FreeConsole();
        log.AppendLine("Done");
        File.WriteAllText(logPath, log.ToString());
        return 0;
    }
}
