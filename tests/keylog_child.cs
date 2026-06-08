// Key-logger child: runs inside a psmux pane, logs every console input char code
// (what psmux actually forwards through conpty) to a file. Mirrors what nvim sees.
// Build: csc /nologo /out:keylog_child.exe keylog_child.cs
using System;
using System.IO;
using System.Text;

class KeyLog {
    static int Main() {
        string log = Path.Combine(Environment.GetEnvironmentVariable("TEMP"), "psmux_keylog.txt");
        File.WriteAllText(log, "KEYLOG START\n");
        var sb = new StringBuilder();
        while (true) {
            ConsoleKeyInfo k;
            try { k = Console.ReadKey(true); }
            catch { System.Threading.Thread.Sleep(20); continue; }
            int ch = (int)k.KeyChar;
            string line = string.Format("char=0x{0:X2} key={1} mods={2}\n", ch, k.Key, k.Modifiers);
            File.AppendAllText(log, line);
            // Sentinel: '0x1A' (Ctrl+Z) or 'Q' ends the logger cleanly.
            if (ch == 0x1A) { File.AppendAllText(log, "KEYLOG END\n"); break; }
        }
        return 0;
    }
}
