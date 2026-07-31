// ============================================================================
// Context Cursor —— iPadOS 风格的「磁吸」指针 (超低延迟优化版)
// ============================================================================
// 一颗半透明玻璃圆点跟随鼠标；悬停到可交互元素（链接 / 按钮）上时，会快速变形成
// 贴合该元素的圆角矩形。
//
// 性能与延迟优化：
// 1. 自由移动模式下：位置 1:1 实时跟随鼠标，0ms 拖尾与迟钝感。
// 2. 磁吸吸附模式下：采用 0.45 高响应度插值 + 0.12s 极速 CSS 变形。
// ============================================================================

const STYLE = `
.cc-cursor {
  position: fixed;
  top: 0;
  left: 0;
  width: 18px;
  height: 18px;
  border-radius: 50%;
  background: rgba(150, 150, 160, 0.22);
  border: 1px solid rgba(255, 255, 255, 0.45);
  box-shadow: 0 1px 6px rgba(0, 0, 0, 0.08);
  pointer-events: none;
  z-index: 9999;
  opacity: 0;
  transform: translate3d(-100px, -100px, 0);
  transition: width 0.12s cubic-bezier(0.16, 1, 0.3, 1),
              height 0.12s cubic-bezier(0.16, 1, 0.3, 1),
              border-radius 0.12s cubic-bezier(0.16, 1, 0.3, 1),
              background-color 0.15s ease,
              border-color 0.15s ease,
              opacity 0.15s ease;
  will-change: transform, width, height;
}
.dark .cc-cursor {
  background: rgba(255, 255, 255, 0.15);
  border-color: rgba(255, 255, 255, 0.25);
}
.cc-cursor--active {
  background: rgba(120, 120, 130, 0.16);
  border-color: rgba(255, 255, 255, 0.6);
}
html.cc-enabled, html.cc-enabled * { cursor: none !important; }
`;

export function initContextCursor(options = {}) {
  if (typeof window === 'undefined' || !window.matchMedia) return;
  const fine = window.matchMedia('(pointer: fine)').matches;
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (!fine || reduced) return;

  const SELECTOR =
    options.selector ||
    'a[href], button, [role="button"], .btn-pill, .nav-link, .lang-btn, .theme-toggle, .model-chip-btn, .mcp-tab-btn';
  const BASE = options.size || 18;
  const PAD = options.padding ?? 6;
  const EASE = options.ease ?? 0.45; // 吸附态高响应度插值
  const PARALLAX = options.parallax ?? 8;

  const styleEl = document.createElement('style');
  styleEl.textContent = STYLE;
  document.head.appendChild(styleEl);

  const blob = document.createElement('div');
  blob.className = 'cc-cursor';
  document.body.appendChild(blob);
  document.documentElement.classList.add('cc-enabled');

  let mouseX = window.innerWidth / 2;
  let mouseY = window.innerHeight / 2;
  let curX = mouseX;
  let curY = mouseY;
  let target = null;
  let shown = false;

  function applyTarget(el) {
    if (el === target) return;
    target = el;
    if (el) {
      const rect = el.getBoundingClientRect();
      const radius = parseFloat(getComputedStyle(el).borderRadius) || 0;
      const h = rect.height + PAD * 2;
      blob.style.width = `${rect.width + PAD * 2}px`;
      blob.style.height = `${h}px`;
      blob.style.borderRadius = `${Math.max(6, Math.min(radius + PAD, h / 2))}px`;
      blob.classList.add('cc-cursor--active');
    } else {
      blob.style.width = `${BASE}px`;
      blob.style.height = `${BASE}px`;
      blob.style.borderRadius = '50%';
      blob.classList.remove('cc-cursor--active');
    }
  }

  function tick() {
    if (target && !target.isConnected) applyTarget(null);

    if (target) {
      const rect = target.getBoundingClientRect();
      const cx = rect.left + rect.width / 2;
      const cy = rect.top + rect.height / 2;
      const destX = cx + (mouseX - cx) / PARALLAX;
      const destY = cy + (mouseY - cy) / PARALLAX;
      curX += (destX - curX) * EASE;
      curY += (destY - curY) * EASE;
    } else {
      // 自由移动模式：100% 实时同步，0ms 拖尾
      curX = mouseX;
      curY = mouseY;
    }

    const w = blob.offsetWidth || BASE;
    const h = blob.offsetHeight || BASE;
    blob.style.transform = `translate3d(${curX - w / 2}px, ${curY - h / 2}px, 0)`;
    requestAnimationFrame(tick);
  }

  document.addEventListener('mousemove', (e) => {
    mouseX = e.clientX;
    mouseY = e.clientY;
    if (!shown) {
      shown = true;
      blob.style.opacity = '1';
    }
  }, { passive: true });

  document.addEventListener('mouseover', (e) => {
    const el = e.target.closest ? e.target.closest(SELECTOR) : null;
    applyTarget(el);
  }, { passive: true });

  document.addEventListener('mouseleave', () => {
    blob.style.opacity = '0';
    shown = false;
  });
  window.addEventListener('blur', () => {
    blob.style.opacity = '0';
    shown = false;
  });

  requestAnimationFrame(tick);
}
