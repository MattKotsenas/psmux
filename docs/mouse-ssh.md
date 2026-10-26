# Mouse Over SSH

psmux has first-class mouse support over a normal SSH pseudo-terminal when the
server runs Windows 11 build 22523 or newer. On Windows 10 and earlier Windows
11 builds, use the included client wrapper to bypass ConPTY.

## Compatibility

| Client → Server | Keyboard | Mouse | Command |
|---|:---:|:---:|---|
| Any OS → Windows 11 build 22523+ | ✅ | ✅ | Normal `ssh` |
| macOS/Linux → Windows 10 | ✅ | ✅ | `scripts/psmux-ssh.sh` |
| Any OS → Windows 10 with a normal SSH PTY | ✅ | ❌ | ConPTY consumes mouse VT bytes |
| Any OS → Windows Server 2019/2022 | ✅ | ⚠️ | Gated off by default, see below |
| Local Windows 10/11 | ✅ | ✅ | Run psmux normally |

## Builds below 22523

Below build 22523 psmux does not enable mouse reporting on the VT input path at
all (SSH, JediTerm, WezTerm; a local Windows Terminal session is covered
separately below). That is
deliberate: on Windows 10 era console hosts an incoming mouse report could fast
fail conhost and take the pane process with it, and a dead mouse beats a dead
session.

The threshold is drawn conservatively. The crash was only ever measured on
Windows 10 build 19045, while some later console hosts under the threshold,
Windows Server 2022 (build 20348) among them, handle mouse fine and only need
psmux to write the enable sequence itself. On such a host set:

```powershell
$env:PSMUX_FORCE_MOUSE = "1"
```

before attaching, and the mouse comes back. Set it in your profile to make it
stick. If a click kills your session, unset it: your console host is one of the
ones the gate exists for.

This also covers local WezTerm and JetBrains terminals on a sub 22523 build,
which take the same VT input path as SSH.

### The gate does not apply to a local Windows Terminal session

The gate covers the VT input path: SSH, JediTerm and WezTerm, where an incoming
SGR report is fed to conhost as VT bytes on the ConPTY input pipe. That is the
path the crash was measured on.

A local Windows Terminal session never uses that path, and it does not register
mouse by writing escape sequences either. Under ConPTY a client's own mouse
DECSET bytes never reach the terminal at all: conhost absorbs
`ESC [ ? 1000 h`, `1002h`, `1003h` and `1006h` written to stdout, by a raw
`WriteFile` on the console handle exactly as much as by `WriteConsoleW`. What
conhost does relay is the Win32 console flag: setting `ENABLE_MOUSE_INPUT` on
the client's input handle makes it emit `ESC [ ? 1003 ; 1006 h` to the terminal,
and clearing the flag emits `ESC [ ? 1003 ; 1006 l`. That console flag is the
only mouse registration channel a local client has, and psmux sets it at startup
on every build.

