<script setup>
import { ref, computed } from 'vue';

const props = defineProps({
  text: {
    type: Object,
    required: true
  }
});

const activeTab = ref('mcp'); // 'mcp', 'skills', 'js', 'rag'

const items = computed(() => [
  {
    id: 'mcp',
    type: 'MCP SERVER',
    title: 'HealthKit & Calendar MCP',
    badge: 'Official Swift MCP SDK',
    desc: '在 AI 想要获取你的步数或日历日程时，原生交互 Sheet 会向你申请权限，绝不静默窃取隐私。',
    snippet: `// Native MCP Tool Execution
{
  "server": "etos.mcp.personal",
  "tool": "get_daily_steps",
  "arguments": { "date": "today" },
  "approval": "ASK_USER_CONFIRMATION"
}`
  },
  {
    id: 'skills',
    type: 'AGENT SKILLS',
    title: 'GitHub 技能包一键导入',
    badge: 'Agentic Skill Pack',
    desc: '直接粘贴 GitHub 仓库链接或 RAW 文件地址，即刻注入代码审查、海报生成或工作流指令集。',
    snippet: `# SKILL: CodeReviewer Pro
description: "Inspect Swift & Rust diffs for memory leaks"
tools: [file_search, git_diff_parser]
instructions: |
  Check for strong reference cycles in closure capture lists.`
  },
  {
    id: 'js',
    type: 'CUSTOM JS',
    title: '沙盒 JavaScript 自定义工具',
    badge: 'Isolated JS Engine',
    desc: '在手机上直接编辑与运行轻量 JS 脚本工具，无死锁执行，与系统沙盒完美隔离。',
    snippet: `// CustomJSTools/weather.js
export async function run(args) {
  const res = await fetch(\`https://api.weather.com/\${args.city}\`);
  return res.json();
}`
  },
  {
    id: 'rag',
    type: 'SQLCIPHER RAG',
    title: 'SQLite 全盘物理加密向量库',
    badge: 'GRDB + SQLCipher',
    desc: '本地 Embedding 与长效记忆直接落地在加密 SQLite 数据库中，支持 SillyTavern 世界书触发。',
    snippet: `CREATE TABLE memory_vectors (
  id TEXT PRIMARY KEY,
  vector BLOB NOT NULL,
  content TEXT NOT NULL,
  created_at INTEGER NOT NULL
) STRICT;`
  }
]);

const currentItem = computed(() => items.value.find(i => i.id === activeTab.value) || items.value[0]);
</script>

<template>
  <div class="mcp-demo-container">
    <div class="mcp-tabs">
      <button
        v-for="item in items"
        :key="item.id"
        type="button"
        class="mcp-tab-btn"
        :class="{ active: activeTab === item.id }"
        @click="activeTab = item.id"
      >
        <span class="tab-type">{{ item.type }}</span>
        <span class="tab-title">{{ item.title }}</span>
      </button>
    </div>

    <div class="mcp-display-card">
      <div class="mcp-card-header">
        <div class="mcp-card-meta">
          <span class="mcp-badge">{{ currentItem.badge }}</span>
          <h3>{{ currentItem.title }}</h3>
        </div>
        <p class="mcp-desc">{{ currentItem.desc }}</p>
      </div>

      <div class="mcp-code-preview">
        <div class="code-bar">
          <span class="dot red"></span>
          <span class="dot yellow"></span>
          <span class="dot green"></span>
          <span class="code-filename">{{ currentItem.id.toUpperCase() }} SPEC</span>
        </div>
        <pre><code>{{ currentItem.snippet }}</code></pre>
      </div>
    </div>
  </div>
</template>
