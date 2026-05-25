import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { sveltekit } from "@sveltejs/kit/vite";
import { defineConfig } from "vite";
import type { Plugin } from "vite";

export default defineConfig({
  plugins: [ghosttyWasmAsset(), sveltekit()],
  worker: {
    format: "es",
  },
  test: {
    environment: "jsdom",
    include: ["src/**/*.test.ts"],
  },
});

function ghosttyWasmAsset(): Plugin {
  const fileName = "ghostty-vt.wasm";
  const sourcePath = join(process.cwd(), "node_modules/ghostty-web", fileName);

  function readWasm(): Buffer {
    if (!existsSync(sourcePath)) {
      throw new Error(`Missing ${fileName}; run bun install before starting the web app.`);
    }
    return readFileSync(sourcePath);
  }

  return {
    name: "prowl-ghostty-wasm-asset",
    configureServer(server) {
      server.middlewares.use(`/${fileName}`, (_request, response) => {
        response.setHeader("Content-Type", "application/wasm");
        response.end(readWasm());
      });
    },
    generateBundle() {
      this.emitFile({
        type: "asset",
        fileName,
        source: readWasm(),
      });
    },
  };
}
