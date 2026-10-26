// timerres_probe.exe
// How long does a "1 millisecond" sleep actually take on this box, before and
// after asking for a 1ms timer period? Every sleep-based wait in a program that
// has not raised the timer resolution rounds up to the system tick, which on
// Windows defaults to 15.6ms.
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

class TimerRes
{
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
    [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint ms);
    [DllImport("ntdll.dll")]
    static extern int NtQueryTimerResolution(out uint max, out uint min, out uint cur);

    static double MeasureSleep(int ms, int iters)
    {
        var sw = Stopwatch.StartNew();
        for (int i = 0; i < iters; i++) Thread.Sleep(ms);
        return sw.Elapsed.TotalMilliseconds / iters;
    }

    static void Main()
    {
        uint mx, mn, cur;
        NtQueryTimerResolution(out mx, out mn, out cur);
        Console.WriteLine("timer resolution current={0:F4} ms (min={1:F4} max={2:F4})",
            cur / 10000.0, mn / 10000.0, mx / 10000.0);
        Console.WriteLine("Sleep(1) actual = {0:F3} ms   [default]", MeasureSleep(1, 60));
        Console.WriteLine("Sleep(0) actual = {0:F3} ms", MeasureSleep(0, 2000));
        timeBeginPeriod(1);
        NtQueryTimerResolution(out mx, out mn, out cur);
        Console.WriteLine("after timeBeginPeriod(1): resolution={0:F4} ms", cur / 10000.0);
        Console.WriteLine("Sleep(1) actual = {0:F3} ms   [1ms period]", MeasureSleep(1, 200));
        timeEndPeriod(1);
    }
}
