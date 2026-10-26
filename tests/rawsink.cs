// Issue #503 raw sink: copies stdin byte-for-byte to a file.
//
// Used as the `pipe-pane -o` target so the capture path itself introduces no
// encoding, buffering or console-codepage transformation. This is the C#
// equivalent of the pwsh one-liner the reporter used, minus pwsh startup.
//
// Usage: rawsink.exe <outputPath>
// Compile: csc /nologo /optimize /out:rawsink.exe rawsink.cs

using System;
using System.IO;

static class RawSink
{
    static void Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("usage: rawsink.exe <outputPath>");
            Environment.Exit(2);
        }

        using (Stream stdin = Console.OpenStandardInput())
        using (FileStream outFile = File.Create(args[0]))
        {
            byte[] buf = new byte[65536];
            int n;
            while ((n = stdin.Read(buf, 0, buf.Length)) > 0)
            {
                outFile.Write(buf, 0, n);
                outFile.Flush();
            }
        }
    }
}
