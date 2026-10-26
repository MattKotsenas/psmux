// ctrlc_immune_helper.cs (issue #454)
//
// A faithful model of the "unresponsive program" a user reaches for Ctrl+Break
// to stop: it IGNORES Ctrl+C entirely (traps CTRL_C_EVENT and returns TRUE) but
// leaves Ctrl+Break at its default so a genuine CTRL_BREAK_EVENT terminates it.
// This is exactly the case the old psmux fix missed: Ctrl+Break was mapped to the
// Ctrl+C path, which a Ctrl+C-immune program swallows, so it kept running while a
// real terminal (Windows Terminal) would have killed it.
//
// Prints "CTRLC_IMMUNE_READY pid=<pid>" once running, then a periodic
// "STILL_ALIVE <n>" heartbeat so a test can see it survive Ctrl+C and stop on
// Ctrl+Break.
using System;
using System.Runtime.InteropServices;

class CtrlcImmune
{
    delegate bool HandlerRoutine(uint ctrlType);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

    const uint CTRL_C_EVENT = 0;
    const uint CTRL_BREAK_EVENT = 1;

    static HandlerRoutine _keepAlive;

    static int Main()
    {
        // Swallow Ctrl+C (return TRUE = handled), but let Ctrl+Break fall through
        // to the default handler, which terminates the process.
        _keepAlive = new HandlerRoutine(t => t == CTRL_C_EVENT);
        SetConsoleCtrlHandler(_keepAlive, true);

        Console.Out.WriteLine("CTRLC_IMMUNE_READY pid=" + System.Diagnostics.Process.GetCurrentProcess().Id);
        Console.Out.Flush();

        int n = 0;
        while (true)
        {
            System.Threading.Thread.Sleep(200);
            n++;
            if (n % 25 == 0)
            {
                Console.Out.WriteLine("STILL_ALIVE " + n);
                Console.Out.Flush();
            }
        }
    }
}
