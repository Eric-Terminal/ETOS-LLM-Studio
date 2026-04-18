import { defineConfig } from "vitepress";
import { defineTeekConfig } from "vitepress-theme-teek/config";

const teekConfig = defineTeekConfig({
  teekHome: false,
  vpHome: true,
  pageStyle: "default",
  themeSize: "wide",
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

export default defineConfig({
  extends: teekConfig,
  lang: "zh-CN",
  title: "ETOS LLM Studio",
  description: "运行在 iPhone 与 Apple Watch 上的原生 AI 客户端文档站。",
  cleanUrls: true,
  lastUpdated: true,
  ignoreDeadLinks: false,
  head: [
    ["meta", { name: "theme-color", content: "#f6f6f7" }],
    ["meta", { name: "mobile-web-app-capable", content: "yes" }],
    ["meta", { name: "apple-mobile-web-app-capable", content: "yes" }],
    ["meta", { name: "apple-mobile-web-app-status-bar-style", content: "default" }],
    ["link", { rel: "icon", href: "/icon.png" }]
  ],
  themeConfig: {
    siteTitle: "ETOS LLM Studio Docs",
    nav: [
      { text: "快速开始", link: "/guide/getting-started" },
      { text: "设计文档", link: "/design/" },
      { text: "功能模块", link: "/modules/chat-and-models" },
      { text: "隐藏技巧", link: "/tips/hidden-gems" },
      { text: "常见问题", link: "/faq/" },
      { text: "GitHub", link: "https://github.com/Eric-Terminal/ETOS-LLM-Studio" }
    ],
    sidebar: [
      {
        text: "开始使用",
        items: [
          { text: "总览", link: "/guide/getting-started" },
          { text: "安装与运行", link: "/guide/installation" },
          { text: "第一次配置提供商", link: "/guide/first-provider" },
          { text: "第一次发起聊天", link: "/guide/first-chat" },
          { text: "界面导览", link: "/guide/interface-tour" }
        ]
      },
      {
        text: "设计文档",
        items: [
          { text: "产品设计总览", link: "/design/" },
          { text: "提示词与上下文拼装", link: "/design/prompt-assembly" },
          { text: "Daily Pulse 设计原理", link: "/design/daily-pulse" },
          { text: "记忆、会话摘要与用户画像", link: "/design/memory-and-profile" },
          { text: "世界书与工具治理", link: "/design/worldbook-and-tools" }
        ]
      },
      {
        text: "核心模块",
        items: [
          { text: "聊天与模型", link: "/modules/chat-and-models" },
          { text: "工具与 MCP", link: "/modules/tools-and-mcp" },
          { text: "Skills 与快捷指令", link: "/modules/skills-and-shortcuts" },
          { text: "记忆与世界书", link: "/modules/memory-worldbook" },
          { text: "Daily Pulse", link: "/modules/daily-pulse" },
          { text: "同步与备份", link: "/modules/sync-backup" },
          { text: "调试与反馈", link: "/modules/debug-feedback" }
        ]
      },
      {
        text: "进阶提示",
        items: [
          { text: "隐藏技巧", link: "/tips/hidden-gems" },
          { text: "Apple Watch 使用建议", link: "/tips/watch-usage" }
        ]
      },
      {
        text: "帮助",
        items: [{ text: "常见问题", link: "/faq/" }]
      }
    ],
    outline: {
      level: [2, 3],
      label: "本页目录"
    },
    lastUpdatedText: "最后更新于",
    search: {
      provider: "local"
    },
    socialLinks: [
      { icon: "github", link: "https://github.com/Eric-Terminal/ETOS-LLM-Studio" }
    ],
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
});
