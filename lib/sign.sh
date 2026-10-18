# Code signing for everything mac-rice builds (sourced by shell/build.sh, native/build.sh and
# install.sh). macOS ties permission grants (Accessibility, Location, Bluetooth…) to the
# signing certificate, so a stable identity keeps them across rebuilds; ad-hoc signatures
# change with every build and macOS asks again.
#
# ~/.local/state/mac-rice/signing holds `identity=` and optionally `keychain=` (install.sh
# writes it). Without it an existing `yabai-cert` is used (manual setup from the yabai wiki).

RICE_SIGNING="$HOME/.local/state/mac-rice/signing"
RICE_KEYCHAIN_PASS="$HOME/.local/state/mac-rice/keychain-pass"

rice_sign_identity() {
    if [ -f "$RICE_SIGNING" ]; then
        sed -n 's/^identity=//p' "$RICE_SIGNING" || true
    elif security find-identity -p codesigning 2>/dev/null | grep -q '"yabai-cert"'; then
        echo yabai-cert
    fi
}

# rice_sign <path>...: sign with the stable identity, or ad-hoc with a warning.
rice_sign() {
    rice_id="$(rice_sign_identity)"
    keychain="$(sed -n 's/^keychain=//p' "$RICE_SIGNING" 2>/dev/null || true)"
    if [ -n "$keychain" ] && [ -f "$RICE_KEYCHAIN_PASS" ]; then
        security unlock-keychain -p "$(cat "$RICE_KEYCHAIN_PASS")" "$keychain" 2>/dev/null || true
    fi
    for target in "$@"; do
        if [ -n "$rice_id" ] && codesign -fs "$rice_id" ${keychain:+--keychain "$keychain"} "$target" 2>/dev/null; then
            continue
        fi
        echo "warning: no signing identity, $target stays ad-hoc signed (macOS will ask for permissions again after rebuilds)" >&2
        codesign -fs - "$target" 2>/dev/null || true
    done
}
