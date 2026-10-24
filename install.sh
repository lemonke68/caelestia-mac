#!/bin/bash
# mac-rice installer.
#
#   curl -fsSL https://raw.githubusercontent.com/lemonke68/caelestia-mac/main/install.sh | bash
#   ./install.sh [--yes] [--full] [--no-apps]
#
#   --yes      take the default answer to every question
#   --full     go on to full mode (scripting addition, needs Recovery) without asking
#   --no-apps  skip the optional apps (Zen, Zed, Telegram, Spotify)
#   --update   what `rice update` runs after git pull: packages, yabai, links, build, restart
#
# Safe to run again: every step checks what is already there. Re-running is also how a
# checkout is (re)linked after moving it.
set -euo pipefail

RICE_REPO_URL="${RICE_REPO_URL:-https://github.com/lemonke68/caelestia-mac}"
RICE_DEFAULT_ROOT="$HOME/.local/share/caelestia-mac"

# ---------- bootstrap: curl | bash has no checkout yet ----------

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -z "$here" ] || [ ! -f "$here/lib/common.sh" ]; then
    echo "==> mac-rice: bootstrap"
    if [ "$(id -u)" -eq 0 ]; then echo "Run without sudo." >&2; exit 1; fi
    brew_bin=/opt/homebrew/bin/brew
    [ "$(uname -m)" = arm64 ] || brew_bin=/usr/local/bin/brew
    if [ ! -x "$brew_bin" ]; then
        echo "==> Installing Homebrew (package manager). It will ask for your macOS password and Enter."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty
    fi
    eval "$("$brew_bin" shellenv)"
    if [ -d "$RICE_DEFAULT_ROOT/.git" ]; then
        git -C "$RICE_DEFAULT_ROOT" pull -q --ff-only || true
    else
        git clone -q "$RICE_REPO_URL" "$RICE_DEFAULT_ROOT"
    fi
    # Questions need the keyboard, not the pipe the script came through
    if : 2>/dev/null </dev/tty; then exec "$RICE_DEFAULT_ROOT/install.sh" "$@" </dev/tty; fi
    exec "$RICE_DEFAULT_ROOT/install.sh" "$@"
fi

RICE_ROOT="$here"
export RICE_ROOT
. "$RICE_ROOT/lib/common.sh"
. "$RICE_ROOT/lib/sign.sh"
. "$RICE_ROOT/lib/yabai.sh"
. "$RICE_ROOT/lib/sa.sh"
. "$RICE_ROOT/lib/doctor.sh"

opt_full=0 opt_apps=1 opt_update=0
for arg in "$@"; do
    case "$arg" in
        --yes) RICE_YES=1 ;;
        --update) opt_update=1 opt_apps=0 ;;
        --full) opt_full=1 ;;
        --no-apps) opt_apps=0 ;;
        *) die "unknown flag $arg (see the top of install.sh)" ;;
    esac
done
export RICE_YES="${RICE_YES:-0}"

# ---------- steps ----------

step_preflight() {
    say "Checking the system"
    [ "$(id -u)" -ne 0 ] || die "run without sudo; admin rights are requested only where needed"
    version_ge "$RICE_MIN_MACOS" "$(macos_version)" \
        || die "macOS $RICE_MIN_MACOS or later is required (found $(macos_version))"
    ok "macOS $(macos_version), $(uname -m)$(is_arm && echo ' (Apple Silicon)' || echo ' (Intel)')"

    local g
    g="$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c 'Resolution:' || true)"
    ok "displays: ${g:-1} (frame and side bar go on the main one, with the menu bar)"
    if pgrep -xq AeroSpace; then
        warn "AeroSpace is running and conflicts with yabai"
        if ask "Quit AeroSpace?" y; then osascript -e 'quit app "AeroSpace"' || true; fi
    fi
    curl -fsI --max-time 10 https://github.com >/dev/null || die "cannot reach github.com"
}

step_homebrew() {
    say "Homebrew"
    if ! load_brew; then
        info "installing Homebrew; it will ask for your macOS password and Enter"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty
        load_brew || die "Homebrew installation failed"
    fi
    zprofile_add "eval \"\$($(brew_prefix)/bin/brew shellenv)\""
    xcode-select -p >/dev/null 2>&1 || die "Command Line Tools missing: run xcode-select --install and try again"
    ok "Homebrew $(brew --version | head -1 | cut -d' ' -f2)"
}

