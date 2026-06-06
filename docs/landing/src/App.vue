<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';

import { translations } from './i18n.js';
import { useWaveLoader } from './composables/useWaveLoader.js';
import { useMagneticCursor } from './composables/useMagneticCursor.js';
import { useTheme } from './composables/useTheme.js';
import { useLang } from './composables/useLang.js';

const REPO_URL = 'https://github.com/Eric-Terminal/ETOS-LLM-Studio';
const DOCS_URL = 'https://etos-llm-studio-docs.pages.dev';
const QUICKSTART_PATH = '/guide/getting-started';
const MODULES_PATH = '/modules/chat-and-models';

const { wavePaths, showLoader, loaderLeaving, showFrame, frameLeaving } = useWaveLoader();
useMagneticCursor();
const { isDark, toggle: toggleTheme } = useTheme();
const { current: currentLang, list: langList, set: setLang } = useLang();

const text = computed(() => translations[currentLang.value] ?? translations.zh);
const docsHref = computed(() => {
  // 中文/英文走对应路径，其它语言暂时回落英文版。
  const lang = currentLang.value;
  if (lang === 'zh' || lang === 'zh-Hant') return `${DOCS_URL}${QUICKSTART_PATH}`;
  return `${DOCS_URL}/en${QUICKSTART_PATH}`;
});
const modulesHref = computed(() => {
  const lang = currentLang.value;
  if (lang === 'zh' || lang === 'zh-Hant') return `${DOCS_URL}${MODULES_PATH}`;
  return `${DOCS_URL}/en${MODULES_PATH}`;
});

const titleLetters = computed(() => {
  // 把标题切成字符数组，CJK 单字也独立动画。空格保留。
  return Array.from(text.value.hero.title);
});

// 个性化预览：三项真实外观功能——上传壁纸 / 对话框颜色（调色盘）/ 去掉 AI 气泡。
// 默认值对齐 App：Telegram 浅蓝灰壁纸 + Telegram 蓝气泡（rgb 0.24,0.56,0.95）。
const DEFAULT_BUBBLE = '#3477d3';
const DEFAULT_WALL = 'linear-gradient(180deg, #d9e6eb 0%, #e0ebf2 100%)';

const bubbleColor = ref(DEFAULT_BUBBLE);
const wallpaperUrl = ref('');
const hideBotBubble = ref(false);

// 把 hex 按比例压暗，模拟 App 用户气泡渐变的深色端（darkened factor 0.86）。
function darkenHex(hex, factor) {
  const n = hex.replace('#', '');
  if (n.length !== 6) return hex;
  const ch = (i) => Math.round(parseInt(n.slice(i, i + 2), 16) * factor);
  const h = (v) => Math.max(0, Math.min(255, v)).toString(16).padStart(2, '0');
  return `#${h(ch(0))}${h(ch(2))}${h(ch(4))}`;
}

const wallValue = computed(() =>
  wallpaperUrl.value ? `url("${wallpaperUrl.value}") center / cover no-repeat` : DEFAULT_WALL
);
const phoneStyle = computed(() => ({
  '--persona-accent': bubbleColor.value,
  '--persona-accent-dark': darkenHex(bubbleColor.value, 0.86),
  '--persona-wall': wallValue.value
}));

function onWallpaperChange(event) {
  const file = event.target.files?.[0];
  if (!file) return;
  if (wallpaperUrl.value) URL.revokeObjectURL(wallpaperUrl.value);
  wallpaperUrl.value = URL.createObjectURL(file);
}
function resetPersona() {
  if (wallpaperUrl.value) URL.revokeObjectURL(wallpaperUrl.value);
  wallpaperUrl.value = '';
  bubbleColor.value = DEFAULT_BUBBLE;
  hideBotBubble.value = false;
}

// 滚动 marquee：统一英文，不走 i18n。
const marqueeItems = [
  'OpenAI',
  'Anthropic Claude',
  'Google Gemini',
  'OpenAI-compatible',
  'MCP',
  'Agent Skills',
  'Shortcuts',
  'Local RAG',
  'Worldbook',
  'Daily Pulse'
];

