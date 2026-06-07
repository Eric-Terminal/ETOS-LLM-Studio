# ETOS LLM Studio 文档站

独立的 VitePress 文档站源码，部署到 Cloudflare Pages。

## 本地开发

```bash
cd docs/site
pnpm install
pnpm docs:dev
```

构建：

```bash
pnpm docs:build
```

构建产物输出到 `.vitepress/dist`。

## 目录结构

- 中文版（默认根路径 `/`）：`guide/` `modules/` `design/` `tips/` `faq/` `index.md`
- 英文版镜像（`/en/`）：`en/guide/` `en/modules/` `en/design/` `en/tips/` `en/faq/` `en/index.md`
- 主题样式：`.vitepress/theme/custom.css`（Apple 风 / 见项目根 `DESIGN.md`）
- 站点配置：`.vitepress/config.ts`（i18n locales、nav、sidebar）

## Cloudflare Pages 配置

- Framework preset：`None`
- Root directory：`docs/site`
- Build command：`corepack enable && pnpm install --frozen-lockfile && pnpm docs:build`
- Output directory：`.vitepress/dist`
- Production branch：`main`
- Preview branch：推荐保留 `dev`

## 维护约定

- 中英文双语，统一在 `.vitepress/config.ts` 的 `locales` 配置中维护。
- 中文版改了之后，**对应英文版**也要同步更新（不是机翻——按英文写作惯例改写）。
- 所有 UI 文案的中文（按钮名、Section 名、字段名等）必须直接来自 `ETOSCore/ETOSCore/` 或 `ETOS LLM Studio/ETOS LLM Studio iOS App/` 下的 `NSLocalizedString` 调用，不要凭印象写。
- 写作规范见项目根 `PLAN.md` 第 1 节"写作规范"。
- `docs/` 目录下其他子目录（隐私页、调试工具、审计文档）**不并入本站**，保持原样。
