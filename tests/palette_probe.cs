// palette_probe.exe <pid>
//
// Dumps another process's console colour table (the 16 RGB values a console
// screen buffer resolves attribute indices against) plus the current default
// attribute, using GetConsoleScreenBufferInfoEx over an AttachConsole.
//
// This is the measurement for the palette half of issue #623.  A console app
// such as Far Manager can install its own 16 colour RGB table with
// SetConsoleScreenBufferInfoEx.  Under a real conhost window that changes what
// the user sees.  Under a pseudoconsole it does not leave the pseudoconsole:
// ConPTY has no escape sequence to forward a console palette change to the
// terminal that hosts it (microsoft/terminal#11522), so the table measured here
// tells us whether the app changed it at all and what it changed it to.
using System;
using System.Runtime.InteropServices;
using System.Text;

class PaletteProbe
{
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string n, uint a, uint s, IntPtr sec, uint d, uint f, IntPtr t);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleScreenBufferInfoEx(IntPtr h, ref CONSOLE_SCREEN_BUFFER_INFOEX i);

    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SMALL_RECT { public short Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct CONSOLE_SCREEN_BUFFER_INFOEX
    {
        public int cbSize;
        public COORD dwSize;
        public COORD dwCursorPosition;
        public ushort wAttributes;
        public SMALL_RECT srWindow;
        public COORD dwMaximumWindowSize;
        public ushort wPopupAttributes;
        public int bFullscreenSupported;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
        public uint[] ColorTable;
    }

    static int Main(string[] argv)
    {
        if (argv.Length < 1) { Console.Error.WriteLine("usage: palette_probe <pid>"); return 1; }
        uint pid = uint.Parse(argv[0]);
        var sb = new StringBuilder();

        FreeConsole();
        if (!AttachConsole(pid)) { Console.Error.WriteLine("ATTACH_FAIL " + Marshal.GetLastWin32Error()); return 2; }
        IntPtr h = CreateFileW("CONOUT$", 0xC0000000u, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h == new IntPtr(-1)) { int e = Marshal.GetLastWin32Error(); FreeConsole(); Console.Error.WriteLine("CONOUT_FAIL " + e); return 3; }

        var info = new CONSOLE_SCREEN_BUFFER_INFOEX();
        info.cbSize = Marshal.SizeOf(typeof(CONSOLE_SCREEN_BUFFER_INFOEX));
        info.ColorTable = new uint[16];
        bool ok = GetConsoleScreenBufferInfoEx(h, ref info);
        int err = ok ? 0 : Marshal.GetLastWin32Error();
        FreeConsole();
        if (!ok) { Console.Error.WriteLine("INFOEX_FAIL " + err); return 4; }

        sb.AppendFormat("ATTR 0x{0:X4} POPUP 0x{1:X4} SIZE {2}x{3}\n",
            info.wAttributes, info.wPopupAttributes, info.dwSize.X, info.dwSize.Y);
        for (int i = 0; i < 16; i++)
        {
            uint v = info.ColorTable[i];
            // COLORREF is 0x00BBGGRR.
            int r = (int)(v & 0xFF), g = (int)((v >> 8) & 0xFF), b = (int)((v >> 16) & 0xFF);
            sb.AppendFormat("COLOR {0,2} #{1:X2}{2:X2}{3:X2} rgb({4},{5},{6})\n", i, r, g, b, r, g, b);
        }
        Console.Out.Write(sb.ToString());
        return 0;
    }
}
