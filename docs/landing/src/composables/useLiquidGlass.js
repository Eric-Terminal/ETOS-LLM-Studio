// ============================================================================
// Liquid Glass —— 轻量版（仅保留高光 + CSS 磨砂）
// ============================================================================
// 原先用 圆角矩形 SDF → feImage → feDisplacementMap → backdrop-filter 实时
// 生成边缘折射贴图，但每个元素都要画一张逐像素 canvas 并 toDataURL，多个气泡 /
// 圆钮 / 输入框叠加下内存开销很大（数百 MB）。
//
// 这里改为不再生成折射贴图：玻璃质感完全交给 CSS —— 元素自身的
// `backdrop-filter: blur() saturate()` 提供磨砂，`::before` 提供边缘高光。
// 指令保留为空操作，以免改动模板里的 v-liquid-glass 用法。
// ============================================================================

export function createLiquidGlassDirective() {
  return { mounted() {}, unmounted() {} };
}
