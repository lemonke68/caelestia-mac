# macOS rice

Цель: максимально приблизить macOS (MacBook Pro 14" M1 Pro, macOS 27.0.1) к райсу на Asahi Arch: Hyprland (Lua) + caelestia (Quickshell), перекрашенные в палитру Hyprlain.

Установка на чистый Mac и устройство репо — [README](../README.md). Конфиги лежат в `config/` и подключены в `~/.config` симлинками (`install.sh`), команды — в `~/.local/bin`. Этот файл — справочник: стек, бинды, системные изменения.

Источник правды на Linux: https://github.com/lemonke68/dotfiles-hyprlain (снят с живой системы 2026-10-17, коммит `7d98d08`). Старый рис (waybar и т.д.) там в `legacy/`.

## Стек

| Роль | Linux | macOS | Статус |
|---|---|---|---|
| Тайлинг | Hyprland (dwindle) | yabai (форк AhsanFazal для macOS 27) + scripting addition | работает |
| Хоткеи | Hyprland binds | skhd | работает, бинды caelestia |
| Рамки окон | Hyprland border | JankyBorders | работает, цвета из схемы |
| Special workspaces | `special:*` | yabai scratchpads | term, magic, music |
| Бар | caelestia (вертикальный слева) | rice-shell (слева) + SketchyBar (сверху) | работает, цвета из схемы |
| Рамка | caelestia border (10, скругление 25) | rice-shell | работает |
| Темы | `caelestia/theme-switch` | `mac-rice/bin/theme-switch` | hyprlain (+ личные темы вне репо) |
| Виджеты/дашборд | caelestia drawers | rice-shell, план в [shell/PLAN.md](../shell/PLAN.md) | фазы 1–6 из 7 (сайдбар отложен) |
| Вырез | — | дашборд rice-shell (boring.notch удалён) | работает |
| Анимированные обои | gif-обои caelestia (патч `Wallpaper.qml`) | свой `rice-wallpaper` (Swift) | работает; Backdrop не подошёл |
| Терминал | kitty | kitty | конфиг перенесён, цвета из схемы |
| Редактор | Zed | Zed | тема Caelestia из схемы |
| AeroSpace | — | выключен (конфликтует с yabai) | `~/.aerospace.toml` оставлен |

## Темы

Та же модель, что на Arch: тема = схема caelestia (120 ролей Material, тот же `scheme.txt`) + режим.

```
mac-rice/
  bin/theme-switch          python, аналог ~/.config/caelestia/theme-switch
  themes/<имя>/scheme.txt   копия из dotfiles-hyprlain/home/.config/caelestia/themes/<имя>/
  themes/<имя>/theme.json   name, description, mode (dark/light)
  templates/zed.json        шаблон Zed из caelestia-dots/cli
  native/                   Swift: common/ (декодер кадров, FillView), wallpaper/, picker/, build.sh
  bin/rice-wallpaper        демон обоев (launchd: com.mac-rice.wallpaper)
  bin/rice-picker           coverflow-пикер обоев (alt + I)
  bin/wallpaper-next        следующие обои из wallpaperDir темы (alt + shift + I)
```

```
~/mac-projects/mac-rice/bin/theme-switch            # текущая
~/mac-projects/mac-rice/bin/theme-switch list
~/mac-projects/mac-rice/bin/theme-switch hyprlain
```

Что пишет `theme-switch <имя>`:

| Файл | Роли схемы |
|---|---|
| `~/.config/sketchybar/colors.sh` | surface (бар), surfaceContainerHigh (подложки), primary/onPrimary (акцент), onSurface, onSurfaceVariant, outline, error |
| `~/.config/borders/bordersrc` | active `primary` + `e6`, inactive `onSurfaceVariant` + `11` (как `activeWindowBorderColour` caelestia) |
| `~/.config/kitty/theme.conf` | background, onBackground, primary, primaryContainer, term0–15 (как `apply-cava.sh`) |
| `~/.config/zed/themes/caelestia.json` | шаблон caelestia-cli, `{{ роль.hex }}` и `{{ mode }}` |
| внешний вид macOS | dark/light по `mode` темы |
| обои | `wallpaper` из `theme.json` → `rice-wallpaper set` |

Новая тема: скопировать `scheme.txt` из репо дотфайлов в `themes/<имя>/`, добавить `theme.json`.

## Конфиги

Все файлы ниже — симлинки на `config/` в репо (кроме сгенерированных theme-switch).

| Файл | Что внутри |
|---|---|
| `~/.config/yabai/yabairc` | BSP, отступы 10/10, focus follows mouse, opacity 0.95, float-правила, scratchpad-правила, Steam на воркспейсе 5 (один, во весь экран: минимальная ширина 1010pt не помещается в половину; его диалоги плавают поверх на том же воркспейсе — сигнал `window_created` → `steam.sh`), external_bar 38, сигналы для SketchyBar |
| `~/.config/yabai/space.sh` | `focus N` / `move N`: рабочие столы создаются по требованию |
| `~/.config/yabai/scratch.sh` | `<label>`: показать/спрятать scratchpad, запустить приложение, если его нет |
| `~/.config/skhd/skhdrc` | бинды (ниже) |
| `~/.config/borders/bordersrc` | генерируется theme-switch |
| `~/.config/sketchybar/sketchybarrc` | бар 38pt, notch_width 230 |
| `~/.config/sketchybar/colors.sh` | генерируется theme-switch; функция `glyph` для Nerd Font иконок |
| `~/.config/sketchybar/plugins/*.sh` | spaces, front_app, clock, battery, wifi, volume |
| `~/.config/kitty/kitty.conf` | из `apply-cava.sh`: opacity 0.78, JetBrainsMono Nerd Font, beam; + blur, padding. Старый файл в `kitty.conf.bak` |
| `~/.config/zed/settings.json` | тема Caelestia, JetBrainsMono Nerd Font |

Сервисы: `yabai --restart-service`, `skhd --restart-service`, `brew services restart sketchybar`, `brew services restart borders`.

Логи: `/tmp/yabai_$USER.err.log`, `/tmp/skhd_$USER.err.log`.

## rice-shell

Свой «quickshell»: Swift/SwiftUI, launchd-агент `com.mac-rice.shell`, исходники в `shell/Sources/`, сборка `shell/build.sh`. План и фазы — [shell/PLAN.md](../shell/PLAN.md).

Сейчас: рамка (толщина 10, скругление внутренних углов 25; левый край — бар 60, верхний — SketchyBar) и вертикальный бар: лого, воркспейсы yabai с иконками окон, активное окно (заголовок повёрнут), часы (`tertiary`), статусы (громкость, раскладка, Wi-Fi, Bluetooth, батарея), кнопка питания. Шрифты как в caelestia: Google Sans Flex, Rubik, Material Symbols Rounded.

Сессия (фаза 2): панель справа, вырастает из рамки (вогнутые «наплывы» радиусом 25, как drawers caelestia). Кнопки 80 pt: выход (без подтверждения), выключение, гифка `sessionGif` темы, сон (на Arch hibernate), перезагрузка. ↑/↓/Tab — фокус, Enter — выполнить, Esc или клик мимо — закрыть. Открывается кнопкой питания в баре или `ctrl + alt + Delete`.

Общий механизм панелей — `shell/Sources/Panel.swift`: одна форма для любой кромки, выезд из-за рамки, фокус клавиатуры, закрытие по клику снаружи.

Дашборд (фаза 3): висит из выреза, открывается наведением на вырез (задержка 150 мс), закрывается, когда мышь уходит с выреза и панели; `alt + O` — открыть с фокусом клавиатуры (← / → — вкладки). Сетка как в `Dash.qml`: погода (open-meteo), пользователь (`~/.face`, аптайм), часы, календарь (колесо листает месяцы, клик по заголовку — сегодня), CPU / RAM / диск, медиа (обложка, дуга прогресса, управление, `mediaGif` темы). Вкладки (фаза 4):
- **Media** — обложка в форме Cookie9 (медленно вращается), трек, ползунок перемотки (`media-control seek`), shuffle / назад / плей / вперёд / repeat, синхронный текст (клик по строке — перемотка): источники и их порядок берутся из настроек Feishin (`lyrics` в его config.json, сейчас NetEase → LRCLIB), из NetEase выбирается лучшее совпадение по названию, исполнителю и длительности. Тексты с самого Navidrome (их Feishin показывает первыми) не подтягиваются — для этого нужен доступ к серверу. Вокруг обложки — визуализатор (`Visualiser.swift`): системный звук через Core Audio tap (разрешение «запись системного звука» спрашивается один раз), БПФ на 60 полос 50 Гц – 12 кГц, сглаживание как у cava; работает только пока открыта вкладка Media.
- **Performance** — CPU и GPU (загрузка, температура с датчиков PMU через IOHID: `tdie*` — CPU, `TP*g` — GPU), диск, сеть (en0), память, «бак» батареи (время до разряда/заряда, состояние).
- **Weather** — город, дата, восход/закат, температура, влажность, ощущается, ветер, прогноз на 7 дней (open-meteo, запасной хост `previous-runs-api.open-meteo.com` как в патче Arch).
- `rice-shell dashboard media|performance|weather|dashboard` — открыть сразу на вкладке.

- Медиа: `media-control` (brew, тап `ungive/media-control`) — тот же mediaremote-adapter, что был в boring.notch. Feishin отдаёт трек только с включённым Settings → Media Session.
- Погода: город из `~/.config/mac-rice/shell.json` → `{"weather": {"location": "Москва"}}` (или `"55.75,37.62"`); без него — CoreLocation (агенту без .app macOS отказывает), потом IP (с VPN город не тот). Сейчас стоит Москва.
- Бинарники подписаны `yabai-cert`, чтобы разрешения macOS (Bluetooth и т.д.) не слетали после пересборки.

Лаунчер (фаза 5): снизу по центру, поле поиска внизу, результаты растут вверх (до 7, лучший — у поля), панель подстраивает высоту. `alt + Space`.
- Приложения из `/Applications`, `/System/Applications`, `~/Applications` (+ Utilities): нечёткий поиск (начало, начало слова, инициалы, подстрока, буквы по порядку), часто запускаемые выше (счётчики в `~/.local/state/mac-rice/launcher.json`). Запрос, набранный не в той раскладке («яут»), тоже находит (Zen).
- Калькулятор: выражение с цифрами и знаками (`(2+3)*7`, `2^10`, `7%3`) — результат первой строкой, Enter копирует. Свой парсер, без NSExpression.
- Команды через `>`: `>calc`, `>theme <имя>`, `>wallpaper` (пикер), `>dashboard`, `>session`, `>lock`, `>sleep`, `>light`, `>dark`. Tab дополняет.
- ↑/↓ — выбор, Enter — запуск, Esc / клик мимо — закрыть.

OSD (фаза 6): справа, два вертикальных ползунка 30×150 (громкость, яркость встроенного экрана), прячется через 2 с (не прячется, пока мышь на нём), ползунки можно тянуть.
- Медиаклавиши громкости, mute и яркости перехватываются event tap'ом (`MediaKeys` в `Osd.swift`), громкость — CoreAudio, яркость — приватный DisplayServices; системный HUD не появляется. Шаг 1/16, с `option + shift` — 1/64, как в macOS.
- Нужно разрешение Accessibility для rice-shell. Без него клавиши остаются у macOS (системный HUD), OSD всё равно показывается при любом изменении громкости. Статус пишется в `/tmp/rice-shell.err.log` (`media keys: …`).
- Подсветки клавиатуры нет: на MacBook Pro M1 нет клавиш подсветки.
- `rice-shell toggle osd` — показать.

Статусы и трей — в SketchyBar (из левого бара убраны):
- справа: раскладка (EN/RU), громкость, Bluetooth (`blueutil`), Wi-Fi, батарея, часы;
- трей: фоновые приложения со своим значком в меню-баре (Karing, FlClashX, Tailscale…). rice-shell сам добавляет их в SketchyBar с иконкой приложения (`Tray.swift`), клик нажимает настоящий значок через Accessibility — открывается родное меню приложения. Список обновляется при запуске/закрытии приложений и раз в 20 с.
- fullscreen: на пространстве с нативным fullscreen-окном rice-shell прячет рамку и вертикальную панель, а SketchyBar скрывается (`--bar hidden=on`). При уходе с него всё возвращается. Состояние берётся из `is-native-fullscreen` фокусного пространства в `SpacesService` или из `~/.local/state/mac-rice/fullscreen-spaces` (id пространств, переведённых в fullscreen через `alt + F`). Окна не убираются, а становятся прозрачными: после `orderOut` macOS оставляет их только на одном пространстве.
- сон и пробуждение: после сна окна rice-shell могут потерять размещение «на всех пространствах» (панель на одном воркспейсе, лаунчер «открыт», но не виден). Поэтому на пробуждение системы и экрана, разблокировку, возврат в сессию и смену экранов rice-shell через секунду пересоздаёт рамку, панель и все панели-попапы. App Nap для него выключен (`ProcessInfo.beginActivity`), иначе после долгого простоя macOS тормозит его таймеры. Если панель всё же числится открытой, но её окна не видно, `toggle` сбрасывает состояние и открывает её заново.
- лог `/tmp/rice-shell.err.log`: время запуска (`start`), события сна, пробуждения и экранов (`event: …`), пересоздание окон (`rebuild windows`), каждая команда кроме `spaces-changed` (`command: …`) и самовосстановление панели (`panel: open but not visible …`). Если что-то перестало работать, сверь время сбоя с этими строками.
- запись экрана: при записи через `Cmd+Shift+5` системная кнопка «Стоп» скрыта под SketchyBar, поэтому rice-shell (`RecordingService` в `Tray.swift`) раз в секунду смотрит в меню-бар `com.apple.screencaptureui` и, пока запись идёт, показывает справа красную плашку с таймером. Клик по ней (`rice-shell record-stop`) нажимает настоящую кнопку «Стоп» через Accessibility. Запасной вариант без бара: `Cmd+Ctrl+Esc`.
- клик по Wi-Fi / Bluetooth — выпадающая панель rice-shell под значком (`Popouts.swift`, как popouts caelestia): переключатель, сети с силой сигнала / сопряжённые устройства, клик — подключиться (пароль для новых сетей спрашивается в панели).
- rice-shell собран как `bin/RiceShell.app` (`bin/rice-shell` — симлинк для CLI): только .app получают геолокацию (без неё macOS скрывает названия Wi-Fi сетей) и захват звука.

Сессия и дашборд выезжают и по наведению: сессия — на правый край экрана рядом с ней, дашборд — на вырез (`EdgeHover` в `Panel.swift`).

- `rice-shell spaces-changed` — дёргают сигналы yabai; `rice-shell theme-changed` — theme-switch; `rice-shell toggle session|dashboard|launcher`.
- yabai-отступы под рамку: left 70, right/bottom 20, top 10. SketchyBar непрозрачный (`surface`), он же верхняя кромка рамки.

## Обои

`rice-wallpaper` — аналог патча `Wallpaper.qml`: gif анимируется, png/jpg статично, картинка заполняет экран с обрезкой краёв (`PreserveAspectCrop`). Окно на уровне рабочего стола, под иконками Finder, на всех Spaces.

- Кадры gif декодируются один раз, масштабирует GPU (`contentsGravity = resizeAspectFill`); CPU ~0%. Память: все кадры в RAM (~250 МБ для `lainonde.gif`).
- Маленькие гифки (ширина < 1000) масштабируются без сглаживания, чтобы пиксель-арт оставался чётким.
- Когда окна полностью закрывают рабочий стол, анимация на паузе.
- Пересборка: `native/build.sh` (собирает все хелперы и перезапускает агент).

```
bin/rice-wallpaper set ~/.config/assets/media/anim/lainonde.gif
bin/rice-wallpaper get
```

Ассеты скопированы из репо дотфайлов в `~/.config/assets/` (`media`, `sprites`, `palette`; в репо — `assets/`).

Почему не Backdrop: импортирует только видео через свой редактор, gif не берёт, нет URL-схемы или CLI — theme-switch не может им управлять.

### Пикер (`rice-picker`)

Порт `shell-patches/modules/wallpaperpicker/Content.qml` на SwiftUI с той же геометрией: shear −0.3 (картинка внутри скошена обратно и стоит ровно), активная карточка 16:9 (`max(260, min(W·0.46, H·0.52·16/9, 780))`) с рамкой `primary`, боковые `0.3·0.88^(d−1)` по ширине и `0.9^(d−1)` по высоте, затемнение 0.35, скругление `28·0.85^d`. Gif играет только на активной.

- ← / →, колесо (одна позиция на щелчок), Home / End; клик по боковой — выбрать, по центральной — применить.
- Предпросмотр живой: через 180 мс после остановки обои на рабочем столе меняются. Enter — оставить, Esc / клик мимо / повторный alt + I — вернуть исходные.
- Чипы категорий = подпапки `wallpaperDir` (`anim`, `static`), поиск по пути.
- Цвета из `scheme.txt` текущей темы.

## Бинды

Источник: caelestia `hypr/variables.lua` (дефолты) + `caelestia/hypr-vars.lua` + `caelestia/hypr-user.lua`.
Перевод модификаторов: `SUPER` → `alt`, `SUPER + ALT` → `alt + cmd`. Буквы в skhdrc — keycode'ы, работают на русской раскладке.

Почему не Cmd (хотя на Asahi Super — это физический Cmd): бинды перехватили бы маковские Cmd + C / V / F / W / T…, а перенос шорткатов приложений на Ctrl через Karabiner решили не делать (2026-10-17).

### Приложения

| macOS | Arch | Действие |
|---|---|---|
| alt + Enter | SUPER + Return | kitty |
| alt + W | SUPER + W | Zen |
| alt + T | SUPER + T | Zed |
| alt + E | SUPER + E | Finder (на Arch nautilus) |

### Окна

| macOS | Arch | Действие |
|---|---|---|
| alt + Q | SUPER + Q | закрыть окно |
| alt + shift + Q | SUPER + SHIFT + Q | завершить приложение |
| alt + F | SUPER + F | fullscreen на месте: окно на весь экран без отступов, рамка, панель и SketchyBar прячутся (`~/.config/yabai/fullscreen.sh`) |
| alt + cmd + F | SUPER + ALT + F | нативный fullscreen macOS |
| alt + V | SUPER + V | float / tile |
| alt + P | SUPER + P | закрепить на всех столах (sticky) |
| alt + ctrl + \ | CTRL + SUPER + Backslash | центрировать |
| alt + N | SUPER + N | сменить направление сплита |
| alt + B | — | выровнять сплиты |
| alt + M | SUPER + M | группа: стол в stack-раскладку и обратно |
| alt + ctrl + H/J / K/L | SUPER + CTRL + H/J / K/L | предыдущее / следующее окно в группе |
| alt + H/J/K/L, alt + стрелки | SUPER + hjkl / стрелки | фокус |
| alt + shift + H/J/K/L | SUPER + SHIFT + hjkl | переместить окно |
| alt + Tab / alt + shift + Tab | ALT + TAB | следующее / предыдущее окно на столе |
| alt + − / = | SUPER + Minus / Equal | ширина − / + |
| alt + shift + − / = | SUPER + SHIFT + Minus / Equal | высота − / + |
| alt + cmd + стрелки | SUPER + ALT + стрелки | ресайз |
| alt + ЛКМ-драг / ПКМ-драг | SUPER + мышь | двигать / ресайзить |

### Рабочие столы

| macOS | Arch | Действие |
|---|---|---|
| alt + 1…0 | SUPER + 1…0 | стол 1…10 (создаётся при первом заходе) |
| alt + shift + 1…0 | SUPER + SHIFT + 1…0 | перенести окно и перейти |
| alt + ctrl + ← / →, alt + PgUp / PgDn | CTRL + SUPER + ← / →, SUPER + PgUp / PgDn | предыдущий / следующий стол |
| alt + cmd + PgUp / PgDn | SUPER + ALT + PgUp / PgDn | перенести окно на соседний стол |
| alt + \` | SUPER + grave | выпадающий терминал (kitty `kitty-dropdown`, сверху 75%×45%) |
| alt + S | SUPER + S | special workspace `magic` |
| alt + cmd + S | SUPER + ALT + S | отправить окно в `magic` |
| alt + ctrl + M | CTRL + SUPER + M | музыка (Spotify) |
| alt + D | SUPER + D | Telegram: открыть или переключиться на него (тайлится как обычное окно, не scratchpad) |
| ctrl + shift + Esc | CTRL + SHIFT + Escape | Activity Monitor (на Arch — btop) |

Ограничение yabai: в scratchpad один label = одно окно. Поэтому `magic` — одно окно.

### Утилиты

| macOS | Arch | Действие |
|---|---|---|
| alt + shift + S | SUPER + SHIFT + S | скриншот области в буфер |
| alt + shift + M | SUPER + SHIFT + M | mute |
| alt + Esc | SUPER + Escape | заблокировать экран |
| alt + shift + R | — | перезапуск yabai |
| ctrl + alt + Delete | CTRL + ALT + Delete | панель сессии |
| alt + O | SUPER + O | дашборд |
| alt + Space | SUPER (тап) | лаунчер |
| alt + I | SUPER + I | пикер обоев (повторное нажатие закрывает) |
| alt + shift + I | — | следующие обои без пикера |

### Не перенесено

| Arch | Почему / чем заменить |
|---|---|
| SUPER + SHIFT + N — сайдбар | фаза 7 rice-shell |
| SUPER + SHIFT + V — буфер | история буфера в Spotlight |
| SUPER + Period — эмодзи | `ctrl + cmd + Space` |
| SUPER + SHIFT + P — пипетка | нет CLI; Digital Color Meter |
| CTRL + SUPER + Space / = / − — медиа | медиаклавиши F7–F9 или кнопки в дашборде |
| SUPER + R — todo, SUPER + U — ungroup | не нужны / нет аналога |
| CTRL + SUPER + 1…0 — группы столов | нет аналога |
| колесо мыши с SUPER — смена стола | skhd не ловит колесо |



## Меню-бар macOS

Не автоскрывается, а всегда на месте, но прозрачный (`yabai -m config menubar_opacity 0.0`); SketchyBar поверх (`topmost=on`). Так он больше не выезжает при наведении на вырез. Высота меню-бара = высота выреза (38pt), поэтому место не теряется; `external_bar all:0:0`, чтобы yabai не добавлял отступ второй раз.

Меню приложений мышью теперь недоступно. С клавиатуры: `cmd + shift + /` (поиск по всем пунктам меню, Help), `ctrl + F2` (фокус на меню-бар).

## Системные настройки, которые менялись

- SIP: `csrutil enable --without fs --without debug --without nvram` (в Recovery).
- boot-args: `-arm64e_preview_abi`.
- Сертификат `yabai-cert` в Keychain (self-signed, Code Signing).
- `/private/etc/sudoers.d/yabai`: беспарольный `yabai --load-sa`, привязан к sha256 бинарника.
- Accessibility: yabai, skhd.
- Menu bar: автоскрытие выключено, прозрачность 0 через yabai (см. «Меню-бар macOS»).
- Dock: обычный, видимый (автоскрытие пробовали, неудобно).
- `com.apple.dock mru-spaces = false`: macOS не переставляет рабочие столы.
- Внешний вид dark/light переключает theme-switch.

Установка и откат yabai: [yabai-install.md](yabai-install.md).

## Ограничения macOS

- Прозрачность через yabai гасит окно целиком, вместе с текстом. Прозрачный фон с блюром и чёткий текст — только в приложениях, которые это умеют (kitty, Zed, Ghostty).
- SketchyBar не умеет вертикальный бар. Боковая панель caelestia — только через свой движок.
- Quickshell (Qt + Wayland layer-shell) на macOS не запускается.
- После каждого обновления macOS: `cd ~/src/yabai-fork && git pull && make install-local`; offsets Dock могут сломаться до выхода фикса.
- Официального yabai под macOS 27 нет (на 2026-10-17 последний релиз 7.1.25 от 2026-05-08). Перейти обратно: `make uninstall-local`, потом `brew install asmvik/formulae/yabai`.

## Дальше

1. Свой движок виджетов: вертикальная панель, дашборд (Dashboard / Media / Performance / Weather), power-меню, сайдбар — бинды alt + O и alt + shift + N.
2. Скорость повтора клавиш (`KeyRepeat`, `InitialKeyRepeat`, `ApplePressAndHoldEnabled`).
3. Курсор Bibata-Modern-Hyprlain (на macOS — только через сторонние утилиты; под вопросом).
4. Собрать mac-конфиги в репо с дотфайлами (`macos/` рядом с `home/`).
