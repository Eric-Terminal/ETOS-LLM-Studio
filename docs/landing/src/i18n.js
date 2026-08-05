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
    title: 'ETOS LLM Studio · 原生 AI 客户端',
    subtitle: 'iPhone + Apple Watch 原生 AI 客户端 · 端侧 LLM 与全能工具中心'
  },
  nav: {
    localModel: '端侧 LLM',
    features: '功能矩阵',
    mcpSkills: '工具与技能',
    personalize: '个性化',
    privacy: '隐私与安全',
    tech: '技术栈',
    docs: '文档',
    github: 'GitHub',
    download: '获取 App'
  },
  hero: {
    title: '你的 AI，揣在手里，戴在腕上。',
    lead:
      '运行在 iPhone 与 Apple Watch 上的原生 LLM 客户端。支持 GGUF 端侧本地模型、MCP 工具协议、Agent Skills 与 SQLCipher 物理加密。你的 Key、你的数据，零中间服务器。',
    actionsPrimary: '轻松上手教程',
    actionsSecondary: '探索功能模块',
    statusOnline: '持续迭代中 · 750+ Swift 源文件',
    statusBadge: 'BUILT FOR APPLE PLATFORMS'
  },
  stats: [
    { label: 'Swift 源文件', val: '750+' },
    { label: '原生 Swift 代码行', val: '280,000+' },
    { label: '中间服务器', val: '0' },
    { label: '隐私与物理加密', val: '100% Local' }
  ],
  localDemo: {
    badge: '端侧本地模型',
    title: 'iOS 端侧硬核 GGUF 本地模型推理',
    lead: '不需要连接任何网络或 API 服务。底层通过 llama.cpp C ABI 桥接，直接在 iPhone 上加载 GGUF 权重，并提供实时 CPU / Metal / 内存性能监视器。',
    selectModelLabel: '选择本地 GGUF 模型',
    thinkHeader: '本地模型思考时间线 (Thinking Timeline)',
    userQuestion: '运行端侧 GGUF 本地模型需要连接网络或 API Key 吗？',
    kvCacheActiveLabel: 'KV Cache 前缀复用已生效',
    kvCacheInactiveLabel: 'KV Cache 未开启',
    models: [
      {
        name: 'Phi-4-mini-Instruct.Q4_K_M.gguf',
        size: '2.48 GB',
        hud: {
          cpuMetal: '13%',
          cpuOnly: '63%',
          gpuMetal: '78%',
          ramMetal: '2.7 GB (Metal)',
          ramMetalKV: '3.0 GB (Metal + KV)',
          ramCpu: '3.1 GB (RAM)',
          ramCpuKV: '3.4 GB (RAM + KV)',
          speedFlash: 49.6,
          speedFlashKV: 57.8,
          speedBase: 29.8,
          speedKV: 34.2
        },
        thinking: '正在使用 Metal GPU 加速计算，分析对话上下文与 GGUF Jinja 对话模板...',
        response: '完全不需要网络或 API Key！模型权重与 Embedding 嵌入向量数据库完全运行在你的 iPhone 本机设备上。零联网权限，不消耗流量，隐私 100% 物理隔离。'
      },
      {
        name: 'Gemma-3-4B-Instruct.Q4_K_M.gguf',
        size: '2.85 GB',
        hud: {
          cpuMetal: '17%',
          cpuOnly: '69%',
          gpuMetal: '84%',
          ramMetal: '3.1 GB (Metal)',
          ramMetalKV: '3.5 GB (Metal + KV)',
          ramCpu: '3.7 GB (RAM)',
          ramCpuKV: '4.1 GB (RAM + KV)',
          speedFlash: 38.0,
          speedFlashKV: 44.3,
          speedBase: 23.2,
          speedKV: 26.8
        },
        thinking: 'Checking local GGUF memory budget and Metal GPU offload layers...',
        response: 'Gemma 3 4B 本地推理完成！全流式 Metal GPU 加速输出与 KV Cache 前缀复用正常，内存占用按上下文缓存同步增加。'
      },
      {
        name: 'Qwen3-8B-Instruct.Q4_K_M.gguf',
        size: '4.92 GB',
        hud: {
          cpuMetal: '24%',
          cpuOnly: '82%',
          gpuMetal: '91%',
          ramMetal: '5.2 GB (Metal)',
          ramMetalKV: '5.8 GB (Metal + KV)',
          ramCpu: '6.1 GB (RAM)',
          ramCpuKV: '6.8 GB (RAM + KV)',
          speedFlash: 26.4,
          speedFlashKV: 30.5,
          speedBase: 15.7,
          speedKV: 18.2
        },
        thinking: '正在解析 <think> 推理链：1. 检索本地 SQLite 数据库；2. 匹配 KV Cache 缓存前缀；3. 生成结构化思考步骤...',
        response: 'Qwen3 8B 本地推理完成！全流式 Metal GPU 加速输出与 KV Cache 前缀复用正常，吞吐与内存占用按 8B 模型规模显示。'
      }
    ]
  },
  mcpSkillsSection: {
    badge: '工具与生态',
    title: 'MCP 协议 · Agent Skills · 沙盒 JS',
    lead: '集成 Swift Model Context Protocol (MCP) 官方 SDK，支持从 GitHub 一键导入 Agent Skills 技能包，并可在沙盒内运行自定义 JavaScript 工具。',
    tabs: [
      {
        id: 'mcp',
        type: 'BUILT-IN APP TOOL',
        title: '内置系统时间工具',
        badge: 'Built-in App Tool',
        desc: '在 AI 想要获取设备时间时，调用内置 App Tool；它不属于外部 MCP 工具，参数为空。',
        snippet: `// Built-in App Tool Execution
{
  "tool": "app_get_system_time",
  "arguments": {}
}`
      },
      {
        id: 'skills',
        type: 'AGENT SKILLS',
        title: 'GitHub 技能包一键导入',
        badge: 'Agentic Skill Pack',
        desc: '直接粘贴 GitHub 仓库链接或 RAW 文件地址，即刻注入代码审查、海报生成或工作流指令集。',
        snippet: `---
name: code-reviewer-pro
description: "Inspect Swift & Rust diffs for memory leaks"
allowed-tools:
  - app_read_sandbox_file
  - app_query_sqlite
---

# CodeReviewer Pro

检查 Swift 闭包捕获列表、Rust unsafe 边界与数据库迁移风险。`
      },
      {
        id: 'jsc',
        type: 'JSC JS TOOL',
        title: 'JavaScriptCore 格式化工具',
        badge: 'app_create_custom_jsc_js_tool',
        desc: '创建可复用的 iOS JSC 自定义脚本工具，脚本声明同步 function main(input)，保存在 CustomJSTools 目录。',
        snippet: `// CustomJSTools/format_currency.js
// iOS JSC 执行引擎：同步函数，无 Node/fetch/Promise
function main(input) {
  var amount = input.amount || 0;
  var currency = input.currency || 'USD';
  return {
    formatted: currency + ' ' + amount.toFixed(2),
    timestamp: new Date().toISOString()
  };
}`
      },
      {
        id: 'rag',
        type: 'SQLCIPHER RAG',
        title: 'SQLite 全盘物理加密向量库',
        badge: 'GRDB + SQLCipher',
        desc: '本地 Embedding 与长效记忆直接落地在加密 SQLite 数据库中，支持 SillyTavern 世界书触发。',
        snippet: `-- memory_vectors.sqlite
CREATE TABLE memory_chunks (
  chunk_id TEXT PRIMARY KEY,
  parent_memory_id TEXT NOT NULL,
  text TEXT NOT NULL,
  embedding BLOB NOT NULL,
  metadata TEXT NOT NULL
) STRICT;`
      }
    ]
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
      bot: '你好！👋\n很高兴见到你，有什么想聊的或者需要帮忙的吗？无论是端侧 GGUF 调参、MCP 工具配置、Agent Skills 导入，还是日常问答，都可以直接告诉我。',
      placeholder: '输入消息…'
    }
  },
  features: {
    title: '不是套壳。是把模型当 Apple 平台公民来设计。',
    lead: '主界面只留聊天，其余全部收进设置。下面这些是你装好之后会陆续找到的能力。',
    items: [
      {
        kicker: '01 / CHAT & PROVIDERS',
        title: '多模型 · 多 Provider · 兼容到底',
        body:
          '原生适配 OpenAI Chat、OpenAI Responses、Anthropic、Gemini，外加任意 OpenAI 兼容接口。支持多 Key 轮询、参数表达式、原始 JSON 请求体、单条 AI 回复重写与计费估算。',
        tags: ['OpenAI', 'Claude', 'Gemini', 'Custom JSON']
      },
      {
        kicker: '02 / LOCAL GGUF',
        title: '端侧 GGUF 本地模型 & 性能监视器',
        body:
          '底层通过 llama.cpp C ABI 桥接，在 iOS 上直接运行 GGUF 本地权重。支持 Metal GPU 加速、Flash Attention、KV offload、流式思考解析与浮动性能监视面板（CPU/Metal/RAM）。',
        tags: ['llama.cpp', 'GGUF', 'Metal GPU', '性能 HUD']
      },
      {
        kicker: '03 / TOOLS & SKILLS',
        title: 'MCP 协议 · Agent Skills · 沙盒 JS',
        body:
          '统一管理 MCP 服务器（Streamable HTTP/SSE）、Agent Skills 技能包（GitHub/RAW 导入）、iOS 快捷指令与内建 SQLite/文件沙盒/健康/日历工具，具备原生问答Sheet审批控制。',
        tags: ['MCP SDK', 'Agent Skills', 'Shortcuts', '审批 Sheet']
      },
      {
        kicker: '04 / RAG & WORLDBOOK',
        title: '本地 RAG 记忆 · 世界书 · 嵌入向量',
        body:
          '跨会话长期事实记忆、支持 SillyTavern 兼容的世界书 Lorebook（条件触发、注入预算）与用户画像。向量索引完全本地 SQLite 运行，绝不下发云端。',
        tags: ['长期记忆', '世界书 Lorebook', 'SQLite 向量']
      },
      {
        kicker: '05 / DAILY PULSE',
        title: 'Daily Pulse 每日脉冲主动情报',
        body:
          '每天定时预生成主动情报卡片：新闻、邮件提醒、日程预判、技术摘要。支持卡片一键转待跟进任务与长效偏好反馈学习，抬腕即看。',
        tags: ['定时', '情报卡片', '任务跟进', 'Watch 抬腕']
      },
      {
        kicker: '06 / WATCH & SYNC',
        title: 'iPhone ↔ Watch 权威增量同步',
        body:
          'WatchConnectivity 局域网快速通道 + CloudKit / APNs 后台漫游。双端配备权威世代指针与数据覆盖冲突裁决短语，离线分叉合并零丢失。',
        tags: ['WatchConnectivity', 'CloudKit', '世代指针']
      },
      {
        kicker: '07 / WATCH NATIVE',
        title: '手腕上的完整体验，不是阉割版',
        body:
          '数码表冠缩放图片、Markdown 与代码高亮、思考时间线、TTS 朗读、单会话跨端发送。watchOS 设置扁平化为单层 List，零 TabView。',
        tags: ['watchOS', '数码表冠', '抬腕语音', 'TTS']
      },
      {
        kicker: '08 / SECURITY & BACKUP',
        title: 'SQLCipher 全盘加密 & 快照备份',
        body:
          '底层数据库采用 SQLCipher 物理加密，结合 PBKDF2 主密码与 Face ID / Touch ID 应用锁。支持加密快照 `.elsbackup` 导出及 Cloudflare R2 / S3 签名云备份。',
        tags: ['SQLCipher', 'Face ID 锁', 'AES-256', 'S3/R2 云备份']
      }
    ]
  },
  screenshots: {
    title: '看看它在你手里是什么样。',
    lead: '截图直接来自当前真实 Build。',
    captionOne: 'iOS · 聊天与功能面板',
    captionTwo: 'Apple Watch · 独立端侧体验'
  },
  privacy: {
    title: '你的 Key，你的数据，你的设备。',
    lead:
      '没有任何中间服务器。模型请求从你的设备直接发出，对话存在本机 SQLite（SQLCipher 加密），同步通过 iPhone 与 Watch 在局域网或 CloudKit 完成。要不要交给第三方，全是你的选择。',
    bullets: [
      { kicker: 'BYOK', title: '你提供 Key，App 直发模型', body: '我们不代付、不转发、不缓存你的请求。' },
      { kicker: 'LOCAL FIRST', title: '会话与记忆存在本机', body: 'SQLCipher 全盘加密，配合 Face ID 应用锁。' },
      { kicker: 'EXPORTABLE', title: 'ETOS 数据包与加密快照', body: '一键导出/导入 `.elsbackup`，跨端迁移无痛。' },
      { kicker: 'OPEN SOURCE', title: 'GPLv3 开源', body: '代码完全公开可审计，欢迎 PR 与 Issue。' }
    ]
  },
  tech: {
    title: '用原生工具，做原生体验。',
    lead: '没有 Electron，没有 React Native，没有 WebView 套壳。快速，性能超强。',
    items: [
      { name: 'Swift 6 · SwiftUI', desc: 'iOS 18 + watchOS 11 原生 UI，遵循 Apple HIG。' },
      { name: 'llama.cpp C ABI', desc: 'iOS 端侧运行 GGUF 权重，Metal GPU 加速与性能 HUD。' },
      { name: 'Swift MCP SDK', desc: 'Model Context Protocol 官方 SDK，支持 SSE / Streamable HTTP。' },
      { name: 'GRDB · SQLCipher', desc: '物理全盘加密 SQLite + ValueObservation 响应式查询。' },
      { name: 'WatchConnectivity & CloudKit', desc: '双端低延迟增量同步，带世代指针与 APNs 静默唤醒。' },
      { name: 'SFSpeechRecognizer & TTS', desc: '系统与云端语音识别及朗读引擎，实时回填与自动回退。' }
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
    title: 'ETOS LLM Studio · Native AI Client',
    subtitle: 'Native AI Client for iPhone + Apple Watch · On-Device LLM & Powerful Tooling'
  },
  nav: {
    localModel: 'On-Device LLM',
    features: 'Features',
    mcpSkills: 'MCP & Skills',
    personalize: 'Personalize',
    privacy: 'Privacy & Security',
    tech: 'Stack',
    docs: 'Docs',
    github: 'GitHub',
    download: 'Get App'
  },
  hero: {
    title: 'AI in your pocket. And on your wrist.',
    lead:
      'A native LLM client that runs on iPhone and Apple Watch. Supporting GGUF on-device local models, MCP protocol, Agent Skills, and SQLCipher physical encryption. Zero middle server.',
    actionsPrimary: 'Read Quickstart Guide',
    actionsSecondary: 'Explore Feature Matrix',
    statusOnline: 'Active Development · 750+ Swift Files',
    statusBadge: 'BUILT FOR APPLE PLATFORMS'
  },
  stats: [
    { label: 'Swift Source Files', val: '750+' },
    { label: 'Native Swift Code Lines', val: '280,000+' },
    { label: 'Middle Servers', val: '0' },
    { label: 'Privacy & Physical Encryption', val: '100% Local' }
  ],
  localDemo: {
    badge: 'On-Device Local Model',
    title: 'Native GGUF Inference & Performance HUD on iOS',
    lead: 'No network or API keys needed. Bridged via llama.cpp C ABI directly on iOS with Metal GPU acceleration and real-time CPU / Metal / Memory telemetry.',
    selectModelLabel: 'Select Local GGUF Model',
    thinkHeader: 'Thinking Timeline',
    userQuestion: 'Does running on-device GGUF models require network or API keys?',
    kvCacheActiveLabel: 'KV Cache Prefix Reuse Active',
    kvCacheInactiveLabel: 'KV Cache Disabled',
    models: [
      {
        name: 'Phi-4-mini-Instruct.Q4_K_M.gguf',
        size: '2.48 GB',
        hud: {
          cpuMetal: '13%',
          cpuOnly: '63%',
          gpuMetal: '78%',
          ramMetal: '2.7 GB (Metal)',
          ramMetalKV: '3.0 GB (Metal + KV)',
          ramCpu: '3.1 GB (RAM)',
          ramCpuKV: '3.4 GB (RAM + KV)',
          speedFlash: 49.6,
          speedFlashKV: 57.8,
          speedBase: 29.8,
          speedKV: 34.2
        },
        thinking: 'Accelerating via Metal GPU, analyzing chat context and GGUF Jinja chat template...',
        response: 'No network or API key required! Model weights and SQLite vector database run 100% locally on your iPhone with zero telemetry.'
      },
      {
        name: 'Gemma-3-4B-Instruct.Q4_K_M.gguf',
        size: '2.85 GB',
        hud: {
          cpuMetal: '17%',
          cpuOnly: '69%',
          gpuMetal: '84%',
          ramMetal: '3.1 GB (Metal)',
          ramMetalKV: '3.5 GB (Metal + KV)',
          ramCpu: '3.7 GB (RAM)',
          ramCpuKV: '4.1 GB (RAM + KV)',
          speedFlash: 38.0,
          speedFlashKV: 44.3,
          speedBase: 23.2,
          speedKV: 26.8
        },
        thinking: 'Checking local GGUF memory budget and Metal GPU offload layers...',
        response: 'Gemma 3 4B local execution complete. Metal streaming and KV prefix reuse are active, with memory increasing to reflect the cached context.'
      },
      {
        name: 'Qwen3-8B-Instruct.Q4_K_M.gguf',
        size: '4.92 GB',
        hud: {
          cpuMetal: '24%',
          cpuOnly: '82%',
          gpuMetal: '91%',
          ramMetal: '5.2 GB (Metal)',
          ramMetalKV: '5.8 GB (Metal + KV)',
          ramCpu: '6.1 GB (RAM)',
          ramCpuKV: '6.8 GB (RAM + KV)',
          speedFlash: 26.4,
          speedFlashKV: 30.5,
          speedBase: 15.7,
          speedKV: 18.2
        },
        thinking: 'Parsing <think> reasoning chain: 1. Search local SQLite; 2. Match KV Cache prefix; 3. Generate structured thinking steps...',
        response: 'Qwen3 8B local inference complete. Metal acceleration and KV reuse are active, with throughput and memory shown at the larger 8B scale.'
      }
    ]
  },
  mcpSkillsSection: {
    badge: 'Tools & Ecosystem',
    title: 'MCP Protocol · Agent Skills · Sandboxed JS',
    lead: 'Official Swift Model Context Protocol SDK, one-click Agent Skill import from GitHub, and sandboxed JavaScript tool runtime.',
    tabs: [
      {
        id: 'mcp',
        type: 'BUILT-IN APP TOOL',
        title: 'Built-in System Time Tool',
        badge: 'Built-in App Tool',
        desc: 'When AI requests device time, it calls a built-in App Tool. This is not an external MCP tool and takes no arguments.',
        snippet: `// Built-in App Tool Execution
{
  "tool": "app_get_system_time",
  "arguments": {}
}`
      },
      {
        id: 'skills',
        type: 'AGENT SKILLS',
        title: 'GitHub Skill Import',
        badge: 'Agentic Skill Pack',
        desc: 'Paste GitHub repo links or RAW file URLs to inject code inspection or prompt workflow skill packs.',
        snippet: `---
name: code-reviewer-pro
description: "Inspect Swift & Rust diffs for memory leaks"
allowed-tools:
  - app_read_sandbox_file
  - app_query_sqlite
---

# CodeReviewer Pro

Check Swift closure captures, Rust unsafe boundaries, and database migration risks.`
      },
      {
        id: 'jsc',
        type: 'JSC JS TOOL',
        title: 'JavaScriptCore Formatter',
        badge: 'app_create_custom_jsc_js_tool',
        desc: 'Create reusable iOS JSC custom script tools with synchronous main(input) functions saved in CustomJSTools.',
        snippet: `// CustomJSTools/format_currency.js
// iOS JSC Execution Engine: Sync function without Node/fetch/Promise
function main(input) {
  var amount = input.amount || 0;
  var currency = input.currency || 'USD';
  return {
    formatted: currency + ' ' + amount.toFixed(2),
    timestamp: new Date().toISOString()
  };
}`
      },
      {
        id: 'rag',
        type: 'SQLCIPHER RAG',
        title: 'SQLite Encrypted Vector Store',
        badge: 'GRDB + SQLCipher',
        desc: 'Local embeddings and long-term memory stored inside encrypted SQLite database with SillyTavern Worldbook support.',
        snippet: `-- memory_vectors.sqlite
CREATE TABLE memory_chunks (
  chunk_id TEXT PRIMARY KEY,
  parent_memory_id TEXT NOT NULL,
  text TEXT NOT NULL,
  embedding BLOB NOT NULL,
  metadata TEXT NOT NULL
) STRICT;`
      }
    ]
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
      bot: "Hi! 👋\nGreat to meet you — anything you'd like to chat about or need a hand with? GGUF local model tuning, MCP tools, Agent Skills, or prompt engineering, just ask!",
      placeholder: 'Message'
    }
  },
  features: {
    title: "Not a wrapper. A native Apple-platform citizen.",
    lead: 'The main view is just chat. Everything else lives in Settings. Here is what you will gradually find.',
    items: [
      {
        kicker: '01 / CHAT & PROVIDERS',
        title: 'Multi-model · Multi-provider · Total Compatibility',
        body:
          'Native support for OpenAI Chat, OpenAI Responses, Anthropic, Gemini, plus any OpenAI-compatible endpoint. Key rotation, parameter expressions, raw JSON, single response rewrite, and cost tracking.',
        tags: ['OpenAI', 'Claude', 'Gemini', 'Custom JSON']
      },
      {
        kicker: '02 / LOCAL GGUF',
        title: 'On-Device GGUF Models & Performance HUD',
        body:
          'Bridged via llama.cpp C ABI to execute GGUF weights directly on iOS. Metal GPU acceleration, Flash Attention, KV offload, streaming thinking tags, and floating performance monitor HUD.',
        tags: ['llama.cpp', 'GGUF', 'Metal GPU', 'HUD']
      },
      {
        kicker: '03 / TOOLS & SKILLS',
        title: 'MCP Protocol · Agent Skills · Sandboxed JS',
        body:
          'Unified tool hub managing MCP servers (SSE/HTTP), Agent Skills (GitHub/RAW import), Shortcuts, SQLite/sandboxed files/Health/Calendar tools with native approval Sheets.',
        tags: ['MCP SDK', 'Agent Skills', 'Shortcuts', 'Approval Sheet']
      },
      {
        kicker: '04 / RAG & WORLDBOOK',
        title: 'Local RAG Memory · Worldbook · SQLite Vectors',
        body:
          'Cross-session facts, SillyTavern compatible Worldbook lorebook (conditional triggers, budget control), and user profile. Vector database runs 100% locally in SQLite.',
        tags: ['Memory', 'Worldbook', 'Local RAG', 'SQLite']
      },
      {
        kicker: '05 / DAILY PULSE',
        title: 'Daily Pulse Proactive Intelligence',
        body:
          'Pre-generated intelligence cards (news, calendar prep, tech digests). Convert cards into actionable follow-up tasks with feedback learning and Apple Watch raise-to-view.',
        tags: ['Scheduled', 'Cards', 'Task Tracking', 'Watch Raise']
      },
      {
        kicker: '06 / WATCH & SYNC',
        title: 'iPhone ↔ Watch Authority Sync',
        body:
          'WatchConnectivity low-latency channel + CloudKit / APNs background sync. Equipped with generation pointers and conflict resolution phrase for zero data loss.',
        tags: ['WatchConnectivity', 'CloudKit', 'Generation Pointers']
      },
      {
        kicker: '07 / WATCH NATIVE',
        title: 'A complete experience on the wrist',
        body:
          'Digital Crown zoom, Markdown + code highlighting, thinking timeline, TTS readout, cross-device send. Flat single-layer list layout without TabView.',
        tags: ['watchOS', 'Digital Crown', 'Voice', 'TTS']
      },
      {
        kicker: '08 / SECURITY & BACKUP',
        title: 'SQLCipher Encryption & Cloud Backups',
        body:
          'Physical SQLCipher database encryption with PBKDF2 master key & Face ID app lock. Encrypted `.elsbackup` snapshots and S3 / Cloudflare R2 cloud backup.',
        tags: ['SQLCipher', 'Face ID', 'AES-256', 'S3/R2 Backup']
      }
    ]
  },
  screenshots: {
    title: 'See what it looks like in your hand.',
    lead: 'Screens are from the current real build.',
    captionOne: 'iOS · Chat & Features',
    captionTwo: 'Apple Watch · Session View'
  },
  privacy: {
    title: 'Your key. Your data. Your device.',
    lead:
      'ETOS runs no server of its own. Requests go from your device straight to the model. Chats live in local SQLite (SQLCipher encrypted). Sync happens over LAN or CloudKit.',
    bullets: [
      { kicker: 'BYOK', title: 'You bring the key', body: 'We never proxy, cache, or bill your requests.' },
      { kicker: 'LOCAL FIRST', title: 'Chats live on device', body: 'SQLCipher physical encryption + Face ID app lock.' },
      { kicker: 'EXPORTABLE', title: 'Take data with you', body: 'One-click `.elsbackup` snapshot export/import for effortless migrations.' },
      { kicker: 'OPEN SOURCE', title: 'GPLv3 License', body: 'Code is open and auditable. PRs and issues welcome.' }
    ]
  },
  tech: {
    title: 'Native tools for a native feel.',
    lead: 'No Electron. No React Native. No WebView shell.',
    items: [
      { name: 'Swift 6 · SwiftUI', desc: 'iOS 18 + watchOS 11, true to Apple HIG.' },
      { name: 'llama.cpp C ABI', desc: 'Runs GGUF weights on-device with Metal GPU & HUD.' },
      { name: 'Swift MCP SDK', desc: 'Official Model Context Protocol SDK for Swift.' },
      { name: 'GRDB · SQLCipher', desc: 'Encrypted SQLite with reactive ValueObservation.' },
      { name: 'WatchConnectivity & CloudKit', desc: 'Low-latency sync with generation pointers and APNs.' },
      { name: 'SFSpeechRecognizer & TTS', desc: 'System and cloud speech engines with automatic fallback.' }
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
    title: 'ETOS LLM Studio · ネイティブ AI クライアント',
    subtitle: 'iPhone + Apple Watch 向けネイティブ AI クライアント'
  },
  nav: {
    localModel: 'ローカル LLM',
    features: '機能',
    mcpSkills: 'ツールとスキル',
    personalize: 'カスタマイズ',
    privacy: 'プライバシー',
    tech: '技術スタック',
    docs: 'ドキュメント',
    github: 'GitHub',
    download: 'アプリを入手'
  },
  hero: {
    title: 'AI を、手の中に。腕の上に。',
    lead:
      'iPhone と Apple Watch で動作するネイティブ LLM クライアント。オンデバイス GGUF ローカルモデル、MCP プロトコル、Agent Skills、SQLCipher 暗号化をサポート。中間サーバーゼロ。',
    actionsPrimary: 'クイックスタートを読む',
    actionsSecondary: '機能を見る',
    statusOnline: 'アクティブに開発中 · 750+ Swift ファイル',
    statusBadge: 'BUILT FOR APPLE PLATFORMS'
  },
  stats: [
    { label: 'Swift ソースファイル', val: '750+' },
    { label: 'Swift コード行数', val: '280,000+' },
    { label: '中間サーバー', val: '0' },
    { label: '物理暗号化・ローカルファースト', val: '100% Local' }
  ],
  localDemo: {
    badge: 'オンデバイスローカルモデル',
    title: 'iOS 上での GGUF 推論 & パフォーマンス HUD',
    lead: 'ネット接続や API キーは一切不要。llama.cpp C ABI 経由で Metal GPU アクセラレーションとリアルタイム CPU/GPU/メモリ モニターを搭載。',
    selectModelLabel: 'ローカル GGUF モデルを選択',
    thinkHeader: '思考タイムライン (Thinking Timeline)',
    userQuestion: 'ローカル GGUF モデルの実行にネット接続や API キーは必要ですか？',
    kvCacheActiveLabel: 'KV Cache プレフィックス再利用中',
    kvCacheInactiveLabel: 'KV Cache 未有効化',
    models: [
      {
        name: 'Phi-4-mini-Instruct.Q4_K_M.gguf',
        size: '2.48 GB',
        hud: {
          cpuMetal: '13%',
          cpuOnly: '63%',
          gpuMetal: '78%',
          ramMetal: '2.7 GB (Metal)',
          ramMetalKV: '3.0 GB (Metal + KV)',
          ramCpu: '3.1 GB (RAM)',
          ramCpuKV: '3.4 GB (RAM + KV)',
          speedFlash: 49.6,
          speedFlashKV: 57.8,
          speedBase: 29.8,
          speedKV: 34.2
        },
        thinking: 'Metal GPU 加速で計算中、GGUF Jinja テンプレートを解析中...',
        response: 'ネット接続や API キーは一切不要です！モデルウェイトと SQLite ベクトル DB は端末内で 100% ローカル動作します。'
      },
      {
        name: 'Gemma-3-4B-Instruct.Q4_K_M.gguf',
        size: '2.85 GB',
        hud: {
          cpuMetal: '17%',
          cpuOnly: '69%',
          gpuMetal: '84%',
          ramMetal: '3.1 GB (Metal)',
          ramMetalKV: '3.5 GB (Metal + KV)',
          ramCpu: '3.7 GB (RAM)',
          ramCpuKV: '4.1 GB (RAM + KV)',
          speedFlash: 38.0,
          speedFlashKV: 44.3,
          speedBase: 23.2,
          speedKV: 26.8
        },
        thinking: 'Checking local GGUF memory budget and Metal GPU offload layers...',
        response: 'Gemma 3 4B ローカル推論完了！Metal GPU 加速と KV Cache 再利用が正常に動作し、キャッシュ分のメモリも反映されています。'
      },
      {
        name: 'Qwen3-8B-Instruct.Q4_K_M.gguf',
        size: '4.92 GB',
        hud: {
          cpuMetal: '24%',
          cpuOnly: '82%',
          gpuMetal: '91%',
          ramMetal: '5.2 GB (Metal)',
          ramMetalKV: '5.8 GB (Metal + KV)',
          ramCpu: '6.1 GB (RAM)',
          ramCpuKV: '6.8 GB (RAM + KV)',
          speedFlash: 26.4,
          speedFlashKV: 30.5,
          speedBase: 15.7,
          speedKV: 18.2
        },
        thinking: '<think> 推論チェーンを解析中: 1. SQLite 検索; 2. KV Cache マッチング; 3. 思考ステップ生成...',
        response: 'Qwen3 8B ローカル推論完了。8B モデル規模に合わせたスループットとメモリ使用量を表示しています。'
      }
    ]
  },
  mcpSkillsSection: {
    badge: 'ツールとエコシステム',
    title: 'MCP プロトコル · Agent Skills · Sandboxed JS',
    lead: '公式 Swift MCP SDK、GitHub からのワンクリック Agent Skill インポート、サンドボックス化 JavaScript ランタイムを搭載。',
    tabs: [
      {
        id: 'mcp',
        type: 'BUILT-IN APP TOOL',
        title: '内蔵システム時刻ツール',
        badge: 'Built-in App Tool',
        desc: 'AI がデバイス時刻を必要とするときは内蔵 App Tool を呼び出します。外部 MCP ツールではなく、引数も不要です。',
        snippet: `// Built-in App Tool Execution
{
  "tool": "app_get_system_time",
  "arguments": {}
}`
      },
      {
        id: 'skills',
        type: 'AGENT SKILLS',
        title: 'GitHub スキルインポート',
        badge: 'Agentic Skill Pack',
        desc: 'GitHub リポジトリリンクや RAW URL を貼り付けるだけで、コードレビューやワークフロースキルを注入。',
        snippet: `---
name: code-reviewer-pro
description: "Inspect Swift & Rust diffs for memory leaks"
allowed-tools:
  - app_read_sandbox_file
  - app_query_sqlite
---

# CodeReviewer Pro

Swift のクロージャキャプチャ、Rust unsafe 境界、データベース移行リスクを確認します。`
      },
      {
        id: 'jsc',
        type: 'JSC JS TOOL',
        title: 'JavaScriptCore フォーマッター',
        badge: 'app_create_custom_jsc_js_tool',
        desc: 'CustomJSTools に保存される同期 function main(input) を備えた再利用可能な iOS JSC カスタムスクリプト。',
        snippet: `// CustomJSTools/format_currency.js
// iOS JSC エンジン: Node/fetch/Promise なしの同期関数
function main(input) {
  var amount = input.amount || 0;
  var currency = input.currency || 'USD';
  return {
    formatted: currency + ' ' + amount.toFixed(2),
    timestamp: new Date().toISOString()
  };
}`
      },
      {
        id: 'rag',
        type: 'SQLCIPHER RAG',
        title: 'SQLite 暗号化ベクトルストア',
        badge: 'GRDB + SQLCipher',
        desc: '暗号化 SQLite データベース内に長期記憶を保存。SillyTavern ワールドブック対応。',
        snippet: `-- memory_vectors.sqlite
CREATE TABLE memory_chunks (
  chunk_id TEXT PRIMARY KEY,
  parent_memory_id TEXT NOT NULL,
  text TEXT NOT NULL,
  embedding BLOB NOT NULL,
  metadata TEXT NOT NULL
) STRICT;`
      }
    ]
  },
  personalize: {
    title: 'あなただけの Studio。',
    lead: '壁紙をアップロードし、バブルの色を選び、AI バブルの表示をカスタマイズ。右側のプレビューがリアルタイムで更新されます。',
    pickerHint: '下で調整、右側でリアルタイム確認',
    wallpaperLabel: '背景レイヤー',
    wallpaperAction: '背景画像を選択',
    colorLabel: 'カラープロファイル',
    hideBubbleLabel: '助手バブルを非表示',
    reset: 'デフォルトに戻す',
    chat: {
      title: '挨拶とサポート',
      user: 'こんにちは',
      bot: 'こんにちは！👋\n何かお手伝いできることはありますか？ローカル GGUF モデルの調整、MCP ツール、Agent Skills のインポートなど、何でもお気軽にどうぞ！',
      placeholder: 'メッセージを入力…'
    }
  },
  features: {
    title: '単なる Web ラッパーではありません。',
    lead: 'メイン画面はチャットのみ。その他はすべて設定に集約。',
    items: [
      {
        kicker: '01 / CHAT & PROVIDERS',
        title: 'マルチモデル · マルチプロバイダー',
        body: 'OpenAI、Claude、Gemini、任意の OpenAI 互換 API をサポート。キーローテーション、カスタムパラメータ式、JSON プレビューに対応。',
        tags: ['OpenAI', 'Claude', 'Gemini', 'Custom']
      },
      {
        kicker: '02 / LOCAL GGUF',
        title: 'オンデバイス GGUF ローカルモデル & HUD',
        body: 'llama.cpp C ABI 経由で iOS 上で直接 GGUF モデルを実行。Metal GPU アクセラレーション、Flash Attention、リアルタイム HUD を搭載。',
        tags: ['llama.cpp', 'GGUF', 'Metal GPU', 'HUD']
      },
      {
        kicker: '03 / TOOLS & SKILLS',
        title: 'MCP プロトコル · Agent Skills · JS ツール',
        body: 'MCP サーバー、Agent Skills、Shortcuts、SQLite/ファイル操作/ヘルスケア/カレンダーツールを統括。',
        tags: ['MCP SDK', 'Agent Skills', 'Shortcuts']
      },
      {
        kicker: '04 / RAG & WORLDBOOK',
        title: 'ローカル RAG 記憶 · ワールドブック',
        body: '長期記憶、SillyTavern 互換のワールドブック (Lorebook)、ユーザープロファイル。ベクトルインデックスは完全にローカル SQLite で動作。',
        tags: ['Memory', 'Worldbook', 'SQLite']
      },
      {
        kicker: '05 / DAILY PULSE',
        title: 'Daily Pulse アクティブインテリジェンス',
        body: '毎日自動でインテリジェンスカードを生成。アクションアイテムへの変換、フィードバック学習、Watch での確認に対応。',
        tags: ['Scheduled', 'Cards', 'Watch']
      },
      {
        kicker: '06 / WATCH & SYNC',
        title: 'iPhone ↔ Watch 同期',
        body: 'WatchConnectivity & CloudKit バックグラウンド漫遊。世代ポインタと競合自動解決を搭載。',
        tags: ['WatchConnectivity', 'CloudKit']
      },
      {
        kicker: '07 / WATCH NATIVE',
        title: '手首の上の完全な体験',
        body: 'Digital Crown ズーム、Markdown + コードハイライト、思考タイムライン、TTS 読み上げをサポート。',
        tags: ['watchOS', 'Digital Crown', 'Voice']
      },
      {
        kicker: '08 / SECURITY & BACKUP',
        title: 'SQLCipher 暗号化 & クラウドバックアップ',
        body: 'SQLCipher 物理全盤暗号化、PBKDF2 + Face ID アプリロック。暗号化 `.elsbackup` や S3 / Cloudflare R2 クラウドバックアップに対応。',
        tags: ['SQLCipher', 'Face ID', 'S3/R2']
      }
    ]
  },
  screenshots: {
    title: '実際の画面をご覧ください。',
    lead: '現在のリアルビルドからのスクリーンショットです。',
    captionOne: 'iOS · チャット画面',
    captionTwo: 'Apple Watch · セッション画面'
  },
  privacy: {
    title: 'あなたの Key、あなたのデータ。',
    lead: '中継サーバーはありません。リクエストはあなたのデバイスからモデルへ直接送信され、会話はローカル SQLite (SQLCipher) に保存されます。',
    bullets: [
      { kicker: 'BYOK', title: 'API Key は自身で管理', body: 'リクエストを転送・キャッシュ・課金することはありません。' },
      { kicker: 'LOCAL FIRST', title: '端末内暗号化保存', body: 'SQLCipher 全盤暗号化 + Face ID ロック。' },
      { kicker: 'EXPORTABLE', title: 'データのエクスポート', body: 'ワンクリックで `.elsbackup` パックを出力・移行可能。' },
      { kicker: 'OPEN SOURCE', title: 'GPLv3 ライセンス', body: 'コードは公開されており監査可能です。' }
    ]
  },
  tech: {
    title: 'ネイティブツールによる極上のネイティブ体験。',
    lead: 'Electron も React Native もなし。高速で強力。',
    items: [
      { name: 'Swift 6 · SwiftUI', desc: 'iOS 18 + watchOS 11 ネイティブ UI。' },
      { name: 'llama.cpp C ABI', desc: 'iOS 上で GGUF を実行し Metal 加速。' },
      { name: 'Swift MCP SDK', desc: '公式 Model Context Protocol SDK。' },
      { name: 'GRDB · SQLCipher', desc: '暗号化 SQLite とレスポンシブクエリ。' },
      { name: 'WatchConnectivity & CloudKit', desc: '低遅延の世代管理同期。' },
      { name: 'SFSpeechRecognizer & TTS', desc: '音声認識と自動フォールバック付き読み上げ。' }
    ]
  },
  cta: {
    title: '10分で最初の会話を。',
    lead: 'インストールから最初の返信までわかりやすく案内します。',
    primary: 'ガイドを読む',
    secondary: 'GitHub で見る',
    secondaryDesc: 'Star や Issue、PR 大歓迎。'
  },
  footer: {
    madeBy: 'Made with care by',
    author: 'Eric-Terminal',
    license: 'GPL-3.0 License',
    repo: 'github.com/Eric-Terminal/ETOS-LLM-Studio',
    docs: 'ドキュメント',
    backToTop: 'トップに戻る'
  },
  loader: {
    kicker: 'HELLO FROM ETOS',
    line: 'BOOTING LANDING',
    year: '2026'
  },
  ui: {
    theme: { light: 'ライト', dark: 'ダーク' },
    langHint: '言語を選択してください。'
  }
};