Windows Terminal sometimes drops a long lived local client's registration on its
own, so the client re-asserts the flag every 30 seconds and on every resize.
That re-assert runs on every build, including builds below 22523: it is a
console mode call, it feeds nothing to the VT input parser, and it only restores
a registration the same session already had. Before psmux 3.3.9 it sat behind
the build gate, so on Windows 10 a dropped registration was permanent. The
terminal, having been told `ESC [ ? 1003 ; 1006 l`, then fell back to
alternate scroll and turned every wheel notch into Up and Down arrow keys, which
psmux forwarded into the pane. Applications that read the wheel themselves, such
as Claude Code, reported that the scroll wheel was sending arrow keys
(issue #597).

`PSMUX_FORCE_MOUSE=0` still pins mouse off completely, on any build, including
this re-assert.

### What reaches the program inside the pane below 22523

The build gate above is about the client to terminal direction. There is a
second, independent limitation in the opposite direction, from psmux into the
pane's child, and it is a property of the pane's conhost rather than of the
terminal you attach from. Below build 22523 conhost does not hand an SGR mouse
report written into a pane's ConPTY input pipe to the child, so a program that
reads the mouse as VT bytes on stdin (node based TUIs such as Claude Code,
anything reading raw stdin) never sees it. There is no psmux level fix for
that half; the bytes are lost inside conhost.

Programs that read console `INPUT_RECORD`s do get the mouse on those builds,
because psmux also injects a Win32 `MOUSE_EVENT` record straight into the
pane's console input buffer with `WriteConsoleInputW`, which skips the VT
parser. That covers crossterm and ratatui apps, Bubble Tea and other Go TUIs,
PSReadLine and native Windows TUIs. Since psmux 3.3.9 the record carries
clicks, releases, drags and motion on those builds and not only the wheel
([#597](https://github.com/psmux/psmux/issues/597)). On 22523 and above the
wheel keeps its record and everything else travels on the pipe alone, so
nothing changes there.

Both channels obey the same audience rule, on every build: a report is only
delivered to a pane whose application asked for the mouse, by sending a mouse
DECSET or by holding `ENABLE_MOUSE_INPUT` on its console. A full screen program
that never asked (htop with the mouse off, codex) receives nothing, because it
would read the report as literal keystrokes
([#598](https://github.com/psmux/psmux/issues/598)). psmux keeps that
authorization on the pane for as long as the process that earned it is alive,
so a `node` child putting its console into raw mode (which overwrites the
console mode word and drops `ENABLE_MOUSE_INPUT` for good) can no longer
silence the wheel for the rest of the pane's life
([#613](https://github.com/psmux/psmux/issues/613)). For a program that
registers through neither channel, `set-option -p -t %N @mouse-force on`
exempts that one pane, and `PSMUX_FORCE_WHEEL=1` is the server wide last
resort. Both are described in [configuration.md](configuration.md).

Inside a VT bridge such as `wsl.exe` or `ssh.exe` the report is written as a
Win32 record as well, and psmux no longer toggles the console's quick edit
mode around that write, which conhost used to echo back into the pane as a
DECSET/DECRST pair that cancelled the mouse mode the program had asked for.
Clicks in `nvim` inside WSL work again as a result
([#604](https://github.com/psmux/psmux/issues/604)).

## Windows 10 client wrapper

Copy `scripts/psmux-ssh.sh` to the macOS or Linux client, then run:

```sh
sh psmux-ssh.sh --session work -- user@windows-host

# A named psmux socket/namespace:
sh psmux-ssh.sh --socket project --session work -- user@windows-host

# SSH options are passed through after `--`:
sh psmux-ssh.sh --session work -- -p 2222 user@windows-host
```

For a persistent one-command client, copy both scripts to the client and run
the installer once:

```sh
sh install-psmux-win.sh --host user@windows-host \
  --psmux C:/Users/user/.cargo/bin/psmux.exe

psmux-win -s work
psmux-win -L project -s work
```

The installer writes only `~/.local/bin/psmux-win` and
`${XDG_CONFIG_HOME:-~/.config}/psmux-win/config`. Existing copies are backed
up with a timestamp before replacement. It does not edit SSH configuration.

The remote `psmux` executable must be on `PATH`. The wrapper:

1. saves the local terminal state and switches it to raw mode;
2. enables xterm button/drag reporting and SGR coordinates locally;
3. runs `ssh -T`, which gives psmux direct stdin/stdout pipes instead of a
   Windows pseudoconsole;
4. attaches to the requested session; and
5. disables mouse reporting and restores the exact saved terminal state after
   normal exit, failure, disconnect, `HUP`, `INT`, or `TERM`.

Do not add `-t` or `-tt`. Allocating a remote PTY puts ConPTY back in the byte
path and recreates the Windows 10 limitation.

To test a not-yet-installed build, select its remote executable explicitly:

```sh
sh psmux-ssh.sh --session work \
  --psmux C:/path/to/psmux.exe -- user@windows-host
```

## Byte-level cause

With a normal interactive SSH session, Windows OpenSSH hosts the remote process
inside ConPTY. On Windows 10, ConPTY consumes output DEC private-mode sequences
such as `ESC[?1000h`, `ESC[?1002h`, and `ESC[?1006h`; the SSH client therefore
never tells its terminal to report the wheel. Even if those modes are enabled
separately on the client, Windows 10 ConPTY also consumes the inbound SGR wheel
report (for example `ESC[<64;10;5M`) before psmux can parse it.

There is no SSH terminal-mode negotiation flag for xterm mouse reporting, and a
server process inside ConPTY cannot access sshd's pseudoconsole pipes. `ssh -T`
is the supported OpenSSH mechanism that omits the remote PTY. In this mode the
existing psmux VT pipe reader receives keyboard and SGR mouse bytes directly,
and psmux queries terminal size with XTWINOPS (`ESC[18t`).

The build gate for normal SSH PTYs remains in place: forcing mouse registration
through old ConPTY versions is not a safe server-only workaround (issue #457).
