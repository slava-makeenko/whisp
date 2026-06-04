# CONTEXT — рабочий контекст по whisp

> Операционный слой: текущее состояние, открытые задачи, как собирать/запускать,
> принятые решения и подводные камни. Детали архитектуры — в [DESIGN.md](DESIGN.md),
> статус по фазам — в [VERIFY.md](VERIFY.md), обзор — в [README.md](README.md).
>
> Обновлено: 2026-06-04

## Что это

**whisp** — нативное macOS-приложение для диктовки/транскрипции в стиле VoiceInk / Wispr Flow.
Личный проект «для себя». Распознавание **на устройстве** (выбор лучшего доступного движка
в рантайме, **мультиязык/авто-определение**), глобальный хоткей, вставка под курсор,
**AI-форматирование текста** (локально или через LLM) и **Command Mode** (голосовое редактирование
выделения). **Работает в фоне** (закрытие окна не завершает). UI: menu-bar (MenuBarExtra) +
окно-дашборд (Dashboard / History / Power Mode / Settings) + индикатор у «нотча».

## Структура

Тонкая Xcode-обёртка (`App/`) + SPM-ядро (`Sources/`, вся логика, тестируется headless).

| Модуль | Назначение |
|---|---|
| `WhispCore` | Оркестратор `DictationController` (режимы `dictation`/`command`, VAD-гейтинг, anti-throttle), персистентность (SwiftData), стораджи (History/Metrics/Dictionary), PowerMode, лицензирование, `AppConstants` |
| `WhispAudio` | Захват аудио (`AVAudioEngineCapturer`), VAD (`EnergyVAD`) |
| `WhispASR` | Роутер движков: SpeechAnalyzer (macOS 26, за флагом) / FluidAudio **Parakeet** (дефолт) / **WhisperKit** / **whisper.cpp** (SwiftWhisper). Выбор движка — `TranscriptionOptions.preferredBackend`; прайминг словаря — `vocabulary` |
| `WhispInput` | Глобальный хоткей `CarbonHotkeyMonitor` (комбинации, permission-free); вставка текста (AX + pasteboard, буфер обмена сохраняется/восстанавливается) |
| `WhispPlatform` | Keychain (`KeychainSecretStore`), системные обёртки |
| `WhispLLM` | OpenAI-совместимое улучшение текста (Groq/OpenRouter/Anthropic через `/chat/completions`) + `LocalTextCleaner` (локальная чистка без ключа) |

App-слой (`App/Sources/`): `WhispApp` (точка входа), `DashboardView`, `SettingsView`,
`RootView`, `NotchRecorder` (индикатор у нотча), `ModifierTapMonitor` (хоткей одиночным
модификатором: double-tap/hold), `PowerModeView` (стиль форматирования под приложение),
`EnhancementProvider`/`EnhancementStyle` (провайдеры LLM + пресеты форматирования),
`OnboardingView`, `ShortcutField`, `HoverEffects`, `Waveform` и т.д. Иконки — `Assets.xcassets`
(AppIcon цветной + MenuBarIcon монохромный template), исходник `icon.svg` в корне.

## Как собрать / запустить / протестировать

```bash
# Сгенерировать проект из project.yml (XcodeGen)
xcodegen generate

# Сборка app
xcodebuild -project whisp.xcodeproj -scheme whisp -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

# Найти бандл (ВАЖНО: исключить Index.noindex — там стаб без бинаря)
APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -name whisp.app \
  -path '*/Build/Products/Debug/*' | grep -v Index.noindex | head -1)

# ОБЯЗАТЕЛЬНО: ставить в /Applications + подписывать стабильным сертификатом. Иначе грант
# Accessibility слетает (DerivedData-путь + неподписанный бинарь → TCC сбрасывается каждую сборку).
# Подпись привязывает грант к DR (team + bundle id) + стабильный путь /Applications.
rm -rf /Applications/whisp.app && cp -R "$APP" /Applications/whisp.app
codesign --force --deep --sign "Apple Development: makslav96@gmail.com (44K83FNU65)" /Applications/whisp.app
open /Applications/whisp.app

# Тесты пакета (Swift Testing). Ожидаемо: «Test run with 45 tests in 13 suites passed»
# Параллельный прогон иногда падает SIGSEGV на teardown SwiftData — гоняй: swift test --no-parallel
swift test
```

### Сборка DMG для установки

Одной командой — стилизованный, самодостаточный, подписанный DMG (всё в `packaging/`):

```bash
packaging/build-dmg.sh                 # → ~/Desktop/whisp.dmg
packaging/build-dmg.sh /путь/out.dmg   # свой путь вывода
WHISP_SIGN_IDENTITY="Apple Development: …" packaging/build-dmg.sh   # другой сертификат
```

