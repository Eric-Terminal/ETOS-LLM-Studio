// 多语言文案中心
//
// 维护原则：
// 1. 文案以「短句、主动语态」为先，避免营销八股。
// 2. 中文与繁中分离，因为词汇/动词偏好不一致。
// 3. 任何 UI 字符串都从这里读，禁止把语言串硬编码进组件。

export const LANG_LIST = [
  { code: 'zh', name: '简体中文' },
  { code: 'en', name: 'English' },
  { code: 'ja', name: '日本語' },
  { code: 'ru', name: 'Русский' },
  { code: 'zh-Hant', name: '繁體中文' }
];

const zh = {
  meta: {
    title: 'ETOS LLM Studio',
    subtitle: 'iPhone + Apple Watch 原生 AI 客户端'
  },
  nav: {
    features: '功能',
    personalize: '个性化',
    privacy: '隐私',
    tech: '技术',
    docs: '文档',
    github: 'GitHub',
    download: '获取 App'
  },
  hero: {
    title: '你的 AI，揣在手里，戴在腕上。',
    lead:
      '运行在 iPhone 与 Apple Watch 上的原生 LLM 客户端。你的 Key、你的数据，从设备直接发往模型，没有中间服务器。',
    actionsPrimary: '轻松上手',
    actionsSecondary: '查看功能模块',
    statusOnline: '正在维护中',
    statusBadge: 'BUILT FOR APPLE PLATFORMS'
  },
  personalize: {
    title: '一眼认得出，是你的 Studio。',
    lead: '上传一张壁纸、挑一个对话框颜色、要不要 AI 气泡——右边这台实时跟着变。',
    pickerHint: '调下面三项，右侧实时预览',
    wallpaperLabel: '背景图层',
    wallpaperAction: '选择背景图',
    colorLabel: '颜色配置',
    hideBubbleLabel: '关闭助手气泡',
    reset: '恢复默认',
    chat: {
      title: '问候与帮助',
      user: '你好',
      bot: '你好！👋\n很高兴见到你，有什么想聊的或者需要帮忙的吗？无论是图片处理、海报设计、提示词编写、角色设定，还是其他问题，都可以直接告诉我。',
      placeholder: '输入消息…'
    }
  },
  features: {
    title: '不是套壳。是把模型当 Apple 平台公民来设计。',
    lead: '主界面只留聊天，其余全部收进设置。下面这些是你装好之后会陆续找到的能力。',
    items: [
      {
        kicker: '01 / CHAT',
        title: '多模型 · 多 Provider · 兼容到底',
        body:
          '原生适配 OpenAI Chat、OpenAI Responses、Anthropic、Gemini，外加任意 OpenAI 兼容接口。支持多 Key 轮询、参数表达式、原始 JSON 请求体、提供商级 / 全局两层代理。',
        tags: ['OpenAI', 'Claude', 'Gemini', 'Custom']
      },
      {
        kicker: '02 / TOOLS',
        title: 'MCP · Skills · 快捷指令',
        body:
          '工具中心统一管理 MCP 服务器、Agent Skills 技能包、iOS 快捷指令、内置工具。支持会话级启用、审批策略、流式调试与连线时间线。',
        tags: ['MCP', 'Skills', 'Shortcuts', '审批策略']
      },
      {
        kicker: '03 / MEMORY',
        title: '长期记忆 · 世界书 · 用户画像',
        body:
          '跨会话的事实记忆、关键词触发的世界书条目、模型可读的用户画像。本地向量索引，离线可用，可与每日脉冲联动。',
        tags: ['长期记忆', '世界书', '本地 RAG']
      },
      {
        kicker: '04 / DAILY PULSE',
        title: '主动情报，不是被动问答',
        body:
          '按你设定的节奏自动生成情报卡片：新闻、邮件提醒、日程预判、技术摘要。Watch 端会在抬腕时呈现，错过的可在 iPhone 端回看。',
        tags: ['定时', '情报卡片', 'Watch 抬腕']
      },
      {
        kicker: '05 / SYNC',
        title: 'iPhone ↔ Watch 局域网直连同步',
        body:
          '不走服务器、不走 iCloud（除非你愿意）。双端通过 WatchConnectivity 与本地点对点协议互传，SQLCipher 全盘加密，可导出 ETOS 数据包随时迁移。',
        tags: ['WatchConnectivity', 'SQLCipher', 'ETOS 数据包']
      },
      {
        kicker: '06 / WATCH',
        title: '手腕上的完整体验，不是阉割版',
        body:
          '数码表冠缩放图片、Markdown 与代码高亮、思考时间线、TTS 朗读、单会话跨端发送。watchOS 设置扁平化为单层 List，零 TabView。',
        tags: ['watchOS', '数码表冠', '抬腕语音']
      }
    ]
  },
  screenshots: {
    title: '看看它在你手里是什么样。',
    lead: '截图直接来自当前版本。',
    captionOne: 'iOS · 聊天主界面',
    captionTwo: 'Apple Watch · 单会话回看'
  },
  privacy: {
    title: '你的 Key，你的数据，你的设备。',
    lead:
      '没有任何中间服务器。模型请求从你的设备直接发出，对话存在本机 SQLite（SQLCipher 加密），同步通过 iPhone 与 Watch 在局域网内完成。要不要上 CloudKit、要不要交给第三方，全是你的选择。',
    bullets: [
      { kicker: 'BYOK', title: '你提供 Key，App 直发模型', body: '我们不代付、不转发、不缓存你的请求。' },
      { kicker: 'LOCAL FIRST', title: '会话与记忆存在本机', body: 'SQLCipher 全盘加密，可应用锁 + Face ID 双重门。' },
      { kicker: 'EXPORTABLE', title: 'ETOS 数据包，随时拎走', body: '一键导出/导入，迁移设备不是难题。' },
      { kicker: 'OPEN SOURCE', title: 'GPLv3 开源', body: '代码可审计，PR 与 Issue 都欢迎。' }
    ]
  },
  tech: {
    title: '用原生工具，做原生体验。',
    lead: '没有 Electron，没有 React Native，没有 WebView 套壳。快速，性能超强。',
    items: [
      { name: 'Swift 6 · SwiftUI', desc: 'iOS 18 + watchOS 11 原生 UI，遵循 Apple HIG。' },
      { name: 'GRDB · SQLCipher', desc: '加密 SQLite + ValueObservation 响应式查询。' },
      { name: 'WatchConnectivity', desc: '双端低延迟同步，无中间服务器。' },
      { name: 'Background Tasks', desc: 'Daily Pulse 在后台预生成，抬腕即看。' },
      { name: 'SF Symbols 6', desc: '原生图标体系，与系统视觉一致。' },
      { name: 'App Intents', desc: 'Siri 快捷指令与 Spotlight 深度集成。' }
    ]
  },
  cta: {
    title: '十分钟跑通第一条对话。',
    lead: '装机、配 Provider、第一条消息，每一步都告诉你点哪里。',
    primary: '阅读上手教程',
    secondary: 'GitHub 源码',
    secondaryDesc: '欢迎 Star、Issue、PR。'
  },
  footer: {
    madeBy: 'Made with care by',
    author: 'Eric-Terminal',
    license: 'GPL-3.0 License',
    repo: 'github.com/Eric-Terminal/ETOS-LLM-Studio',
    docs: '文档站',
    backToTop: '回到顶部'
  },
  loader: {
    kicker: 'HELLO FROM ETOS',
    line: 'BOOTING LANDING',
    year: '2026'
  },
  ui: {
    theme: { light: '浅色', dark: '深色' },
    langHint: '选择你顺手的语言。'
  }
};

