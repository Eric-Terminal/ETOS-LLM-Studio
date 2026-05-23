import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

// Cloudflare Pages 直接读取 dist/ 即可。
export default defineConfig({
  plugins: [vue()],
  base: './',
  build: {
    outDir: 'dist',
    assetsInlineLimit: 4096,
    cssCodeSplit: false
  }
});
