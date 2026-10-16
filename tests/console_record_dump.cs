// Dumps console input records with precise wall-clock stamps (issue #841
// follow up).  With "vt" it turns on ENABLE_VIRTUAL_TERMINAL_INPUT, so it reads
// the bytes a pane child is sent, one record per byte.
// Usage: console_record_dump.exe <outfile> <seconds> [vt]
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

class ConsoleRecordDump
{
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint m);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool ReadConsoleInputW(IntPtr h, [Out] INPUT_RECORD[] b, uint len, out uint read);
    [DllImport("kernel32.dll")] static extern void GetSystemTimePreciseAsFileTime(out long ft);
    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    struct INPUT_RECORD {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public int bKeyDown;
        [FieldOffset(8)] public ushort wRepeatCount;
        [FieldOffset(10)] public ushort wVirtualKeyCode;
        [FieldOffset(12)] public ushort wVirtualScanCode;
        [FieldOffset(14)] public char UnicodeChar;
        [FieldOffset(16)] public uint dwControlKeyState;
    }
    static double Now() { long ft; GetSystemTimePreciseAsFileTime(out ft); return (ft - 116444736000000000L) / 10000.0; }
    static int Main(string[] a)
    {
        IntPtr h = GetStdHandle(-10);
        uint m; GetConsoleMode(h, out m);
        uint nm = m & ~(0x0001u | 0x0002u | 0x0004u);
        if (a.Length > 2 && a[2] == "vt") nm |= 0x0200;
        SetConsoleMode(h, nm);
        var sb = new StringBuilder();
        sb.AppendFormat("{0:F3} START mode=0x{1:X}\n", Now(), nm);
        File.WriteAllText(a[0], sb.ToString());
        double end = Now() + double.Parse(a[1]) * 1000;
        var buf = new INPUT_RECORD[64];
        while (Now() < end)
        {
            if (WaitForSingleObject(h, 100) != 0) continue;
            uint n; ReadConsoleInputW(h, buf, 64, out n);
            double t = Now();
            for (int i = 0; i < n; i++)
            {
                var r = buf[i];
                if (r.EventType != 1) { sb.AppendFormat("{0:F3} batch={1} type={2}\n", t, n, r.EventType); continue; }
                sb.AppendFormat("{0:F3} batch={1} {2} vk=0x{3:X2} scan=0x{4:X2} ch=0x{5:X4} ctrl=0x{6:X} rep={7}\n",
                    t, n, r.bKeyDown != 0 ? "DOWN" : "UP  ", r.wVirtualKeyCode, r.wVirtualScanCode, (int)r.UnicodeChar, r.dwControlKeyState, r.wRepeatCount);
            }
            File.WriteAllText(a[0], sb.ToString());
        }
        File.WriteAllText(a[0], sb.ToString());
        return 0;
    }
}
