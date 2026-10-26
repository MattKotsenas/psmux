// Print RTL_USER_PROCESS_PARAMETERS.ConsoleFlags (bit 0 = "ignore Ctrl+C")
// and the ConsoleHandle for one or more pids.
//
// Windows has no API to ask "does this process ignore Ctrl+C?", but the state
// SetConsoleCtrlHandler(NULL, TRUE) sets lives in the process parameters block
// and is INHERITED by children, so it is readable from outside with
// NtQueryInformationProcess + ReadProcessMemory.
using System;
using System.Runtime.InteropServices;

class CtrlFlags {
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_BASIC_INFORMATION {
        public IntPtr Reserved1; public IntPtr PebBaseAddress;
        public IntPtr R2; public IntPtr R3;
        public IntPtr UniqueProcessId; public IntPtr R4;
    }
    [DllImport("ntdll.dll")]
    static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PROCESS_BASIC_INFORMATION pbi, int len, out int ret);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);

    const uint PROCESS_QUERY_INFORMATION = 0x0400;
    const uint PROCESS_VM_READ = 0x0010;

    static int Main(string[] args) {
        foreach (string a in args) {
            int pid;
            if (!int.TryParse(a, out pid)) continue;
            IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
            if (h == IntPtr.Zero) { Console.WriteLine(pid + " OPEN_FAILED err=" + Marshal.GetLastWin32Error()); continue; }
            try {
                var pbi = new PROCESS_BASIC_INFORMATION(); int ret;
                int st = NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(pbi), out ret);
                if (st != 0) { Console.WriteLine(pid + " NTQUERY_FAILED 0x" + st.ToString("X8")); continue; }
                byte[] p = new byte[8]; IntPtr got;
                if (!ReadProcessMemory(h, (IntPtr)((long)pbi.PebBaseAddress + 0x20), p, (IntPtr)8, out got)) {
                    Console.WriteLine(pid + " READ_PARAMS_FAILED err=" + Marshal.GetLastWin32Error()); continue;
                }
                long pp = BitConverter.ToInt64(p, 0);
                byte[] blk = new byte[0x28];
                if (!ReadProcessMemory(h, (IntPtr)pp, blk, (IntPtr)blk.Length, out got)) {
                    Console.WriteLine(pid + " READ_BLOCK_FAILED err=" + Marshal.GetLastWin32Error()); continue;
                }
                long consoleHandle = BitConverter.ToInt64(blk, 0x10);
                uint consoleFlags = BitConverter.ToUInt32(blk, 0x18);
                Console.WriteLine(pid + " ConsoleFlags=0x" + consoleFlags.ToString("X8")
                    + " ignoreCtrlC=" + ((consoleFlags & 1) != 0)
                    + " ConsoleHandle=0x" + consoleHandle.ToString("X"));
            } finally { CloseHandle(h); }
        }
        return 0;
    }
}