Скрипт: Release-сборка (флаг LOCAL_BUILD — без CloudKit/Sparkle-заглушек) → подпись →
проверка самодостаточности → RW-образ HFS+ → раскладка окна → сжатие в UDZO.
⚠️ Первый запуск спросит «… wants to control Finder» — нажми OK (Finder применяет фон/иконки).

Файлы `packaging/`:
- `build-dmg.sh` — оркестратор (всё перечисленное выше).
- `dmg-background.swift` — рендер фона окна (CoreGraphics, 1280×800px @2x, Retina-чёткий).
- `dmg-layout.applescript` — раскладка окна Finder (фон, позиции иконок, скрытый тулбар).

Почему Release, а не Debug: Debug дробит код в `whisp.debug.dylib` (стаб 58КБ + dylib 19МБ) —
такая копия не запускается. Release статически линкует все SPM-движки в основной бинарь
(~11.7МБ); единственная динам. зависимость — `@rpath/Sparkle.framework` (вшита в бандл).

Установка: открыть DMG → перетащить whisp в Applications. Локальный DMG без quarantine →
Gatekeeper не мешает. На ДРУГОМ Mac (скачанный) нужна нотаризация — Apple Development cert
не нотаризован, обход у пользователя: ПКМ по приложению → «Открыть».

## Текущее состояние

- Все 11 фаз сборки завершены (см. VERIFY.md). Диктовка работает, краша нет.
- Недавняя работа (личные доработки UI):
  - больше интерактивности: hover-эффекты, анимации, hover на кнопке записи (курсор + яркость).
  - выбор языка в меню (MenuBarExtra → `Menu("Language")` с тумблерами).
  - доп. LLM-провайдеры: Groq, OpenRouter, Anthropic.
  - индикатор у нотча: пилюля под меню-баром — **только белый эквалайзер по центру**, постоянная
    анимация от таймера (не зависит от уровня звука), без иконки и таймера; только во время сессии.
  - **звуки старт/стоп** записи (`NSSound` Pop/Bottle, тумблер «Sound on start / stop» в настройках)
    через DI-замыкание `onCue` в `DictationController` (ядро без AppKit).
  - **хоткей одиночным модификатором** (`fn`/⌃/⌥/⌘) через `ModifierTapMonitor`: Toggle (двойной тап),
    Push-to-Talk (зажать), **Hybrid (двойной тап = вкл/выкл + зажать = диктовка)**. Accessibility для глобального.
  - **доработки качества «как у VoiceInk»** (см. раздел ниже).
  - **мультиязычность**: мультивыбор языков (Settings/меню) → авто-определение (1 язык = прибит, 0/2+ = авто).
  - **AI-форматирование текста** (Фазы A/B/C) — см. раздел ниже.
  - **иконка** из `icon.svg` (Dock + меню-бар монохром-template); установка в `/Applications` + `codesign`.
    ⚠️ В `AppIcon.appiconset` не хватало `icon_64.png` (слот 32×32@2x) → собранная иконка была неполной
    (без 256/512) → пусто в Stage Manager. Фикс: перегенерить ВСЕ размеры из `icon_1024.png` через `sips`.
    Проверка: `assetutil --info …/Assets.car | grep AppIcon` должен показать 16/32/64/128/256/512/1024.
    Залипший кэш иконок чистится только sudo (`rm -rf /Library/Caches/com.apple.iconservices.store`) или релогином.
  - **фоновый режим**: ✕ не завершает приложение; пилюля/эквалайзер/захват не тормозят в фоне.
  - **swiftui-pro** скилл установлен (`~/.claude/skills/swiftui-pro`) — ревью SwiftUI; быстрые правки применены.
  - **переименование VoiceInk → whisp** (полное, до уровня модулей) — см. ниже.
  - **Wispr-стиль (Фаза 1)**: кремовая палитра + белые карточки + кастомный sidebar + экран Home
    (приветствие + бейдж хоткея, карточка статов, лента истории) — `App/Sources/Theme.swift`
    (`Theme`, `CardSection`, `ScreenHeader`, `WindowAccessor`). Settings/History/Power Mode собраны
    кастомными `CardSection` с явным `Theme.primaryText` — **НЕ `Form .grouped`**: у него vibrancy-баг
    (метки рендерятся белым на cream → невидимы). Тумблеры — `.toggleStyle(.switch)` в `CardSection`.
  - **Кастомизация (Settings → Оформление)**: акцентный цвет (`AccentPalette`, 7 цветов; `.tint` на
    RootView + динамический computed `Theme.accent`) + стиль шрифта (`AppFontStyle` System/Rounded/Serif/Mono
    через `.fontDesign`). Инпуты — `.wispField()` (вне `Form` нативные macOS-поля тёмные на cream).
  - **Светлая тема обязательна**: окно форсит `.preferredColorScheme(.light)` — иначе при тёмной теме
    macOS системные контролы (сегментер, меню-пикеры) рендерят **белый текст на белых карточках**.
    `.menu`-Picker всё равно прячет значение → свои `WispValueMenu`/`WispMenuPicker` (на `Menu` с явным тёмным значением).
    Скриншот окна в обход Stage Manager: `screencapture -o -l<CGWindowID>` (id — через `/tmp/winid.swift`).
  - **Settings — отдельное окно в стиле Wispr Flow** (`Window("Settings", id: "settings")`, открывается
    из главного sidebar через `openWindow` или ⌘,): свой category-sidebar (General/Appearance/AI/Dictionary/
    Data + версия), serif-заголовок, карточки `SettingsGroup` со строками `SettingRow` (заголовок+описание+
    контрол справа), чёрные тумблеры `WisprToggleStyle`. Settings убран из главного NavigationSplitView.
    (⚠️ `openWindow` внутри `CommandGroup` для ⌘, капризен — основной путь это пункт sidebar.)
  - **Режимы форматирования (Фаза 2)**: режим **Auto** (`EnhancementStyle.autoStyle` — формат по
    bundle id приложения), явный режим побеждает Auto; быстрый выбор — пилюля на Home + меню-бар «Mode».
  - **Локализация (Фаза 3)**: `App/Resources/Localizable.xcstrings` (en→ru, 89 ключей) + переключатель
    Settings → App Language (`appLanguage`: system/en/ru) через `.environment(\.locale)` — живое
    переключение; строки-переменные обёрнуты в `LocalizedStringKey(...)`. Осталось: плюрализация,
    onboarding, длинный хвост строк.

