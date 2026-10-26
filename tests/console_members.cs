// Lists the processes attached to another process's console.
//
// Usage: console_members.exe <pid> <outfile>
//
// Frees its own console, attaches to the console of <pid>, and writes the
// GetConsoleProcessList result (space separated pids) to <outfile>, or
// "ATTACH_FAIL <err>" when the attach is refused.  The result goes to a file
// because once this process has left its own console it has no stdout.
//
// Issue #761 uses it to see whether the psmux server has joined the console of
// the client that spawned it.
using System;
using System.IO;
using System.Runtime.InteropServices;

class ConsoleMembers {
    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll")] static extern uint GetConsoleProcessList(uint[] list, uint n);

    static int Main(string[] args) {
        if (args.Length < 2) return 2;
        uint pid = uint.Parse(args[0]);
        string result;
        FreeConsole();
        if (!AttachConsole(pid)) {
            result = "ATTACH_FAIL " + Marshal.GetLastWin32Error();
        } else {
            uint[] list = new uint[256];
            uint n = GetConsoleProcessList(list, 256);
            FreeConsole();
            var parts = new string[n];
            for (int i = 0; i < n; i++) parts[i] = list[i].ToString();
            result = string.Join(" ", parts);
        }
        File.WriteAllText(args[1], result);
        return 0;
    }
}
