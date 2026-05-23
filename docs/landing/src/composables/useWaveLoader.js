// 开屏波浪动画 + 边框收束
//
// 原理：用噪声驱动一组 SVG 路径，按列竖向起伏，跟随光标产生力场扰动。
// 落地后路径并不销毁，而是以左右两侧 mask 渐显的方式继续作为背景纹理常驻。

import { onBeforeUnmount, onMounted, ref } from 'vue';

function fadeNoise(t) {
  return t * t * (3 - 2 * t);
}

function hashNoise(x, y) {
  const value = Math.sin(x * 127.1 + y * 311.7) * 43758.5453123;
  return value - Math.floor(value);
}

function valueNoise(x, y) {
  const ix = Math.floor(x);
  const iy = Math.floor(y);
  const fx = x - ix;
  const fy = y - iy;
  const ux = fadeNoise(fx);
  const uy = fadeNoise(fy);
  const a = hashNoise(ix, iy);
  const b = hashNoise(ix + 1, iy);
  const c = hashNoise(ix, iy + 1);
  const d = hashNoise(ix + 1, iy + 1);
  const x1 = a + (b - a) * ux;
  const x2 = c + (d - c) * ux;
  return (x1 + (x2 - x1) * uy) * 2 - 1;
}

export function useWaveLoader({ duration = 1900 } = {}) {
  const wavePaths = ref([]);
  const showLoader = ref(true);
  const loaderLeaving = ref(false);
  const showFrame = ref(true);
  const frameLeaving = ref(false);

  let waveFrame;
  let waveStart = 0;
  let loaderTimer;
  let waveLines = [];
  const mouse = {
    x: -1000,
    y: 0,
    sx: -1000,
    sy: 0,
    lx: -1000,
    ly: 0,
    velocity: 0,
    smoothVelocity: 0,
    angle: 0,
    set: false
  };

  function resetLines(width, height) {
    const xGap = width <= 600 ? 18 : 13;
    const yGap = width <= 600 ? 28 : 22;
    const totalLines = Math.ceil((width + 220) / xGap);
    const totalPoints = Math.ceil((height + 80) / yGap);
    const xStart = (width - totalLines * xGap) / 2;
    const yStart = (height - totalPoints * yGap) / 2;

    waveLines = Array.from({ length: totalLines + 1 }, (_, lineIndex) =>
      Array.from({ length: totalPoints + 1 }, (_, pointIndex) => ({
        x: xStart + xGap * lineIndex,
        y: yStart + yGap * pointIndex,
        wave: { x: 0, y: 0 },
        cursor: { x: 0, y: 0, vx: 0, vy: 0 }
      }))
    );
  }

  function computeFrame(time) {
    const width = window.innerWidth;
    const height = window.innerHeight;
    const elapsed = time - waveStart;
    const expectedLines = Math.ceil((width + 220) / (width <= 600 ? 16 : 11)) + 1;

    if (waveLines.length !== expectedLines) {
      resetLines(width, height);
    }

    mouse.sx += (mouse.x - mouse.sx) * 0.1;
    mouse.sy += (mouse.y - mouse.sy) * 0.1;

    const dx = mouse.x - mouse.lx;
    const dy = mouse.y - mouse.ly;
    const distance = Math.hypot(dx, dy);
    mouse.velocity = distance;
    mouse.smoothVelocity += (distance - mouse.smoothVelocity) * 0.1;
    mouse.smoothVelocity = Math.min(100, mouse.smoothVelocity);
    mouse.angle = Math.atan2(dy, dx);
    mouse.lx = mouse.x;
    mouse.ly = mouse.y;

    wavePaths.value = waveLines.map((points) => {
      const moved = points.map((point) => {
        const move =
          valueNoise(
            (point.x + elapsed * 0.0125) * 0.002,
            (point.y + elapsed * 0.005) * 0.0015
          ) * 11;

        point.wave.x = Math.cos(move) * 34;
        point.wave.y = Math.sin(move) * 12;

        const forceDx = point.x - mouse.sx;
        const forceDy = point.y - mouse.sy;
        const forceDistance = Math.hypot(forceDx, forceDy);
        const radius = Math.max(145, mouse.smoothVelocity * 2.1);

        if (mouse.set && forceDistance < radius) {
          const strength = 1 - forceDistance / radius;
          const force = Math.cos(forceDistance * 0.001) * strength;
          point.cursor.vx +=
            Math.cos(mouse.angle) * force * radius * mouse.smoothVelocity * 0.00038;
          point.cursor.vy +=
            Math.sin(mouse.angle) * force * radius * mouse.smoothVelocity * 0.00038;
        }

        point.cursor.vx += (0 - point.cursor.x) * 0.005;
        point.cursor.vy += (0 - point.cursor.y) * 0.005;
        point.cursor.vx *= 0.925;
        point.cursor.vy *= 0.925;
        point.cursor.x += point.cursor.vx * 2;
        point.cursor.y += point.cursor.vy * 2;
        point.cursor.x = Math.min(100, Math.max(-100, point.cursor.x));
        point.cursor.y = Math.min(100, Math.max(-100, point.cursor.y));

        return {
          x: Math.round((point.x + point.wave.x + point.cursor.x) * 10) / 10,
          y: Math.round((point.y + point.wave.y + point.cursor.y) * 10) / 10
        };
      });

      let d = `M ${moved[0].x} ${moved[0].y}`;
      for (let i = 1; i < moved.length - 1; i += 1) {
        const p = moved[i];
        const next = moved[i + 1];
        const midX = Math.round(((p.x + next.x) / 2) * 10) / 10;
        const midY = Math.round(((p.y + next.y) / 2) * 10) / 10;
        d += ` Q ${p.x} ${p.y} ${midX} ${midY}`;
      }
      const last = moved[moved.length - 1];
      d += ` L ${last.x} ${last.y}`;

      return { d };
    });
  }

  function tick(time) {
    computeFrame(time);
    waveFrame = window.requestAnimationFrame(tick);
  }

  function onPointerMove(event) {
    mouse.x = event.clientX;
    mouse.y = event.clientY;
    if (!mouse.set) {
      mouse.sx = mouse.x;
      mouse.sy = mouse.y;
      mouse.lx = mouse.x;
      mouse.ly = mouse.y;
      mouse.set = true;
    }
  }

  function finish() {
    loaderLeaving.value = true;
    window.setTimeout(() => {
      showLoader.value = false;
      frameLeaving.value = true;
      window.setTimeout(() => {
        showFrame.value = false;
      }, 1100);
    }, 620);
  }

  onMounted(() => {
    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reducedMotion) {
      showLoader.value = false;
      showFrame.value = false;
      return;
    }
    waveStart = performance.now();
    resetLines(window.innerWidth, window.innerHeight);
    computeFrame(waveStart);
    waveFrame = window.requestAnimationFrame(tick);
    loaderTimer = window.setTimeout(finish, duration);
    window.addEventListener('pointermove', onPointerMove, { passive: true });
  });

  onBeforeUnmount(() => {
    window.cancelAnimationFrame(waveFrame);
    window.clearTimeout(loaderTimer);
    window.removeEventListener('pointermove', onPointerMove);
  });

  return { wavePaths, showLoader, loaderLeaving, showFrame, frameLeaving };
}
