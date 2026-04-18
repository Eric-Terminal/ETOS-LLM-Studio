import Theme from "vitepress-theme-teek";
import "./custom.css";

export default {
  ...Theme,
  async enhanceApp(ctx) {
    await Theme.enhanceApp?.(ctx);
  }
};
