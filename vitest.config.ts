import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    include: ['tests/unit/**/*.test.ts'],
    // in-process worker threads: also keeps the sandboxed dev shell happy
    pool: 'threads',
  },
})