## Качество транскрипции / движки (2026-06-03)

Активный движок по умолчанию — **Parakeet (FluidAudio)** = тот же, что у VoiceInk
(native SpeechAnalyzer не скомпилирован — нет флага `ENABLE_NATIVE_SPEECH_ANALYZER`).
Сделано для приближения к VoiceInk:
- **VAD-гейтинг** (`DictationController` forward-цикл): в движок идёт только речь —
  ведущая/хвостовая/долгая тишина дропается (pre-roll 8 чанков ≈680мс + hangover EnergyVAD),
  чтобы Whisper не галлюцинировал на тишине. Тумблер **Settings → Transcription → Trim silence** (`useVAD`).
- **Тюнинг WhisperKit**: язык из локали + `chunkingStrategy: .vad`; пороги галлюцинаций
  (`compressionRatio`/`logProb`/`noSpeech`) уже в дефолтах `DecodingOptions`.
- **Прайминг словаря**: `TranscriptionOptions.vocabulary` ← канонические формы из `DictionaryStore`
  (через `vocabularyProvider`); WhisperKit использует как `promptTokens`. (Parakeet custom-vocab
  есть, но только через стриминговый `SlidingWindowAsrManager` — **не делали** из-за риска регрессии.)
- **Вставка**: уже была надёжной (буфер обмена сохраняется).
- **whisper.cpp** как выбираемый движок (SwiftWhisper, бандлит ggml/Metal). Модель `ggml-base`
  качается при первом запуске в `Application Support/whisp/Models`. Выбор: **Settings → Engine**
  (Auto / Parakeet / WhisperKit / whisper.cpp). Файловый путь декодирует через AVAudioConverter (не тестирован живьём).

## AI-улучшение текста (Фазы A/B/C, 2026-06-04)

Гибрид: транскрипция on-device, текст (не аудио) опционально полируется LLM. Применяется в
`textPostProcessor` (`WhispApp`).
- **A — форматирование (пресеты).** `EnhancementStyle`: Raw / Clean-up / Email / Chat / Code / Custom.
  Settings → AI Enhancement → Formatting. Дефолт **Clean-up** работает **без ключа** через `LocalTextCleaner`
  (режет только звуки-заминки um/uh/эм, чинит пробелы/регистр); остальные стили — через LLM.
- **B — Power Mode (стиль под приложение).** `PowerModeView` (слот сайдбара) + `AppEnhancementRule`
  (JSON в AppStorage `enhancementAppRules`). Диктуешь в приложение с правилом → его стиль; иначе глобальный.
  Цель = `NSWorkspace.frontmostApplication` в `textPostProcessor`.
- **C — Command Mode.** Settings-тумблер `commandModeEnabled`. Выделил текст → хоткей → говоришь
  инструкцию → выделение заменяется правкой LLM. `DictationController` читает выделение
  (`injector.readSelection()` = AX `kAXSelectedText`) на старте; есть выделение + флаг → режим `command`
  → `commandProcessor(команда, выделение)` → вставка. Нужен LLM-ключ.

## Открытые задачи / возможные шаги