const en = {
  meta: {
    title: 'ETOS LLM Studio',
    subtitle: 'A native AI client for iPhone + Apple Watch'
  },
  nav: {
    features: 'Features',
    personalize: 'Personalize',
    privacy: 'Privacy',
    tech: 'Stack',
    docs: 'Docs',
    github: 'GitHub',
    download: 'Get the App'
  },
  hero: {
    title: 'AI in your pocket. And on your wrist.',
    lead:
      'A native LLM client that runs on iPhone and Apple Watch. Your key, your data — straight from device to model. No middle server.',
    actionsPrimary: 'Read the quickstart',
    actionsSecondary: 'See the modules',
    statusOnline: 'In active development',
    statusBadge: 'BUILT FOR APPLE PLATFORMS'
  },
  personalize: {
    title: 'Unmistakably yours.',
    lead: 'Upload a wallpaper, pick a bubble color, keep or drop the AI bubble — the phone on the right updates live.',
    pickerHint: 'Tweak these three; preview on the right',
    wallpaperLabel: 'Background Layer',
    wallpaperAction: 'Select background image',
    colorLabel: 'Color profiles',
    hideBubbleLabel: 'Hide Assistant Bubbles',
    reset: 'Reset to default',
    chat: {
      title: 'Greetings & Help',
      user: 'Hi',
      bot: "Hi! 👋\nGreat to meet you — anything you'd like to chat about or need a hand with? Image editing, poster design, prompt writing, character setup, or anything else, just tell me.",
      placeholder: 'Message'
    }
  },
  features: {
    title: "Not a wrapper. A native Apple-platform citizen.",
    lead: 'The main view is just chat. Everything else lives in Settings. Here is what you will gradually find.',
    items: [
      {
        kicker: '01 / CHAT',
        title: 'Multi-model · Multi-provider · Compatible to the end',
        body:
          'Native support for OpenAI Chat, OpenAI Responses, Anthropic, Gemini, plus any OpenAI-compatible endpoint. Key rotation, parameter expressions, raw JSON body, two-layer proxy.',
        tags: ['OpenAI', 'Claude', 'Gemini', 'Custom']
      },
      {
        kicker: '02 / TOOLS',
        title: 'MCP · Skills · Shortcuts',
        body:
          'A single tool hub unifies MCP servers, Agent Skills, iOS Shortcuts, and built-ins. Per-session toggles, approval policy, streaming debug, and a tool-call timeline.',
        tags: ['MCP', 'Skills', 'Shortcuts', 'Approval']
      },
      {
        kicker: '03 / MEMORY',
        title: 'Long-term memory · Worldbook · User profile',
        body:
          'Cross-session facts, keyword-triggered worldbook entries, a model-readable user profile. Local vector index, works offline, plugs into Daily Pulse.',
        tags: ['Memory', 'Worldbook', 'Local RAG']
      },
      {
        kicker: '04 / DAILY PULSE',
        title: 'Proactive briefing, not passive Q&A',
        body:
          'Cards generated on your schedule: news, mail nudges, calendar prep, tech digests. Watch shows them on raise; iPhone keeps the backlog.',
        tags: ['Scheduled', 'Cards', 'Raise to view']
      },
      {
        kicker: '05 / SYNC',
        title: 'iPhone ↔ Watch over LAN',
        body:
          'No server, no iCloud (unless you opt in). Peer-to-peer over WatchConnectivity and local protocols. SQLCipher full-disk encryption. Export an ETOS bundle to migrate.',
        tags: ['WatchConnectivity', 'SQLCipher', 'ETOS bundle']
      },
      {
        kicker: '06 / WATCH',
        title: 'A complete experience on the wrist — not a crippled one',
        body:
          'Digital Crown zoom, Markdown + code highlighting, thinking timeline, TTS readout, cross-device send. watchOS settings stay flat — one List, no TabView.',
        tags: ['watchOS', 'Digital Crown', 'Voice']
      }
    ]
  },
  screenshots: {
    title: 'See what it looks like in your hand.',
    lead: 'Screens are from the current build.',
    captionOne: 'iOS · Chat',
    captionTwo: 'Apple Watch · Session view'
  },
  privacy: {
    title: 'Your key. Your data. Your device.',
    lead:
      'ETOS runs no server of its own. Requests go from your device straight to the model. Chats live in local SQLite (SQLCipher). Sync happens over your LAN between iPhone and Watch. CloudKit? Third-party? Only if you choose.',
    bullets: [
      { kicker: 'BYOK', title: 'You bring the key', body: 'We never proxy, cache, or bill your requests.' },
      { kicker: 'LOCAL FIRST', title: 'Chats live on device', body: 'SQLCipher encryption + app lock with Face ID.' },
      { kicker: 'EXPORTABLE', title: 'Take the data with you', body: 'One-click ETOS bundle export/import for migrations.' },
      { kicker: 'OPEN SOURCE', title: 'GPLv3, auditable', body: 'Code is open. PRs and issues welcome.' }
    ]
  },
  tech: {
    title: 'Native tools for a native feel.',
    lead: 'No Electron. No React Native. No WebView shell.',
    items: [
      { name: 'Swift 6 · SwiftUI', desc: 'iOS 18 + watchOS 11, true to Apple HIG.' },
      { name: 'GRDB · SQLCipher', desc: 'Encrypted SQLite with reactive ValueObservation.' },
      { name: 'WatchConnectivity', desc: 'Low-latency sync. No middle server.' },
      { name: 'Background Tasks', desc: 'Daily Pulse pre-renders in the background.' },
      { name: 'SF Symbols 6', desc: 'Stays visually consistent with the system.' },
      { name: 'App Intents', desc: 'Deep Siri Shortcuts and Spotlight hooks.' }
    ]
  },
  cta: {
    title: 'First chat in ten minutes.',
    lead: 'From install to first reply, every step tells you where to tap.',
    primary: 'Read the quickstart',
    secondary: 'Source on GitHub',
    secondaryDesc: 'Stars, issues and PRs welcome.'
  },
  footer: {
    madeBy: 'Made with care by',
    author: 'Eric-Terminal',
    license: 'GPL-3.0 License',
    repo: 'github.com/Eric-Terminal/ETOS-LLM-Studio',
    docs: 'Docs',
    backToTop: 'Back to top'
  },
  loader: {
    kicker: 'HELLO FROM ETOS',
    line: 'BOOTING LANDING',
    year: '2026'
  },
  ui: {
    theme: { light: 'Light', dark: 'Dark' },
    langHint: 'Pick the language you prefer.'
  }
};

