import { env } from 'cloudflare:workers';
import { applyD1Migrations, reset } from 'cloudflare:test';
import { beforeEach } from 'vitest';
import type { D1Migration } from '@cloudflare/vitest-plugin';
import type { Env } from '../src/models';
declare global { namespace Cloudflare { interface Env extends Omit<import('../src/models').Env, 'OAUTH_PROVIDER'> { TEST_MIGRATIONS: D1Migration[]; } } }
beforeEach(async () => { await reset(); await applyD1Migrations(env.DB, env.TEST_MIGRATIONS); });
