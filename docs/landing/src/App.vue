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
const { cursorEl } = useMagneticCursor();
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
        <div class="loader-title">ETOS</div>
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
        <div class="section-label">{{ text.hero.eyebrow }}</div>
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
        <span v-for="(m, i) in text.marquee" :key="`a-${i}`">{{ m }}</span>
        <span v-for="(m, i) in text.marquee" :key="`b-${i}`">{{ m }}</span>
      </div>
    </section>

    <!-- 截图 -->
    <section class="screenshots tile-parchment" v-reveal>
      <div class="container">
        <div class="section-label">{{ text.screenshots.captionOne }} · {{ text.screenshots.captionTwo }}</div>
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

    <!-- 功能 -->
    <section id="features" class="features tile-dark" v-reveal>
      <div class="container">
        <div class="section-label section-label-light">{{ text.sectionLabel.features }}</div>
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
        <div class="section-label">{{ text.sectionLabel.privacy }}</div>
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
        <div class="section-label">{{ text.sectionLabel.tech }}</div>
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
        <div class="section-label section-label-light">{{ text.sectionLabel.cta }}</div>
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

  <div ref="cursorEl" class="cursor" aria-hidden="true">
    <span></span><span></span><span></span><span></span>
  </div>
</template>
