// csiinject654.exe <pid> <spec> [spec...]
//
// Console input injector for issue #654, the CSI u extended key.
//
// conhost's input parser does not know `CSI <code> ; <mods> u`, so it flushes
// the unrecognised sequence into the console input buffer ONE RECORD PER BYTE,
// every record carrying vk 0, scan 0 and the byte in UnicodeChar, and every
// record of the one press arriving in a SINGLE ReadConsoleInputW.  That shape
// is what `hexseq:` reproduces, byte for byte, in one WriteConsoleInput call:
//
//   DOWN vk=0x00 scan=0x00 uChar=0x001b        the ESC
//   DOWN vk=0x00 scan=0x00 uChar=0x005b  '['
//   DOWN vk=0x00 scan=0x00 uChar=0x0031  '1'
//   DOWN vk=0x00 scan=0x00 uChar=0x0033  '3'
//   DOWN vk=0x00 scan=0x00 uChar=0x003b  ';'
//   DOWN vk=0x00 scan=0x00 uChar=0x0032  '2'
//   DOWN vk=0x00 scan=0x00 uChar=0x0075  'u'
//
// tests/entinject611.cs writes (vk, uChar, ctrl) triples for real keyboard
// records; this one writes the vk-less records a console produces when it is
// flushing bytes it could not parse, and the burst a clipboard paste produces,
// which is the same shape and the reason a paste has to be told apart from a
// key.
//
// Specs:
//   hexseq:1b,5b,31,...   one DOWN record per value, vk 0, scan 0, ONE write
//   burst:<text>          a clipboard paste: DOWN+UP per character, ONE write
//   type:<text>[:MS]      human typing: one write per character, MS apart
//                         (default 40 ms, which is far outside the 20 ms the
//                         client's paste heuristic uses)
//   key:VK,UCHAR,CTRL     one real keyboard key, DOWN+UP, hex without 0x
//   sleep:MS
//
// Everything the injector did goes to $TEMP\csiinject654.log, because an
// injector that has detached its console cannot report on its own stdout.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

class CsiInject654
{
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share,
        IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] buf, uint len, out uint written);
    [DllImport("user32.dll")] static extern uint MapVirtualKeyW(uint code, uint mapType);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern short VkKeyScanW(char ch);

    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 1;
    const uint FILE_SHARE_WRITE = 2;
    const uint OPEN_EXISTING = 3;
    const ushort KEY_EVENT = 1;
    const uint SHIFT_PRESSED = 0x0010;

    [StructLayout(LayoutKind.Sequential)]
    struct KEY_EVENT_RECORD
    {
        public int bKeyDown;
        public ushort wRepeatCount;
        public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode;
        public char UnicodeChar;
        public uint dwControlKeyState;
    }

    [StructLayout(LayoutKind.Explicit)]
    struct INPUT_RECORD
    {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
    }

    static IntPtr h;
    static List<string> log = new List<string>();

    static INPUT_RECORD Rec(bool down, ushort vk, char ch, uint ctrl)
    {
        var r = new INPUT_RECORD();
        r.EventType = KEY_EVENT;
        r.KeyEvent.bKeyDown = down ? 1 : 0;
        r.KeyEvent.wRepeatCount = 1;
        r.KeyEvent.wVirtualKeyCode = vk;
        r.KeyEvent.wVirtualScanCode = vk == 0 ? (ushort)0 : (ushort)MapVirtualKeyW(vk, 0);
        r.KeyEvent.UnicodeChar = ch;
        r.KeyEvent.dwControlKeyState = ctrl;
        return r;
    }

    static void Flush(List<INPUT_RECORD> recs, string what)
    {
        if (recs.Count == 0) return;
        uint w;
        var arr = recs.ToArray();
        bool ok = WriteConsoleInputW(h, arr, (uint)arr.Length, out w);
        log.Add(string.Format("  WRITE {0} n={1} ok={2} w={3} e={4}",
            what, arr.Length, ok, w, ok ? 0 : Marshal.GetLastWin32Error()));
        recs.Clear();
    }

    static void CharKey(List<INPUT_RECORD> into, char c)
    {
        short sc = VkKeyScanW(c);
        ushort vk = (ushort)(sc & 0xFF);
        uint ctrl = (sc & 0x100) != 0 ? SHIFT_PRESSED : 0u;
        into.Add(Rec(true, vk, c, ctrl));
        into.Add(Rec(false, vk, c, ctrl));
    }

    static int Main(string[] argv)
    {
        string logFile = Path.Combine(Path.GetTempPath(), "csiinject654.log");
        if (argv.Length < 2)
        {
            File.WriteAllText(logFile, "usage: csiinject654 <pid> <spec>...\r\n");
            return 99;
        }
        uint pid;
        if (!uint.TryParse(argv[0], out pid))
        {
            File.WriteAllText(logFile, "bad pid\r\n");
            return 98;
        }
        log.Add("PID=" + pid);

        FreeConsole();
        if (!AttachConsole(pid))
        {
            log.Add("AttachConsole FAILED e=" + Marshal.GetLastWin32Error());
            File.WriteAllText(logFile, string.Join("\r\n", log.ToArray()));
            return 97;
        }
        h = CreateFileW("CONIN$", GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (h == new IntPtr(-1) || h == IntPtr.Zero)
        {
            log.Add("CONIN$ FAILED e=" + Marshal.GetLastWin32Error());
            FreeConsole();
            File.WriteAllText(logFile, string.Join("\r\n", log.ToArray()));
            return 96;
        }

        var buf = new List<INPUT_RECORD>();
        for (int i = 1; i < argv.Length; i++)
        {
            string s = argv[i];
            if (s.StartsWith("sleep:"))
            {
                Thread.Sleep(int.Parse(s.Substring(6)));
                log.Add("  sleep " + s.Substring(6));
            }
            else if (s.StartsWith("hexseq:"))
            {
                foreach (string v in s.Substring(7).Split(','))
                {
                    char ch = (char)ushort.Parse(v.Trim(), NumberStyles.HexNumber);
                    buf.Add(Rec(true, 0, ch, 0));
                }
                Flush(buf, "hexseq[" + s.Substring(7) + "]");
            }
            else if (s.StartsWith("burst:"))
            {
                foreach (char c in s.Substring(6)) CharKey(buf, c);
                Flush(buf, "burst[" + s.Substring(6) + "]");
            }
            else if (s.StartsWith("type:"))
            {
                string rest = s.Substring(5);
                int ms = 40;
                int colon = rest.LastIndexOf(':');
                if (colon > 0 && int.TryParse(rest.Substring(colon + 1), out ms))
                    rest = rest.Substring(0, colon);
                else ms = 40;
                foreach (char c in rest)
                {
                    CharKey(buf, c);
                    Flush(buf, "type " + c);
                    Thread.Sleep(ms);
                }
            }
            else if (s.StartsWith("key:"))
            {
                var p = s.Substring(4).Split(',');
                ushort vk = ushort.Parse(p[0], NumberStyles.HexNumber);
                char ch = (char)ushort.Parse(p[1], NumberStyles.HexNumber);
                uint ct = p.Length > 2 ? uint.Parse(p[2], NumberStyles.HexNumber) : 0u;
                buf.Add(Rec(true, vk, ch, ct));
                buf.Add(Rec(false, vk, ch, ct));
                Flush(buf, s);
            }
            else log.Add("  UNKNOWN spec " + s);
        }

        FreeConsole();
        File.WriteAllText(logFile, string.Join("\r\n", log.ToArray()));
        return 0;
    }
}
