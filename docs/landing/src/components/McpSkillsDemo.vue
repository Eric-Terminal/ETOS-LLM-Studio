<script setup>
import { ref, computed } from 'vue';

const props = defineProps({
  text: {
    type: Object,
    required: true
  }
});

const activeTab = ref('mcp');

const sectionText = computed(() => props.text.mcpSkillsSection || {});
const tabs = computed(() => sectionText.value.tabs || []);

const currentTabItem = computed(() => {
  return tabs.value.find(t => t.id === activeTab.value) || tabs.value[0] || {
    id: 'mcp',
    type: 'MCP SERVER',
    title: '',
    badge: '',
    desc: '',
    snippet: ''
  };
});
</script>

<template>
  <div class="mcp-demo-container">
    <div class="mcp-tabs">
      <button
        v-for="item in tabs"
        :key="item.id"
        type="button"
        class="mcp-tab-btn"
        :class="{ active: activeTab === item.id }"
        :aria-pressed="activeTab === item.id"
        @click="activeTab = item.id"
      >
        <span class="tab-type">{{ item.type }}</span>
        <span class="tab-title">{{ item.title }}</span>
      </button>
    </div>

    <div class="mcp-display-card">
      <div class="mcp-card-header">
        <div class="mcp-card-meta">
          <span class="mcp-badge">{{ currentTabItem.badge }}</span>
          <h3>{{ currentTabItem.title }}</h3>
        </div>
        <p class="mcp-desc">{{ currentTabItem.desc }}</p>
      </div>

      <div class="mcp-code-preview">
        <div class="code-bar">
          <span class="dot red"></span>
          <span class="dot yellow"></span>
          <span class="dot green"></span>
          <span class="code-filename">{{ currentTabItem.id.toUpperCase() }} {{ sectionText.specLabel }}</span>
        </div>
        <pre><code>{{ currentTabItem.snippet }}</code></pre>
      </div>
    </div>
  </div>
</template>
