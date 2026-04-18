# ETOS LLM Studio 文档站

这个目录是独立的 VitePress 文档站源码，专门用于 Cloudflare Pages 静态部署。

## 本地开发

```bash
cd docs/site
pnpm install
pnpm docs:dev
```

## 构建

```bash
cd docs/site
pnpm docs:build
```

构建产物输出到 `.vitepress/dist`。

## Cloudflare Pages

- Framework preset: `None`
- Root directory: `docs/site`
- Build command: `corepack enable && pnpm install --frozen-lockfile && pnpm docs:build`
- Output directory: `.vitepress/dist`
- Production branch: `main`
- Preview branch: 推荐保留 `dev`

## 维护约定

- 站点当前只启用简体中文内容。
- 英文与日文先预留结构，不在首版启用语言切换。
- 现有 `docs/` 下的隐私页、调试工具和审计文档保持原样，不并入本目录。
