// 按钮磁吸悬停（仅在 hover-capable 设备启用）
//
// 注：原先这里还渲染了一个四角描边的自定义光标，已移除（改用
// composables/useContextCursor.js 的 iPadOS 风格指针）。此处仅保留
// 按钮在悬停时朝鼠标方向轻微位移的「磁吸」效果。

import { onBeforeUnmount, onMounted } from 'vue';

export function useMagneticCursor() {
  const listeners = [];

  function bind() {
    if (window.matchMedia('(hover: none), (pointer: coarse)').matches) return;

    const magneticSelectors = '.theme-toggle, .lang-btn, .nav-link, .back-to-top, .btn-pill';
    document.querySelectorAll(magneticSelectors).forEach((el) => {
      el.classList.add('is-magnetic');
      const onMag = (e) => {
        const r = el.getBoundingClientRect();
        const x = (e.clientX - r.left - r.width / 2) * 0.4;
        const y = (e.clientY - r.top - r.height / 2) * 0.4;
        el.style.setProperty('--mx', x);
        el.style.setProperty('--my', y);
      };
      const onReset = () => {
        el.style.setProperty('--mx', 0);
        el.style.setProperty('--my', 0);
      };
      el.addEventListener('pointermove', onMag);
      el.addEventListener('pointerleave', onReset);
      listeners.push({ t: el, e: 'pointermove', fn: onMag });
      listeners.push({ t: el, e: 'pointerleave', fn: onReset });
    });
  }

  onMounted(() => {
    // 首屏 loader 期间不立刻绑定，等下个事件循环 DOM 完整再 query。
    window.setTimeout(bind, 2200);
  });

  onBeforeUnmount(() => {
    listeners.forEach(({ t, e, fn }) => t.removeEventListener(e, fn));
  });
}
