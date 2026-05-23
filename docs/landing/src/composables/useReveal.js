// IntersectionObserver 触发的滚动揭示
//
// 用法：在元素上加 v-reveal 指令（见 main.js / App.vue），或直接给元素挂 .reveal-block 等待 .is-visible。
// 这里返回一个 directive，让调用方按需注册。

export function createRevealDirective({ threshold = 0.15 } = {}) {
  if (typeof window === 'undefined' || !('IntersectionObserver' in window)) {
    return {
      mounted(el) {
        el.classList.add('is-visible');
      }
    };
  }

  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          observer.unobserve(entry.target);
        }
      });
    },
    { threshold }
  );

  return {
    mounted(el) {
      el.classList.add('reveal-block');
      observer.observe(el);
    },
    unmounted(el) {
      observer.unobserve(el);
    }
  };
}
