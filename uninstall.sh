#!/bin/bash
# Remove mac-rice and put the Mac back the way install.sh found it:
# services and agents, scripting addition and sudoers entry, config symlinks (files that
# were there before come back from the backup), ~/.local/bin links, macOS settings.
# Homebrew packages and the signing certificate go only if you say so. SIP can only be
# switched back on from Recovery: the steps are printed at the end.
set -euo pipefail

RICE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RICE_ROOT
. "$RICE_ROOT/lib/common.sh"
. "$RICE_ROOT/lib/sign.sh"
. "$RICE_ROOT/lib/yabai.sh"
. "$RICE_ROOT/lib/sa.sh"
load_brew >/dev/null 2>&1 || true

un_services() {
    say "Services"
    for label in com.mac-rice.shell com.mac-rice.wallpaper "$RICE_RESUME_LABEL"; do
        launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
        rm -f "$HOME/Library/LaunchAgents/$label.plist"
    done
    for svc in skhd yabai; do
        if command -v "$svc" >/dev/null 2>&1; then
            "$svc" --stop-service >/dev/null 2>&1 || true
            "$svc" --uninstall-service >/dev/null 2>&1 || true
        fi
    done
    brew services stop sketchybar >/dev/null 2>&1 || true
    brew services stop borders >/dev/null 2>&1 || true
    ok "stopped"
}

un_sa() {
    had_sa=0
    if [ -f "$RICE_SUDOERS" ]; then
        had_sa=1
        say "Scripting addition"
        sudo yabai --uninstall-sa 2>/dev/null || true
        sudo rm -f "$RICE_SUDOERS"
        ok "removed, along with the sudoers entry"
    fi
    if [ "$(state_get yabai_source)" = fork ]; then
        rm -f "$(brew_prefix)/bin/yabai"
        ok "yabai (fork build) removed; sources kept in $(yabai_fork_dir)"
    fi
}

un_links() {
    say "Configs"
    if [ -f "$RICE_LINKS" ]; then
        while IFS= read -r dst; do
            [ -L "$dst" ] || continue
            case "$(readlink "$dst")" in "$RICE_ROOT"/*) rm -f "$dst" ;; *) continue ;; esac
            # Newest backup of this path, if install.sh moved something away
            rel="${dst#$HOME/}"
            latest="$(ls -1d "$RICE_BACKUP"/*/"$rel" 2>/dev/null | sort | tail -1 || true)"
            if [ -n "$latest" ]; then
                mv "$latest" "$dst"
                info "restored ${dst/#$HOME/~}"
            fi
        done < "$RICE_LINKS"
        rm -f "$RICE_LINKS"
    fi
    # Files theme-switch generated next to the links
    rm -f "$HOME/.config/sketchybar/colors.sh" "$HOME/.config/borders/bordersrc" \
          "$HOME/.config/kitty/theme.conf" "$HOME/.config/zed/themes/caelestia.json"
    if [ -f "$HOME/.zprofile" ]; then
        grep -v ' # mac-rice$' "$HOME/.zprofile" > "$HOME/.zprofile.tmp" || true
        mv "$HOME/.zprofile.tmp" "$HOME/.zprofile"
    fi
    ok "symlinks removed, previous files restored"
}

un_defaults() {
    say "macOS settings"
    prev="$(state_get prev_mru_spaces)"
    if [ -n "$prev" ]; then
        if [ "$prev" = default ]; then defaults delete com.apple.dock mru-spaces 2>/dev/null || true
        else defaults write com.apple.dock mru-spaces -bool "$prev"; fi
        killall Dock 2>/dev/null || true
    fi
    if [ "$(state_get prev_hide_menubar)" = 1 ]; then
        defaults write NSGlobalDomain _HIHideMenuBar -bool true
        killall SystemUIServer 2>/dev/null || true
    fi
    ok "restored space ordering and menu bar"
    info "ctrl + 1…9 space shortcuts left in place (System Settings → Keyboard → Keyboard Shortcuts)"
}

un_packages() {
    if ask "Remove the Homebrew packages installed by the rice (skhd, SketchyBar, borders, fonts, kitty…)?" n; then
        brew uninstall --ignore-dependencies skhd sketchybar borders media-control blueutil 2>/dev/null || true
        [ "$(state_get yabai_source)" = brew ] && brew uninstall yabai 2>/dev/null || true
        brew uninstall --cask kitty font-jetbrains-mono-nerd-font font-material-symbols font-rubik \
            font-google-sans-flex font-sf-pro font-sketchybar-app-font 2>/dev/null || true
        ok "packages removed (jq and Homebrew kept)"
    fi
}

un_cert() {
    local keychain
    keychain="$(sed -n 's/^keychain=//p' "$RICE_SIGNING" 2>/dev/null || true)"
    if [ -n "$keychain" ] && ask "Remove the mac-rice-cert signing certificate?" y; then
        security delete-keychain "$keychain" 2>/dev/null || true
        rm -f "$RICE_SIGNING" "$RICE_KEYCHAIN_PASS"
        ok "certificate removed"
    fi
}

un_bootarg() {
    if is_arm && nvram boot-args 2>/dev/null | grep -q -- '-arm64e_preview_abi'; then
        rest="$(nvram boot-args | cut -f2- | sed 's/-arm64e_preview_abi//; s/  */ /g; s/^ //; s/ $//')"
        if [ -n "$rest" ]; then sudo nvram boot-args="$rest"; else sudo nvram -d boot-args; fi
        ok "boot-arg -arm64e_preview_abi removed"
    fi
}

un_finish() {
    rm -f "$RICE_STATE"
    cat <<EOF

${c_green}Done.${c_off} Accessibility permissions can be revoked manually.
The rice folder is still at ${RICE_ROOT/#$HOME/~} and can simply be deleted.
EOF

    if [ "$had_sa" = 1 ] || ! csrutil status | grep -q 'status: enabled'; then
        cat <<EOF

${c_bold}SIP is currently partially disabled.${c_off} To re-enable it:
  1. Boot into Recovery (as during install: shut down, hold the power button →
     Options; on Intel, restart holding ⌘ + R).
  2. Utilities → Terminal, run: ${c_bold}csrutil enable${c_off}
  3. Restart.
EOF
    fi
}

# Sourced with RICE_UNINSTALL_LIB=1 (tests) only the functions are defined
[ "${RICE_UNINSTALL_LIB:-0}" = 1 ] && return 0

[ "${1:-}" = --yes ] && RICE_YES=1
say "Uninstalling mac-rice"
ask "Remove the rice and restore previous settings?" n || exit 0
un_services
un_sa
un_links
un_defaults
un_packages
un_cert
un_bootarg
un_finish
