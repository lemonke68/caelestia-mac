# `rice doctor`: what works and what still needs the user. `--plain` prints
# id<TAB>status<TAB>text<TAB>hint lines (status ok|warn|fail|off) for rice-shell's setup window.

doctor_line() {   # id status text [hint]
    if [ "$DOCTOR_PLAIN" = 1 ]; then
        printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}"
        return
    fi
    case "$2" in
        ok)   ok "$3" ;;
        off)  info "– $3" ;;
        *)    warn "$3${4:+ — $4}" ;;
    esac
}

# A process that macOS refuses Accessibility exits at once and launchd restarts it, so
# "running for a few seconds" means it has access.
running_steady() {
    local pid etime
    pid="$(pgrep -x "$1" | head -1)"
    [ -n "$pid" ] || return 1
    etime="$(ps -o etime= -p "$pid" | tr -d ' ')"
    case "$etime" in 00:0[0-2]|0:0[0-2]) return 1 ;; esac
}

rice_doctor() {
    DOCTOR_PLAIN=0
    [ "${1:-}" = --plain ] && DOCTOR_PLAIN=1
    load_brew >/dev/null 2>&1 || true

    if command -v brew >/dev/null 2>&1; then doctor_line brew ok "Homebrew"
    else doctor_line brew fail "Homebrew not installed" "run install.sh"; fi

    if [ -n "$(rice_sign_identity)" ]; then doctor_line signing ok "signing certificate: $(rice_sign_identity)"
    else doctor_line signing warn "no signing certificate" "macOS will ask for permissions again after each rebuild"; fi

    if ! command -v yabai >/dev/null 2>&1; then
        doctor_line yabai fail "yabai not installed" "run install.sh"
    elif yabai -m query --spaces >/dev/null 2>&1; then
        doctor_line yabai ok "yabai: tiling works"
    elif tail -5 "/tmp/yabai_$USER.err.log" 2>/dev/null | grep -q 'accessibility'; then
        doctor_line yabai fail "yabai: no access" "Accessibility → enable yabai"
    else
        doctor_line yabai fail "yabai not running" "yabai --start-service"
    fi

    if ! command -v skhd >/dev/null 2>&1; then
        doctor_line skhd fail "skhd not installed" "run install.sh"
    elif running_steady skhd; then
        doctor_line skhd ok "skhd: hotkeys work"
    elif tail -5 "/tmp/skhd_$USER.err.log" 2>/dev/null | grep -q 'accessibility'; then
        doctor_line skhd fail "skhd: no access" "Accessibility → enable skhd"
    elif tail -1 "/tmp/skhd_$USER.err.log" 2>/dev/null | grep -q 'secure keyboard entry'; then
        # macOS hands the keyboard to one app only: the lock screen, or Terminal / a password
        # manager with "Secure Keyboard Entry" on. skhd retries on its own once it is released.
        local owner
        owner="$(tail -1 "/tmp/skhd_$USER.err.log" | sed -n "s/.*by ([0-9]*) '\(.*\)'.*/\1/p")"
        if [ "$owner" = loginwindow ]; then
            doctor_line skhd warn "skhd is waiting for the screen to unlock" "starts on its own"
        else
            doctor_line skhd fail "skhd: keyboard captured by $owner" "turn off Secure Keyboard Entry in it"
        fi
    else
        doctor_line skhd fail "skhd not running" "skhd --start-service"
    fi

    if pgrep -x sketchybar >/dev/null; then doctor_line sketchybar ok "SketchyBar"
    else doctor_line sketchybar fail "SketchyBar not running" "brew services start sketchybar"; fi

    if pgrep -x borders >/dev/null; then doctor_line borders ok "window borders (borders)"
    else doctor_line borders warn "borders not running" "brew services start borders"; fi

    if agent_running com.mac-rice.shell; then doctor_line shell ok "rice-shell"
    else doctor_line shell fail "rice-shell not running" "rice restart"; fi

    if agent_running com.mac-rice.wallpaper; then doctor_line wallpaper ok "wallpapers (rice-wallpaper)"
    else doctor_line wallpaper warn "rice-wallpaper not running" "rice restart"; fi

    if sa_loaded && sa_sip_ok && sa_bootarg_ok && ! sa_sudoers_ok; then
        doctor_line mode warn "yabai was updated; the sudoers entry is stale" "run rice sa (asks for password), otherwise full mode breaks after reboot"
    elif sa_loaded && sa_sip_ok && sa_bootarg_ok; then
        doctor_line mode ok "full mode (scripting addition)"
    elif [ "$(state_get sa)" = pending ]; then
        doctor_line mode warn "full mode: not finished" "rice sa"
    else
        doctor_line mode off "basic mode (full: rice sa)"
    fi
}