- Прайминг словаря на **Parakeet** (риск: переписать рабочий бэкенд на `SlidingWindowAsrManager` — стриминг).
- Крупный swiftui-pro рефактор: вынос `some View`-свойств `DashboardView`/`SettingsView` в отдельные структуры.
- Иконка приложения в Stage Manager не обновляется без сброса системного кэша (`sudo rm -rf
  /Library/Caches/com.apple.iconservices.store` или ре-логин) — сама иконка применена корректно.
- Авто-ширина/hover-expand пилюли; динамический список моделей; Sparkle P4 (когда будут ключи/URL).

## Ключевые решения и подводные камни

- **Хоткей через Carbon `RegisterEventHotKey`** (permission-free), не CGEventTap:
  CGEventTap требует Input Monitoring и сбрасывается при ad-hoc пересборках. `⌥Space` — toggle.
- **CloudKit за рантайм-гейтом entitlement**: флаг `LOCAL_BUILD` не доходит до SPM-пакета,
  поэтому в `PersistenceController.makeContainer` проверка
  `SecTaskCopyValueForEntitlement("com.apple.developer.icloud-services")`. Debug — без CloudKit.
- **Сцена `Window("whisp", id:"main")`**, не `WindowGroup` (иначе «Open Window» плодит окна).
  `AppDelegate` активирует приложение на старте/реопене — иначе окно открывается за Xcode
  и видно только иконку в меню-баре.
- **Индикатор нотча в detached `NSPanel`**: `@Observable` не пробрасывается → main-runloop
  `Timer` + чтение свойств контроллера напрямую. И: **текст с градиентной заливкой не рисуется**
  в этой панели → таймер сделан сплошным зелёным (иконка/эквалайзер заливаются сплошным).
- **SwiftData**: мульти-стор контейнер; в тестах `@Suite(.serialized)` (иначе SIGSEGV
  на параллельном teardown контейнеров).
- **Верификация компилятором**: пишем лучший известный API → `swift build`/`xcodebuild` →
  чиним по реальному SDK (Xcode 26.5 / macOS 26.5 SDK, deploy target 14.4, Swift 6 strict concurrency).
- **API-ключи только в Keychain**, никогда в бэкапах/логах.
- **Вставка текста = ⌘V (paste), а не AX-set / синтез клавиш.** `kAXSelectedText` и
  `keyboardSetUnicodeString` молча не срабатывают в Warp/терминалах/Electron (статус «inserted», а
  текста нет). Инжектор активирует целевое приложение и вставляет через ⌘V (буфер сохраняется/восстанавливается).
- **Accessibility для вставки + стабильность гранта.** Вставка требует `AXIsProcessTrusted()`. Чтобы
  грант не слетал между сборками — приложение должно быть **в /Applications и подписано** (Apple
  Development cert). Из DerivedData/неподписанным TCC сбрасывается каждую сборку (`tccutil reset
  Accessibility com.example.whisp` чистит устаревшую запись). Цель вставки определяется на старте диктовки
  (`captureFocus`, + трекинг последнего не-whisp приложения). В дашборде — статус вставки и плашка Accessibility.
- **Фоновый режим.** `applicationShouldTerminateAfterLastWindowClosed → false` (+ MenuBarExtra) — ✕ не
  завершает. `AppDelegate.beginActivity` (на всё время жизни) + `.latencyCritical` на время записи
  + «хвост» 300мс перед `capturer.stop()` (чтобы не терять конец фразы) — иначе фон душит анимацию/захват.
- **Нотч-пилюля независима от окна.** `NotchRecorderController.observe(controller)` через
  `withObservationTracking` (а не `.onChange` во вью окна) — иначе при закрытии окна пилюля переставала обновляться.
- **Мультиязык.** `TranscriptionOptions.pinnedLanguageCode` = код только при 1 выбранном языке, иначе `nil`
  → авто-детект. Code-switching внутри одной фразы модели не вытягивают (англ. слово в рус. фразе → кириллица).

## Переименование VoiceInk → whisp (2026-06-03)

Полный рефактор: 6 модулей (`WhispCore…`), 5 тест-таргетов, app-таргет/проект/схема `whisp`,
пакет `Whisp`, видимое имя `whisp` (строчными). Bundle id `com.example.whisp`.

**Побочки смены bundle id (новый bundle = «другое» приложение для системы):**
- сброс настроек (новый домен UserDefaults): онбординг заново, хоткей → `⌥Space`, язык/провайдер по умолчанию;
- keychain-сервис переименован (`…voiceink.secrets → …whisp.secrets`) → **API-ключи ввести заново** в Settings;
- микрофон может переспросить разрешение при первой диктовке.

## Ограничения окружения разработки

- Скриншоты/запись экрана из терминала заблокированы TCC; запустить диктовку «headless»
  нельзя → **визуальные проверки и саму диктовку (`⌥Space`) выполняет пользователь** (⌘R / запуск бандла).
- Проект **не** под git (на момент написания).
