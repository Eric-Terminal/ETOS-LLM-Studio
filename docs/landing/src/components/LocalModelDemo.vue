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
const kvCache = ref(false);

const localDemoText = computed(() => props.text.localDemo || {});

const rawModels = computed(() => localDemoText.value.models || []);

const currentModel = computed(() => {
  const base = rawModels.value[selectedModelIndex.value] || rawModels.value[0] || {
    name: 'Qwen2.5-7B-Instruct.Q4_K_M.gguf',
    size: '4.35 GB',
    thinking: '',
    response: '',
    hud: {}
  };

  const isMetal = metalOffload.value;
  const isFlash = flashAttention.value;
  const isKV = kvCache.value;
  const hud = base.hud || {};

  const cpu = isMetal
    ? (hud.cpuMetal || '18%')
    : (hud.cpuOnly || '78%');
  const gpu = isMetal
    ? (hud.gpuMetal || '92%')
    : '0%';
  const ram = isMetal
    ? (isKV ? (hud.ramMetalKV || '5.2 GB (Metal + KV)') : (hud.ramMetal || '4.8 GB (Metal)'))
    : (isKV ? (hud.ramCpuKV || '5.8 GB (RAM + KV)') : (hud.ramCpu || '5.1 GB (RAM)'));
  const speedVal = isFlash
    ? (hud.speedFlash || 38.4)
    : (hud.speedBase || 22.1);

  return {
    ...base,
    ram,
    gpuUtil: gpu,
    cpuUtil: cpu,
    speed: `${speedVal} t/s`,
    kvStatusLabel: isKV
      ? localDemoText.value.kvCacheEnabledLabel
      : localDemoText.value.kvCacheDisabledLabel
  };
});
</script>

<template>
  <div class="local-demo-wrapper">
    <div class="local-demo-controls">
      <div class="control-header">
        <span class="control-badge">{{ localDemoText.controlBadge }}</span>
        <span class="control-title">{{ localDemoText.selectModelLabel }}</span>
      </div>

      <div class="model-buttons">
        <button
          v-for="(m, i) in rawModels"
          :key="i"
          type="button"
          class="model-chip-btn"
          :class="{ active: selectedModelIndex === i }"
          :aria-pressed="selectedModelIndex === i"
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
          <span class="toggle-text">{{ localDemoText.metalOffloadLabel }}</span>
        </label>

        <label class="toggle-item">
          <input type="checkbox" v-model="flashAttention" />
          <span class="toggle-box"></span>
          <span class="toggle-text">{{ localDemoText.flashAttentionLabel }}</span>
        </label>

        <label class="toggle-item">
          <input type="checkbox" v-model="kvCache" />
          <span class="toggle-box"></span>
          <span class="toggle-text">{{ localDemoText.kvCacheLabel }}</span>
        </label>
      </div>

      <!-- 这里展示估算数据，真实性能取决于设备、量化与上下文。 -->
      <div class="hud-stats-grid">
        <div class="hud-stat">
          <div class="stat-label">{{ localDemoText.cpuLoadLabel }}</div>
          <div class="stat-val">{{ currentModel.cpuUtil }}</div>
          <div class="stat-bar-track"><div class="stat-bar-fill" :style="{ width: currentModel.cpuUtil }"></div></div>
        </div>
        <div class="hud-stat">
          <div class="stat-label">{{ localDemoText.metalGPULabel }}</div>
          <div class="stat-val">{{ currentModel.gpuUtil }}</div>
          <div class="stat-bar-track"><div class="stat-bar-fill metal" :style="{ width: currentModel.gpuUtil }"></div></div>
        </div>
        <div class="hud-stat">
          <div class="stat-label">{{ localDemoText.memoryLabel }}</div>
          <div class="stat-val">{{ currentModel.ram }}</div>
        </div>
        <div class="hud-stat">
          <div class="stat-label">{{ localDemoText.speedLabel }}</div>
          <div class="stat-val highlight">{{ currentModel.speed }}</div>
        </div>
      </div>
      <p class="hud-estimate-note">{{ localDemoText.estimateDisclaimer }}</p>
    </div>

    <div class="local-demo-screen">
      <div class="screen-hud-bar">
        <div class="hud-left">
          <span class="hud-dot active"></span>
          <span class="hud-model-tag">{{ currentModel.name }}</span>
        </div>
        <div class="hud-right">
          <span class="hud-kv-tag" :class="{ active: kvCache }">{{ currentModel.kvStatusLabel }}</span>
          <span class="hud-speed-badge">{{ currentModel.speed }}</span>
        </div>
      </div>

      <div class="screen-chat-area">
        <div class="chat-row user">
          <div class="chat-bubble user">
            {{ localDemoText.userQuestion }}
          </div>
        </div>

        <div class="chat-row bot">
          <div v-if="currentModel.thinking" class="chat-think-box">
            <div class="think-header">
              <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83" />
              </svg>
              <span>{{ localDemoText.thinkHeader || 'Thinking Timeline' }}</span>
            </div>
            <div class="think-content">{{ currentModel.thinking }}</div>
          </div>

          <div class="chat-bubble bot">
            {{ currentModel.response }}
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