const ja = {
  meta: {
    title: 'ETOS LLM Studio',
    subtitle: 'iPhone と Apple Watch のためのネイティブ AI クライアント'
  },
  nav: {
    features: '機能',
    personalize: 'カスタマイズ',
    privacy: 'プライバシー',
    tech: '技術',
    docs: 'ドキュメント',
    github: 'GitHub',
    download: 'App を入手'
  },
  hero: {
    title: 'AI をポケットに、そして手首に。',
    lead:
      'iPhone と Apple Watch 上で動くネイティブ LLM クライアント。あなたの Key、あなたのデータが、デバイスから直接モデルへ。中継サーバーはありません。',
    actionsPrimary: 'クイックスタートを読む',
    actionsSecondary: '機能モジュール',
    statusOnline: '開発中',
    statusBadge: 'BUILT FOR APPLE PLATFORMS'
  },
  personalize: {
    title: 'ひと目で分かる、あなたの Studio。',
    lead: '壁紙をアップロード、バブルの色を選ぶ、AI バブルの有無——右のスマホがリアルタイムで反映します。',
    pickerHint: '下の3項目を調整、右でプレビュー',
    wallpaperLabel: '背景レイヤー',
    wallpaperAction: '背景画像を選択',
    colorLabel: 'カラープロファイル',
    hideBubbleLabel: 'アシスタントの吹き出しを非表示',
    reset: 'デフォルトに戻す',
    chat: {
      title: 'あいさつとヘルプ',
      user: 'こんにちは',
      bot: 'こんにちは！👋\nお会いできてうれしいです。話したいことや、お手伝いできることはありますか？画像処理、ポスターデザイン、プロンプト作成、キャラクター設定、その他なんでも、気軽にどうぞ。',
      placeholder: 'メッセージ'
    }
  },
  features: {
    title: 'ガワだけではない。Apple プラットフォームの一員として設計。',
    lead: 'メイン画面はチャットのみ。残りはすべて設定に。インストール後に少しずつ見つかる機能たちです。',
    items: [
      {
        kicker: '01 / CHAT',
        title: 'マルチモデル · マルチプロバイダ · どこまでも互換',
        body:
          'OpenAI Chat / Responses、Anthropic、Gemini にネイティブ対応。任意の OpenAI 互換 API も。Key ローテーション、パラメータ式、生 JSON ボディ、二層プロキシ。',
        tags: ['OpenAI', 'Claude', 'Gemini', 'カスタム']
      },
      {
        kicker: '02 / TOOLS',
        title: 'MCP · Skills · ショートカット',
        body:
          '統合ツールセンターが MCP サーバー、Agent Skills、iOS ショートカット、組み込みツールを一括管理。会話単位の ON/OFF、承認ポリシー、ストリーミングデバッグ。',
        tags: ['MCP', 'Skills', 'Shortcuts', '承認']
      },
      {
        kicker: '03 / MEMORY',
        title: '長期記憶 · ワールドブック · ユーザープロファイル',
        body:
          '会話をまたぐ事実、キーワードでトリガーされるワールドブック、モデルが読めるプロファイル。ローカルベクター検索、オフライン可、Daily Pulse 連携。',
        tags: ['長期記憶', 'ワールドブック', 'ローカル RAG']
      },
      {
        kicker: '04 / DAILY PULSE',
        title: '受け身ではなく、先回り。',
        body:
          'スケジュールに沿ってカードを自動生成：ニュース、メールリマインダ、予定の前準備、技術ダイジェスト。Watch では手首を上げると表示。',
        tags: ['スケジュール', 'カード', '抬腕']
      },
      {
        kicker: '05 / SYNC',
        title: 'iPhone ↔ Watch を LAN で直結同期',
        body:
          'サーバー経由なし、iCloud も任意。WatchConnectivity と P2P プロトコルで双方向。SQLCipher 全体暗号化、ETOS バンドルで持ち運び可。',
        tags: ['WatchConnectivity', 'SQLCipher', 'ETOS バンドル']
      },
      {
        kicker: '06 / WATCH',
        title: '手首でもフル体験。簡易版ではありません。',
        body:
          'デジタルクラウンでズーム、Markdown とコードハイライト、思考タイムライン、TTS、双方向送信。watchOS の設定は単層 List のみ、TabView は使いません。',
        tags: ['watchOS', 'デジタルクラウン', '音声入力']
      }
    ]
  },
  screenshots: {
    title: '実機での姿を、そのまま。',
    lead: '現行ビルドからのスクリーンショット。',
    captionOne: 'iOS · チャット',
    captionTwo: 'Apple Watch · 会話ビュー'
  },
  privacy: {
    title: 'あなたの Key、データ、デバイス。',
    lead:
      'ETOS は自前のサーバーを持ちません。リクエストはデバイスから直接モデルへ。会話はローカル SQLite に SQLCipher で暗号化保存。同期は iPhone と Watch の LAN 直結。CloudKit や第三者連携は完全にオプトインです。',
    bullets: [
      { kicker: 'BYOK', title: 'Key はあなたが用意', body: 'こちらでプロキシも、キャッシュも、課金もしません。' },
      { kicker: 'LOCAL FIRST', title: 'チャットは端末内', body: 'SQLCipher 暗号化 + Face ID アプリロック。' },
      { kicker: 'EXPORTABLE', title: 'ETOS バンドルで持ち運び', body: '機種変更時もワンクリックで移行可能。' },
      { kicker: 'OPEN SOURCE', title: 'GPLv3 オープンソース', body: 'コードは監査可能。PR と Issue を歓迎。' }
    ]
  },
  tech: {
    title: 'ネイティブの道具で、ネイティブの感触を。',
    lead: 'Electron も React Native も WebView ガワもありません。',
    items: [
      { name: 'Swift 6 · SwiftUI', desc: 'iOS 18 + watchOS 11 のネイティブ UI、HIG 準拠。' },
      { name: 'GRDB · SQLCipher', desc: '暗号化 SQLite と ValueObservation。' },
      { name: 'WatchConnectivity', desc: '低遅延同期。中継サーバーなし。' },
      { name: 'Background Tasks', desc: 'Daily Pulse はバックグラウンドで事前生成。' },
      { name: 'SF Symbols 6', desc: 'システムの視覚と整合。' },
      { name: 'App Intents', desc: 'Siri ショートカットと Spotlight 連携。' }
    ]
  },
  cta: {
    title: '10 分で最初の会話を。',
    lead: 'インストールから初回返信まで、どこを押すか毎ステップ明示します。',
    primary: 'クイックスタート',
    secondary: 'GitHub ソース',
    secondaryDesc: 'Star・Issue・PR お待ちしています。'
  },
  footer: {
    madeBy: 'Made with care by',
    author: 'Eric-Terminal',
    license: 'GPL-3.0 ライセンス',
    repo: 'github.com/Eric-Terminal/ETOS-LLM-Studio',
    docs: 'ドキュメント',
    backToTop: 'トップへ戻る'
  },
  loader: {
    kicker: 'HELLO FROM ETOS',
    line: 'BOOTING LANDING',
    year: '2026'
  },
  ui: {
    theme: { light: 'ライト', dark: 'ダーク' },
    langHint: 'お好みの言語をどうぞ。'
  }
};

