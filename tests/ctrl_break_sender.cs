// ctrl_break_sender.cs (issue #454)
//
// Delivers a genuine console control signal (CTRL_BREAK_EVENT or CTRL_C_EVENT)
// to the console shared by a target process — exactly what a terminal emulator
// does when the user presses Ctrl+Break / Ctrl+C. This is the ONLY faithful way
// to test Ctrl+Break: Windows always delivers it as a console *signal*, never as
// a keystroke, so WriteConsoleInput / SendInput cannot reproduce it.
//
// Mechanism: FreeConsole() then AttachConsole(pid) attaches this helper to the
// target's console; GenerateConsoleCtrlEvent(evt, 0) broadcasts to every process
// on that console (now including the target). We install our own survive-all
// handler first so the broadcast can't kill the sender before it logs.
//
// Usage: ctrl_break_sender.exe <pid> [break|c]
//   break (default) -> CTRL_BREAK_EVENT
//   c               -> CTRL_C_EVENT
// Log: %TEMP%\psmux_ctrl_break_sender.log
using System;
using System.IO;
using System.Runtime.InteropServices;

class CtrlBreakSender
{
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);

    delegate bool HandlerRoutine(uint ctrlType);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

    const uint CTRL_C_EVENT = 0;
    const uint CTRL_BREAK_EVENT = 1;

    // Keep a reference so the delegate isn't garbage-collected.
    static HandlerRoutine _keepAlive;

    static int Main(string[] args)
    {
        string logFile = Path.Combine(Path.GetTempPath(), "psmux_ctrl_break_sender.log");
        if (args.Length < 1)
        {
            File.WriteAllText(logFile, "Usage: ctrl_break_sender.exe <pid> [break|c]");
            return 99;
        }
        uint pid = uint.Parse(args[0]);
        uint evt = (args.Length >= 2 && args[1] == "c") ? CTRL_C_EVENT : CTRL_BREAK_EVENT;

        var log = new System.Text.StringBuilder();
        log.AppendLine("PID=" + pid + " evt=" + (evt == CTRL_BREAK_EVENT ? "CTRL_BREAK" : "CTRL_C"));

        FreeConsole();
        if (!AttachConsole(pid))
        {
            log.AppendLine("AttachConsole FAILED err=" + Marshal.GetLastWin32Error());
            File.WriteAllText(logFile, log.ToString());
            return 2;
        }

        // Survive the broadcast we are about to send (group 0 includes us).
        _keepAlive = new HandlerRoutine(t => t == CTRL_C_EVENT || t == CTRL_BREAK_EVENT);
        SetConsoleCtrlHandler(_keepAlive, true);

        // Log BEFORE sending in case delivery is faster than expected.
        log.AppendLine("about to GenerateConsoleCtrlEvent");
        File.WriteAllText(logFile, log.ToString());

        bool ok = GenerateConsoleCtrlEvent(evt, 0);
        int err = ok ? 0 : Marshal.GetLastWin32Error();
        log.AppendLine("GenerateConsoleCtrlEvent ok=" + ok + " err=" + err);
        File.WriteAllText(logFile, log.ToString());

        System.Threading.Thread.Sleep(300);
        FreeConsole();
        return ok ? 0 : 1;
    }
}
