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
    echo "==> mac-rice: подготовка"
    if [ "$(id -u)" -eq 0 ]; then echo "Запусти без sudo." >&2; exit 1; fi
    brew_bin=/opt/homebrew/bin/brew
    [ "$(uname -m)" = arm64 ] || brew_bin=/usr/local/bin/brew
    if [ ! -x "$brew_bin" ]; then
        echo "==> Ставлю Homebrew (менеджер пакетов). Он спросит пароль от Mac и Enter."
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
        *) die "неизвестный флаг $arg (см. начало install.sh)" ;;
    esac
done
export RICE_YES="${RICE_YES:-0}"

# ---------- steps ----------

step_preflight() {
    say "Проверяю систему"
    [ "$(id -u)" -ne 0 ] || die "запусти без sudo — права администратора попрошу только там, где нужно"
    version_ge "$RICE_MIN_MACOS" "$(macos_version)" \
        || die "нужна macOS $RICE_MIN_MACOS или новее (сейчас $(macos_version))"
    ok "macOS $(macos_version), $(uname -m)$(is_arm && echo ' (Apple Silicon)' || echo ' (Intel)')"

    local g
    g="$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c 'Resolution:' || true)"
    ok "мониторов: ${g:-1} (рамка и левый бар — на главном, где меню-бар)"
    if pgrep -xq AeroSpace; then
        warn "запущен AeroSpace — он конфликтует с yabai"
        if ask "Закрыть AeroSpace?" y; then osascript -e 'quit app "AeroSpace"' || true; fi
    fi
    curl -fsI --max-time 10 https://github.com >/dev/null || die "нет доступа к github.com"
}

step_homebrew() {
    say "Homebrew"
    if ! load_brew; then
        info "ставлю Homebrew — он спросит пароль от Mac и Enter"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty
        load_brew || die "Homebrew не установился"
    fi
    zprofile_add "eval \"\$($(brew_prefix)/bin/brew shellenv)\""
    xcode-select -p >/dev/null 2>&1 || die "нет Command Line Tools: выполни xcode-select --install и запусти снова"
    ok "Homebrew $(brew --version | head -1 | cut -d' ' -f2)"
}

step_packages() {
    say "Пакеты и шрифты"
    # Install only; upgrading what is already there is for `rice update`
    local no_upgrade=1
    [ "$opt_update" = 1 ] && no_upgrade=""
    if ! HOMEBREW_BUNDLE_NO_UPGRADE="$no_upgrade" brew bundle --file "$RICE_ROOT/Brewfile"; then
        warn "часть пакетов не встала (например, приложение уже стоит не через Homebrew) — продолжаю"
    fi

    [ "$opt_apps" = 1 ] || return 0
    # name:cask — apps the hotkeys open
    local entry app cask missing=""
    for entry in Zen:zen Zed:zed Telegram:telegram Spotify:spotify; do
        app="${entry%%:*}" cask="${entry#*:}"
        [ -d "/Applications/$app.app" ] || [ -d "$HOME/Applications/$app.app" ] || missing="$missing $cask"
    done
    [ -n "$missing" ] || return 0
    info "горячие клавиши открывают Zen (alt+W), Zed (alt+T), Telegram (alt+D), Spotify (alt+ctrl+M)"
    if ask "Поставить недостающие:$missing?" n; then
        # shellcheck disable=SC2086
        brew install --cask $missing || warn "не все приложения встали"
    fi
}

step_signing() {
    say "Сертификат для подписи"
    if [ -n "$(rice_sign_identity)" ]; then
        ok "есть: $(rice_sign_identity)"
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
    ok "создан mac-rice-cert (свой keychain, связка «Вход» не тронута)"
}

step_yabai() {
    say "yabai (тайлинг окон)"
    if [ "$opt_update" = 1 ]; then yabai_update; ok "yabai $(yabai --version)"; else yabai_install; fi
}

step_link() {
    say "Конфиги"
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
    ok "~/.config → ${RICE_ROOT/#$HOME/~}/config (старые файлы в ${RICE_BACKUP/#$HOME/~})"
}