const ru = {
  meta: {
    title: 'ETOS LLM Studio · Нативный AI-клиент',
    subtitle: 'Нативный AI-клиент для iPhone + Apple Watch · Локальные GGUF модели'
  },
  nav: {
    localModel: 'Локальный LLM',
    features: 'Возможности',
    mcpSkills: 'MCP и Инструменты',
    personalize: 'Персонализация',
    privacy: 'Конфиденциальность',
    tech: 'Стек',
    docs: 'Доки',
    github: 'GitHub',
    download: 'Скачать App'
  },
  hero: {
    title: 'Ваш ИИ. В кармане и на запястье.',
    lead:
      'Нативный LLM-клиент для iPhone и Apple Watch. Поддержка локальных GGUF моделей, MCP протокола, Agent Skills и шифрования SQLCipher. Без промежуточных серверов.',
    actionsPrimary: 'Быстрый старт',
    actionsSecondary: 'Модули и функции',
    statusOnline: 'В активной разработке · 750+ Swift файлов',
    statusBadge: 'BUILT FOR APPLE PLATFORMS'
  },
  stats: [
    { label: 'Файлов Swift', val: '750+' },
    { label: 'Строк кода Swift', val: '280,000+' },
    { label: 'Промежуточных серверов', val: '0' },
    { label: 'Локальное шифрование', val: '100% Local' }
  ],
  localDemo: {
    badge: 'Локальная модель на устройстве',
    title: 'Нативный GGUF инференс и HUD производительности на iOS',
    lead: 'Работает полностью без интернета. Модели GGUF исполняются через C ABI llama.cpp с ускорением Metal GPU и онлайн-монитором CPU/Metal/Памяти.',
    selectModelLabel: 'Выберите модель GGUF',
    thinkHeader: 'Таймлайн размышлений (Thinking Timeline)',
    userQuestion: 'Требуется ли интернет или API ключ для локальной модели GGUF?',
    kvCacheActiveLabel: 'Префикс KV Cache активирован',
    kvCacheInactiveLabel: 'KV Cache отключен',
    models: [
      {
        name: 'Phi-4-mini-Instruct.Q4_K_M.gguf',
        size: '2.48 GB',
        hud: {
          cpuMetal: '13%',
          cpuOnly: '63%',
          gpuMetal: '78%',
          ramMetal: '2.7 GB (Metal)',
          ramMetalKV: '3.0 GB (Metal + KV)',
          ramCpu: '3.1 GB (RAM)',
          ramCpuKV: '3.4 GB (RAM + KV)',
          speedFlash: 49.6,
          speedFlashKV: 57.8,
          speedBase: 29.8,
          speedKV: 34.2
        },
        thinking: 'Ускорение Metal GPU, анализ контекста чата и шаблона GGUF Jinja...',
        response: 'Интернет и API ключ не требуются! Веса модели и векторная база SQLite работают 100% локально на вашем iPhone.'
      },
      {
        name: 'Gemma-3-4B-Instruct.Q4_K_M.gguf',
        size: '2.85 GB',
        hud: {
          cpuMetal: '17%',
          cpuOnly: '69%',
          gpuMetal: '84%',
          ramMetal: '3.1 GB (Metal)',
          ramMetalKV: '3.5 GB (Metal + KV)',
          ramCpu: '3.7 GB (RAM)',
          ramCpuKV: '4.1 GB (RAM + KV)',
          speedFlash: 38.0,
          speedFlashKV: 44.3,
          speedBase: 23.2,
          speedKV: 26.8
        },
        thinking: 'Checking local GGUF memory budget and Metal GPU offload layers...',
        response: 'Локальный инференс Gemma 3 4B завершен! Metal GPU и KV Cache активны, а память включает дополнительный контекстный кэш.'
      },
      {
        name: 'Qwen3-8B-Instruct.Q4_K_M.gguf',
        size: '4.92 GB',
        hud: {
          cpuMetal: '24%',
          cpuOnly: '82%',
          gpuMetal: '91%',
          ramMetal: '5.2 GB (Metal)',
          ramMetalKV: '5.8 GB (Metal + KV)',
          ramCpu: '6.1 GB (RAM)',
          ramCpuKV: '6.8 GB (RAM + KV)',
          speedFlash: 26.4,
          speedFlashKV: 30.5,
          speedBase: 15.7,
          speedKV: 18.2
        },
        thinking: 'Разбор цепочки <think>: 1. Поиск SQLite; 2. Совпадение KV Cache; 3. Генерация шагов...',
        response: 'Локальный инференс Qwen3 8B завершен. HUD показывает пропускную способность и память с учетом масштаба 8B модели.'
      }
    ]
  },
  mcpSkillsSection: {
    badge: 'Инструменты и экосистема',
    title: 'Протокол MCP · Agent Skills · Песочница JS',
    lead: 'Официальный Swift MCP SDK, импорт Agent Skills с GitHub в один клик и изолированный запуск JS-скриптов.',
    tabs: [
      {
        id: 'mcp',
        type: 'BUILT-IN APP TOOL',
        title: 'Встроенный инструмент системного времени',
        badge: 'Built-in App Tool',
        desc: 'Когда AI требуется время устройства, он вызывает встроенный App Tool. Это не внешний MCP инструмент, и аргументы не нужны.',
        snippet: `// Built-in App Tool Execution
{
  "tool": "app_get_system_time",
  "arguments": {}
}`
      },
      {
        id: 'skills',
        type: 'AGENT SKILLS',
        title: 'Импорт навыков GitHub',
        badge: 'Agentic Skill Pack',
        desc: 'Вставьте ссылку на GitHub или RAW URL для внедрения пакетов навыков ревью кода и рабочих процессов.',
        snippet: `---
name: code-reviewer-pro
description: "Inspect Swift & Rust diffs for memory leaks"
allowed-tools:
  - app_read_sandbox_file
  - app_query_sqlite
---

# CodeReviewer Pro

Check Swift closure captures, Rust unsafe boundaries, and database migration risks.`
      },
      {
        id: 'jsc',
        type: 'JSC JS TOOL',
        title: 'Форматирование JavaScriptCore',
        badge: 'app_create_custom_jsc_js_tool',
        desc: 'Создавайте многоразовые инструменты JS с синхронной функцией main(input), сохраняемые в CustomJSTools.',
        snippet: `// CustomJSTools/format_currency.js
// Движок iOS JSC: Синхронная функция без Node/fetch/Promise
function main(input) {
  var amount = input.amount || 0;
  var currency = input.currency || 'USD';
  return {
    formatted: currency + ' ' + amount.toFixed(2),
    timestamp: new Date().toISOString()
  };
}`
      },
      {
        id: 'rag',
        type: 'SQLCIPHER RAG',
        title: 'Зашифрованная база SQLite RAG',
        badge: 'GRDB + SQLCipher',
        desc: 'Долгосрочная память сохраняется в зашифрованной базе SQLite с поддержкой SillyTavern Worldbook.',
        snippet: `-- memory_vectors.sqlite
CREATE TABLE memory_chunks (
  chunk_id TEXT PRIMARY KEY,
  parent_memory_id TEXT NOT NULL,
  text TEXT NOT NULL,
  embedding BLOB NOT NULL,
  metadata TEXT NOT NULL
) STRICT;`
      }
    ]
  },
  personalize: {
    title: 'Ваш уникальный Studio.',
    lead: 'Загрузите обои, выберите цвет баббла, настройте стиль AI — предпросмотр справа меняется в реальном времени.',
    pickerHint: 'Настройте элементы слева',
    wallpaperLabel: 'Фоновый слой',
    wallpaperAction: 'Выбрать обои',
    colorLabel: 'Цветовой профиль',
    hideBubbleLabel: 'Скрыть баббл ассистента',
    reset: 'Сбросить',
    chat: {
      title: 'Приветствие',
      user: 'Привет',
      bot: 'Привет! 👋\nЧем я могу помочь? Локальные GGUF модели, MCP инструменты, Agent Skills или промпты — обращайтесь!',
      placeholder: 'Сообщение…'
    }
  },
  features: {
    title: 'Не просто оболочка. Нативный гражданин экосистемы Apple.',
    lead: 'Главный экран — это только чат. Всё остальное бережно убрано в Настройки.',
    items: [
      {
        kicker: '01 / CHAT & PROVIDERS',
        title: 'Многомодельность и совместимость',
        body: 'Поддержка OpenAI, Claude, Gemini и любых совместимых API. Ротация ключей, пользовательские параметры и JSON.',
        tags: ['OpenAI', 'Claude', 'Gemini', 'Custom']
      },
      {
        kicker: '02 / LOCAL GGUF',
        title: 'Локальные GGUF модели и HUD',
        body: 'Прямой запуск весов GGUF на iOS через llama.cpp C ABI. Ускорение Metal GPU, Flash Attention и плавающий HUD.',
        tags: ['llama.cpp', 'GGUF', 'Metal GPU', 'HUD']
      },
      {
        kicker: '03 / TOOLS & SKILLS',
        title: 'Протокол MCP · Agent Skills · JS',
        body: 'Единый центр управления MCP серверами, пакетами Agent Skills, Shortcuts и локальными инструментами.',
        tags: ['MCP SDK', 'Agent Skills', 'Shortcuts']
      },
      {
        kicker: '04 / RAG & WORLDBOOK',
        title: 'Локальная память RAG и Worldbook',
        body: 'Долгосрочные факты, совместимый с SillyTavern Worldbook (Lorebook) и векторный индекс в SQLite.',
        tags: ['Memory', 'Worldbook', 'SQLite']
      },
      {
        kicker: '05 / DAILY PULSE',
        title: 'Daily Pulse — активная аналитика',
        body: 'Ежедневная генерация карточек новостей и задач с обучением по отзывам и просмотром на Apple Watch.',
        tags: ['Scheduled', 'Cards', 'Watch']
      },
      {
        kicker: '06 / WATCH & SYNC',
        title: 'Синхронизация iPhone ↔ Watch',
        body: 'Прямой канал WatchConnectivity и CloudKit с генераторными указателями и защитой от конфликтов.',
        tags: ['WatchConnectivity', 'CloudKit']
      },
      {
        kicker: '07 / WATCH NATIVE',
        title: 'Полноценный опыт на запястье',
        body: 'Зум с Digital Crown, подсветка кода, таймлайн размышлений и озвучка TTS.',
        tags: ['watchOS', 'Digital Crown', 'Voice']
      },
      {
        kicker: '08 / SECURITY & BACKUP',
        title: 'Шифрование SQLCipher и бэкапы',
        body: 'Физическое шифрование SQLCipher, защита Face ID, зашифрованные `.elsbackup` и бэкапы в S3 / Cloudflare R2.',
        tags: ['SQLCipher', 'Face ID', 'S3/R2']
      }
    ]
  },
  screenshots: {
    title: 'Как это выглядит в действии.',
    lead: 'Скриншоты из текущей сборки.',
    captionOne: 'iOS · Чат и панели',
    captionTwo: 'Apple Watch · Экран сессии'
  },
  privacy: {
    title: 'Ваши ключи. Ваши данные. Ваше устройство.',
    lead: 'Никаких промежуточных серверов. Запросы отправляются напрямую с устройства, чаты хранятся в локальном SQLCipher.',
    bullets: [
      { kicker: 'BYOK', title: 'Свой API ключ', body: 'Мы не проксируем и не кэшируем ваши запросы.' },
      { kicker: 'LOCAL FIRST', title: 'Шифрование на устройстве', body: 'База данных SQLCipher + блокировка Face ID.' },
      { kicker: 'EXPORTABLE', title: 'Экспорт данных', body: 'Экспорт `.elsbackup` в один клик для легкого переноса.' },
      { kicker: 'OPEN SOURCE', title: 'Лицензия GPLv3', body: 'Открытый исходный код для полного аудита.' }
    ]
  },
  tech: {
    title: 'Нативные инструменты для нативной скорости.',
    lead: 'Без Electron. Без React Native. Без WebView.',
    items: [
      { name: 'Swift 6 · SwiftUI', desc: 'Нативный UI для iOS 18 и watchOS 11.' },
      { name: 'llama.cpp C ABI', desc: 'Запуск GGUF весов с Metal GPU на iOS.' },
      { name: 'Swift MCP SDK', desc: 'Официальный SDK Model Context Protocol.' },
      { name: 'GRDB · SQLCipher', desc: 'Зашифрованный SQLite с реактивными запросами.' },
      { name: 'WatchConnectivity & CloudKit', desc: 'Низколатентная синхронизация без серверов.' },
      { name: 'SFSpeechRecognizer & TTS', desc: 'Распознавание и озвучка речи с фоллбэком.' }
    ]
  },
  cta: {
    title: 'Первый чат за 10 минут.',
    lead: 'Простые инструкции от установки до первого ответа.',
    primary: 'Быстрый старт',
    secondary: 'Код на GitHub',
    secondaryDesc: 'Star, issue и PR приветствуются.'
  },
  footer: {
    madeBy: 'Made with care by',
    author: 'Eric-Terminal',
    license: 'GPL-3.0 License',
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
    langHint: 'Выберите язык.'
  }
};

