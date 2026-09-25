# How attach works

attach is a single bash script. It combines three tools: reptyr moves the
program, abduco keeps it in a detachable session, and fzf provides the picker.
This document covers the parts that aren't obvious.

## The two lists

**Terminal mode** looks at every `pts/*` terminal owned by you. It finds each
terminal's session leader (usually a shell) and whatever is in the
foreground. The row shows the foreground program's name, its working
directory, the terminal and its age. The full command line goes in a hidden
field that the preview pane shows, wrapped. Real consoles (`tty1`…) are never
listed: stealing the one your desktop runs on would take the desktop down.

**Process mode** lists every process of yours that has a terminal.

Both lists leave out your own terminal and anything already captured (see
below). They add one `*` row per abduco session, sorted next to the originals
with the same program name.

## Stealing

In terminal mode attach runs `reptyr -T <session leader>`. Here reptyr doesn't
move the program. It takes the **controller side of the terminal**, the end
the emulator window reads from and writes to, out of the emulator process. The
shell and everything under it stay on the same `pts/N` and never notice.

In process mode it runs `reptyr <pid>`, which moves that one process onto a new
terminal. reptyr refuses when other processes share its process group.

Either way, reptyr runs inside a new abduco session:

```
abduco -e ^d -c vim0  env ATTACH_SESSION=vim0 … bash -c 'reptyr -T PID || …'
```

The small bash wrapper keeps the session open if reptyr fails, so its error
stays on screen instead of disappearing with the session.

reptyr runs as you, not under sudo. As root it would create the new terminal
owned by root, and your program couldn't open it (`Permission denied`). That's
why it needs ptrace permission some other way (see the README).

## Closing the frozen window

After `reptyr -T`, the emulator still has its window but nothing behind it any
more, so the window freezes. attach closes it:

1. Before stealing, it looks up the emulator: the session leader's parent. It
   reads `/proc/<emulator>/fdinfo/*` and records which terminals the emulator
   controls (each controller file descriptor reports a `tty-index`).
2. If the emulator controls exactly this one terminal, a background job waits
   until reptyr has taken it, i.e. until that `tty-index` disappears from the
   emulator's fdinfo. Then it kills the emulator with SIGKILL.

SIGKILL is deliberate. A normal close lets the emulator run its cleanup, and
Alacritty, foot and others send SIGHUP to their child when they close. Here
that child is the program you just stole. SIGKILL skips that cleanup; the
program is adopted by init and carries on.

When the emulator controls other terminals too (Ghostty, WezTerm and kitty run
every window in one process), attach leaves it alone and says so. If reptyr
fails, the `tty-index` never disappears and the job gives up after 20 seconds
without killing anything.

## Knowing what's captured

A terminal counts as captured when either of these is true:

- **abduco controls it.** That's a session's inner terminal, where the reptyr
  wrapper runs. It's found through abduco's fdinfo, as above.
- **It's a reptyr target's terminal.** After `reptyr -T PID`, PID is still on its
  old `pts/N`. reptyr's own fdinfo is unreadable when it runs with file
  capabilities (the process is marked non-dumpable), so attach reads reptyr's
  command line, which is always readable, takes the PID, and looks up its
  terminal.

Captured terminals are left out of the lists, and so are windows whose
foreground program is an `abduco` client. That's why nothing ever nests.

**Which session a terminal belongs to** is traced from the other end: for each
reptyr process, the grandparent is the abduco server whose command line holds
`-c NAME`. The same lookup tells `attach` when it's running *inside* a stolen
program. `ATTACH_SESSION` is set only in the session's wrapper; the stolen
program keeps its original environment. So attach also compares its own
terminal against every session's stolen terminal. That stops a session from
attaching to itself.

## Session rows

`abduco` with no arguments lists sessions, each prefixed by a state character:
`*` means a client is attached, blank means detached, `+` means the program
exited. For each session, attach finds the stolen program as above, then the
foreground process on its terminal, and fills in the same columns as a normal
row. The session name goes in the TTY column and in a sixth, hidden field.

- **Enter** on a row with that field set joins the session:
  `abduco -e ^d -a NAME`. abduco serves any number of clients at once, and the
  others stay connected.
- **Ctrl-X** runs `attach --kill {6}` and then reloads the list from
  `attach --rows`. On rows without the field it does nothing.

## Forcing a repaint

A new abduco client starts on a blank screen. abduco keeps no copy of the
screen, so it can't redraw it; the program has to. Many full-screen programs
(system monitors among them) draw only what changed, and redraw everything only when
the terminal size *really* changes. A SIGWINCH at the same size does nothing,
and attaching from a window of the same size doesn't change the size.

So 0.5 seconds after a join (1.5 seconds after a steal, to give reptyr time to
connect), attach runs `stty -F /dev/pts/N rows R-1`, waits 0.3 seconds, and
restores `rows R`. Those are two real size changes, so the program repaints the
whole screen.

## Killing a session

`attach -K NAME` ends a session the way closing its terminal would. It sends
SIGHUP to every process in the stolen program's process session
(`pkill -s SID`), escalating to SIGTERM and then SIGKILL for anything still
alive after two seconds. When the program is gone, reptyr exits and the abduco
session ends with it.

The session-wide signal is used only when the stolen process leads its own
session. Otherwise (a `-p` steal that stayed in its old session), only that one
process is signalled, so the shell it came from is never hit.

Killing just the abduco server would be wrong. The program would lose its
terminal but keep running, orphaned. Some programs then spin at 100% CPU.
attach falls back to killing the server only when the program is already gone
and the session is still there.

## Session names

The name is the program's name (from `/proc/PID/comm`), made safe for use as a
file name, plus the lowest free number: `vim0`, `vim1`. If the name ends
in a digit, a dash goes before the number: `python3-0`. Override it with
`-s NAME`.
