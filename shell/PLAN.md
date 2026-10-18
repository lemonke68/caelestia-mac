# rice-shell — план

Свой «quickshell» для macOS: один процесс на Swift/SwiftUI (launchd-агент), который рисует рамку, вертикальный бар и выезжающие панели caelestia. Источник геометрии и поведения — `caelestia-dots/shell` (`modules/`, `plugin/src/Caelestia/Config/tokens.hpp`) и патчи из dotfiles-hyprlain.

Решения (2026-10-18):
- Бары: **оба** — вертикальный бар caelestia слева + рамка, SketchyBar сверху остаётся и служит верхней кромкой рамки.
- Дашборд выезжает **из выреза**; boring.notch удаляется, когда в дашборде появится медиа.
- Нужны: сессия справа, сайдбар/уведомления, лаунчер, OSD.

## Архитектура

```
shell/
  Sources/
    App.swift          запуск, окна, IPC
    Theme.swift        scheme.txt текущей темы, перезагрузка по rice.theme.changed
    Tokens.swift       размеры из tokens.hpp (rounding, spacing, padding, font, bar, dashboard…)
    Frame.swift        рамка: окно поверх рабочего стола, клики насквозь
    Panel.swift        базовая выезжающая панель: форма с «наплывами» (вогнутые углы) у кромки рамки
    Bar/…              вертикальный бар
    Dashboard/…        дашборд из выреза
    Session/…, Launcher/…, Sidebar/…, Osd/…
    Services/          Spaces (yabai), Media (MediaRemote), System (батарея, сеть, bt), Weather…
```

- Каждый элемент — отдельное `NSWindow` без рамки: рамка (`ignoresMouseEvents`), бар, каждая панель. Цвет фона один — `surface`, поэтому стыки не видны.
- IPC: `rice-shell <команда>` шлёт distributed notification работающему процессу (`toggle dashboard|session|sidebar|launcher`, `spaces-changed`, `theme-changed`). skhd и сигналы yabai вызывают CLI.
- theme-switch после применения темы шлёт `rice.theme.changed`.

## Геометрия (caelestia → mac, в pt)

| Что | caelestia | mac |
|---|---|---|
| Толщина рамки | `border.thickness` 10 | 10 (справа, снизу) |
| Скругление внутреннего угла рамки | `border.rounding` 25 | 25 |
| Ширина бара | `bar.innerWidth` 40 + 2 × padding 10 | 60 |
| Верхняя кромка | рамка 10 | SketchyBar 38 (высота выреза) |
| Отступ окон от рамки | `windowGapsOut` 10 | yabai: left 70, right/bottom 20, top 10 |

## Фазы

1. ✅ **Ядро + рамка + бар.** Theme/Tokens, окно рамки, бар (лого, воркспейсы yabai, активное окно, часы столбиком, статусы wifi/bt/батарея, power). yabai-отступы под рамку, SketchyBar непрозрачный в цвет рамки.
2. ✅ **Сессия** (справа): выход, выключение, перезагрузка, сон, блокировка; кнопки 80 pt. Отрабатывает механику панелей и «наплывов». Бинд: power в баре, `ctrl + alt + Delete`-аналог.
3. ✅ **Дашборд из выреза**, вкладка Dashboard: пользователь/аптайм, дата-время, календарь, погода (open-meteo), ресурсы (CPU/RAM/диск), медиа. Сервис медиа через `media-control` (mediaremote-adapter). Удаление boring.notch.
4. ✅ Вкладки **Media** (обложка, прогресс, управление), **Performance**, **Weather**.
5. ✅ **Лаунчер**: приложения (/Applications + Spotlight), калькулятор, действия, обои; бинд alt + Space.
6. ✅ **OSD** громкости/яркости/подсветки: перехват медиаклавиш (CGEventTap), CoreAudio, DisplayServices; системный HUD подавляется.
7. ⏸ **Сайдбар** (отложен 2026-10-18): быстрые переключатели + уведомления. Риск: у macOS нет публичного API для чужих уведомлений — исследовать (db usernoted с Full Disk Access).

## Риски

- Уведомления (фаза 7) — может не получиться читать чужие уведомления.
- Подавление системного HUD (фаза 6) — через event tap, нужен Accessibility.
- MediaRemote на macOS 15.4+ закрыт для сторонних процессов; mediaremote-adapter обходит через perl (как в boring.notch).
