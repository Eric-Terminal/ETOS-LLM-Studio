import { createApp } from 'vue';
import App from './App.vue';
import './style.css';
import { createRevealDirective } from './composables/useReveal.js';

const app = createApp(App);
app.directive('reveal', createRevealDirective({ threshold: 0.15 }));
app.mount('#app');
