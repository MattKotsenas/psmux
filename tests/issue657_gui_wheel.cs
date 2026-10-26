// Rolls a REAL mouse wheel at a GUI terminal window (Alacritty, WezTerm, ...).
//
// Every other wheel harness in this tree injects below the terminal: console
// MOUSE_EVENT records with WriteConsoleInput, or SGR bytes written into a pty.
// Issue #657 was reported against Alacritty, so one layer has to start where
// the user's hand does: a WM_MOUSEWHEEL message posted to the terminal's own
// window, which the terminal then decides to turn into an SGR report for the
// application (or to keep for its own scrollback).
//
// winit keeps the pointer position from the last WM_MOUSEMOVE, so a move is
// posted first; WM_MOUSEWHEEL carries SCREEN coordinates in lParam while
// WM_MOUSEMOVE carries client coordinates.
//
// Build: csc /nologo /out:issue657_gui_wheel.exe issue657_gui_wheel.cs
// Usage: issue657_gui_wheel.exe <pid> <up|down> <count> <clientX> <clientY>
using System;
using System.Runtime.InteropServices;

class Issue657GuiWheel {
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    delegate bool EnumProc(IntPtr h, IntPtr l);

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }

    const uint WM_MOUSEMOVE  = 0x0200;
    const uint WM_MOUSEWHEEL = 0x020A;

    static IntPtr found = IntPtr.Zero;
    static uint want;

    static int Main(string[] a) {
        if (a.Length < 5) {
            Console.WriteLine("usage: issue657_gui_wheel <pid> <up|down> <count> <clientX> <clientY>");
            return 2;
        }
        want = uint.Parse(a[0]);
        int count = int.Parse(a[2]);
        int cx = int.Parse(a[3]), cy = int.Parse(a[4]);
        int delta = (a[1] == "up") ? 120 : -120;

        EnumWindows((h, l) => {
            uint p;
            GetWindowThreadProcessId(h, out p);
            if (p == want && IsWindowVisible(h)) {
                RECT r;
                GetClientRect(h, out r);
                if (r.R - r.L > 100 && r.B - r.T > 100) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);

        if (found == IntPtr.Zero) { Console.WriteLine("NOWINDOW pid=" + want); return 3; }

        POINT pt; pt.X = cx; pt.Y = cy;
        POINT sp = pt;
        ClientToScreen(found, ref sp);
        Console.WriteLine("HWND=0x{0:X} client={1},{2} screen={3},{4}", found.ToInt64(), cx, cy, sp.X, sp.Y);

        IntPtr lpClient = (IntPtr)((cy << 16) | (cx & 0xFFFF));
        IntPtr lpScreen = (IntPtr)((sp.Y << 16) | (sp.X & 0xFFFF));

        PostMessage(found, WM_MOUSEMOVE, IntPtr.Zero, lpClient);
        System.Threading.Thread.Sleep(150);
        for (int i = 0; i < count; i++) {
            PostMessage(found, WM_MOUSEMOVE, IntPtr.Zero, lpClient);
            PostMessage(found, WM_MOUSEWHEEL, (IntPtr)((long)delta << 16), lpScreen);
            System.Threading.Thread.Sleep(220);
        }
        Console.WriteLine("SENT {0} notches", count);
        return 0;
    }
}
