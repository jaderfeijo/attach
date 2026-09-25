#!/usr/bin/env bash
# install.sh — install (or remove) attach
#
#   curl -fsSL https://raw.githubusercontent.com/jaderfeijo/attach/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/jaderfeijo/attach/main/install.sh | bash -s -- --uninstall
#
# Environment (all optional; unset means "ask", or the default when there is
# no terminal to ask on):
#   ATTACH_PREFIX=DIR       install to DIR/bin (default: ~/.local)
#   ATTACH_REF=REF          git branch/tag to install from (default: main)
#   ATTACH_DEPS=yes|no      install missing dependencies with the package manager
#   ATTACH_PTRACE=scope|cap|skip
#                           how to let reptyr ptrace as your user (see README)

set -euo pipefail

REPO=jaderfeijo/attach
REF=${ATTACH_REF:-main}
PREFIX=${ATTACH_PREFIX:-$HOME/.local}
BIN=$PREFIX/bin/attach
SYSCTL_FILE=/etc/sysctl.d/60-attach-ptrace.conf
PACMAN_HOOK=/etc/pacman.d/hooks/attach-reptyr-ptrace.hook

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# curl | bash has the script on stdin, so questions go through the terminal
have_tty() { [ -r /dev/tty ] && [ -w /dev/tty ] && { : </dev/tty; } 2>/dev/null; }
ask() {  # prompt default -> answer
  local a=""
  if have_tty; then
    printf '%s ' "$1" >/dev/tty
    read -r a </dev/tty || true
  fi
  printf '%s' "${a:-$2}"
}

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO=sudo

# ----------------------------------------------------------------- uninstall --
if [ "${1:-}" = "--uninstall" ]; then
  if [ -e "$BIN" ]; then rm -f "$BIN"; say "removed $BIN"; else say "$BIN is not installed"; fi
  # system settings are only undone when someone is there to confirm it
  if ! have_tty; then
    [ -e "$SYSCTL_FILE" ] && say "left $SYSCTL_FILE in place; remove it with: sudo rm $SYSCTL_FILE"
    [ -e "$PACMAN_HOOK" ] && say "left $PACMAN_HOOK in place; remove it with: sudo rm $PACMAN_HOOK"
    say "a cap_sys_ptrace on reptyr, if any, was left; drop it with: sudo setcap -r \$(command -v reptyr)"
    exit 0
  fi
  for f in "$SYSCTL_FILE" "$PACMAN_HOOK"; do
    [ -e "$f" ] || continue
    case $(ask "remove $f (created by the installer)? [Y/n]" y) in
      [nN]*) ;;
      *) $SUDO rm -f "$f"; say "removed $f" ;;
    esac
  done
  if command -v getcap >/dev/null && r=$(command -v reptyr 2>/dev/null) \
     && getcap "$r" | grep -q cap_sys_ptrace; then
    case $(ask "drop cap_sys_ptrace from $r? [Y/n]" y) in
      [nN]*) ;;
      *) $SUDO setcap -r "$r"; say "dropped the capability from $r" ;;
    esac
  fi
  [ -e "$SYSCTL_FILE" ] || say "ptrace_scope returns to the distro default at the next boot"
  say "running sessions were left alone: list them with 'abduco'"
  exit 0
fi

[ "$(uname -s)" = Linux ] || die "attach is Linux only (it relies on /proc and ptrace)"

# -------------------------------------------------------------- dependencies --
pm=""
for c in pacman apt-get dnf zypper; do command -v "$c" >/dev/null && { pm=$c; break; }; done

missing=()
for c in reptyr fzf abduco; do command -v "$c" >/dev/null || missing+=("$c"); done

if [ ${#missing[@]} -gt 0 ]; then
  say "missing: ${missing[*]}"
  deps=${ATTACH_DEPS:-}
  if [ -z "$deps" ]; then
    if [ -n "$pm" ]; then
      case $(ask "install them with $pm (needs sudo)? [Y/n]" y) in [nN]*) deps=no ;; *) deps=yes ;; esac
    else
      deps=no
    fi
  fi
  if [ "$deps" = yes ]; then
    case $pm in
      pacman)  $SUDO pacman -S --needed --noconfirm "${missing[@]}" ;;
      apt-get) $SUDO apt-get update -qq && $SUDO apt-get install -y "${missing[@]}" ;;
      dnf)     $SUDO dnf install -y "${missing[@]}" ;;
      zypper)  $SUDO zypper --non-interactive install "${missing[@]}" ;;
      *)       die "no supported package manager; install ${missing[*]} yourself and rerun" ;;
    esac
  else
    warn "attach needs ${missing[*]}; install them before using it"
  fi
