# Full mode: yabai's scripting addition. Needs SIP partly off (only from Recovery, which a
# script cannot reach), the arm64e boot-arg on Apple Silicon, and a passwordless sudoers
# entry for `yabai --load-sa`. Each step is checked, so `rice sa` can be re-run any time;
# after a restart a one-shot launchd agent reopens Terminal to carry on.

RICE_SUDOERS=/private/etc/sudoers.d/yabai
RICE_RESUME_LABEL=com.mac-rice.resume

sa_sip_ok() {
    local s
    s="$(csrutil status 2>/dev/null)"
    echo "$s" | grep -q 'status: disabled' && return 0
    echo "$s" | grep -q 'Filesystem Protections: disabled' || return 1
    echo "$s" | grep -q 'Debugging Restrictions: disabled' || return 1
    if is_arm; then echo "$s" | grep -q 'NVRAM Protections: disabled' || return 1; fi
}

sa_bootarg_ok() { ! is_arm || nvram boot-args 2>/dev/null | grep -q -- '-arm64e_preview_abi'; }
sa_loaded() { [ -S "/tmp/yabai-sa_$USER.socket" ] && [ -f "$RICE_SUDOERS" ]; }
yabai_hash() { shasum -a 256 "$(command -v yabai)" 2>/dev/null | cut -d' ' -f1; }
# The sudoers entry pins yabai's hash: after a rebuild `sudo -n yabai --load-sa` stops working
# (and the scripting addition is gone after the next restart) until it is written again.
sa_sudoers_ok() { [ -f "$RICE_SUDOERS" ] && [ "$(state_get sudoers_hash)" = "$(yabai_hash)" ]; }

sa_write_sudoers() {
    local bin hash
    bin="$(command -v yabai)" || die "yabai not found"
    hash="$(shasum -a 256 "$bin" | cut -d' ' -f1)"
    info "updating $RICE_SUDOERS (may ask for your macOS password)"
    printf '%s ALL=(root) NOPASSWD: sha256:%s %s --load-sa\n' "$(whoami)" "$hash" "$bin" \
        | sudo tee "$RICE_SUDOERS" >/dev/null
    sudo chmod 0440 "$RICE_SUDOERS"
    if ! sudo visudo -cf "$RICE_SUDOERS" >/dev/null; then
        sudo rm -f "$RICE_SUDOERS"
        die "sudoers entry failed validation and was removed"
    fi
    state_set sudoers_hash "$hash"
}

# Reopen Terminal on the next login to finish `rice sa`.
sa_resume_arm() {
    local cmd="$RICE_STATE_DIR/resume.command" plist="$HOME/Library/LaunchAgents/$RICE_RESUME_LABEL.plist"
    mkdir -p "$RICE_STATE_DIR"
    printf '#!/bin/bash\nexec "%s/bin/rice" sa --resume\n' "$RICE_ROOT" > "$cmd"
    chmod +x "$cmd"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$RICE_RESUME_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>Terminal</string>
        <string>$cmd</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST
}

sa_resume_disarm() {
    local plist="$HOME/Library/LaunchAgents/$RICE_RESUME_LABEL.plist"
    [ -f "$plist" ] || return 0
    launchctl bootout "gui/$(id -u)/$RICE_RESUME_LABEL" 2>/dev/null || true
    rm -f "$plist" "$RICE_STATE_DIR/resume.command"
}

sa_recovery_steps() {
    cat <<EOF

${c_bold}A one-time boot into Recovery is required.${c_off}
The Mac will shut down, so take a photo of these steps or open them on a phone:
https://github.com/$RICE_REPO/blob/main/docs/full-mode.md

EOF
    if is_arm; then
        cat <<EOF
  1.  menu → Shut Down. Wait for the screen to go dark.
  2. Press and hold the power button (Touch ID) until
     "Loading startup options" appears. Release it.
  3. Choose Options → Continue. If asked, select your user
     and enter the password.
  4. In the menu bar at the top: Utilities → Terminal.
  5. Enter this command and press Enter (confirm with "y" and the password):

       ${c_bold}csrutil enable --without fs --without debug --without nvram${c_off}

  6. Then this one (an error here is fine; the installer
     does it after the reboot):

       ${c_bold}nvram boot-args=-arm64e_preview_abi${c_off}

  7.  menu → Restart.
EOF
    else
        cat <<EOF
  1.  menu → Restart, then immediately hold ⌘ + R until the Apple logo.
  2. In the menu bar at the top: Utilities → Terminal.
  3. Enter this command and press Enter:

       ${c_bold}csrutil disable --with kext --with dtrace --with nvram --with basesystem${c_off}

  4.  menu → Restart.
EOF
    fi
    cat <<EOF

After you log in, Terminal opens on its own and finishes the setup.
To revert everything: ${c_bold}rice uninstall${c_off} (it also explains how to re-enable SIP).
EOF
}

sa_warning() {
    cat <<EOF

${c_bold}Full mode${c_off} enables what yabai can do with its scripting addition:
  • instant space switching and on-demand space creation (alt + 1…0)
  • moving windows between spaces (alt + shift + 1…0)
  • transparent system menu bar, window transparency, special workspaces

Cost: part of macOS's protection (SIP) is disabled. In practice:
  • the system is less protected against malware running with admin rights;
  • iPhone/iPad apps from the App Store stop launching on Apple Silicon;
  • major macOS updates may temporarily break yabai until it is patched.
Everything else works without full mode: tiling, bars, dashboard, themes, wallpapers.
EOF
}

sa_run() {
    local resume="${1:-}"
    [ "$resume" = --resume ] && sa_resume_disarm

    if sa_loaded && sa_sip_ok && sa_bootarg_ok && sa_sudoers_ok; then
        ok "full mode is already enabled"
        state_set sa on
        return 0
    fi

    if [ "$resume" != --resume ]; then
        sa_warning
        ask "Enable full mode?" n || { info "keeping basic mode; enable later with: rice sa"; return 0; }
    fi

    if ! sa_sip_ok; then
        say "Step 1 of 3: SIP (Recovery)"
        sa_recovery_steps
        sa_resume_arm
        state_set sa pending
        echo
        info "When ready, shut down the Mac following the steps above."
        return 0
    fi
    ok "SIP configured"

    if ! sa_bootarg_ok; then
        say "Step 2 of 3: boot-arg for Apple Silicon"
        local current
        current="$(nvram boot-args 2>/dev/null | cut -f2-)"
        sudo nvram boot-args="${current:+$current }-arm64e_preview_abi" || die "nvram refused to write boot-args"
        sa_resume_arm
        state_set sa pending
        ok "boot-arg written"
        if ask "One more reboot is needed. Restart now?" y; then
            osascript -e 'tell application "System Events" to restart' >/dev/null 2>&1 || sudo shutdown -r now
        else
            info "restart when convenient; Terminal will continue on its own"
        fi
        return 0
    fi
    ok "boot-arg in place"

    say "Step 3 of 3: scripting addition"
    sa_write_sudoers
    sudo yabai --load-sa || die "yabai --load-sa failed; details: /tmp/yabai_$USER.err.log"
    yabai --restart-service >/dev/null 2>&1 || true
    state_set sa on
    ok "full mode enabled"
}
