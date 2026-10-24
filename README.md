# caelestia-mac

A macOS rice modeled after [caelestia](https://github.com/caelestia-dots/shell) (Hyprland + Quickshell on Arch):
tiling windows, a vertical bar and a frame around the desktop, a dashboard that slides out of the notch,
an app launcher, a session menu, volume and brightness OSDs, animated wallpapers, and Material themes
generated from a single color scheme.

Built on [yabai](https://github.com/asmvik/yabai) (tiling), [skhd](https://github.com/asmvik/skhd)
(hotkeys), [SketchyBar](https://github.com/FelixKratz/SketchyBar) (top bar),
[JankyBorders](https://github.com/FelixKratz/JankyBorders) (window borders), kitty, and **rice-shell**,
a custom Quickshell-like layer written in Swift/SwiftUI.

## Requirements

- macOS 14.4 or later
- Apple Silicon or Intel

Tested on a 14" MacBook Pro (M1 Pro) running macOS 27. The bar and frame adapt to the display:
with or without a notch, built-in or external. They are drawn on the display that holds the menu bar.

## Installation

Open Terminal and run:

```bash
curl -fsSL https://raw.githubusercontent.com/lemonke68/caelestia-mac/main/install.sh | bash
```

The installer sets up Homebrew, packages and fonts, builds rice-shell, and links the configs.
The repository is cloned to `~/.local/share/caelestia-mac`. The script is safe to re-run: each step
checks what is already in place.

Installer flags (when running `./install.sh` from a checkout):

```
--yes       accept the default answer to every prompt
--full      continue into full mode without asking
--no-apps   skip the optional apps (Zen, Zed, Telegram, Spotify)
```

During installation you will need to:

1. **Enter your macOS password** when Homebrew and a few system steps ask for it.
2. **Grant permissions.** macOS does not allow scripts to grant them, so a setup window opens at the end.
   Each red row has a button that opens the relevant System Settings pane; enable the toggle there
   and the row turns green.
3. **Optionally enable full mode** (see below).

### Basic and full mode

| | Basic | Full |
|---|---|---|
| Tiling, focus, resizing, bars, dashboard, themes, wallpapers | ✓ | ✓ |
| Switching spaces (alt + 1…9) | via macOS ctrl + 1…9; spaces are created manually in Mission Control | instant; spaces are created automatically |
| Moving a window to another space (alt + shift + 1…0) | — | ✓ |
| Window and system menu bar transparency | — | ✓ |
| Requirements | none | boot into Recovery once and partially disable SIP |

Enable full mode with `rice sa` or from the setup window. The installer walks through the steps and
resumes automatically after the reboot. A step-by-step guide (handy to keep open on a phone):
[docs/full-mode.md](docs/full-mode.md).

Trade-offs of full mode: part of macOS's System Integrity Protection is disabled, iPhone/iPad apps
stop launching on Apple Silicon, and major macOS updates may temporarily break yabai until it is patched.

## Commands

```
rice doctor      show what works and what doesn't
rice setup       open the setup window (permissions, mode)
rice update      update and rebuild
rice restart     restart everything
rice theme       themes: rice theme list, rice theme <name>
rice sa          enable full mode
rice uninstall   remove everything and restore the previous state
```

## Keybindings

The modifier is `alt` (⌥). Essentials:

| Keys | Action |
|---|---|
| alt + Enter | terminal |
| alt + Space | launcher (apps, calculator, `>` commands) |
| alt + O | dashboard (or hover the notch) |
| alt + 1…0 / alt + shift + 1…0 | switch to space / move window there |
| alt + H/J/K/L or arrows | move focus; with shift, move the window |
| alt + Q / alt + F / alt + V | close / fullscreen / toggle floating |
| alt + I / alt + shift + I | wallpaper picker / next wallpaper |
| alt + ` | drop-down terminal |
| ctrl + alt + Delete | shut down, sleep, restart |

Full keybinding list and internals: [docs/REFERENCE.md](docs/REFERENCE.md).

## System changes

- Configs in `~/.config` are replaced with symlinks into the repository. Existing files are backed up
  to `~/.local/state/mac-rice/backup/` and restored on uninstall.
- Commands are installed to `~/.local/bin`, and a `PATH` line (marked `# mac-rice`) is added to `~/.zprofile`.
- A `mac-rice-cert` signing certificate is stored in a separate keychain so permissions survive rebuilds.
  The login keychain is not touched.
- System settings: spaces are not rearranged automatically, the menu bar is not hidden, and ctrl + 1…9
  switches spaces (basic mode only).
- Full mode: SIP partially disabled, the `-arm64e_preview_abi` boot-arg, and a `/etc/sudoers.d/yabai`
  entry for `yabai --load-sa`.

`rice uninstall` reverts all of the above. SIP can only be re-enabled from Recovery; the uninstaller
prints the commands.

## Repository layout

```
install.sh, uninstall.sh   install and uninstall
lib/                       installer steps: yabai, full mode, doctor, signing
bin/                       rice, theme-switch, wallpaper-next (+ built rice-shell and wallpaper binaries)
config/                    files linked into ~/.config/… (yabai, skhd, sketchybar, kitty)
shell/                     rice-shell (Swift): frame, bar, dashboard, launcher, OSD, setup window
native/                    wallpapers: rice-wallpaper daemon and rice-picker
themes/                    caelestia schemes (scheme.txt) + theme.json
assets/                    wallpapers and theme GIFs
patches/yabai/             patches on top of the yabai fork for macOS 27
```
