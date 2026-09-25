# Why attach doesn't support macOS

attach runs on Linux only, and a macOS port isn't planned. Its main job is
taking a program that's **already running** in another terminal and moving it
into yours. On macOS, the operating system doesn't let one process do that to
another. This page explains why, and what to use on a Mac instead.

## What stealing takes

attach relies on [reptyr](https://github.com/nelhage/reptyr), which takes over
a running program like this:

1. It attaches to the program (or, in terminal mode, to the terminal emulator)
   with `ptrace`.
2. It makes the attached process run system calls it didn't intend to: open a
   new terminal, move its standard input and output onto it with `dup2`, and
   switch to a new session. In terminal mode, it also pulls the emulator's end
   of the terminal out of the emulator and into reptyr, by passing the file
   descriptor over a socket.
3. It detaches, and the program carries on as if nothing happened, now on the
   new terminal.

Step 2 needs full control of another process: reading and writing its
registers and memory, and making it run code.

## Why macOS rules it out

**`ptrace` on macOS can't do it.** The macOS `ptrace` supports little beyond
attaching, continuing, single-stepping, detaching and `PT_DENY_ATTACH`. It has
no requests for reading or writing another process's registers or memory,
which is what step 2 depends on. Debuggers do that through the Mach APIs
instead (`task_for_pid`, `thread_get_state`, `mach_vm_write`).

**The Mach route is locked down.** `task_for_pid` needs root or a code-signing
entitlement for debuggers. Even then, System Integrity Protection refuses it
for Apple's own binaries and for apps built with the hardened runtime (unless
they opt in to being debugged). Most of the programs you'd want to steal fall
into those groups:

- the shell itself (`/bin/zsh`, `/bin/bash`), which are Apple binaries
  protected by SIP;
- Terminal.app, and most third-party terminals, which ship with the hardened
  runtime;
- Homebrew and other signed tools built with the hardened runtime.

So even as root, the process at the heart of the problem, the shell running in
another window, can't be taken over without turning SIP off. No reptyr port
exists for these reasons.

**The rest of attach is Linux-specific too.** It finds captured terminals and
the emulator behind a window through `/proc` (including the `tty-index`
field in `/proc/PID/fdinfo`), forces repaints with GNU `stty -F`, reads the
Yama `ptrace_scope` setting, and relies on Linux `ps` and `pgrep` options.
These could be rewritten with `libproc` and BSD tools, but without step 2
there's nothing for them to support. On top of that, Terminal.app and iTerm2
run every window in one process, so a stolen terminal's frozen window could
never be closed without closing all the others.

## What to use on a Mac

Everything apart from stealing does work on macOS: named, detachable sessions
with one program each. The only difference is that the program has to **start**
inside the session:

```sh
brew install abduco
abduco -c build make        # start a program in a session named "build"
# detach with Ctrl-\, then from any terminal, including over SSH:
abduco -a build
```

`dtach`, `tmux` and `screen` do the same. Get into the habit of starting
long-running programs this way, and there's nothing to steal later.
