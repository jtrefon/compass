import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";

export default defineConfig({
  site: "https://jtrefon.github.io/compass/",
  base: "/compass",
  outDir: "../docs",
  publicDir: "public",
  integrations: [sitemap()],
  trailingSlash: "ignore",
  vite: {
    build: { emptyOutDir: false },
  },
});
