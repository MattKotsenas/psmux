// Holds the Windows clipboard open for N ms (at most 5000), the way a clipboard
// history listener or an RDP clipboard bridge opens it right after a change.
// OpenClipboard needs a real window: with a NULL owner other processes can
// still open the clipboard, so the hold would block nobody.
// Usage: clipboard_holder <ms> <readyfile>   (writes readyfile once it holds it)
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

class ClipboardHolder {
    [DllImport("user32.dll", SetLastError = true)] static extern bool OpenClipboard(IntPtr h);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    static int Main(string[] a) {
        int ms = Math.Min(int.Parse(a[0]), 5000);
        IntPtr owner = new Form().Handle;
        bool held = false;
        for (int i = 0; i < 400 && !held; i++) { held = OpenClipboard(owner); if (!held) Thread.Sleep(5); }
        if (!held) { Console.WriteLine("could not open the clipboard"); return 1; }
        try {
            File.WriteAllText(a[1], "held");
            Thread.Sleep(ms);
        } finally { CloseClipboard(); }
        return 0;
    }
}
