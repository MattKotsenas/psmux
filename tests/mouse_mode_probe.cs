// mouse_mode_probe.exe <pid> [set|clear|query]   (issue #597)
// Attaches to a running process's console and clears (or sets) ENABLE_MOUSE_INPUT
// on its input buffer. This models a mid-session console-mode reset: Windows
// Terminal, a nested console app, or any AttachConsole-based tool can leave the
// client's console without ENABLE_MOUSE_INPUT, at which point the terminal stops
// reporting mouse until the app re-asserts the flag.
using System;
using System.Runtime.InteropServices;

class ClearMousePid {
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateFileW(string n, uint a, uint s, IntPtr sec, uint d, uint f, IntPtr t);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetConsoleMode(IntPtr h, uint m);

    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, OPEN_EXISTING = 3;
    const uint ENABLE_MOUSE_INPUT = 0x0010;
    const uint ENABLE_EXTENDED_FLAGS = 0x0080;

    static int Main(string[] a) {
        uint pid = uint.Parse(a[0]);
        string op = a.Length > 1 ? a[1] : "clear";
        FreeConsole();
        if (!AttachConsole(pid)) { Console.Error.WriteLine("ATTACH_FAILED " + Marshal.GetLastWin32Error()); return 2; }
        IntPtr h = CreateFileW("CONIN$", GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (h == (IntPtr)(-1)) { Console.Error.WriteLine("CONIN_FAILED " + Marshal.GetLastWin32Error()); return 3; }
        uint m;
        if (!GetConsoleMode(h, out m)) { Console.Error.WriteLine("GETMODE_FAILED"); return 4; }
        string res = "before=0x" + m.ToString("X4") + " mouse=" + ((m & ENABLE_MOUSE_INPUT) != 0);
        if (op == "clear") {
            SetConsoleMode(h, (m & ~ENABLE_MOUSE_INPUT) | ENABLE_EXTENDED_FLAGS);
        } else if (op == "set") {
            SetConsoleMode(h, m | ENABLE_MOUSE_INPUT | ENABLE_EXTENDED_FLAGS);
        }
        uint m2; GetConsoleMode(h, out m2);
        res += " after=0x" + m2.ToString("X4") + " mouse=" + ((m2 & ENABLE_MOUSE_INPUT) != 0);
        FreeConsole();
        Console.WriteLine(res);
        return 0;
    }
}
