// 自定义磁吸光标（仅在 hover-capable 设备启用）

import { onBeforeUnmount, onMounted, ref } from 'vue';

export function useMagneticCursor() {
  const cursorEl = ref(null);
  let rafId;
  const pos = { x: -100, y: -100 };
  const smooth = { x: -100, y: -100 };
  const size = { w: 26, h: 26 };
  let target = null;
  const listeners = [];

  function tick() {
    let x = pos.x;
    let y = pos.y;
    if (target) {
      const rect = target.getBoundingClientRect();
      const cx = rect.left + rect.width / 2;
      const cy = rect.top + rect.height / 2;
      x = cx + (x - cx) * 0.12;
      y = cy + (y - cy) * 0.12;
      size.w = rect.width + 20;
      size.h = rect.height + 20;
    } else {
      size.w += (26 - size.w) * 0.2;
      size.h += (26 - size.h) * 0.2;
    }
    smooth.x += (x - smooth.x) * 0.28;
    smooth.y += (y - smooth.y) * 0.28;
    if (cursorEl.value) {
      cursorEl.value.style.transform = `translate3d(${smooth.x}px, ${smooth.y}px, 0) translate(-50%, -50%)`;
      cursorEl.value.style.setProperty('--cursor-width', `${size.w}px`);
      cursorEl.value.style.setProperty('--cursor-height', `${size.h}px`);
    }
    rafId = window.requestAnimationFrame(tick);
  }

  function bind() {
    if (window.matchMedia('(hover: none), (pointer: coarse)').matches) return;
    document.body.classList.add('has-custom-cursor');

    const onMove = (e) => {
      pos.x = e.clientX;
      pos.y = e.clientY;
    };
    window.addEventListener('pointermove', onMove, { passive: true });
    listeners.push({ t: window, e: 'pointermove', fn: onMove });

    rafId = window.requestAnimationFrame(tick);

    const hoverSelectors =
      'a, button, .nav-link, .lang-btn, .theme-toggle, .feature-card, .privacy-card, .stat-card, .download-card, .tag-chip, .marquee-track';
    document.querySelectorAll(hoverSelectors).forEach((el) => {
      const onEnter = () => {
        target = el;
        cursorEl.value?.classList.add('is-hover');
      };
      const onLeave = () => {
        target = null;
        cursorEl.value?.classList.remove('is-hover');
      };
      el.addEventListener('pointerenter', onEnter);
      el.addEventListener('pointerleave', onLeave);
      listeners.push({ t: el, e: 'pointerenter', fn: onEnter });
      listeners.push({ t: el, e: 'pointerleave', fn: onLeave });
    });

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

    const onLeaveWindow = () => cursorEl.value?.classList.add('is-hidden');
    const onEnterWindow = () => cursorEl.value?.classList.remove('is-hidden');
    document.addEventListener('mouseleave', onLeaveWindow);
    document.addEventListener('mouseenter', onEnterWindow);
    listeners.push({ t: document, e: 'mouseleave', fn: onLeaveWindow });
    listeners.push({ t: document, e: 'mouseenter', fn: onEnterWindow });
  }

  onMounted(() => {
    // 首屏 loader 期间不立刻绑定，等下个事件循环 DOM 完整再 query。
    window.setTimeout(bind, 2200);
  });

  onBeforeUnmount(() => {
    window.cancelAnimationFrame(rafId);
    listeners.forEach(({ t, e, fn }) => t.removeEventListener(e, fn));
    document.body.classList.remove('has-custom-cursor');
  });

  return { cursorEl };
}
