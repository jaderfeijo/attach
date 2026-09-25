# attach

Grab a program that's running in another terminal on your Linux machine, pull it
into the terminal you're using now (over SSH, for example), and keep it in a
named session that you can detach from and come back to.

```
  PROCESS          DIRECTORY                      TTY          UPTIME
  bash             ~                              pts/1        10:00
* htop             ~                              htop0        45:00
  make             ~/src/example                  pts/2        20:00
  vim              ~/src/example                  pts/3        01:00:00
  vim              ~/notes                        pts/4        05:00
────────────────────────────────────────────────────────────────────────
* captured: detached, or attached in another window · enter joins · ctrl-x kills
```

Say you left an editor, a system monitor or a long build running in a terminal
on your desktop, and you're now on your laptop. SSH in, run `attach`, pick it, and it's
in front of you. The window it came from closes. Detach with **Ctrl-D** and it
keeps running. Run `attach` again from anywhere and it's listed with a `*`.
Pick it to rejoin.

It combines three tools:

- [reptyr](https://github.com/nelhage/reptyr) moves the running program onto
  your current terminal.
- [abduco](https://github.com/martanne/abduco) keeps it in a named session
  that you can detach from. Each session holds exactly one program: no windows,
  panes or status bar. Several terminals can be attached to the same session at
  once.
- [fzf](https://github.com/junegunn/fzf) provides the picker.

> **Linux only.** macOS is not supported and won't be: it doesn't let one
> process take over another like this. [docs/macos.md](docs/macos.md) explains
> why, and what to use on a Mac instead.

## Install

### Arch Linux (AUR)

```sh
yay -S attach        # or paru -S attach, or any AUR helper
```

The package installs `attach` to `/usr/bin` and pulls in reptyr, abduco and
fzf. It doesn't change any system setting. After installing, it tells you how
to set up [ptrace permission](#ptrace-permission), and it ships both
options as opt-in files in `/usr/share/attach/`.

### Any distro (install script)

```sh
curl -fsSL https://raw.githubusercontent.com/jaderfeijo/attach/main/install.sh | bash
```

The installer:

1. installs `reptyr`, `fzf` and `abduco` if they're missing (pacman, apt, dnf
   or zypper, after asking);
2. puts `attach` in `~/.local/bin`;
3. asks how reptyr should be allowed to ptrace your programs (see
   [ptrace permission](#ptrace-permission)).

To answer everything up front, for example on a machine you set up with a
script:

```sh
curl -fsSL https://raw.githubusercontent.com/jaderfeijo/attach/main/install.sh \
  | ATTACH_DEPS=yes ATTACH_PTRACE=scope bash
```

| Variable        | Values               | Default        |
|-----------------|----------------------|----------------|
| `ATTACH_PREFIX` | install to `DIR/bin` | `~/.local`     |
| `ATTACH_REF`    | branch or tag        | `main`         |
| `ATTACH_DEPS`   | `yes`, `no`          | ask            |
| `ATTACH_PTRACE` | `scope`, `cap`, `skip` | ask (`skip` without a terminal) |

**Manual install:** put [`attach`](attach) anywhere on your `PATH`, install the
three dependencies, then set up [ptrace permission](#ptrace-permission) yourself.

### Requirements

- Linux (attach reads `/proc` and uses ptrace). macOS is
  [not supported](docs/macos.md).
- bash 4.4+, procps (`ps`, `pgrep`), coreutils
- reptyr, abduco, fzf (0.63+ shows the legend as a footer; older versions show
  it in the header)

## Usage

```
attach               pick a terminal, steal the whole thing
attach -p            pick a single process instead
attach -l            print the list and exit
attach -s NAME       name the new session yourself
attach -k            keep the original window open (frozen) after a steal
attach --no-session  steal into this terminal with no session around it
attach -r NAME       join session NAME without the picker
attach -K NAME       kill session NAME
attach -L            list sessions
attach -V            version
```

### In the picker

| Key        | On a terminal/process row      | On a `*` session row                    |
|------------|--------------------------------|-----------------------------------------|
| Enter      | steal it into a new session    | join the session                        |
| Ctrl-X     | nothing                        | kill the session, then refresh the list |
| Esc        | quit                           | quit                                    |

The preview pane at the bottom shows the full command line (the list shows only
the program's name) and the process tree of that terminal.

### In a session

| Key / action       | Effect                                                        |
|--------------------|---------------------------------------------------------------|
| **Ctrl-D**         | detach; the program keeps running                             |
| close the window   | same as detaching                                             |
| the program exits  | the session ends                                              |

Sessions are named after the program with a number: `vim0`, `vim1`,
`htop0`… A name that already ends in a digit gets a dash, so `python3` becomes
`python3-0`.

## What happens when you steal

- **Terminal mode** (`attach`) takes over the whole terminal, including the
  shell and everything running in it. The emulator window it came from (Alacritty,
  foot, sshd for an SSH login…) would otherwise stay open and frozen, so
  attach kills that one process. It uses SIGKILL, so the emulator can't hang up
  the program on its way out. It only does this when that emulator process
  hosts no other terminals: with one process per window (Alacritty, foot) the
  window closes, while a single-process, multi-window emulator (Ghostty,
  WezTerm, kitty) stays open. Pass `-k` to always keep it.
- **Process mode** (`attach -p`) moves one process and leaves its shell behind.
  reptyr can't do this when the process has children in the same process group
  (a shell pipeline, for example); use terminal mode for those.
- **Nothing nests:** terminals that are already captured, and windows attached
  to a session, never appear as things to steal. Running `attach` inside a
  session steals into that session instead of wrapping another one around it.
- **Full repaint:** many full-screen programs (system monitors, for example)
  redraw only the parts of the screen that change. After a steal or a join, attach briefly shrinks the
  program's terminal by one row and restores it, which forces a full repaint.

[docs/how-it-works.md](docs/how-it-works.md) explains each of these in detail.

## ptrace permission

reptyr takes over a program by attaching to it with ptrace. Most distros ship
with the Yama security module at `ptrace_scope = 1`. At that setting a process
may only ptrace its own descendants, and the programs you want to grab aren't
descendants of `attach`. Running reptyr under `sudo` doesn't help either: reptyr
then creates the new terminal as root, and your program can no longer open it.

The installer offers three choices:

| Option  | What it does | Trade-off |
|---------|--------------|-----------|
| `scope` *(recommended)* | writes `kernel.yama.ptrace_scope = 0` to `/etc/sysctl.d/60-attach-ptrace.conf` | Any of your processes can ptrace any other of **your** processes, as Linux allowed before Yama. Root's processes and other users' stay out of reach. |
| `cap`   | `setcap cap_sys_ptrace+ep` on reptyr, plus a pacman hook on Arch so upgrades keep it | Only reptyr gets the ability, but it gets **all** of it: anything that can run reptyr can take over any process on the machine, root's included. |
| `skip`  | nothing | attach stops with an error until you set one of the above. |

To do it by hand:

```sh
# scope
echo 'kernel.yama.ptrace_scope = 0' | sudo tee /etc/sysctl.d/60-attach-ptrace.conf
sudo sysctl --system

# cap
sudo setcap cap_sys_ptrace+ep "$(command -v reptyr)"
```

These files are in [`contrib/`](contrib), and the AUR package installs them to
`/usr/share/attach/`:

- [`60-attach-ptrace.conf`](contrib/60-attach-ptrace.conf): the `scope` option;
  copy it to `/etc/sysctl.d/`.
- [`attach-reptyr-ptrace.hook`](contrib/attach-reptyr-ptrace.hook): with the
  `cap` option, re-applies the capability after reptyr upgrades; copy it to
  `/etc/pacman.d/hooks/`.

## Limitations

- **Ctrl-D belongs to the session.** Inside a session it detaches instead of
  reaching the program as end-of-input, so leave a shell with `exit` and quit
  anything else that expects Ctrl-D some other way. (abduco supports only single-key detach, so a
  tmux-style Ctrl-B d isn't possible.) Plain `abduco -a NAME` still uses
  abduco's default detach key, Ctrl-\\.
- **No scrollback.** abduco keeps no copy of the screen, so output a plain shell
  printed while nobody was attached is gone. Full-screen programs repaint.
- **Killing a session hangs it up:** the stolen terminal's processes get
  SIGHUP, then SIGTERM, then SIGKILL for anything still running.
- **Linux only.** Sessions and captures are found through `/proc`.

## Uninstall

Installed from the AUR: `sudo pacman -R attach`. Any of the opt-in files you
copied into `/etc` stay there until you remove them.

Installed with the script:

```sh
curl -fsSL https://raw.githubusercontent.com/jaderfeijo/attach/main/install.sh | bash -s -- --uninstall
```

This removes the script. Run from a terminal, it also offers to undo the ptrace
change the installer made. Without one, it changes no system settings and
prints the commands instead. It leaves running sessions and the three
dependencies alone.

## License

[MIT](LICENSE)