fi

if command -v fzf >/dev/null && ! fzf --help 2>/dev/null | grep -q -- '--footer='; then
  say "fzf $(fzf --version | cut -d' ' -f1) has no footer; the legend will show in the header instead"
fi

# ------------------------------------------------------------------- install --
mkdir -p "$(dirname "$BIN")"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
if [ -n "$here" ] && [ -f "$here/attach" ] && [ -f "$here/install.sh" ]; then
  cp "$here/attach" "$tmp"                       # running from a clone
else
  url=https://raw.githubusercontent.com/$REPO/$REF/attach
  curl -fsSL "$url" -o "$tmp" || die "could not download $url"
fi
head -1 "$tmp" | grep -q '^#!.*bash' || die "downloaded file does not look like the attach script"
install -m 755 "$tmp" "$BIN"
say "installed $("$BIN" --version) to $BIN"

case ":$PATH:" in
  *":$(dirname "$BIN"):"*) ;;
  *) warn "$(dirname "$BIN") is not on your PATH; add it to your shell profile" ;;
esac

# -------------------------------------------------------------------- ptrace --
# reptyr must ptrace the process it steals. Under yama ptrace_scope=1 (the
# default on most distros) a user may only ptrace their own descendants.
scope=$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo 0)
reptyr_bin=$(command -v reptyr 2>/dev/null || true)
has_cap() { [ -n "$reptyr_bin" ] && command -v getcap >/dev/null && getcap "$reptyr_bin" | grep -q cap_sys_ptrace; }

if [ "$scope" = 0 ] || has_cap; then
  say "reptyr can already ptrace your processes"
elif [ "$scope" -ge 2 ]; then
  warn "yama ptrace_scope is $scope: only root may ptrace, and attach cannot work as a normal user"
else
  choice=${ATTACH_PTRACE:-}
  if [ -z "$choice" ]; then
    if have_tty; then
      cat >/dev/tty <<'EOF'

reptyr needs permission to ptrace the programs it steals. Pick one:

  1) scope  Set kernel.yama.ptrace_scope=0: your processes may ptrace your
            other processes (the pre-2010 Linux default). Recommended.
  2) cap    Give reptyr cap_sys_ptrace: narrower on paper, but anyone who can
            run reptyr can then take over ANY process, root's included.
  3) skip   Change nothing; attach tells you when it can't steal.

EOF
      case $(ask "choice [1]:" 1) in 2|cap) choice=cap ;; 3|skip) choice=skip ;; *) choice=scope ;; esac
    else
      choice=skip
    fi
  fi
  case $choice in
    scope)
      printf '# written by the attach installer: let reptyr steal your own processes\nkernel.yama.ptrace_scope = 0\n' \
        | $SUDO tee "$SYSCTL_FILE" >/dev/null
      $SUDO sysctl -q -w kernel.yama.ptrace_scope=0
      say "ptrace_scope set to 0 (persisted in $SYSCTL_FILE)"
      ;;
    cap)
      [ -n "$reptyr_bin" ] || die "reptyr is not installed"
      $SUDO setcap cap_sys_ptrace+ep "$reptyr_bin"
      say "granted cap_sys_ptrace to $reptyr_bin"
      if [ "$pm" = pacman ]; then
        $SUDO mkdir -p "$(dirname "$PACMAN_HOOK")"
        $SUDO tee "$PACMAN_HOOK" >/dev/null <<EOF
# written by the attach installer: pacman drops file capabilities on upgrade
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = reptyr

[Action]
Description = Granting cap_sys_ptrace to reptyr (attach)...
When = PostTransaction
Exec = /usr/bin/setcap cap_sys_ptrace+ep $reptyr_bin
EOF
        say "added $PACMAN_HOOK so reptyr upgrades keep the capability"
      else
        warn "package upgrades of reptyr drop the capability: rerun this installer afterwards"
      fi
      ;;
    skip) warn "ptrace left as is; stealing will fail until you pick an option (see README)" ;;
    *)    die "ATTACH_PTRACE must be scope, cap or skip" ;;
  esac
fi

say "done: run 'attach' to pick a terminal, 'attach --help' for more"
