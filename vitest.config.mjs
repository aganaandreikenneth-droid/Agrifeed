import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    // Test files share the emulators; run them one at a time.
    fileParallelism: false,
    testTimeout: 30000,
    hookTimeout: 60000,
  },
});
