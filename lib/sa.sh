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

sa_write_sudoers() {
    local bin hash
    bin="$(command -v yabai)" || die "yabai не найден"
    hash="$(shasum -a 256 "$bin" | cut -d' ' -f1)"
    info "обновляю $RICE_SUDOERS (может спросить пароль от Mac)"
    printf '%s ALL=(root) NOPASSWD: sha256:%s %s --load-sa\n' "$(whoami)" "$hash" "$bin" \
        | sudo tee "$RICE_SUDOERS" >/dev/null
    sudo chmod 0440 "$RICE_SUDOERS"
    if ! sudo visudo -cf "$RICE_SUDOERS" >/dev/null; then
        sudo rm -f "$RICE_SUDOERS"
        die "запись sudoers не прошла проверку, удалил её"
    fi
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

${c_bold}Нужно один раз зайти в режим восстановления (Recovery).${c_off}
Mac выключится, поэтому сфотографируй эти шаги или открой их на телефоне:
https://github.com/$RICE_REPO/blob/main/docs/full-mode.md

EOF
    if is_arm; then
        cat <<EOF
  1. Меню  → Выключить. Дождись, пока экран погаснет.
  2. Нажми и держи кнопку питания (Touch ID), пока не появится
     «Загрузка параметров запуска». Отпусти.
  3. Выбери «Параметры» → «Продолжить». Если спросит — выбери своего
     пользователя и введи пароль.
  4. В строке меню сверху: «Утилиты» → «Терминал».
  5. Введи команду и нажми Enter (спросит «y» и пароль — подтверди):

       ${c_bold}csrutil enable --without fs --without debug --without nvram${c_off}

  6. Затем вторую (если она ответит ошибкой — ничего страшного,
     установщик сделает это сам после перезагрузки):

       ${c_bold}nvram boot-args=-arm64e_preview_abi${c_off}

  7. Меню  → Перезагрузить.
EOF
    else
        cat <<EOF
  1. Меню  → Перезагрузить и сразу зажми ⌘ + R до логотипа Apple.
  2. В строке меню сверху: «Утилиты» → «Терминал».
  3. Введи команду и нажми Enter:

       ${c_bold}csrutil disable --with kext --with dtrace --with nvram --with basesystem${c_off}

  4. Меню  → Перезагрузить.
EOF
    fi
    cat <<EOF

После входа в систему Терминал откроется сам и закончит настройку.
Вернуть всё как было: ${c_bold}rice uninstall${c_off} (там же инструкция, как включить SIP обратно).
EOF
}

sa_warning() {
    cat <<EOF

${c_bold}Полный режим${c_off} — это то, что умеет yabai со своим «scripting addition»:
  • мгновенное переключение рабочих столов и создание их по требованию (alt + 1…0)
  • перенос окон между столами (alt + shift + 1…0)
  • прозрачный системный меню-бар, прозрачность окон, special workspaces

Цена: часть защиты macOS (SIP) выключается. Что это значит на практике:
  • система менее защищена от вредоносных программ с правами администратора;
  • на Apple Silicon перестают запускаться iPhone/iPad-приложения из App Store;
  • после крупных обновлений macOS yabai может временно сломаться до фикса.
Без полного режима всё остальное работает: тайлинг, бары, дашборд, темы, обои.
EOF
}

sa_run() {
    local resume="${1:-}"
    [ "$resume" = --resume ] && sa_resume_disarm

    if sa_loaded && sa_sip_ok && sa_bootarg_ok; then
        ok "полный режим уже включён"
        return 0
    fi

    if [ "$resume" != --resume ]; then
        sa_warning
        ask "Включить полный режим?" n || { info "оставляю базовый режим; включить позже: rice sa"; return 0; }
    fi

    if ! sa_sip_ok; then
        say "Шаг 1 из 3: SIP (Recovery)"
        sa_recovery_steps
        sa_resume_arm
        state_set sa pending
        echo
        info "Когда будешь готов — выключи Mac по шагам выше."
        return 0
    fi
    ok "SIP настроен"

    if ! sa_bootarg_ok; then
        say "Шаг 2 из 3: boot-arg для Apple Silicon"
        local current
        current="$(nvram boot-args 2>/dev/null | cut -f2-)"
        sudo nvram boot-args="${current:+$current }-arm64e_preview_abi" || die "nvram не дал записать boot-args"
        sa_resume_arm
        state_set sa pending
        ok "boot-arg записан"
        if ask "Нужна ещё одна перезагрузка. Перезагрузить сейчас?" y; then
            osascript -e 'tell application "System Events" to restart' >/dev/null 2>&1 || sudo shutdown -r now
        else
            info "перезагрузись, когда удобно — Терминал продолжит сам"
        fi
        return 0
    fi
    ok "boot-arg на месте"

    say "Шаг 3 из 3: scripting addition"
    sa_write_sudoers
    sudo yabai --load-sa || die "yabai --load-sa не сработал; подробности: /tmp/yabai_$USER.err.log"
    yabai --restart-service >/dev/null 2>&1 || true
    state_set sa on
    ok "полный режим включён"
}