const isLangMenuOpen = ref(false);
function toggleLangMenu() {
  isLangMenuOpen.value = !isLangMenuOpen.value;
}
function pickLang(code) {
  setLang(code);
  isLangMenuOpen.value = false;
}
function onDocClick(event) {
  if (!event.target.closest('.lang-selector')) {
    isLangMenuOpen.value = false;
  }
}

// 滚动进度条 + 回到顶部
const scrollProgress = ref(0);
const showBackToTop = ref(false);
function onScroll() {
  const max = Math.max(document.documentElement.scrollHeight - window.innerHeight, 1);
  scrollProgress.value = Math.min(window.scrollY / max, 1);
  showBackToTop.value = window.scrollY > 400;
}
function backToTop() {
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

// 顶部条在滚动到一定距离后压缩高度
const isCondensed = ref(false);
function onScrollCondense() {
  isCondensed.value = window.scrollY > 24;
}

onMounted(() => {
  document.addEventListener('click', onDocClick);
  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('scroll', onScrollCondense, { passive: true });
  onScroll();
  onScrollCondense();
});

onBeforeUnmount(() => {
  document.removeEventListener('click', onDocClick);
  window.removeEventListener('scroll', onScroll);
  window.removeEventListener('scroll', onScrollCondense);
  if (wallpaperUrl.value) URL.revokeObjectURL(wallpaperUrl.value);
});
</script>

<template>
  <!-- 开屏遮罩 + 波浪噪声动画 -->
  <div
    v-if="showLoader"
    class="loader-screen"
    :class="{ 'is-leaving': loaderLeaving }"
    aria-label="Loading"
  >
    <svg class="loader-waves" aria-hidden="true">
      <path v-for="(p, i) in wavePaths" :key="i" :d="p.d" />
    </svg>
    <div class="loader-frame">
      <div class="loader-mark" aria-hidden="true">
        <span></span><span></span><span></span><span></span>
      </div>
      <div class="loader-copy">
        <div class="loader-kicker">
          <span>{{ text.loader.kicker }}</span>
          <span>{{ text.loader.year }}</span>
        </div>
        <div class="loader-title">ETOS!</div>
        <div class="loader-line">
          <span>{{ text.loader.line }}</span>
          <span>· · · · ·</span>
        </div>
      </div>
      <div class="loader-progress" aria-hidden="true"><span></span></div>
    </div>
  </div>

  <!-- 加载结束后波浪不销毁，作为背景纹理在两侧渐显 -->
  <svg
    class="loader-waves persistent-waves"
    :class="{ 'is-visible': !showLoader }"
    aria-hidden="true"
  >
    <path v-for="(p, i) in wavePaths" :key="`p-${i}`" :d="p.d" />
  </svg>

  <!-- 四边收束的边框 -->
  <div
    v-if="showFrame"
    class="site-frame"
    :class="{ 'is-leaving': frameLeaving }"
    aria-hidden="true"
  >
    <span class="site-frame-side site-frame-top"></span>
    <span class="site-frame-side site-frame-right"></span>
    <span class="site-frame-side site-frame-bottom"></span>
    <span class="site-frame-side site-frame-left"></span>
  </div>

  <div class="dotted-bg" aria-hidden="true"></div>
  <div
    class="scroll-progress"
    :style="{ transform: `scaleX(${scrollProgress})` }"
    aria-hidden="true"
  ></div>

  <!-- 顶部导航 -->
  <nav class="top-bar" :class="{ condensed: isCondensed }">
    <a class="brand" href="#top">
      <span class="brand-mark" aria-hidden="true">
        <span></span><span></span><span></span><span></span>
      </span>
      <span class="brand-name">ETOS LLM Studio</span>
    </a>
    <div class="nav-right">
      <a class="nav-link" href="#features">{{ text.nav.features }}</a>
      <a class="nav-link" href="#personalize">{{ text.nav.personalize }}</a>
      <a class="nav-link" href="#privacy">{{ text.nav.privacy }}</a>
      <a class="nav-link" href="#tech">{{ text.nav.tech }}</a>
      <a class="nav-link" :href="DOCS_URL" target="_blank" rel="noopener">{{ text.nav.docs }}</a>
      <a class="nav-link" :href="REPO_URL" target="_blank" rel="noopener">{{ text.nav.github }}</a>
      <div class="lang-selector">
        <button class="lang-btn" type="button" @click.stop="toggleLangMenu">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" width="14" height="14">
            <circle cx="12" cy="12" r="9" />
            <line x1="3" y1="12" x2="21" y2="12" />
            <path d="M12 3a14 14 0 0 1 4 9 14 14 0 0 1-4 9 14 14 0 0 1-4-9 14 14 0 0 1 4-9z" />
          </svg>
          <span class="lang-current">{{ langList.find((l) => l.code === currentLang)?.name }}</span>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" width="12" height="12">
            <polyline points="6 9 12 15 18 9"></polyline>
          </svg>
        </button>
        <div class="lang-menu" :class="{ show: isLangMenuOpen }">
          <div class="lang-menu-header">{{ text.ui.langHint }}</div>
          <button
            v-for="l in langList"
            :key="l.code"
            type="button"
            :class="{ active: l.code === currentLang }"
            @click="pickLang(l.code)"
          >
            {{ l.name }}
          </button>
        </div>
      </div>
      <button class="theme-toggle" type="button" :aria-label="isDark ? text.ui.theme.light : text.ui.theme.dark" @click="toggleTheme">
        <svg v-if="isDark" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
          <circle cx="12" cy="12" r="4"></circle>
          <line x1="12" y1="2" x2="12" y2="5"></line>
          <line x1="12" y1="19" x2="12" y2="22"></line>
          <line x1="4.93" y1="4.93" x2="6.7" y2="6.7"></line>
          <line x1="17.3" y1="17.3" x2="19.07" y2="19.07"></line>
          <line x1="2" y1="12" x2="5" y2="12"></line>
          <line x1="19" y1="12" x2="22" y2="12"></line>
          <line x1="4.93" y1="19.07" x2="6.7" y2="17.3"></line>
          <line x1="17.3" y1="6.7" x2="19.07" y2="4.93"></line>
        </svg>
        <svg v-else viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
          <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"></path>
        </svg>
        <span class="theme-label">{{ isDark ? text.ui.theme.light : text.ui.theme.dark }}</span>
      </button>
    </div>
  </nav>

  <main id="top" class="page">
    <!-- HERO -->
    <section class="hero">
      <div class="hero-grid-bg" aria-hidden="true">
        <span></span><span></span><span></span><span></span><span></span><span></span>
      </div>
      <div class="hero-inner">
        <div class="section-label">NATIVE · iOS 18 · watchOS 11</div>
        <h1 class="hero-title" :aria-label="text.hero.title">
          <span
            v-for="(letter, i) in titleLetters"
            :key="i"
            class="title-letter"
            :style="{ '--letter-index': i }"
            aria-hidden="true"
            >{{ letter === ' ' ? ' ' : letter }}</span
          >
        </h1>
        <p class="hero-lead">{{ text.hero.lead }}</p>
        <div class="hero-actions">
          <a class="btn-pill btn-primary" :href="docsHref" target="_blank" rel="noopener">
            <span>{{ text.hero.actionsPrimary }}</span>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" width="14" height="14">
              <line x1="5" y1="12" x2="19" y2="12" />
              <polyline points="13 6 19 12 13 18" />
            </svg>
          </a>
          <a class="btn-pill btn-ghost" :href="modulesHref" target="_blank" rel="noopener">
            {{ text.hero.actionsSecondary }}
          </a>
        </div>
        <div class="hero-status">
          <span class="status-dot"></span>
          <span class="status-text">{{ text.hero.statusOnline }}</span>
          <span class="status-sep">·</span>
          <span class="status-badge">{{ text.hero.statusBadge }}</span>
        </div>
      </div>
    </section>

    <!-- 滚动横向 marquee -->
    <section class="marquee" aria-hidden="true">
      <div class="marquee-track">
        <span v-for="(m, i) in marqueeItems" :key="`a-${i}`">{{ m }}</span>
        <span v-for="(m, i) in marqueeItems" :key="`b-${i}`">{{ m }}</span>
      </div>
    </section>

    <!-- 截图 -->
    <section class="screenshots tile-parchment" v-reveal>
      <div class="container">
        <div class="section-label">SCREENSHOTS · CURRENT BUILD</div>
        <h2 class="tile-title">{{ text.screenshots.title }}</h2>
        <p class="tile-lead">{{ text.screenshots.lead }}</p>
        <div class="screenshots-grid">
          <figure class="shot">
            <div class="shot-frame">
              <img src="/images/screenshots/screenshot-01.png" :alt="text.screenshots.captionOne" loading="lazy" />
            </div>
            <figcaption>{{ text.screenshots.captionOne }}</figcaption>
          </figure>
          <figure class="shot">
            <div class="shot-frame">
              <img src="/images/screenshots/screenshot-02.png" :alt="text.screenshots.captionTwo" loading="lazy" />
            </div>
            <figcaption>{{ text.screenshots.captionTwo }}</figcaption>
          </figure>
        </div>
      </div>
    </section>

    <!-- 个性化外观 -->
    <section id="personalize" class="personalize tile-light" v-reveal>
      <div class="container">
        <div class="section-label">MAKE IT YOURS</div>
        <h2 class="tile-title">{{ text.personalize.title }}</h2>
        <p class="tile-lead">{{ text.personalize.lead }}</p>

        <div class="persona-stage">
          <!-- 左：三项真实外观功能 -->
          <div class="persona-controls">
            <div class="persona-picker-hint">
              <span class="persona-live-dot" aria-hidden="true"></span>
              {{ text.personalize.pickerHint }}
            </div>

            <!-- 1. 上传壁纸 -->
            <div class="persona-control">
              <span class="persona-control-label">{{ text.personalize.wallpaperLabel }}</span>
              <label class="persona-upload">
                <input type="file" accept="image/*" @change="onWallpaperChange" hidden />
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                  <rect x="3" y="3" width="18" height="18" rx="3" />
                  <circle cx="8.5" cy="8.5" r="1.6" />
                  <path d="M21 15l-5-5L5 21" />
                </svg>
                <span>{{ wallpaperUrl ? '✓' : '' }} {{ text.personalize.wallpaperAction }}</span>
              </label>
            </div>

            <!-- 2. 对话框颜色（调色盘） -->
            <div class="persona-control persona-control-row">
              <span class="persona-control-label">{{ text.personalize.colorLabel }}</span>
              <label class="persona-colorpicker">
                <input type="color" v-model="bubbleColor" aria-label="bubble color" />
                <span class="persona-color-hex">{{ bubbleColor.toUpperCase() }}</span>
              </label>
            </div>

            <!-- 3. 去掉 AI 回复气泡 -->
            <div class="persona-control persona-control-row">
              <span class="persona-control-label">{{ text.personalize.hideBubbleLabel }}</span>
              <button
                class="persona-toggle"
                :class="{ on: hideBotBubble }"
                type="button"
                role="switch"
                :aria-checked="hideBotBubble"
                :aria-label="text.personalize.hideBubbleLabel"
                @click="hideBotBubble = !hideBotBubble"
              >
                <span class="persona-toggle-knob" aria-hidden="true"></span>
              </button>
            </div>

            <button class="persona-reset" type="button" @click="resetPersona">{{ text.personalize.reset }}</button>
          </div>

          <!-- 右：仿 iPhone 聊天界面，随预设实时换肤 -->
          <div class="persona-phone-wrap">
            <div class="persona-phone" :style="phoneStyle">
              <img class="persona-frame" src="/images/phone-frame.svg" alt="" aria-hidden="true" />
              <div class="persona-screen">
                <div class="persona-wall" aria-hidden="true"></div>
                <svg v-if="!wallpaperUrl" class="persona-wall-pattern" aria-hidden="true" xmlns="http://www.w3.org/2000/svg">
                  <defs>
                    <pattern id="personaTgPattern" width="120" height="120" patternUnits="userSpaceOnUse">
                      <g fill="#4a5a66">
                        <path transform="translate(22,12)" d="M8 0.6 9.9 5.4 15 5.8 11.1 9.1 12.4 14.1 8 11.3 3.6 14.1 4.9 9.1 1 5.8 6.1 5.4Z" />
                        <path transform="translate(77,17)" d="M8 14.2C8 14.2 1.2 9.9 1.2 5.4 1.2 3.1 2.9 1.6 4.8 1.6 6.1 1.6 7.3 2.4 8 3.6 8.7 2.4 9.9 1.6 11.2 1.6 13.1 1.6 14.8 3.1 14.8 5.4 14.8 9.9 8 14.2 8 14.2Z" />
                        <path transform="translate(10,54)" d="M1.2 7.4 14.8 1.4 8.8 14.8 7 8.8Z" />
                        <path transform="translate(62,50)" d="M3.5 2H12.5A2 2 0 0 1 14.5 4V9A2 2 0 0 1 12.5 11H6.5L3.5 13.8V11A2 2 0 0 1 1.5 9V4A2 2 0 0 1 3.5 2Z" />
                        <path transform="translate(40,90)" d="M8 14.2C8 14.2 1.2 9.9 1.2 5.4 1.2 3.1 2.9 1.6 4.8 1.6 6.1 1.6 7.3 2.4 8 3.6 8.7 2.4 9.9 1.6 11.2 1.6 13.1 1.6 14.8 3.1 14.8 5.4 14.8 9.9 8 14.2 8 14.2Z" />
                        <path transform="translate(92,84)" d="M8 0.6 9.9 5.4 15 5.8 11.1 9.1 12.4 14.1 8 11.3 3.6 14.1 4.9 9.1 1 5.8 6.1 5.4Z" />
                      </g>
                    </pattern>
                  </defs>
                  <rect width="100%" height="100%" fill="url(#personaTgPattern)" />
                </svg>
                <div class="persona-scrim" aria-hidden="true"></div>
                <div class="persona-statusbar">
                  <span class="persona-status-left">
                    <span class="persona-time">11:20</span>
                  </span>
                  <span class="persona-island" aria-hidden="true"></span>
                  <span class="persona-statusbar-right" aria-hidden="true">
                    <svg class="persona-signal" viewBox="0 0 17 12" fill="currentColor">
                      <rect x="0" y="8" width="3" height="4" rx="1" />
                      <rect x="4.6" y="5.5" width="3" height="6.5" rx="1" />
                      <rect x="9.2" y="3" width="3" height="9" rx="1" />
                      <rect x="13.8" y="0" width="3" height="12" rx="1" />
                    </svg>
                    <span class="persona-net">4G</span>
                    <svg class="persona-batt" viewBox="0 0 26 12" fill="none">
                      <rect x="0.6" y="0.6" width="21.5" height="10.8" rx="3" stroke="currentColor" stroke-opacity="0.4" />
                      <rect x="2" y="2" width="18" height="8" rx="1.6" fill="currentColor" />
                      <rect x="23.6" y="4" width="1.6" height="4" rx="0.8" fill="currentColor" fill-opacity="0.4" />
                    </svg>
                  </span>
                </div>
                <div class="persona-nav">
                  <span class="persona-nav-btn" v-liquid-glass aria-hidden="true">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round">
                      <circle cx="4.6" cy="7" r="1.15" fill="currentColor" stroke="none" />
                      <line x1="9" y1="7" x2="20" y2="7" />
                      <circle cx="4.6" cy="12" r="1.15" fill="currentColor" stroke="none" />
                      <line x1="9" y1="12" x2="20" y2="12" />
                      <circle cx="4.6" cy="17" r="1.15" fill="currentColor" stroke="none" />
                      <line x1="9" y1="17" x2="20" y2="17" />
                    </svg>
                  </span>
                  <span class="persona-nav-pill" v-liquid-glass>
                    <span class="persona-nav-texts">
                      <span class="persona-nav-title">{{ text.personalize.chat.title }}</span>
                      <span class="persona-nav-sub">GPT-5.5 · OpenAI</span>
                    </span>
                    <svg class="persona-nav-chevron" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                      <polyline points="6 9 12 15 18 9" />
                    </svg>
                  </span>
                  <span class="persona-nav-btn" v-liquid-glass aria-hidden="true">
                    <svg viewBox="0 0 24 24" fill="currentColor">
                      <path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58a.49.49 0 0 0 .12-.61l-1.92-3.32a.488.488 0 0 0-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54a.484.484 0 0 0-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 0 0-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z" />
                    </svg>
                  </span>
                </div>
                <div class="persona-messages">
                  <div class="persona-row persona-row-user">
                    <div class="persona-bubble persona-bubble-user" v-liquid-glass="{ blur: 1 }"><span class="persona-btext">{{ text.personalize.chat.user }}</span></div>
                  </div>
                  <div class="persona-row persona-row-bot">
                    <div v-if="!hideBotBubble" class="persona-bubble persona-bubble-bot" v-liquid-glass="{ blur: 6 }"><span class="persona-btext">{{ text.personalize.chat.bot }}</span></div>
                    <div v-else class="persona-bubble persona-bubble-bot persona-bubble-bot--bare"><span class="persona-btext">{{ text.personalize.chat.bot }}</span></div>
                  </div>
                </div>
                <div class="persona-inputbar">
                  <span class="persona-circle persona-clip" v-liquid-glass aria-hidden="true">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
                      <path d="M20.5 11.5l-8.4 8.4a4.5 4.5 0 0 1-6.4-6.4l8.5-8.5a3 3 0 0 1 4.3 4.3l-8.5 8.5a1.5 1.5 0 0 1-2.1-2.1l7.8-7.8" />
                    </svg>
                  </span>
                  <span class="persona-input" v-liquid-glass><span class="persona-input-text">{{ text.personalize.chat.placeholder }}</span></span>
                  <span class="persona-circle persona-send" v-liquid-glass aria-hidden="true">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
                      <line x1="12" y1="19" x2="12" y2="5" />
                      <polyline points="6 11 12 5 18 11" />
                    </svg>
                  </span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>

    <!-- 功能 -->
    <section id="features" class="features tile-dark" v-reveal>
      <div class="container">
        <div class="section-label section-label-light">FEATURE MATRIX</div>
        <h2 class="tile-title">{{ text.features.title }}</h2>
        <p class="tile-lead">{{ text.features.lead }}</p>
        <div class="feature-grid">
          <article
            v-for="(item, idx) in text.features.items"
            :key="idx"
            class="feature-card"
            v-reveal
            :style="{ '--card-delay': `${idx * 0.06}s` }"
          >
            <div class="feature-kicker">{{ item.kicker }}</div>
            <h3 class="feature-title">{{ item.title }}</h3>
            <p class="feature-body">{{ item.body }}</p>
            <div class="feature-tags">
              <span v-for="t in item.tags" :key="t" class="tag-chip">{{ t }}</span>
            </div>
          </article>
        </div>
      </div>
    </section>

    <!-- 隐私 -->
    <section id="privacy" class="privacy tile-light" v-reveal>
      <div class="container">
        <div class="section-label">PRIVACY & LOCAL-FIRST</div>
        <h2 class="tile-title">{{ text.privacy.title }}</h2>
        <p class="tile-lead">{{ text.privacy.lead }}</p>
        <div class="privacy-grid">
          <article
            v-for="(b, idx) in text.privacy.bullets"
            :key="idx"
            class="privacy-card"
            v-reveal
          >
            <div class="privacy-kicker">{{ b.kicker }}</div>
            <div class="privacy-card-title">{{ b.title }}</div>
            <p class="privacy-card-body">{{ b.body }}</p>
          </article>
        </div>
      </div>
    </section>

    <!-- 技术栈 -->
    <section id="tech" class="tech tile-parchment" v-reveal>
      <div class="container">
        <div class="section-label">TECH STACK</div>
        <h2 class="tile-title">{{ text.tech.title }}</h2>
        <p class="tile-lead">{{ text.tech.lead }}</p>
        <div class="tech-grid">
          <div v-for="(t, idx) in text.tech.items" :key="idx" class="stat-card" v-reveal>
            <div class="stat-name">{{ t.name }}</div>
            <div class="stat-desc">{{ t.desc }}</div>
          </div>
        </div>
      </div>
    </section>

    <!-- CTA -->
    <section class="cta tile-dark" v-reveal>
      <div class="container cta-inner">
        <div class="section-label section-label-light">READY TO START</div>
        <h2 class="cta-title">{{ text.cta.title }}</h2>
        <p class="cta-lead">{{ text.cta.lead }}</p>
        <div class="cta-actions">
          <a class="btn-pill btn-primary btn-large" :href="docsHref" target="_blank" rel="noopener">
            {{ text.cta.primary }}
          </a>
          <a class="download-card" :href="REPO_URL" target="_blank" rel="noopener">
            <svg viewBox="0 0 24 24" fill="currentColor" width="20" height="20" aria-hidden="true">
              <path d="M12 .5C5.65.5.5 5.65.5 12c0 5.08 3.29 9.39 7.86 10.91.58.1.79-.25.79-.56 0-.28-.01-1.02-.02-2-3.2.7-3.88-1.54-3.88-1.54-.52-1.33-1.28-1.69-1.28-1.69-1.05-.72.08-.71.08-.71 1.16.08 1.77 1.19 1.77 1.19 1.03 1.77 2.71 1.26 3.37.96.1-.75.4-1.26.73-1.55-2.55-.29-5.24-1.28-5.24-5.69 0-1.26.45-2.29 1.19-3.1-.12-.29-.51-1.46.11-3.04 0 0 .97-.31 3.18 1.18a11.04 11.04 0 0 1 5.79 0c2.21-1.49 3.18-1.18 3.18-1.18.62 1.58.23 2.75.11 3.04.74.81 1.18 1.84 1.18 3.1 0 4.42-2.69 5.39-5.25 5.68.41.36.78 1.06.78 2.14 0 1.55-.01 2.8-.01 3.18 0 .31.21.67.8.55C20.21 21.38 23.5 17.07 23.5 12 23.5 5.65 18.35.5 12 .5z" />
            </svg>
            <div class="download-text">
              <div class="download-title">{{ text.cta.secondary }}</div>
              <div class="download-desc">{{ text.cta.secondaryDesc }}</div>
            </div>
          </a>
        </div>
      </div>
    </section>

    <footer class="footer">
      <div class="container footer-inner">
        <div class="footer-left">
          <span>{{ text.footer.madeBy }}</span>
          <a :href="REPO_URL" target="_blank" rel="noopener">{{ text.footer.author }}</a>
        </div>
        <div class="footer-right">
          <a :href="REPO_URL" target="_blank" rel="noopener">{{ text.footer.repo }}</a>
          <span class="footer-divider">·</span>
          <a :href="DOCS_URL" target="_blank" rel="noopener">{{ text.footer.docs }}</a>
          <span class="footer-divider">·</span>
          <span>{{ text.footer.license }}</span>
        </div>
      </div>
    </footer>
  </main>

  <button
    class="back-to-top"
    :class="{ show: showBackToTop }"
    type="button"
    :aria-label="text.footer.backToTop"
    @click="backToTop"
  >
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
      <polyline points="18 15 12 9 6 15"></polyline>
    </svg>
  </button>
</template>