const ru = {
  meta: {
    title: 'ETOS LLM Studio',
    subtitle: 'Нативный AI-клиент для iPhone и Apple Watch'
  },
  nav: {
    features: 'Возможности',
    personalize: 'Оформление',
    privacy: 'Приватность',
    tech: 'Стек',
    docs: 'Документация',
    github: 'GitHub',
    download: 'Получить'
  },
  hero: {
    title: 'AI в кармане. И на запястье.',
    lead:
      'Нативный LLM-клиент для iPhone и Apple Watch. Ваш ключ, ваши данные — с устройства напрямую в модель. Никакого посредника.',
    actionsPrimary: 'Краткое руководство',
    actionsSecondary: 'Модули',
    statusOnline: 'В активной разработке',
    statusBadge: 'BUILT FOR APPLE PLATFORMS'
  },
  personalize: {
    title: 'Безошибочно ваша Studio.',
    lead: 'Загрузите обои, выберите цвет пузыря, оставьте или уберите пузырь ИИ — телефон справа меняется вживую.',
    pickerHint: 'Настройте три пункта, превью справа',
    wallpaperLabel: 'Слой фона',
    wallpaperAction: 'Выбрать фоновое изображение',
    colorLabel: 'Цветовые профили',
    hideBubbleLabel: 'Скрыть пузыри ассистента',
    reset: 'Сбросить',
    chat: {
      title: 'Приветствие и помощь',
      user: 'Привет',
      bot: 'Привет! 👋\nРад знакомству! О чём хотите поговорить или с чем помочь? Обработка изображений, дизайн постеров, написание промптов, создание персонажей или что-то ещё — просто скажите.',
      placeholder: 'Сообщение'
    }
  },
  features: {
    title: 'Не обёртка. Гражданин платформы Apple.',
    lead: 'Главный экран — только чат. Всё остальное живёт в «Настройках». Вот что вы найдёте, когда поставите.',
    items: [
      {
        kicker: '01 / CHAT',
        title: 'Много моделей · Много провайдеров · Совместимость до конца',
        body:
          'Нативная поддержка OpenAI Chat / Responses, Anthropic, Gemini и любых OpenAI-совместимых API. Ротация ключей, выражения параметров, сырое JSON-тело, двухслойный прокси.',
        tags: ['OpenAI', 'Claude', 'Gemini', 'Custom']
      },
      {
        kicker: '02 / TOOLS',
        title: 'MCP · Skills · Shortcuts',
        body:
          'Единый центр инструментов: MCP-серверы, Agent Skills, iOS Shortcuts, встроенные. Включение по сессии, политика одобрения, отладка потока.',
        tags: ['MCP', 'Skills', 'Shortcuts', 'Approval']
      },
      {
        kicker: '03 / MEMORY',
        title: 'Долгая память · Worldbook · Профиль',
        body:
          'Факты между сессиями, записи Worldbook по триггерам, читаемый моделью профиль. Локальный векторный индекс, оффлайн, интеграция с Daily Pulse.',
        tags: ['Память', 'Worldbook', 'Local RAG']
      },
      {
        kicker: '04 / DAILY PULSE',
        title: 'Не пассивные ответы — проактивные карточки',
        body:
          'Карточки по вашему расписанию: новости, напоминания о почте, подготовка к встречам, технологические дайджесты. Watch показывает при поднятии руки.',
        tags: ['Расписание', 'Карточки', 'Raise to view']
      },
      {
        kicker: '05 / SYNC',
        title: 'iPhone ↔ Watch по локальной сети',
        body:
          'Без сервера, без iCloud (если сами не захотите). P2P через WatchConnectivity. SQLCipher шифрует всё. Можно унести ETOS-пакет с собой.',
        tags: ['WatchConnectivity', 'SQLCipher', 'ETOS-пакет']
      },
      {
        kicker: '06 / WATCH',
        title: 'Полный опыт на запястье, а не урезанный.',
        body:
          'Зум Digital Crown, Markdown и подсветка кода, таймлайн размышлений, TTS, кросс-устройство. Настройки watchOS — один плоский List.',
        tags: ['watchOS', 'Digital Crown', 'Голос']
      }
    ]
  },
  screenshots: {
    title: 'Как это выглядит в руках.',
    lead: 'Скриншоты из текущей сборки.',
    captionOne: 'iOS · Чат',
    captionTwo: 'Apple Watch · Сессия'
  },
  privacy: {
    title: 'Ваш ключ. Ваши данные. Ваше устройство.',
    lead:
      'ETOS не держит собственного сервера. Запрос уходит с устройства напрямую в модель. Чаты в локальной SQLite (SQLCipher). Синхронизация — по локальной сети между iPhone и Watch. CloudKit или сторонние сервисы — только если сами выберете.',
    bullets: [
      { kicker: 'BYOK', title: 'Ключ — ваш', body: 'Мы не проксируем, не кэшируем, не списываем за запросы.' },
      { kicker: 'LOCAL FIRST', title: 'Чаты на устройстве', body: 'Шифрование SQLCipher + блокировка по Face ID.' },
      { kicker: 'EXPORTABLE', title: 'ETOS-пакет с собой', body: 'Экспорт/импорт одной кнопкой при переезде.' },
      { kicker: 'OPEN SOURCE', title: 'GPLv3, проверяемо', body: 'Код открыт. PR и issue — приветствуются.' }
    ]
  },
  tech: {
    title: 'Нативные инструменты — нативный отклик.',
    lead: 'Без Electron, без React Native, без оболочек WebView.',
    items: [
      { name: 'Swift 6 · SwiftUI', desc: 'iOS 18 + watchOS 11, следуя Apple HIG.' },
      { name: 'GRDB · SQLCipher', desc: 'Шифрованная SQLite + реактивные наблюдения.' },
      { name: 'WatchConnectivity', desc: 'Низкая задержка. Без сервера-посредника.' },
      { name: 'Background Tasks', desc: 'Daily Pulse рендерится в фоне.' },
      { name: 'SF Symbols 6', desc: 'Визуально согласовано с системой.' },
      { name: 'App Intents', desc: 'Глубокая интеграция Siri и Spotlight.' }
    ]
  },
  cta: {
    title: 'Первый чат за десять минут.',
    lead: 'От установки до первого ответа — каждый шаг подскажет, куда нажать.',
    primary: 'Краткое руководство',
    secondary: 'GitHub',
    secondaryDesc: 'Star, issues и PR приветствуются.'
  },
  footer: {
    madeBy: 'С заботой собрано',
    author: 'Eric-Terminal',
    license: 'GPL-3.0',
    repo: 'github.com/Eric-Terminal/ETOS-LLM-Studio',
    docs: 'Документация',
    backToTop: 'Наверх'
  },
  loader: {
    kicker: 'HELLO FROM ETOS',
    line: 'BOOTING LANDING',
    year: '2026'
  },
  ui: {
    theme: { light: 'Светлая', dark: 'Тёмная' },
    langHint: 'Выберите удобный язык.'
  }
};

