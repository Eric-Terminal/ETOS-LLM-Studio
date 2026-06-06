# ETOS LLM Studio · Landing

独立于文档站（`docs/site/`）的产品介绍首页，部署到 Cloudflare Pages 时把根目录指向本目录、构建命令 `pnpm install && pnpm build`、产物目录 `dist`。

## 本地开发

```bash
pnpm install
pnpm dev      # http://localhost:5173
pnpm build    # 产物：dist/
pnpm preview  # 本地预览构建产物
```

## 设计原则

- 视觉走 Apple HIG / `DESIGN.md` 的极简语言：白/灰双底色块交替、单一 Action Blue (#0066cc)、SF Pro tight tracking、零渐变。
- 动画借用 `Rishu-Website` 的实现：噪声波浪开屏 + 边框收束 + 字母 settle + 滚动 reveal + 按钮磁吸；鼠标指针改用 iPadOS 风格的 context-cursor（见下方致谢）。
- 多语言：中 / 英 / 日 / 俄 / 繁中，集中维护在 `src/i18n.js`。

## 第三方致谢 / Credits

本页用到以下开源实现，均为 MIT，已重写整合进 `src/composables/`：

- **iPadOS 磁吸指针**（`useContextCursor.js`）—— 算法改编自 Marcel Wiethan 的 *context-cursor*（MIT，Copyright © 2020 Marcel Wiethan），经 [GoldenGoCoding/iPadOS](https://github.com/GoldenGoCoding/iPadOS) 引入；去掉了原版的 GSAP 依赖，改用 CSS 过渡 + requestAnimationFrame 插值。
- **Liquid Glass 边缘折射**（`useLiquidGlass.js`）—— 改编自 [Shu Ding · liquid-glass](https://github.com/shuding/liquid-glass)（MIT）。
