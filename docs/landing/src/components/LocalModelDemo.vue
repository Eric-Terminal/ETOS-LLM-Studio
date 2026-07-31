<script setup>
import { ref, computed } from 'vue';

const props = defineProps({
  text: {
    type: Object,
    required: true
  }
});

const selectedModelIndex = ref(0);
const metalOffload = ref(true);
const flashAttention = ref(true);
const kvCache = ref(true);

const models = computed(() => [
  {
    name: 'Qwen2.5-7B-Instruct.Q4_K_M.gguf',
    size: '4.35 GB',
    ram: metalOffload.value ? '4.8 GB (Metal)' : '5.1 GB (RAM)',
    gpuUtil: metalOffload.value ? '88%' : '0%',
    cpuUtil: metalOffload.value ? '18%' : '76%',
    speed: flashAttention.value ? '38.4 t/s' : '22.1 t/s',
    thinking: '正在使用本地端侧权重视觉/逻辑推理，针对问答结构与格式进行编译处理...',
    response: '根据离线知识库与 GRDB 本地索引，当前系统硬件加速正常启用。'
  },
  {
    name: 'DeepSeek-R1-Distill-Q4_K_S.gguf',
    size: '4.10 GB',
    ram: metalOffload.value ? '4.5 GB (Metal)' : '4.8 GB (RAM)',
    gpuUtil: metalOffload.value ? '94%' : '0%',
    cpuUtil: metalOffload.value ? '12%' : '84%',
    speed: flashAttention.value ? '42.8 t/s' : '26.5 t/s',
    thinking: '分析思考链路：1. 检索本地 SQLite 数据库；2. 解析 GGUF Jinja Chat Template；3. 生成流式思考步骤与最终结论...',
    response: 'DeepSeek-R1 本地推理完成！思考耗时 1.2 秒，全流式 Metal GPU 加速输出。'
  },
  {
    name: 'Llama-3.1-8B-Instruct.Q4_K_M.gguf',
    size: '4.92 GB',
    ram: metalOffload.value ? '5.4 GB (Metal)' : '5.8 GB (RAM)',
    gpuUtil: metalOffload.value ? '82%' : '0%',
    cpuUtil: metalOffload.value ? '22%' : '68%',
    speed: flashAttention.value ? '34.2 t/s' : '19.8 t/s',
    thinking: 'Checking local GGUF memory budget and KV cache allocation...',
    response: 'Llama 3.1 8B local execution complete. All memory and KV offload operating strictly within sandbox limits.'
  }
]);

const currentModel = computed(() => models.value[selectedModelIndex.value]);
</script>

<template>
  <div class="local-demo-wrapper">
    <div class="local-demo-controls">
      <div class="control-header">
        <span class="control-badge">GGUF · llama.cpp C ABI</span>
        <span class="control-title">{{ text.localDemo?.selectModelLabel || '选择本地 GGUF 模型' }}</span>
      </div>

      <div class="model-buttons">
        <button
          v-for="(m, i) in models"
          :key="i"
          type="button"
          class="model-chip-btn"
          :class="{ active: selectedModelIndex === i }"
          @click="selectedModelIndex = i"
        >
          <span class="chip-name">{{ m.name.split('.')[0] }}</span>
          <span class="chip-size">{{ m.size }}</span>
        </button>
      </div>

      <div class="hardware-toggles">
        <label class="toggle-item">
          <input type="checkbox" v-model="metalOffload" />
          <span class="toggle-box"></span>
          <span class="toggle-text">Metal GPU Offload</span>
        </label>

        <label class="toggle-item">
          <input type="checkbox" v-model="flashAttention" />
          <span class="toggle-box"></span>
          <span class="toggle-text">Flash Attention</span>
        </label>

        <label class="toggle-item">
          <input type="checkbox" v-model="kvCache" />
          <span class="toggle-box"></span>
          <span class="toggle-text">KV Cache Offload</span>
        </label>
      </div>

      <!-- Real-time HUD stats -->
      <div class="hud-stats-grid">
        <div class="hud-stat">
          <div class="stat-label">CPU LOAD</div>
          <div class="stat-val">{{ currentModel.cpuUtil }}</div>
          <div class="stat-bar-track"><div class="stat-bar-fill" :style="{ width: currentModel.cpuUtil }"></div></div>
        </div>
        <div class="hud-stat">
          <div class="stat-label">METAL GPU</div>
          <div class="stat-val">{{ currentModel.gpuUtil }}</div>
          <div class="stat-bar-track"><div class="stat-bar-fill metal" :style="{ width: currentModel.gpuUtil }"></div></div>
        </div>
        <div class="hud-stat">
          <div class="stat-label">MEMORY</div>
          <div class="stat-val">{{ currentModel.ram }}</div>
        </div>
        <div class="hud-stat">
          <div class="stat-label">SPEED</div>
          <div class="stat-val highlight">{{ currentModel.speed }}</div>
        </div>
      </div>
    </div>

    <div class="local-demo-screen">
      <div class="screen-hud-bar">
        <div class="hud-left">
          <span class="hud-dot active"></span>
          <span class="hud-model-tag">{{ currentModel.name }}</span>
        </div>
        <div class="hud-right">
          <span class="hud-speed-badge">{{ currentModel.speed }}</span>
        </div>
      </div>

      <div class="screen-chat-area">
        <div class="chat-row user">
          <div class="chat-bubble user">
            运行端侧模型不需要网络连接吗？
          </div>
        </div>

        <div class="chat-row bot">
          <div class="chat-think-box">
            <div class="think-header">
              <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83" />
              </svg>
              <span>{{ text.localDemo?.thinkHeader || '本地模型思考时间线 (Thinking Timeline)' }}</span>
            </div>
            <div class="think-content">{{ currentModel.thinking }}</div>
          </div>

          <div class="chat-bubble bot">
            {{ currentModel.response }}
            <br /><br />
            <strong>完全不需要网络！</strong>模型权重与 Embedding 嵌入向量数据库（SQLite）完全运行在你的设备本机。无需 API Key，零联网权限，不消耗任何数据流量。
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
