# Shared reader for one-shot replies on the psmux control socket.
#
# Dot source it:  . "$PSScriptRoot\tcp_reply_common.ps1"
#
# A one-shot connection (AUTH, one command, no PERSISTENT) gets its reply and
# then the server closes the connection: EOF is the end of the reply, exactly as
# a tmux client reads its server until the peer closes and never on a timer
# (tmux proc.c:82-91 hands the closed read to client_dispatch, client.c:579).
#
# Do NOT decide a reply is over because the socket went quiet for a while
# (`DataAvailable` false after a sleep): a reply can arrive in more than one TCP
# segment, and a StreamReader can hold whole lines in its own buffer while the
# socket shows nothing pending, so a quiet-socket reader can stop with part of
# the reply unread. That is how cli-hook-append once saw only the first hook.
#
# Persistent connections (PERSISTENT, CONTROL) never close by themselves; do not
# use this on them.

# Read raw bytes until the server closes the connection, bounded by TimeoutMs
# in total. Returns the bytes decoded as UTF-8 (everything that arrived, also
# when the bound is hit). Use it on the NetworkStream directly, not after a
# StreamReader has buffered past the auth line.
function Read-TcpReplyToEof {
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [int]$TimeoutMs = 5000,
        [int]$MaxBytes = 16MB
    )
    $ms = [System.IO.MemoryStream]::new()
    $buf = New-Object byte[] 65536
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    try {
        while ($ms.Length -lt $MaxBytes) {
            $left = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($left -le 0) { break }
            if ($Stream.CanTimeout) { $Stream.ReadTimeout = $left }
            $n = $Stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }   # EOF: the server closed, the reply is complete
            $ms.Write($buf, 0, $n)
        }
    } catch {
        # ReadTimeout or a reset: return what arrived
    }
    return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
}

# Read lines from a StreamReader until the server closes the connection
# (ReadLine returns null), bounded by the stream's ReadTimeout per read.
# Returns the lines as an array.
function Read-TcpReplyLines {
    param([Parameter(Mandatory)][System.IO.TextReader]$Reader)
    $lines = @()
    try {
        while ($true) {
            $line = $Reader.ReadLine()
            if ($null -eq $line) { break }
            $lines += $line
        }
    } catch {
        # ReadTimeout or a reset: return what arrived
    }
    return , $lines
}
