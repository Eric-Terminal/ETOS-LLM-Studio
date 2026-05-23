// 语言选择：优先 localStorage，其次浏览器语言，最后兜底中文。

import { ref, watch } from 'vue';
import { LANG_LIST, translations } from '../i18n.js';

const STORAGE_KEY = 'etos-landing-lang';

function detect() {
  if (typeof navigator === 'undefined') return 'zh';
  const nav = navigator.language || '';
  if (/^zh-(hant|tw|hk|mo)/i.test(nav)) return 'zh-Hant';
  if (/^zh/i.test(nav)) return 'zh';
  if (/^ja/i.test(nav)) return 'ja';
  if (/^ru/i.test(nav)) return 'ru';
  return 'en';
}

export function useLang() {
  const saved = typeof localStorage !== 'undefined' ? localStorage.getItem(STORAGE_KEY) : null;
  const current = ref(saved && translations[saved] ? saved : detect());

  watch(current, (value) => {
    try {
      localStorage.setItem(STORAGE_KEY, value);
    } catch (e) {
      /* ignore */
    }
    if (typeof document !== 'undefined') {
      document.documentElement.lang = value === 'zh-Hant' ? 'zh-Hant' : value;
    }
  }, { immediate: true });

  return {
    current,
    list: LANG_LIST,
    set(code) {
      if (translations[code]) current.value = code;
    }
  };
}
