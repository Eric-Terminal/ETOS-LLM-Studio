# ETOS LLM Studio

![Swift](https://img.shields.io/badge/Swift-FA7343?style=flat-square&logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20watchOS-blue?style=flat-square&logo=apple&logoColor=white)
![License](https://img.shields.io/badge/License-GPLv3-0052CC?style=flat-square)
![Build](https://img.shields.io/badge/Build-Passing-44CC11?style=flat-square)

**Нативный AI‑клиент для iOS и Apple Watch. Поддерживает OpenAI, Anthropic Claude, Google Gemini, совместимых провайдеров, вызов MCP‑инструментов, локальную RAG‑память, Worldbook, Daily Pulse, Siri Shortcuts и синхронизацию между устройствами.**

[简体中文](../../README.md) | [English](README_EN.md) | [繁體中文](README_ZH_HANT.md) | [日本語](README_JA.md)

---

## 📸 Скриншоты

| | |
|:---:|:---:|
| <img src="../../assets/screenshots/screenshot-01.png" width="300"> | <img src="../../assets/screenshots/screenshot-02.png" width="300"> |

---

## 👋 Вступление

В школе часто скучно, а вопросов к AI всегда слишком много. Когда я смотрела на приложения в App Store, почти все были либо слишком дорогими, либо слишком урезанными — особенно на Apple Watch. Поэтому я просто решила сделать своё.

Изначально это был маленький эксперимент: около 1 800 строк и даже захардкоженные API‑ключи. Сейчас проект вырос до **235 Swift‑файлов и 118 070 строк кода** (Shared / iOS / watchOS / tests). Название «ETOS LLM Studio» звучит громко, но по сути это всё ещё мой полигон для экспериментов с LLM‑приложениями.

Раньше это был почти чисто watch‑проект, а теперь iOS‑часть тоже стала полноценной: модели, инструменты, память, worldbook, Daily Pulse и синхронизация между устройствами в одном приложении.

### Ключевые возможности

#### Чат и модели

*   **Нативно на двух платформах**: iOS и Apple Watch с единым стилем и адаптированным UX.
*   **Расширенное управление чатами**: полнотекстовый поиск, переход к сообщению по номеру, папки, массовое перемещение и отправка отдельного чата между устройствами.
*   **Поддержка нескольких провайдеров**: OpenAI, Anthropic (Claude), Google (Gemini) и совместимые форматы API.
*   **Расширенная настройка запросов**: кастомные заголовки, выражения параметров, raw JSON body.
*   **Мультимодальность и генерация изображений**: голосовой и графический ввод + AI image generation.
*   **Импорт и экспорт чатов**: импорт из Cherry Studio, RikkaHub, Kelivo, ChatGPT conversations и экспорт в PDF / Markdown / TXT.
*   **Голосовой ввод (STT)**: потоковое распознавание через `SFSpeechRecognizer` с отображением текста в реальном времени.
*   **Озвучивание (TTS)**: системный TTS, облачный TTS и автоматический fallback с отдельными настройками.

#### Отображение и чтение

*   **Гибкая система отображения**: пользовательские шрифты (включая WOFF / WOFF2), приоритеты слотов шрифтов, цвета пузырей/текста и bubbleless UI.
*   **Стратегия fallback-шрифтов**: выбор диапазона fallback на уровне абзаца и символа для стабильного смешанного текста.
*   **Предпросмотр мыслей и контента**: автопредпросмотр мыслей включён по умолчанию.
*   **Улучшенный Markdown и кодовые блоки**: подсветка синтаксиса, feedback при копировании, сворачивание, предпросмотр кода на iOS, Mermaid и стиль цитат с вертикальной линией.

#### Инструменты и автоматизация

*   **Tool Center + Extended Tools**: единое управление MCP / Shortcuts / локальными инструментами, политики подтверждения и переключатели на уровне сессии.
*   **Agent Skills**: сквозная интеграция навыков, управление в Tool Center, импорт из файла (iOS) и по URL (watchOS).
*   **Структурированный опрос (`ask_user_input`)**: пошаговый режим «вопрос за вопросом», правила single/multi choice, кастомный ввод и возврат к предыдущему вопросу.
*   **Расширение набора инструментов**: добавлены SQLite CRUD, отображение web-карточек и автоотправка тикетов обратной связи.
*   **Инструменты файловой песочницы**: поиск, чтение чанками, diff, частичное редактирование, перемещение / копирование / удаление.
*   **Интеграция MCP**: полноценный клиент [Model Context Protocol](https://modelcontextprotocol.io), Streamable HTTP/SSE, reconnect, timeout, handshake и capability negotiation.
*   **Siri Shortcuts**: вызов AI через Shortcuts, кастомные инструменты и URL Scheme роутинг.
*   **Встроенный файловый менеджер**: просмотр и управление sandbox‑файлами прямо в приложении.

#### Память и организация знаний

*   **Локальная RAG‑память**: embeddings могут быть облачными, но **векторная БД полностью локальная (SQLite)**.
*   **Реляционное хранение на GRDB**: основная персистентность мигрирована с JSON на GRDB + SQLite для сессий, настроек, MCP, worldbook, памяти, feedback и shortcuts.
*   **Worldbook**: система в стиле Lorebook (как в SillyTavern) с условными триггерами, session‑изоляцией и импортом.
*   **Совместимость форматов**: PNG naidata, JSON top-level array, `character_book`.
*   **Логи запросов и аналитика скорости**: отдельные request logs, token summary и метрики streaming‑ответов.
*   **Расширенный рендеринг**: Markdown, подсветка кода, таблицы, LaTeX.

#### Daily Pulse

*   **Ежедневные proactive‑карточки**: подбор «что стоит посмотреть сегодня» до ручного запроса.
*   **Pulse‑задачи**: карточки превращаются в follow‑up задачи, незавершённые переносятся на следующие дни.
*   **Обучение на feedback‑истории**: лайки/дизлайки/скрытия/сохранения влияют на будущие результаты.
*   **Утренние уведомления и continue chat**: напоминания по расписанию, быстрые действия из уведомления, сохранение в сессию и продолжение диалога на iOS/watchOS.

#### Синхронизация, отладка и эксплуатация

*   **Синхронизация iOS ↔ watchOS**: провайдеры, сессии, worldbook, настройки инструментов, Daily Pulse и другое, плюс основной контур Manifest/Delta синхронизации.
*   **Синхронизация и резервирование**: экспорт/импорт ETOS‑пакетов, полный импорт на watchOS, резервная копия при запуске и самовосстановление при повреждении, а также прямой POST загрузки пакетов на пользовательский endpoint.
*   **Feedback Assistant в приложении**: категории обратной связи, сбор окружения, PoW‑цепочка отправки, синхронизация между платформами.
*   **Поддержка прокси**: глобальный и per‑provider HTTP(S)/SOCKS прокси с авторизацией.
*   **Feedback Center и уведомления**: комментарии внутри тикета, отметка ответов разработчика, автообновление статуса и переход из high‑priority уведомлений.
*   **LAN‑отладка**: клиент отладки + Go‑сервис + встроенная web‑консоль для управления файлами и сессиями через браузер.
*   **Локализация**: 8 языков — English, 简体中文, 繁體中文（香港）, 日本語, Русский, Français, Español, العربية.

---

## 💸 О цене и открытом коде

Изначально я хотела сделать приложение полностью бесплатным.
Но программа Apple Developer стоит $99 в год, и для студента это заметная сумма.

Позже инвестор помог оплатить подписку, а я должна возвращать затраты через продажи приложения (с долей от выручки). Поэтому версия в App Store платная, но символически.

**Открытый исходный код для меня принципиален.**

Поэтому всё просто:
1.  **Хотите удобство / поддержать проект**: используйте версию из App Store.
2.  **Хотите бесплатно и с полной свободой**: код здесь, лицензия GPLv3, можно собрать самостоятельно на Mac + Xcode без функциональных ограничений.
3.  **Хотите попробовать самую свежую сборку**: TestFlight 👉 [https://testflight.apple.com/join/d4PgF4CK](https://testflight.apple.com/join/d4PgF4CK)

---

## 🛠️ Технологии

*   **Язык**: Swift 6
*   **UI**: SwiftUI
*   **Архитектура**: MVVM + Protocol Oriented Programming
*   **Данные**: GRDB + SQLite (основная персистентность сессий / настроек / памяти и локальная векторная БД), JSON (форматы импорта/экспорта и совместимости)
*   **Сеть и транспорт**: URLSession, Streamable HTTP / SSE (MCP), WebSocket / HTTP polling (LAN‑отладка)
*   **AI‑протокол**: Model Context Protocol (MCP)
*   **Системные интеграции**: Siri Shortcuts, WatchConnectivity, UserNotifications, BackgroundTasks (iOS)
*   **Зависимости**: Swift Package Manager (`GRDB.swift`, `swift-markdown-ui` + transitives `networkimage`, `swift-cmark`)

---

## 🏗️ Архитектура проекта

Проект разделён на два уровня: платформенно‑независимый Shared и отдельные UI‑слои для каждой платформы.

```
Shared/Shared/                  ← Общая бизнес-логика (87 Swift-файлов)
├── ChatService.swift            ← Центральный singleton для сессий, сообщений, выбора модели и оркестрации запросов
├── APIAdapter.swift             ← Адаптеры API (OpenAI / Anthropic / Gemini и совместимые форматы)
├── Models.swift                 ← Основные модели данных
├── Persistence.swift            ← Точка входа хранилища, запуск миграций и координация жизненного цикла
├── PersistenceGRDBStore.swift   ← Ядро реляционной персистентности на GRDB
├── DailyPulse.swift             ← Движок Daily Pulse, карточки, feedback и задачи
├── DailyPulseDeliveryCoordinator.swift ← Утренние уведомления, состояние доставки и подготовка
├── Memory/                      ← Подсистема памяти (чанки, embeddings, storage)
├── SimilaritySearch/            ← Локальная векторная БД (SQLite)
├── MCP/                         ← Клиент и транспорт Model Context Protocol
├── Feedback/                    ← Встроенный feedback-модуль (сбор, подпись, хранение, отправка)
├── Worldbook/                   ← Движок worldbook, импорт/экспорт
├── Sync/                        ← Движок синхронизации iOS ↔ watchOS
├── TTS/                         ← Озвучивание, настройки и пресеты
├── Shortcuts/                   ← Интеграция Siri Shortcuts и URL-роутера
├── AppToolManager.swift         ← Управление локальными инструментами и каталогом инструментов
├── StorageBrowserSupport.swift  ← Поддержка просмотра и управления файлами
└── LocalDebugServer.swift       ← Клиент LAN-отладки

ETOS LLM Studio/ETOS LLM Studio iOS App/    ← UI-слой iOS (44 Swift-файла)
ETOS LLM Studio/ETOS LLM Studio Watch App/  ← UI-слой watchOS (47 Swift-файлов)
Shared/SharedTests/                         ← Тесты Shared-слоя (54 Swift-файла)
```

Поток данных: `View → ChatViewModel → ChatService.shared → APIAdapter → LLM API`, UI обновляется через Combine subjects.

---

## 🚀 Сборка

1.  **Клонируйте проект**:
    ```bash
    git clone https://github.com/Eric-Terminal/ETOS-LLM-Studio.git
    ```
2.  **Требования**:
    *   Xcode 26.0+
    *   watchOS 26.0+ SDK
3.  **Откройте проект**:
    `ETOS LLM Studio.xcworkspace` (именно workspace, не xcodeproj).
    При первом открытии Xcode автоматически подтянет Swift Package зависимости.
4.  **Запуск**:
    Выберите target `ETOS LLM Studio Watch App` или `ETOS LLM Studio iOS App`, подключите устройство/симулятор и нажмите Command + R.
5.  **Настройка**:
    Добавьте API key в настройках. Для удобства можно через LAN Debugging отправить готовый JSON в `Documents/Providers/`.

---

## 📬 Контакты

*   **Разработчик**: Eric Terminal
*   **Email**: ericterminal@gmail.com
*   **GitHub**: [Eric-Terminal](https://github.com/Eric-Terminal)

---

Этот README обновлён 18 апреля 2026 года (после 31d1e21). Если README не успел за кодом, смотрите историю коммитов.