step_defaults() {
    say "Настройки macOS"
    # Spaces keep their order (Hyprland workspaces don't shuffle)
    if [ "$(defaults read com.apple.dock mru-spaces 2>/dev/null)" != 0 ]; then
        state_set prev_mru_spaces "$(defaults read com.apple.dock mru-spaces 2>/dev/null || echo default)"
        defaults write com.apple.dock mru-spaces -bool false
        killall Dock 2>/dev/null || true
    fi
    ok "рабочие столы не переставляются сами"

    # The bar sits on top of the menu bar, which must stay put
    if [ "$(defaults read NSGlobalDomain _HIHideMenuBar 2>/dev/null)" = 1 ]; then
        state_set prev_hide_menubar 1
        defaults write NSGlobalDomain _HIHideMenuBar -bool false
        killall SystemUIServer 2>/dev/null || true
    fi
    ok "меню-бар не прячется"

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
    [ "$(state_get desktop_keys)" = on ] && ok "ctrl + 1…9 переключает рабочие столы (запасной путь базового режима)"
    return 0
}

step_build() {
    say "Сборка rice-shell и обоев (пару минут)"
    local log="$RICE_STATE_DIR/build.log"
    mkdir -p "$RICE_STATE_DIR"
    "$RICE_ROOT/native/build.sh" >"$log" 2>&1 || die "сборка обоев упала, лог: ${log/#$HOME/~}"
    ok "rice-wallpaper, rice-picker"
    "$RICE_ROOT/shell/build.sh" >>"$log" 2>&1 || die "сборка rice-shell упала, лог: ${log/#$HOME/~}"
    ok "RiceShell.app"
}

step_services() {
    say "Запуск"
    service_start yabai
    service_start skhd
    brew services restart sketchybar >/dev/null 2>&1 || brew services start sketchybar >/dev/null
    brew services restart borders >/dev/null 2>&1 || brew services start borders >/dev/null
    local theme
    theme="$(cat "$RICE_STATE_DIR/theme" 2>/dev/null || echo hyprlain)"
    "$RICE_ROOT/bin/theme-switch" "$theme" >/dev/null
    ok "yabai, skhd, SketchyBar, borders; тема $theme"
}

step_permissions() {
    say "Разрешения macOS"
    cat <<EOF
macOS не даёт скриптам выдавать разрешения — это делаешь ты, один раз.
Сейчас откроется окно «Настройка mac-rice»: в каждой строке есть кнопка, которая
открывает нужный раздел Системных настроек. Там включи переключатель у программы.

  • yabai, skhd, rice-shell — «Универсальный доступ» (без него не работают
    окна, горячие клавиши и медиаклавиши)
  • rice-shell — «Геолокация» (погода, названия Wi-Fi) и Bluetooth: macOS спросит сама

В базовом режиме рабочие столы создаются вручную: F3 (Mission Control) → «+» в правом
верхнем углу, сделай штук пять. Переключение — alt + 1…9.

Окно можно открыть снова: ${c_bold}rice setup${c_off}
EOF
    sleep 2   # the agent was just restarted
    "$RICE_BIN/rice-shell" setup
    pause "Когда все строки станут зелёными, нажми Enter… "
    rice_doctor
}

step_full_mode() {
    if [ "$(state_get sa)" = on ]; then return; fi
    say "Полный режим (по желанию)"
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

${c_green}Готово.${c_off} Главное:
  alt + Enter      терминал            alt + Space   лаунчер
  alt + 1…0        рабочие столы       alt + O       дашборд (или наведи на вырез)
  alt + Q          закрыть окно        alt + I       обои
  alt + H/J/K/L    фокус               ctrl+alt+Del  выключение / сон
Все бинды: ${RICE_ROOT/#$HOME/~}/docs/REFERENCE.md

  rice doctor      что работает, что нет
  rice update      обновить
  rice theme       темы (rice theme list)
  rice uninstall   удалить и вернуть как было
Открой новое окно терминала, чтобы команда rice стала доступна.
EOF
}

if [ "$opt_update" = 1 ]; then
    load_brew || die "нет Homebrew — запусти install.sh без --update"
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
