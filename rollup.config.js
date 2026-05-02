import { defineConfig } from 'rollup';
import deckyPlugin from "@decky/rollup";

export default defineConfig(deckyPlugin({
  // Leave empty to let the plugin handle the API v2 defaults
}));