const zhHant = {
  meta: {
    title: 'ETOS LLM Studio · 原生 AI 客戶端',
    subtitle: 'iPhone + Apple Watch 原生 AI 客戶端 · 端側 LLM 與全能工具中心'
  },
  nav: {
    localModel: '端側 LLM',
    features: '功能矩陣',
    mcpSkills: '工具與技能',
    personalize: '個性化',
    privacy: '隱私與安全',
    tech: '技術棧',
    docs: '文檔',
    github: 'GitHub',
    download: '獲取 App'
  },
  hero: {
    title: '你的 AI，揣在手裡，戴在腕上。',
    lead:
      '運行在 iPhone 與 Apple Watch 上的原生 LLM 客戶端。支援 GGUF 端側本地模型、MCP 工具協議、Agent Skills 與 SQLCipher 物理加密。你的 Key、你的數據，零中間伺服器。',
    actionsPrimary: '輕鬆上手教程',
    actionsSecondary: '探索功能模組',
    statusOnline: '持續迭代中 · 750+ Swift 源檔案',
    statusBadge: 'BUILT FOR APPLE PLATFORMS'
  },
  stats: [
    { label: 'Swift 源檔案', val: '750+' },
    { label: '原生 Swift 代碼行', val: '280,000+' },
    { label: '中間伺服器', val: '0' },
    { label: '隱私與物理加密', val: '100% Local' }
  ],
  localDemo: {
    badge: '端側本地模型',
    title: 'iOS 端側硬核 GGUF 本地模型推理',
    lead: '不需要連接任何網路或 API 服務。底層通過 llama.cpp C ABI 橋接，直接在 iPhone 上加載 GGUF 權重，並提供實時 CPU / Metal / 記憶體性能監視器。',
    selectModelLabel: '選擇本地 GGUF 模型',
    thinkHeader: '本地模型思考時間線 (Thinking Timeline)',
    userQuestion: '運行端側 GGUF 本地模型需要連接網路或 API Key 嗎？',
    kvCacheActiveLabel: 'KV Cache 前綴複用已生效',
    kvCacheInactiveLabel: 'KV Cache 未開啟',
    models: [
      {
        name: 'Phi-4-mini-Instruct.Q4_K_M.gguf',
        size: '2.48 GB',
        hud: {
          cpuMetal: '13%',
          cpuOnly: '63%',
          gpuMetal: '78%',
          ramMetal: '2.7 GB (Metal)',
          ramMetalKV: '3.0 GB (Metal + KV)',
          ramCpu: '3.1 GB (RAM)',
          ramCpuKV: '3.4 GB (RAM + KV)',
          speedFlash: 49.6,
          speedFlashKV: 57.8,
          speedBase: 29.8,
          speedKV: 34.2
        },
        thinking: '正在使用 Metal GPU 加速計算，分析對話上下文與 GGUF Jinja 對話模板...',
        response: '完全不需要網路或 API Key！模型權重與 Embedding 嵌入向量數據庫完全運行在你的 iPhone 本機設備上。零聯網權限，不消耗流量，隱私 100% 物理隔離。'
      },
      {
        name: 'Gemma-3-4B-Instruct.Q4_K_M.gguf',
        size: '2.85 GB',
        hud: {
          cpuMetal: '17%',
          cpuOnly: '69%',
          gpuMetal: '84%',
          ramMetal: '3.1 GB (Metal)',
          ramMetalKV: '3.5 GB (Metal + KV)',
          ramCpu: '3.7 GB (RAM)',
          ramCpuKV: '4.1 GB (RAM + KV)',
          speedFlash: 38.0,
          speedFlashKV: 44.3,
          speedBase: 23.2,
          speedKV: 26.8
        },
        thinking: 'Checking local GGUF memory budget and Metal GPU offload layers...',
        response: 'Gemma 3 4B 本地推理完成！全流式 Metal GPU 加速輸出與 KV Cache 快取前綴複用正常，記憶體佔用會隨上下文快取同步增加。'
      },
      {
        name: 'Qwen3-8B-Instruct.Q4_K_M.gguf',
        size: '4.92 GB',
        hud: {
          cpuMetal: '24%',
          cpuOnly: '82%',
          gpuMetal: '91%',
          ramMetal: '5.2 GB (Metal)',
          ramMetalKV: '5.8 GB (Metal + KV)',
          ramCpu: '6.1 GB (RAM)',
          ramCpuKV: '6.8 GB (RAM + KV)',
          speedFlash: 26.4,
          speedFlashKV: 30.5,
          speedBase: 15.7,
          speedKV: 18.2
        },
        thinking: '正在解析 <think> 推理鏈：1. 檢索本地 SQLite 數據庫；2. 匹配 KV Cache 快取前綴；3. 生成結構化思考步驟...',
        response: 'Qwen3 8B 本地推理完成！全流式 Metal GPU 加速輸出與 KV Cache 快取前綴複用正常，吞吐與記憶體佔用按 8B 模型規模顯示。'
      }
    ]
  },
  mcpSkillsSection: {
    badge: '工具與生態',
    title: 'MCP 協議 · Agent Skills · 沙盒 JS',
    lead: '集成 Swift Model Context Protocol (MCP) 官方 SDK，支援從 GitHub 一鍵導入 Agent Skills 技能包，並可在沙盒內運行自定義 JavaScript 工具。',
    tabs: [
      {
        id: 'mcp',
        type: 'BUILT-IN APP TOOL',
        title: '內建系統時間工具',
        badge: 'Built-in App Tool',
        desc: '在 AI 想要獲取設備時間時，調用內建 App Tool；它不屬於外部 MCP 工具，參數為空。',
        snippet: `// Built-in App Tool Execution
{
  "tool": "app_get_system_time",
  "arguments": {}
}`
      },
      {
        id: 'skills',
        type: 'AGENT SKILLS',
        title: 'GitHub 技能包一鍵導入',
        badge: 'Agentic Skill Pack',
        desc: '直接粘貼 GitHub 倉庫鏈接或 RAW 檔案地址，即刻注入代碼審查、海報生成或工作流指令集。',
        snippet: `---
name: code-reviewer-pro
description: "Inspect Swift & Rust diffs for memory leaks"
allowed-tools:
  - app_read_sandbox_file
  - app_query_sqlite
---

# CodeReviewer Pro

檢查 Swift 閉包捕獲列表、Rust unsafe 邊界與資料庫遷移風險。`
      },
      {
        id: 'jsc',
        type: 'JSC JS TOOL',
        title: 'JavaScriptCore 格式化工具',
        badge: 'app_create_custom_jsc_js_tool',
        desc: '創建可複用的 iOS JSC 自定義腳本工具，腳本聲明同步 function main(input)，保存在 CustomJSTools 目錄。',
        snippet: `// CustomJSTools/format_currency.js
// iOS JSC 執行引擎：同步函數，無 Node/fetch/Promise
function main(input) {
  var amount = input.amount || 0;
  var currency = input.currency || 'USD';
  return {
    formatted: currency + ' ' + amount.toFixed(2),
    timestamp: new Date().toISOString()
  };
}`
      },
      {
        id: 'rag',
        type: 'SQLCIPHER RAG',
        title: 'SQLite 全盤物理加密向量庫',
        badge: 'GRDB + SQLCipher',
        desc: '本地 Embedding 與長效記憶直接落地在加密 SQLite 數據庫中，支援 SillyTavern 世界書觸發。',
        snippet: `-- memory_vectors.sqlite
CREATE TABLE memory_chunks (
  chunk_id TEXT PRIMARY KEY,
  parent_memory_id TEXT NOT NULL,
  text TEXT NOT NULL,
  embedding BLOB NOT NULL,
  metadata TEXT NOT NULL
) STRICT;`
      }
    ]
  },
  personalize: {
    title: '一眼認得出，是你的 Studio。',
    lead: '上傳一張桌布、挑一個對話框顏色、要不要 AI 氣泡——右邊這台實時跟著變。',
    pickerHint: '調下面三項，右側實時預覽',
    wallpaperLabel: '背景圖層',
    wallpaperAction: '選擇背景圖',
    colorLabel: '顏色配置',
    hideBubbleLabel: '關閉助手氣泡',
    reset: '恢復預設',
    chat: {
      title: '問候與幫助',
      user: '你好',
      bot: '你好！👋\n很高興見到你，有什麼想聊的或者需要幫忙的嗎？無論是端側 GGUF 調參、MCP 工具配置、Agent Skills 導入，還是日常問答，都可以直接告訴我。',
      placeholder: '輸入訊息…'
    }
  },
  features: {
    title: '不是套殼。是把模型當 Apple 平台公民來設計。',
    lead: '主界面只留聊天，其餘全部收進設定。下面這些是你裝好之後會陸續找到的能力。',
    items: [
      {
        kicker: '01 / CHAT & PROVIDERS',
        title: '多模型 · 多 Provider · 兼容到底',
        body:
          '原生適配 OpenAI Chat、OpenAI Responses、Anthropic、Gemini，外加任意 OpenAI 兼容介面。支援多 Key 輪詢、參數表達式、原始 JSON 請求體、單條 AI 回覆重寫與計費估算。',
        tags: ['OpenAI', 'Claude', 'Gemini', 'Custom JSON']
      },
      {
        kicker: '02 / LOCAL GGUF',
        title: '端側 GGUF 本地模型 & 性能監視器',
        body:
          '底層通過 llama.cpp C ABI 橋接，在 iOS 上直接運行 GGUF 本地權重。支援 Metal GPU 加速、Flash Attention、KV offload、流式思考解析與浮動性能監視面板（CPU/Metal/RAM）。',
        tags: ['llama.cpp', 'GGUF', 'Metal GPU', '性能 HUD']
      },
      {
        kicker: '03 / TOOLS & SKILLS',
        title: 'MCP 協議 · Agent Skills · 沙盒 JS',
        body:
          '統一管理 MCP 伺服器（Streamable HTTP/SSE）、Agent Skills 技能包（GitHub/RAW 導入）、iOS 快捷指令與內建 SQLite/檔案沙盒/健康/日曆工具，具備原生問答 Sheet 審批控制。',
        tags: ['MCP SDK', 'Agent Skills', 'Shortcuts', '審批 Sheet']
      },
      {
        kicker: '04 / RAG & WORLDBOOK',
        title: '本地 RAG 記憶 · 世界書 · 嵌入向量',
        body:
          '跨會話長期事實記憶、支援 SillyTavern 兼容的世界書 Lorebook（條件觸發、注入預算）與用戶畫像。向量索引完全本地 SQLite 運行，絕不下發雲端。',
        tags: ['長期記憶', '世界書 Lorebook', 'SQLite 向量']
      },
      {
        kicker: '05 / DAILY PULSE',
        title: 'Daily Pulse 每日脈衝主動情報',
        body:
          '每天定時預生成主動情報卡片：新聞、郵件提醒、日程預判、技術摘要。支援卡片一鍵轉待跟進任務與長效偏好反饋學習，抬腕即看。',
        tags: ['定時', '情報卡片', '任務跟進', 'Watch 抬腕']
      },
      {
        kicker: '06 / WATCH & SYNC',
        title: 'iPhone ↔ Watch 權威增量同步',
        body:
          'WatchConnectivity 局域網快速通道 + CloudKit / APNs 後台漫遊。雙端配備權威世代指針與數據覆蓋衝突裁決短語，離線分叉合併零丟失。',
        tags: ['WatchConnectivity', 'CloudKit', '世代指針']
      },
      {
        kicker: '07 / WATCH NATIVE',
        title: '手腕上的完整體驗，不是醃割版',
        body:
          '數碼錶冠縮放圖片、Markdown 與代碼高亮、思考時間線、TTS 朗讀、單會話跨端發送。watchOS 設定扁平化為單層 List，零 TabView。',
        tags: ['watchOS', '數碼錶冠', '抬腕語音', 'TTS']
      },
      {
        kicker: '08 / SECURITY & BACKUP',
        title: 'SQLCipher 全盤加密 & 快照備份',
        body:
          '底層數據庫採用 SQLCipher 物理加密，結合 PBKDF2 主密碼與 Face ID / Touch ID 應用鎖。支援加密快照 `.elsbackup` 導出及 Cloudflare R2 / S3 簽名雲備份。',
        tags: ['SQLCipher', 'Face ID 鎖', 'AES-256', 'S3/R2 雲備份']
      }
    ]
  },
  screenshots: {
    title: '看看它在你手裡是什麼樣。',
    lead: '截圖直接來自當前真實 Build。',
    captionOne: 'iOS · 聊天與功能面板',
    captionTwo: 'Apple Watch · 獨立端側體驗'
  },
  privacy: {
    title: '你的 Key，你的數據，你的設備。',
    lead:
      '沒有任何中間伺服器。模型請求從你的設備直接發出，對話存在本地 SQLite（SQLCipher 加密），同步通過 iPhone 與 Watch 在局域網或 CloudKit 完成。要不要交給第三方，全是你的選擇。',
    bullets: [
      { kicker: 'BYOK', title: '你提供 Key，App 直發模型', body: '我們不代付、不轉發、不快取你的請求。' },
      { kicker: 'LOCAL FIRST', title: '會話與記憶存在本地', body: 'SQLCipher 全盤加密，配合 Face ID 應用鎖。' },
      { kicker: 'EXPORTABLE', title: 'ETOS 數據包與加密快照', body: '一鍵導出/導入 `.elsbackup`，跨端遷移無痛。' },
      { kicker: 'OPEN SOURCE', title: 'GPLv3 開源', body: '代碼完全公開可審計，歡迎 PR 與 Issue。' }
    ]
  },
  tech: {
    title: '用原生工具，做原生體驗。',
    lead: '沒有 Electron，沒有 React Native，沒有 WebView 套殼。快速，性能超強。',
    items: [
      { name: 'Swift 6 · SwiftUI', desc: 'iOS 18 + watchOS 11 原生 UI，遵循 Apple HIG。' },
      { name: 'llama.cpp C ABI', desc: 'iOS 端側運行 GGUF 權重，Metal GPU 加速與性能 HUD。' },
      { name: 'Swift MCP SDK', desc: 'Model Context Protocol 官方 SDK，支援 SSE / Streamable HTTP。' },
      { name: 'GRDB · SQLCipher', desc: '物理全盤加密 SQLite + ValueObservation 響應式查詢。' },
      { name: 'WatchConnectivity & CloudKit', desc: '雙端低延遲增量同步，帶世代指針與 APNs 靜默喚醒。' },
      { name: 'SFSpeechRecognizer & TTS', desc: '系統與雲端語音識別及朗讀引擎，實時回填與自動回退。' }
    ]
  },
  cta: {
    title: '十分鐘跑通第一條對話。',
    lead: '裝機、配 Provider、第一條訊息，每一步都告訴你點哪裡。',
    primary: '閱讀上手教程',
    secondary: 'GitHub 原始碼',
    secondaryDesc: '歡迎 Star、Issue、PR。'
  },
  footer: {
    madeBy: 'Made with care by',
    author: 'Eric-Terminal',
    license: 'GPL-3.0 License',
    repo: 'github.com/Eric-Terminal/ETOS-LLM-Studio',
    docs: '文檔站',
    backToTop: '回到頂部'
  },
  loader: {
    kicker: 'HELLO FROM ETOS',
    line: 'BOOTING LANDING',
    year: '2026'
  },
  ui: {
    theme: { light: '淺色', dark: '深色' },
    langHint: '選擇你順手的語言。'
  }
};

export const translations = {
  zh,
  en,
  ja,
  ru,
  'zh-Hant': zhHant
};
