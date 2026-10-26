// mouse_registration_probe.exe <mode>   (issue #597)
// Determines WHICH mechanism makes conhost/ConPTY register mouse reporting with
// the outer terminal:
//   decset_writefile : write DECSET 1000/1002/1003/1006 with WriteFile on CONOUT
//   decset_writecon  : write the same via WriteConsoleW (the buffered stdout path)
//   setconsolemode   : only SetConsoleMode(hIn, ENABLE_MOUSE_INPUT) - no bytes written
//   both             : setconsolemode then decset_writefile
// It then sits still for 4 seconds so the host can capture the outward stream.
using System;
using System.Text;
using System.Runtime.InteropServices;

class RegProbe {
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetConsoleMode(IntPtr h, uint m);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool WriteFile(IntPtr h, byte[] b, uint n, out uint w, IntPtr o);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool WriteConsoleW(IntPtr h, string s, uint n, out uint w, IntPtr r);

    const int STD_INPUT_HANDLE = -10;
    const int STD_OUTPUT_HANDLE = -11;
    const uint ENABLE_MOUSE_INPUT = 0x0010;
    const uint ENABLE_EXTENDED_FLAGS = 0x0080;
    const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
    const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;

    const string DECSET = "\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h";

    static int Main(string[] a) {
        string mode = a.Length > 0 ? a[0] : "both";
        IntPtr hIn = GetStdHandle(STD_INPUT_HANDLE);
        IntPtr hOut = GetStdHandle(STD_OUTPUT_HANDLE);

        uint om; GetConsoleMode(hOut, out om);
        SetConsoleMode(hOut, om | ENABLE_VIRTUAL_TERMINAL_PROCESSING);

        // a marker so the capture can be sliced
        byte[] mark = Encoding.ASCII.GetBytes("<<MARK-" + mode + ">>");
        uint w;
        WriteFile(hOut, mark, (uint)mark.Length, out w, IntPtr.Zero);

        if (mode == "setconsolemode" || mode == "both") {
            uint im; GetConsoleMode(hIn, out im);
            SetConsoleMode(hIn, (im | ENABLE_MOUSE_INPUT | ENABLE_EXTENDED_FLAGS) & ~ENABLE_QUICK_EDIT_MODE);
        }
        if (mode == "decset_writefile" || mode == "both") {
            byte[] b = Encoding.ASCII.GetBytes(DECSET);
            WriteFile(hOut, b, (uint)b.Length, out w, IntPtr.Zero);
        }
        if (mode == "mouse_off") {
            uint im2; GetConsoleMode(hIn, out im2);
            SetConsoleMode(hIn, (im2 | ENABLE_MOUSE_INPUT | ENABLE_EXTENDED_FLAGS) & ~ENABLE_QUICK_EDIT_MODE);
            System.Threading.Thread.Sleep(700);
            uint im3; GetConsoleMode(hIn, out im3);
            SetConsoleMode(hIn, (im3 & ~ENABLE_MOUSE_INPUT) | ENABLE_EXTENDED_FLAGS);
        }
        if (mode == "decset_writecon") {
            WriteConsoleW(hOut, DECSET, (uint)DECSET.Length, out w, IntPtr.Zero);
        }

        byte[] end = Encoding.ASCII.GetBytes("<<END>>");
        WriteFile(hOut, end, (uint)end.Length, out w, IntPtr.Zero);
        System.Threading.Thread.Sleep(3000);
        return 0;
    }
}
