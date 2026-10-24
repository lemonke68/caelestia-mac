# Shared helpers for install.sh, uninstall.sh and bin/rice. Written for macOS /bin/bash 3.2.

RICE_REPO="lemonke68/caelestia-mac"              # GitHub owner/name
RICE_STATE_DIR="$HOME/.local/state/mac-rice"
RICE_STATE="$RICE_STATE_DIR/install"        # key=value lines
RICE_LINKS="$RICE_STATE_DIR/links"          # every symlink install.sh made, for uninstall.sh
RICE_BACKUP="$RICE_STATE_DIR/backup"        # files that were there before, by date
RICE_BIN="$HOME/.local/bin"
RICE_MIN_MACOS="14.4"                       # Core Audio taps (visualiser), see shell/build.sh

if [ -t 1 ]; then
    c_blue=$'\033[1;34m' c_green=$'\033[1;32m' c_yellow=$'\033[1;33m' c_red=$'\033[1;31m'
    c_bold=$'\033[1m' c_off=$'\033[0m'
else
    c_blue='' c_green='' c_yellow='' c_red='' c_bold='' c_off=''
fi

say()  { printf '\n%s==>%s %s%s%s\n' "$c_blue" "$c_off" "$c_bold" "$*" "$c_off"; }
ok()   { printf ' %s✓%s %s\n' "$c_green" "$c_off" "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf ' %s!%s %s\n' "$c_yellow" "$c_off" "$*" >&2; }
die()  { printf ' %s✗%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

# The terminal, even when the script itself arrives on stdin (curl … | bash).
has_tty() { : 2>/dev/null </dev/tty; }
tty_read() { read -r "$@" </dev/tty; }

# ask "Question?" y|n — default answer on Enter; RICE_YES=1 takes the default without asking.
ask() {
    local hint="[y/N]" answer=""
    [ "$2" = y ] && hint="[Y/n]"
    if [ "${RICE_YES:-0}" = 1 ] || ! has_tty; then [ "$2" = y ]; return; fi
    printf '%s?%s %s %s ' "$c_yellow" "$c_off" "$1" "$hint" >/dev/tty
    tty_read answer || answer=""
    case "$answer" in
        y|Y|yes|Yes|д|Д|да|Да) return 0 ;;
        n|N|no|No|н|Н|нет|Нет) return 1 ;;
        *) [ "$2" = y ] ;;
    esac
}

pause() {
    if [ "${RICE_YES:-0}" = 1 ] || ! has_tty; then return 0; fi
    printf '%s' "${1:-Press Enter to continue… }" >/dev/tty
    tty_read _ || true
}

state_get() { sed -n "s/^$1=//p" "$RICE_STATE" 2>/dev/null | tail -1; }
state_set() {
    mkdir -p "$RICE_STATE_DIR"
    { grep -v "^$1=" "$RICE_STATE" 2>/dev/null || true; echo "$1=$2"; } > "$RICE_STATE.tmp"
    mv "$RICE_STATE.tmp" "$RICE_STATE"
}

macos_version() { sw_vers -productVersion; }
macos_major() { macos_version | cut -d. -f1; }
is_arm() { [ "$(uname -m)" = arm64 ]; }
brew_prefix() { if is_arm; then echo /opt/homebrew; else echo /usr/local; fi; }

# version_ge 14.4 14.4.1 → true when $2 >= $1
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$1" ]; }

# Homebrew on PATH for this script, also right after a fresh install.
load_brew() {
    local b
    b="$(brew_prefix)/bin/brew"
    if [ -x "$b" ]; then eval "$("$b" shellenv)"; fi
    command -v brew >/dev/null 2>&1
}

# Add a line to ~/.zprofile once, tagged so uninstall.sh can take it out again.
zprofile_add() {
    local line="$1 # mac-rice"
    touch "$HOME/.zprofile"
    grep -qF "$line" "$HOME/.zprofile" || printf '\n%s\n' "$line" >> "$HOME/.zprofile"
}

# link <source> <target>: symlink, moving whatever was at target into the backup.
link() {
    local src="$1" dst="$2"
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then return; fi
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        local backup="$RICE_BACKUP/$RICE_RUN_ID/${dst#$HOME/}"
        mkdir -p "$(dirname "$backup")"
        mv "$dst" "$backup"
        info "old ${dst/#$HOME/~} → ${backup/#$HOME/~}"
    fi
    mkdir -p "$(dirname "$dst")"
    ln -s "$src" "$dst"
    mkdir -p "$RICE_STATE_DIR"
    grep -qxF "$dst" "$RICE_LINKS" 2>/dev/null || echo "$dst" >> "$RICE_LINKS"
}

RICE_RUN_ID="$(date +%Y%m%d-%H%M%S)"

agent_running() { launchctl print "gui/$(id -u)/$1" 2>/dev/null | grep -q 'state = running'; }
