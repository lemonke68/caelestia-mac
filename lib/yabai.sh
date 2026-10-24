# yabai: Homebrew build up to macOS 26, the AhsanFazal fork on macOS 27 (upstream has no
# macOS 27 support yet). The fork is built from source with patches/yabai/*.patch on top
# and signed with the mac-rice identity, so its Accessibility grant survives updates.
#
#   RICE_YABAI=auto|brew|fork   override the choice (state key yabai_source remembers it)
#   RICE_YABAI_SRC=<dir>        fork checkout (default ~/.local/share/yabai-fork)

RICE_YABAI_FORK_URL="https://github.com/AhsanFazal/yabai"

yabai_source() {
    local s="${RICE_YABAI:-$(state_get yabai_source)}"
    if [ -z "$s" ] || [ "$s" = auto ]; then
        if [ "$(macos_major)" -ge 27 ]; then s=fork; else s=brew; fi
    fi
    echo "$s"
}

yabai_fork_dir() {
    local d="${RICE_YABAI_SRC:-$(state_get yabai_src)}"
    # A checkout made by hand following docs/yabai-install.md
    if [ -z "$d" ] && [ -d "$HOME/src/yabai-fork/.git" ]; then d="$HOME/src/yabai-fork"; fi
    echo "${d:-$HOME/.local/share/yabai-fork}"
}

yabai_build_fork() {
    local src
    src="$(yabai_fork_dir)"
    if [ ! -d "$src/.git" ]; then
        info "cloning the fork into ${src/#$HOME/~}"
        git clone -q "$RICE_YABAI_FORK_URL" "$src" || die "failed to download the yabai fork"
    fi
    state_set yabai_src "$src"

    if [ -n "$(git -C "$src" status --porcelain --untracked-files=no)" ]; then
        warn "${src/#$HOME/~} has uncommitted changes; building as is, without updating"
    else
        # mac-rice branch = fork's latest + our patches; a local branch of the user's own stays untouched
        git -C "$src" fetch -q origin || warn "no network; building the last downloaded version"
        git -C "$src" checkout -q -B mac-rice origin/HEAD
        local p
        for p in "$RICE_ROOT"/patches/yabai/*.patch; do
            [ -f "$p" ] || continue
            if ! git -C "$src" -c user.name=mac-rice -c user.email=mac-rice@localhost am -q --3way "$p" >/dev/null 2>&1; then
                git -C "$src" am --abort >/dev/null 2>&1
                warn "patch $(basename "$p") no longer applies; skipping"
            fi
        done
    fi

    info "building yabai (about a minute)"
    mkdir -p "$RICE_STATE_DIR"
    make -C "$src" install >/dev/null 2>"$RICE_STATE_DIR/yabai-build.log" \
        || die "yabai build failed, log: ${RICE_STATE_DIR/#$HOME/~}/yabai-build.log"
}

# Replace the yabai on PATH with the fork build, signed so Accessibility stays granted.
yabai_install_fork() {
    local dst
    dst="$(brew_prefix)/bin/yabai"
    yabai --stop-service >/dev/null 2>&1 || true
    rm -f "$dst"
    cp "$(yabai_fork_dir)/bin/yabai" "$dst"
    rice_sign "$dst"
}

yabai_install() {
    local source
    source="$(yabai_source)"
    state_set yabai_source "$source"
    if command -v yabai >/dev/null 2>&1 && [ "${1:-}" != --force ]; then
        ok "yabai already installed ($(yabai --version))"
    elif [ "$source" = brew ]; then
        brew install asmvik/formulae/yabai
        ok "yabai $(yabai --version) from Homebrew"
    else
        yabai_build_fork
        yabai_install_fork
        ok "yabai $(yabai --version) built from the fork (macOS $(macos_version))"
    fi
    # A new binary has a new hash: the passwordless --load-sa entry has to follow it
    if [ -f /private/etc/sudoers.d/yabai ]; then sa_write_sudoers; fi
}

yabai_update() {
    if [ "$(state_get yabai_source)" = fork ]; then
        yabai_build_fork
        yabai_install_fork
    else
        brew upgrade asmvik/formulae/yabai 2>/dev/null || true
    fi
    if [ -f /private/etc/sudoers.d/yabai ]; then sa_write_sudoers; sudo yabai --load-sa; fi
    yabai --restart-service >/dev/null 2>&1 || yabai --start-service
}

service_start() {   # service_start yabai|skhd
    if "$1" --restart-service >/dev/null 2>&1; then return; fi
    "$1" --start-service >/dev/null 2>&1 || warn "$1 failed to start"
}
