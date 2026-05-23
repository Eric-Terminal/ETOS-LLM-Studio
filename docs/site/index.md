---
layout: home

hero:
  name: ETOS LLM Studio
  text: iPhone + Apple Watch 原生 AI 客户端
  tagline: 自带 API Key、本地存储、双端同步、零中间服务器。对接 OpenAI / Claude / Gemini / 任意 OpenAI 兼容服务，并支持记忆、世界书、MCP、Skills、每日脉冲与快捷指令。
  image:
    src: /images/hero/etos-hero.jpg
    alt: ETOS LLM Studio 宣传图
  actions:
    - theme: brand
      text: 10 分钟跑通第一条对话
      link: /guide/getting-started
    - theme: alt
      text: 功能模块详解
      link: /modules/chat-and-models
    - theme: alt
      text: GitHub
      link: https://github.com/Eric-Terminal/ETOS-LLM-Studio

features:
  - icon: 📱
    title: iPhone + Apple Watch 双端原生
    details: 两端都有独立交互路径，按屏幕尺寸重新组织入口；不是手机端套个手表壳。
  - icon: 🔌
    title: 你的 Key，你的数据
    details: 模型请求直接从设备发出，不经过中间服务器；所有会话存在本机 SQLite，可随时导出 ETOS 数据包。
  - icon: 🧠
    title: 长期记忆 + 世界书 + 每日脉冲
    details: 不仅仅是一轮对话——把跨会话事实、关键词触发的知识库、定时主动情报全部接进流程。
  - icon: 🧰
    title: MCP / Skills / 快捷指令 / 文件工具
    details: 让模型获得"插件能力"。MCP 接外部服务、Skills 是本地能力包、Shortcuts 把 iOS 自动化暴露给模型当工具。
  - icon: 🎛️
    title: 高级请求配置
    details: 多 Key 轮询、自定义请求头、参数表达式、原始 JSON 请求体、提供商级 / 全局两层代理——什么诡异的兼容接口都能接。
  - icon: 🔄
    title: 双端同步 + 第三方导入
    details: iPhone ↔ Watch 局域网直连同步；支持从 Cherry Studio、RikkaHub、Kelivo、ChatGPT 官方导出迁移过来。
---

## 这文档站是干什么的

ETOS LLM Studio 把功能全收纳进「设置」里，主界面只留聊天。这样做让日常使用变干净，但带来一个问题：**很多功能就算装好了 App 也找不到**。

这份文档站做三件事：

1. **手把手教程**：从下载装机到第一条对话能聊，每一步都告诉你点哪里、填什么、看到什么算成功。
2. **功能详解**：每个功能从「这是什么、解决你什么问题、不用会怎样」讲起，再到具体配置。
3. **设计原理**：如果你想知道"为什么 ETOS 这样设计"——上下文怎么拼装、每日脉冲依赖哪些信号、世界书的注入规则——这里有完整解释。

## 我应该从哪开始读

| 你的情况 | 推荐入口 |
| --- | --- |
| 刚听说，还没下载 | [入门总览](/guide/getting-started)（10 分钟跑通） |
| 已装好但不知道下一步 | [第一次配置提供商](/guide/first-provider) |
| 已能聊天，想认识全部功能 | [界面导览](/guide/interface-tour) |
| 想挑某个功能深挖 | [功能模块](/modules/chat-and-models) |
| 想看为什么 ETOS 这样设计 | [设计文档](/design/) |
| 单纯想看技巧 | [隐藏技巧](/tips/hidden-gems) |
| 遇到问题 | [常见问题](/faq/) |

## 界面预览

很多功能并不会自己跳到脸上——这份文档站存在的目的就是把它们的物理位置、推荐使用顺序、和那些默认不会解释的入口补齐。

<div class="etos-gallery">
  <figure>
    <img src="/images/screenshots/screenshot-01.png" alt="聊天页面截图">
    <figcaption>聊天页不是简单的消息列表——模型切换、附件、工具开关、思考过程、TTS 朗读、消息导出全部都在这一屏内。</figcaption>
  </figure>
  <figure>
    <img src="/images/screenshots/screenshot-02.png" alt="设置页面截图">
    <figcaption>设置页是整台 AI 工作台的总控台。提供商、工具、记忆、同步、每日脉冲、反馈系统都在这里分组管理。</figcaption>
  </figure>
</div>
