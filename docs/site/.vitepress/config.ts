import { defineConfig } from "vitepress";
import { defineTeekConfig } from "vitepress-theme-teek/config";

const teekConfig = defineTeekConfig({
  teekHome: false,
  vpHome: true,
  pageStyle: "default",
  themeSize: "wide",
  breadcrumb: {
    enabled: false
  },
  articleAnalyze: {
    showCreateDate: false,
    showUpdateDate: false
  },
  articleUpdate: {
    enabled: false
  },
  themeEnhance: {
    enabled: false
  },
  articleShare: false,
  comment: false,
  vitePlugins: {
    sidebar: false,
    permalink: false,
    docAnalysis: false
  },
  footerInfo: {
    theme: {
      show: false
    },
    copyright: {
      show: false
    },
    topMessage:
      "文档基于 <a href=\"https://vitepress.dev/\" target=\"_blank\" rel=\"noreferrer\">VitePress</a> 与 <a href=\"https://github.com/Kele-Bingtang/vitepress-theme-teek\" target=\"_blank\" rel=\"noreferrer\">vitepress-theme-teek</a> 构建",
    customHtml: "<span class=\"etos-footer-copy\">Copyright 2025-2026 Eric Terminal</span>"
  }
});

// -----------------------------------------------------------------------------
// 中文（默认语言，根路径）
// -----------------------------------------------------------------------------
const zhConfig = {
  label: "简体中文",
  lang: "zh-CN",
  title: "ETOS LLM Studio",
  description: "运行在 iPhone 与 Apple Watch 上的原生 AI 客户端文档站。",
  themeConfig: {
    siteTitle: "ETOS LLM Studio Docs",
    nav: [
      { text: "快速开始", link: "/guide/getting-started" },
      { text: "功能模块", link: "/modules/chat-and-models" },
      { text: "进阶提示", link: "/tips/hidden-gems" },
      { text: "设计文档", link: "/design/" },
      { text: "常见问题", link: "/faq/" },
      { text: "GitHub", link: "https://github.com/Eric-Terminal/ETOS-LLM-Studio" }
    ],
    sidebar: {
      "/guide/": [
        {
          text: "开始使用",
          items: [
            { text: "入门总览", link: "/guide/getting-started" },
            { text: "安装与首次启动", link: "/guide/installation" },
            { text: "第一次配置提供商", link: "/guide/first-provider" },
            { text: "第一次发起聊天", link: "/guide/first-chat" },
            { text: "界面导览", link: "/guide/interface-tour" }
          ]
        }
      ],
      "/modules/": [
        {
          text: "核心功能",
          items: [
            { text: "聊天与模型", link: "/modules/chat-and-models" },
            { text: "工具与 MCP", link: "/modules/tools-and-mcp" },
            { text: "Skills 与快捷指令", link: "/modules/skills-and-shortcuts" },
            { text: "记忆与世界书", link: "/modules/memory-worldbook" },
            { text: "每日脉冲", link: "/modules/daily-pulse" },
            { text: "同步与备份", link: "/modules/sync-backup" },
            { text: "调试与反馈", link: "/modules/debug-feedback" }
          ]
        }
      ],
      "/design/": [
        {
          text: "设计文档",
          items: [
            { text: "设计哲学", link: "/design/" },
            { text: "提示词与上下文拼装", link: "/design/prompt-assembly" },
            { text: "每日脉冲设计原理", link: "/design/daily-pulse" },
            { text: "记忆、摘要与画像", link: "/design/memory-and-profile" },
            { text: "世界书与工具治理", link: "/design/worldbook-and-tools" }
          ]
        }
      ],
      "/tips/": [
        {
          text: "进阶提示",
          items: [
            { text: "隐藏技巧", link: "/tips/hidden-gems" },
            { text: "Apple Watch 使用建议", link: "/tips/watch-usage" }
          ]
        }
      ],
      "/faq/": [
        {
          text: "帮助",
          items: [{ text: "常见问题", link: "/faq/" }]
        }
      ]
    },
    outline: {
      level: [2, 3],
      label: "本页目录"
    },
    lastUpdatedText: "最后更新于",
    search: {
      provider: "local" as const,
      options: {
        translations: {
          button: { buttonText: "搜索", buttonAriaLabel: "搜索文档" },
          modal: {
            displayDetails: "显示详细列表",
            resetButtonTitle: "清除查询条件",
            backButtonTitle: "关闭搜索",
            noResultsText: "无法找到相关结果",
            footer: {
              selectText: "选择",
              navigateText: "切换",
              closeText: "关闭"
            }
          }
        }
      }
    },
    socialLinks: [{ icon: "github", link: "https://github.com/Eric-Terminal/ETOS-LLM-Studio" }],
    docFooter: {
      prev: "上一篇",
      next: "下一篇"
    },
    returnToTopLabel: "回到顶部",
    sidebarMenuLabel: "菜单",
    darkModeSwitchLabel: "主题",
    lightModeSwitchTitle: "切换到浅色模式",
    darkModeSwitchTitle: "切换到深色模式"
  }
};

