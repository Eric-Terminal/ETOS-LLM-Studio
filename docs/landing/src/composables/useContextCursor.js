// ============================================================================
// Context Cursor —— iPadOS 风格的「磁吸」指针
// ============================================================================
// 一颗半透明玻璃圆点跟随鼠标；悬停到可交互元素（链接 / 按钮）上时，会变形成
// 贴合该元素的圆角矩形并带轻微视差，营造 iPadOS 指针那种吸附 / 软糖质感。
//
// 算法改编自 Marcel Wiethan 的 "context-cursor"（MIT，2020），
// 经由 GoldenGoCoding 的 iPadOS 项目引入：
//   原作者 / 致谢：Marcel Wiethan — context-cursor (MIT, 2020)
//   参考项目：https://github.com/GoldenGoCoding/iPadOS
//
// 原版依赖 GSAP TweenLite，并以 [data-ccursor] 属性 + window.onload 收集目标。
// 这里去掉 GSAP 依赖：尺寸/圆角用 CSS 过渡、位置用 requestAnimationFrame 插值，
// 目标元素改为事件委托（无需改模板）。仅在 (pointer: fine) 且未开启
// prefers-reduced-motion 的设备启用，触屏 / 无障碍场景自动跳过。
// ============================================================================

const STYLE = `
.cc-cursor {
  position: fixed;
  top: 0;
  left: 0;
  width: 18px;
  height: 18px;
  border-radius: 50%;
  background: rgba(150, 150, 160, 0.18);
  border: 1px solid rgba(255, 255, 255, 0.4);
  box-shadow: 0 1px 6px rgba(0, 0, 0, 0.08);
  pointer-events: none;
  z-index: 9999;
  opacity: 0;
  transform: translate3d(-100px, -100px, 0);
  transition: width 0.22s cubic-bezier(0.22, 1, 0.36, 1),
              height 0.22s cubic-bezier(0.22, 1, 0.36, 1),
              border-radius 0.22s cubic-bezier(0.22, 1, 0.36, 1),
              background-color 0.22s ease,
              border-color 0.22s ease,
              opacity 0.2s ease;
  will-change: transform, width, height;
}
.cc-cursor--active {
  background: rgba(120, 120, 130, 0.14);
  border-color: rgba(255, 255, 255, 0.5);
}
html.cc-enabled, html.cc-enabled * { cursor: none !important; }
`;

export function initContextCursor(options = {}) {
  if (typeof window === 'undefined' || !window.matchMedia) return;
  if (document.querySelector('.cc-cursor')) return;
  const fine = window.matchMedia('(pointer: fine)').matches;
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (!fine || reduced) return;

  const SELECTOR =
    options.selector ||
    'a[href], button, [role="button"], .btn-pill, .nav-link, .lang-btn, .theme-toggle';
  const BASE = options.size || 18; // 自由态直径
  const PAD = options.padding ?? 6; // 悬停时在元素四周外扩
  const EASE = options.ease ?? 0.18; // 位置插值系数（越小越「拖尾」）
  const PARALLAX = options.parallax ?? 6; // 悬停时光标朝鼠标偏移的分母（越大越轻）

  // 注入样式（一次）
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
    // 目标可能被移除（如语言菜单收起）
    if (target && !target.isConnected) applyTarget(null);

    let destX = mouseX;
    let destY = mouseY;
    if (target) {
      const rect = target.getBoundingClientRect();
      const cx = rect.left + rect.width / 2;
      const cy = rect.top + rect.height / 2;
      destX = cx + (mouseX - cx) / PARALLAX;
      destY = cy + (mouseY - cy) / PARALLAX;
    }
    curX += (destX - curX) * EASE;
    curY += (destY - curY) * EASE;

    blob.style.transform = `translate3d(${curX - curW / 2}px, ${curY - curH / 2}px, 0)`;
    requestAnimationFrame(tick);
  }

  document.addEventListener('mousemove', (e) => {
    mouseX = e.clientX;
    mouseY = e.clientY;
    if (!shown) {
      shown = true;
      blob.style.opacity = '1';
    }
  });

  // 事件委托：进入任意元素时，向上找最近的可交互祖先
  document.addEventListener('mouseover', (e) => {
    const el = e.target.closest ? e.target.closest(SELECTOR) : null;
    applyTarget(el);
  });

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
