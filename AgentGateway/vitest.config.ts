import { defineConfig } from 'vitest/config';
import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-plugin';

export default defineConfig({
  plugins: [cloudflareTest({
    main: './src/index.ts', remoteBindings: false,
    miniflare: {
      compatibilityDate: '2026-10-16', compatibilityFlags: ['nodejs_compat', 'global_fetch_strictly_public'],
      d1Databases: ['DB'], kvNamespaces: ['OAUTH_KV'],
      bindings: { PUBLIC_ORIGIN: 'https://gateway.test', APPLE_APP_ID: 'com.example.synthetic', CLOUDKIT_CONTAINER: 'iCloud.synthetic', TEST_MIGRATIONS: await readD1Migrations('./migrations') },
    },
  })],
  test: { setupFiles: ['./test/setup.ts'], fileParallelism: false, testTimeout: 20000 },
});
