// Issue #503 ground-truth stream generator.
//
// Emits N self-describing records to stdout as raw UTF-8 bytes, split into many
// small writes to imitate a token-by-token streaming TUI (the reporter used an
// Ink/React Node app streaming Thai text).
//
// Record format:  <Snnnnnn>PAYLOAD</Snnnnnn>\n
//
// Every record carries the same payload, so any byte difference between a
// captured record and the known payload is data corruption, and any missing
// sequence number is data loss. Writes deliberately land mid-UTF-8-sequence so
// that split multi-byte codepoints are exercised.
//
// Usage: streamgen.exe [records] [bytesPerWrite] [spinPerWrite] [payloadId] [holdMs]
//   payloadId: thai (default) | ascii | repaint
//
//   repaint: models what an Ink/React TUI does. Each record is first written with
//   a DECOY body, then immediately rewritten in place (CR) with the real body
//   before the terminal has rendered anything. The final displayed line is always
//   the real body; the decoy is only ever an intermediate frame. Used to show
//   that ConPTY coalesces intermediate frames, so the raw PTY byte stream is NOT
//   a transcript of the child's writes even when nothing displayed is lost.
//   holdMs:    stay alive after writing, so a ConPTY host has time to render and
//              flush the output (conhost renders on a timer, and a child that
//              exits immediately can have its output discarded entirely).
//
// Compile: csc /nologo /optimize /out:streamgen.exe streamgen.cs

using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class StreamGen
{
    [DllImport("kernel32.dll")]
    static extern bool SetConsoleOutputCP(uint wCodePageID);

    // Thai fragments taken verbatim from the words the reporter saw corrupted in
    // issue #503, kept short enough that a record fits on one line.
    const string ThaiPayload = "ปัจจุบันสิ้นเดือน";
    const string AsciiPayload = "abcdefghijklmnopqrstuvwxyz0123456789";

    // Same combining-mark positions as ThaiPayload, so it occupies exactly the
    // same display width and is fully overwritten by the real frame. The base
    // consonants are the two the reporter saw disappear.
    const string DecoyPayload =
        "ทัยยุทัยทิ้ยเทืยท";

    static void Main(string[] args)
    {
        int records = args.Length > 0 ? int.Parse(args[0]) : 200;
        int chunk = args.Length > 1 ? int.Parse(args[1]) : 7;
        int spin = args.Length > 2 ? int.Parse(args[2]) : 0;
        string payloadId = args.Length > 3 ? args[3] : "thai";
        int holdMs = args.Length > 4 ? int.Parse(args[4]) : 0;

        string payload = payloadId == "ascii" ? AsciiPayload : ThaiPayload;

        // A real cross-platform TUI puts the console in UTF-8 before streaming.
        try { SetConsoleOutputCP(65001); } catch { }

        Stream stdout = Console.OpenStandardOutput();

        for (int i = 0; i < records; i++)
        {
            string tag = i.ToString("D6");
            string rec;

            if (payloadId == "repaint")
            {
                // Intermediate frame (decoy), then carriage return and the real
                // frame over the top of it, with no pause in between.
                rec = "<S" + tag + ">" + DecoyPayload + "</S" + tag + ">\r"
                    + "<S" + tag + ">" + ThaiPayload + "</S" + tag + ">\n";
            }
            else
            {
                rec = "<S" + tag + ">" + payload + "</S" + tag + ">\n";
            }

            byte[] bytes = Encoding.UTF8.GetBytes(rec);

            for (int off = 0; off < bytes.Length; off += chunk)
            {
                int n = Math.Min(chunk, bytes.Length - off);
                stdout.Write(bytes, off, n);
                stdout.Flush();
                if (spin > 0) Thread.SpinWait(spin);
            }
        }

        stdout.Flush();
        Console.Error.WriteLine("STREAMGEN_DONE " + records);
        if (holdMs > 0) Thread.Sleep(holdMs);
    }
}
