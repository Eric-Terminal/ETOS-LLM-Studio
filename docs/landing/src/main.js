import { createApp } from 'vue';
import App from './App.vue';
import './style.css';
import { createRevealDirective } from './composables/useReveal.js';
import { createLiquidGlassDirective } from './composables/useLiquidGlass.js';
import { initContextCursor } from './composables/useContextCursor.js';

const app = createApp(App);
app.directive('reveal', createRevealDirective({ threshold: 0.15 }));
app.directive('liquid-glass', createLiquidGlassDirective());
app.mount('#app');

initContextCursor();