step_packages() {
    say "Packages and fonts"
    # Install only; upgrading what is already there is for `rice update`
    local no_upgrade=1
    [ "$opt_update" = 1 ] && no_upgrade=""
    if ! HOMEBREW_BUNDLE_NO_UPGRADE="$no_upgrade" brew bundle --file "$RICE_ROOT/Brewfile"; then
        warn "some packages failed to install (e.g. the app is already installed outside Homebrew); continuing"
    fi

    [ "$opt_apps" = 1 ] || return 0
    # name:cask — apps the hotkeys open
    local entry app cask missing=""
    for entry in Zen:zen Zed:zed Telegram:telegram Spotify:spotify; do
        app="${entry%%:*}" cask="${entry#*:}"
        [ -d "/Applications/$app.app" ] || [ -d "$HOME/Applications/$app.app" ] || missing="$missing $cask"
    done
    [ -n "$missing" ] || return 0
    info "hotkeys open Zen (alt+W), Zed (alt+T), Telegram (alt+D), Spotify (alt+ctrl+M)"
    if ask "Install the missing ones:$missing?" n; then
        # shellcheck disable=SC2086
        brew install --cask $missing || warn "not all apps were installed"
    fi
}

step_signing() {
    say "Signing certificate"
    if [ -n "$(rice_sign_identity)" ]; then
        ok "found: $(rice_sign_identity)"
        return
    fi
    # Own keychain with a random password kept next to the state: codesign can use the key
    # without a dialog, and nothing is added to the login keychain.
    local kc="$HOME/Library/Keychains/mac-rice.keychain-db" tmp pass
    tmp="$(mktemp -d)"
    pass="$(openssl rand -hex 24)"
    mkdir -p "$RICE_STATE_DIR"
    (umask 077; printf '%s' "$pass" > "$RICE_KEYCHAIN_PASS")
    security delete-keychain "$kc" 2>/dev/null || true
    # create-keychain adds it to the search list; put the list back (codesign gets --keychain)
    local search
    search="$(security list-keychains -d user | tr -d '"' | xargs)"
    security create-keychain -p "$pass" "$kc"
    # shellcheck disable=SC2086
    security list-keychains -d user -s $search
    security set-keychain-settings "$kc"   # never auto-lock
    cat > "$tmp/cert.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=mac-rice-cert
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$tmp/cert.cnf" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name mac-rice-cert \
        -out "$tmp/cert.p12" -passout pass:mac-rice 2>/dev/null
    security import "$tmp/cert.p12" -k "$kc" -P mac-rice -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" "$kc" >/dev/null
    rm -rf "$tmp"
    printf 'identity=mac-rice-cert\nkeychain=%s\n' "$kc" > "$RICE_SIGNING"
    ok "created mac-rice-cert (separate keychain, login keychain untouched)"
}

step_yabai() {
    say "yabai (window tiling)"
    if [ "$opt_update" = 1 ]; then yabai_update; ok "yabai $(yabai --version)"; else yabai_install; fi
}

step_link() {
    say "Configs"
    local f
    while IFS= read -r f; do
        link "$RICE_ROOT/config/$f" "$HOME/.config/$f"
    done < <(cd "$RICE_ROOT/config" && find . -type f ! -name '*.example.*' ! -name '.DS_Store' | sed 's|^\./||' | sort)
    mkdir -p "$HOME/.config/mac-rice"
    if [ ! -f "$HOME/.config/mac-rice/shell.json" ]; then
        cp "$RICE_ROOT/config/mac-rice/shell.example.json" "$HOME/.config/mac-rice/shell.json"
    fi
    mkdir -p "$HOME/.config/borders" "$HOME/.config/zed/themes"
    link "$RICE_ROOT/assets" "$HOME/.config/assets"

    for f in rice rice-shell rice-picker rice-wallpaper theme-switch wallpaper-next; do
        link "$RICE_ROOT/bin/$f" "$RICE_BIN/$f"
    done
    zprofile_add 'export PATH="$HOME/.local/bin:$PATH"'
    ok "~/.config → ${RICE_ROOT/#$HOME/~}/config (old files in ${RICE_BACKUP/#$HOME/~})"
}