// -----------------------------------------------------------------------------
// English（镜像目录 /en/）
// -----------------------------------------------------------------------------
const enConfig = {
  label: "English",
  lang: "en-US",
  title: "ETOS LLM Studio",
  description: "A native AI client documentation site for iPhone and Apple Watch.",
  themeConfig: {
    siteTitle: "ETOS LLM Studio Docs",
    nav: [
      { text: "Get Started", link: "/en/guide/getting-started" },
      { text: "Modules", link: "/en/modules/chat-and-models" },
      { text: "Tips", link: "/en/tips/hidden-gems" },
      { text: "Design", link: "/en/design/" },
      { text: "FAQ", link: "/en/faq/" },
      { text: "GitHub", link: "https://github.com/Eric-Terminal/ETOS-LLM-Studio" }
    ],
    sidebar: {
      "/en/guide/": [
        {
          text: "Get Started",
          items: [
            { text: "Overview", link: "/en/guide/getting-started" },
            { text: "Install & First Launch", link: "/en/guide/installation" },
            { text: "Add Your First Provider", link: "/en/guide/first-provider" },
            { text: "Start Your First Chat", link: "/en/guide/first-chat" },
            { text: "Interface Tour", link: "/en/guide/interface-tour" }
          ]
        }
      ],
      "/en/modules/": [
        {
          text: "Core Features",
          items: [
            { text: "Chat & Models", link: "/en/modules/chat-and-models" },
            { text: "Tools & MCP", link: "/en/modules/tools-and-mcp" },
            { text: "Skills & Shortcuts", link: "/en/modules/skills-and-shortcuts" },
            { text: "Memory & Worldbook", link: "/en/modules/memory-worldbook" },
            { text: "Daily Pulse", link: "/en/modules/daily-pulse" },
            { text: "Sync & Backup", link: "/en/modules/sync-backup" },
            { text: "Debug & Feedback", link: "/en/modules/debug-feedback" }
          ]
        }
      ],
      "/en/design/": [
        {
          text: "Design Docs",
          items: [
            { text: "Design Philosophy", link: "/en/design/" },
            { text: "Prompt & Context Assembly", link: "/en/design/prompt-assembly" },
            { text: "Daily Pulse Internals", link: "/en/design/daily-pulse" },
            { text: "Memory, Summary & Profile", link: "/en/design/memory-and-profile" },
            { text: "Worldbook & Tool Governance", link: "/en/design/worldbook-and-tools" }
          ]
        }
      ],
      "/en/tips/": [
        {
          text: "Tips",
          items: [
            { text: "Hidden Gems", link: "/en/tips/hidden-gems" },
            { text: "Using Apple Watch", link: "/en/tips/watch-usage" }
          ]
        }
      ],
      "/en/faq/": [
        {
          text: "Help",
          items: [{ text: "FAQ", link: "/en/faq/" }]
        }
      ]
    },
    outline: {
      level: [2, 3],
      label: "On this page"
    },
    lastUpdatedText: "Last updated",
    search: {
      provider: "local" as const
    },
    socialLinks: [{ icon: "github", link: "https://github.com/Eric-Terminal/ETOS-LLM-Studio" }],
    docFooter: {
      prev: "Previous",
      next: "Next"
    },
    returnToTopLabel: "Back to top",
    sidebarMenuLabel: "Menu",
    darkModeSwitchLabel: "Theme",
    lightModeSwitchTitle: "Switch to light mode",
    darkModeSwitchTitle: "Switch to dark mode"
  }
};

export default defineConfig({
  extends: teekConfig,
  cleanUrls: true,
  lastUpdated: true,
  ignoreDeadLinks: false,
  head: [
    ["meta", { name: "theme-color", content: "#f5f5f7" }],
    ["meta", { name: "mobile-web-app-capable", content: "yes" }],
    ["meta", { name: "apple-mobile-web-app-capable", content: "yes" }],
    ["meta", { name: "apple-mobile-web-app-status-bar-style", content: "default" }],
    ["link", { rel: "preconnect", href: "https://fonts.googleapis.com" }],
    ["link", { rel: "preconnect", href: "https://fonts.gstatic.com", crossorigin: "" }],
    [
      "link",
      {
        rel: "stylesheet",
        href: "https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&family=Noto+Sans+SC:wght@300;400;500;600;700&display=swap"
      }
    ],
    ["link", { rel: "icon", href: "/icon.png" }]
  ],
  locales: {
    root: {
      ...zhConfig
    },
    en: {
      ...enConfig,
      link: "/en/"
    }
  }
});
