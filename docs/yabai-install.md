# Установка yabai (форк для macOS 27)

## 1. Выключить AeroSpace

```bash
osascript -e 'quit app "AeroSpace"'
```

Если AeroSpace есть в System Settings → General → Login Items, убери его оттуда.

## 2. Частично отключить SIP (Recovery)

1. Выключи Mac полностью.
2. Зажми кнопку питания, пока не появится «Loading startup options», затем выбери Options → Continue.
3. В меню сверху открой Utilities → Terminal.
4. Выполни:

```bash
csrutil enable --without fs --without debug --without nvram
```

5. Перезагрузись: Apple menu → Restart.

## 3. Boot-arg (обычный терминал, после загрузки)

```bash
sudo nvram boot-args=-arm64e_preview_abi
```

Перезагрузись ещё раз, затем проверь:

```bash
csrutil status
```

```bash
nvram boot-args
```

## 4. Сертификат для подписи

Keychain Access → меню Keychain Access → Certificate Assistant → Create a Certificate:
- Name: `yabai-cert`
- Identity Type: Self Signed Root
- Certificate Type: Code Signing

Проверка (в списке должна появиться строка `yabai-cert`):

```bash
security find-identity -v -p codesigning
```

## 5. Сборка и установка

```bash
git clone https://github.com/AhsanFazal/yabai ~/src/yabai-fork
```

```bash
cd ~/src/yabai-fork && make install-local
```

## 6. Accessibility

System Settings → Privacy & Security → Accessibility: включи `yabai`.

Проверка (должно показать список spaces, без ошибок):

```bash
yabai -m query --spaces | head
```

## Откат

```bash
cd ~/src/yabai-fork && make uninstall-local
```

Затем в Recovery выполни `csrutil enable` и сбрось boot-arg командой `sudo nvram -d boot-args`.

## Локальный патч: Steam

yabai управляет только окнами обычных приложений, а главное окно Steam принадлежит `Steam Helper` (фоновый CEF-процесс). Без патча это окно не тайлится и лежит поверх остальных. Патч в `src/workspace.m` (`workspace_application_is_observable`) делает исключение для `com.valvesoftware.steam.helper`. Он закоммичен локально в `~/src/yabai-fork`, поэтому `git pull` ниже делает merge, а не затирает его.

## После обновления macOS

```bash
cd ~/src/yabai-fork && git pull --no-rebase && make install-local
```