step_defaults() {
    say "macOS settings"
    # Spaces keep their order (Hyprland workspaces don't shuffle)
    if [ "$(defaults read com.apple.dock mru-spaces 2>/dev/null)" != 0 ]; then
        state_set prev_mru_spaces "$(defaults read com.apple.dock mru-spaces 2>/dev/null || echo default)"
        defaults write com.apple.dock mru-spaces -bool false
        killall Dock 2>/dev/null || true
    fi
    ok "spaces are not rearranged automatically"

    # The bar sits on top of the menu bar, which must stay put
    if [ "$(defaults read NSGlobalDomain _HIHideMenuBar 2>/dev/null)" = 1 ]; then
        state_set prev_hide_menubar 1
        defaults write NSGlobalDomain _HIHideMenuBar -bool false
        killall SystemUIServer 2>/dev/null || true
    fi
    ok "menu bar stays visible"

    # Full mode set up earlier (by hand or another checkout) counts too
    if [ -f "$RICE_SUDOERS" ] && sa_sip_ok; then state_set sa on; fi

    # Basic mode switches desktops with ctrl + 1…9 (symbolic hotkeys 118…126)
    if [ "$(state_get sa)" != on ] && [ "$(state_get desktop_keys)" != on ]; then
        local i key ascii
        for i in 1 2 3 4 5 6 7 8 9; do
            key=$(echo "18 19 20 21 23 22 26 28 25" | cut -d' ' -f$i)
            ascii=$((48 + i))
            defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add $((117 + i)) \
                "<dict><key>enabled</key><true/><key>value</key><dict><key>parameters</key><array><integer>$ascii</integer><integer>$key</integer><integer>262144</integer></array><key>type</key><string>standard</string></dict></dict>"
        done
        /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u 2>/dev/null || true
        state_set desktop_keys on
    fi
    [ "$(state_get desktop_keys)" = on ] && ok "ctrl + 1…9 switches spaces (basic mode fallback)"
    return 0
}

step_build() {
    say "Building rice-shell and wallpapers (a couple of minutes)"
    local log="$RICE_STATE_DIR/build.log"
    mkdir -p "$RICE_STATE_DIR"
    "$RICE_ROOT/native/build.sh" >"$log" 2>&1 || die "wallpaper build failed, log: ${log/#$HOME/~}"
    ok "rice-wallpaper, rice-picker"
    "$RICE_ROOT/shell/build.sh" >>"$log" 2>&1 || die "rice-shell build failed, log: ${log/#$HOME/~}"
    ok "RiceShell.app"
}

step_services() {
    say "Starting services"
    service_start yabai
    service_start skhd
    brew services restart sketchybar >/dev/null 2>&1 || brew services start sketchybar >/dev/null
    brew services restart borders >/dev/null 2>&1 || brew services start borders >/dev/null
    local theme
    theme="$(cat "$RICE_STATE_DIR/theme" 2>/dev/null || echo hyprlain)"
    "$RICE_ROOT/bin/theme-switch" "$theme" >/dev/null
    ok "yabai, skhd, SketchyBar, borders; theme $theme"
}

step_permissions() {
    say "macOS permissions"
    cat <<EOF
macOS does not let scripts grant permissions, so this is a one-time manual step.
The mac-rice Setup window opens next: each row has a button that opens the
relevant System Settings pane. Enable the toggle for the program there.

  • yabai, skhd, rice-shell: Accessibility (required for window management,
    hotkeys and media keys)
  • rice-shell: Location Services (weather, Wi-Fi names) and Bluetooth; macOS asks itself

In basic mode, spaces are created manually: F3 (Mission Control) → "+" in the
top-right corner; create about five. Switch with alt + 1…9.

To reopen the window later: ${c_bold}rice setup${c_off}
EOF
    sleep 2   # the agent was just restarted
    "$RICE_BIN/rice-shell" setup
    pause "Press Enter once all rows are green… "
    rice_doctor
}

step_full_mode() {
    if [ "$(state_get sa)" = on ]; then return; fi
    say "Full mode (optional)"
    if [ "$opt_full" = 1 ]; then
        sa_run --resume   # --resume skips the question, not the steps
    else
        sa_run
    fi
}

step_done() {
    state_set installed "$(date +%Y-%m-%d)"
    state_set root "$RICE_ROOT"
    cat <<EOF

${c_green}Done.${c_off} Essentials:
  alt + Enter      terminal            alt + Space   launcher
  alt + 1…0        spaces              alt + O       dashboard (or hover the notch)
  alt + Q          close window        alt + I       wallpapers
  alt + H/J/K/L    focus               ctrl+alt+Del  shut down / sleep
All keybindings: ${RICE_ROOT/#$HOME/~}/docs/REFERENCE.md

  rice doctor      show what works and what doesn't
  rice update      update
  rice theme       themes (rice theme list)
  rice uninstall   remove and restore the previous state
Open a new terminal window to make the rice command available.
EOF
}

if [ "$opt_update" = 1 ]; then
    load_brew || die "Homebrew not found; run install.sh without --update"
    step_packages
    step_yabai
    step_link
    step_build
    step_services
    rice_doctor
    exit 0
fi

step_preflight
step_homebrew
step_packages
step_signing
step_yabai
step_link
step_defaults
step_build
step_services
step_permissions
step_full_mode
step_done
