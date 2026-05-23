// 主题切换：跟随系统、可手动 override，状态写入 localStorage。

import { ref, watch } from 'vue';

const STORAGE_KEY = 'etos-landing-theme';

export function useTheme() {
  const saved = typeof localStorage !== 'undefined' ? localStorage.getItem(STORAGE_KEY) : null;
  const prefersDark =
    typeof window !== 'undefined' && window.matchMedia('(prefers-color-scheme: dark)').matches;
  const isDark = ref(saved === 'dark' || (!saved && prefersDark));

  function apply(value) {
    if (typeof document === 'undefined') return;
    document.documentElement.classList.toggle('dark', value);
  }
  apply(isDark.value);

  watch(isDark, (value) => {
    apply(value);
    try {
      localStorage.setItem(STORAGE_KEY, value ? 'dark' : 'light');
    } catch (e) {
      /* ignore */
    }
  });

  return {
    isDark,
    toggle() {
      isDark.value = !isDark.value;
    }
  };
}