const zhHant = {
  meta: {
    title: 'ETOS LLM Studio',
    subtitle: 'iPhone + Apple Watch 原生 AI 客戶端'
  },
  nav: {
    features: '功能',
    personalize: '個人化',
    privacy: '隱私',
    tech: '技術',
    docs: '文件',
    github: 'GitHub',
    download: '取得 App'
  },
  hero: {
    title: '把 AI 放進口袋，也放上手腕。',
    lead:
      '一個跑在 iPhone 與 Apple Watch 上的原生 LLM 客戶端。你的 Key、你的資料，從裝置直接送往模型，沒有中介伺服器。',
    actionsPrimary: '閱讀入門教學',
    actionsSecondary: '查看功能模組',
    statusOnline: '持續開發中',
    statusBadge: 'BUILT FOR APPLE PLATFORMS'
  },
  personalize: {
    title: '一眼認得出，是你的 Studio。',
    lead: '上傳一張壁紙、挑一個對話框顏色、要不要 AI 氣泡——右邊這台即時跟著變。',
    pickerHint: '調下面三項，右側即時預覽',
    wallpaperLabel: '背景圖層',
    wallpaperAction: '選擇背景圖',
    colorLabel: '顏色配置',
    hideBubbleLabel: '關閉助手氣泡',
    reset: '恢復預設',
    chat: {
      title: '問候與幫助',
      user: '你好',
      bot: '你好！👋\n很高興見到你，有什麼想聊的或者需要幫忙的嗎？無論是圖片處理、海報設計、提示詞編寫、角色設定，還是其他問題，都可以直接告訴我。',
      placeholder: '輸入訊息…'
    }
  },
  features: {
    title: '不是套殼。是把模型當 Apple 平台公民來設計。',
    lead: '主畫面只留聊天，其餘全部收進設定。下面這些是你裝好之後會慢慢找到的能力。',
    items: [
      {
        kicker: '01 / CHAT',
        title: '多模型 · 多 Provider · 相容到底',
        body:
          '原生支援 OpenAI Chat、OpenAI Responses、Anthropic、Gemini，外加任意 OpenAI 相容介面。支援多 Key 輪詢、參數表達式、原始 JSON 請求體、提供商 / 全域兩層代理。',
        tags: ['OpenAI', 'Claude', 'Gemini', 'Custom']
      },
      {
        kicker: '02 / TOOLS',
        title: 'MCP · Skills · 捷徑',
        body:
          '工具中心統一管理 MCP 伺服器、Agent Skills、iOS 捷徑與內建工具。支援會話級啟用、審批策略、串流除錯與工具時間線。',
        tags: ['MCP', 'Skills', 'Shortcuts', '審批']
      },
      {
        kicker: '03 / MEMORY',
        title: '長期記憶 · 世界書 · 使用者畫像',
        body:
          '跨會話的事實記憶、關鍵字觸發的世界書條目、模型可讀的使用者畫像。本地向量索引，離線可用，可與 Daily Pulse 串接。',
        tags: ['長期記憶', '世界書', '本地 RAG']
      },
      {
        kicker: '04 / DAILY PULSE',
        title: '主動情報，不是被動問答',
        body:
          '依你設定的節奏自動生成情報卡片：新聞、郵件提醒、行程預判、技術摘要。Watch 在抬腕時顯示，錯過的可在 iPhone 端回看。',
        tags: ['排程', '情報卡片', '抬腕']
      },
      {
        kicker: '05 / SYNC',
        title: 'iPhone ↔ Watch 區網直連同步',
        body:
          '不走伺服器、不走 iCloud（除非你願意）。雙端透過 WatchConnectivity 與本地點對點協定互傳，SQLCipher 全盤加密，可隨時匯出 ETOS 資料包搬家。',
        tags: ['WatchConnectivity', 'SQLCipher', 'ETOS 資料包']
      },
      {
        kicker: '06 / WATCH',
        title: '手腕上的完整體驗，而不是閹割版。',
        body:
          '數位錶冠縮放圖片、Markdown 與程式碼高亮、思考時間線、TTS 朗讀、跨端發送。watchOS 設定攤平為單層 List，沒有 TabView。',
        tags: ['watchOS', '數位錶冠', '語音']
      }
    ]
  },
  screenshots: {
    title: '看看它在你手裡是什麼樣。',
    lead: '截圖直接來自目前版本。',
    captionOne: 'iOS · 聊天主畫面',
    captionTwo: 'Apple Watch · 單會話回看'
  },
  privacy: {
    title: '你的 Key，你的資料，你的裝置。',
    lead:
      'ETOS LLM Studio 不營運任何中介伺服器。模型請求從你的裝置直接送出，會話存在本機 SQLite（SQLCipher 加密），同步透過 iPhone 與 Watch 在區網內完成。要不要上 CloudKit、要不要交給第三方，全由你決定。',
    bullets: [
      { kicker: 'BYOK', title: '你提供 Key，App 直送模型', body: '我們不代付、不轉發、不快取你的請求。' },
      { kicker: 'LOCAL FIRST', title: '會話與記憶存在本機', body: 'SQLCipher 全盤加密，可應用鎖 + Face ID 雙重門。' },
      { kicker: 'EXPORTABLE', title: 'ETOS 資料包，隨時帶走', body: '一鍵匯出/匯入，搬家不成問題。' },
      { kicker: 'OPEN SOURCE', title: 'GPLv3 開源', body: '程式碼可審計，PR 與 Issue 都歡迎。' }
    ]
  },
  tech: {
    title: '用原生工具，做原生體驗。',
    lead: '沒有 Electron，沒有 React Native，沒有 WebView 套殼。',
    items: [
      { name: 'Swift 6 · SwiftUI', desc: 'iOS 18 + watchOS 11 原生 UI，遵循 Apple HIG。' },
      { name: 'GRDB · SQLCipher', desc: '加密 SQLite + ValueObservation 響應式查詢。' },
      { name: 'WatchConnectivity', desc: '雙端低延遲同步，無中介伺服器。' },
      { name: 'Background Tasks', desc: 'Daily Pulse 在背景預先生成。' },
      { name: 'SF Symbols 6', desc: '原生圖示體系，與系統視覺一致。' },
      { name: 'App Intents', desc: 'Siri 捷徑與 Spotlight 深度整合。' }
    ]
  },
  cta: {
    title: '十分鐘跑通第一條對話。',
    lead: '裝機、設定 Provider、第一條訊息，每一步都告訴你點哪裡。',
    primary: '閱讀入門教學',
    secondary: 'GitHub 原始碼',
    secondaryDesc: '歡迎 Star、Issue、PR。'
  },
  footer: {
    madeBy: 'Made with care by',
    author: 'Eric-Terminal',
    license: 'GPL-3.0 授權',
    repo: 'github.com/Eric-Terminal/ETOS-LLM-Studio',
    docs: '文件站',
    backToTop: '回到頂部'
  },
  loader: {
    kicker: 'HELLO FROM ETOS',
    line: 'BOOTING LANDING',
    year: '2026'
  },
  ui: {
    theme: { light: '淺色', dark: '深色' },
    langHint: '選擇你慣用的語言。'
  }
};

export const translations = {
  zh,
  en,
  ja,
  ru,
  'zh-Hant': zhHant
};
