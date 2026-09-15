#!/usr/bin/env node
const dbPath = process.env.AI_ROUTER_DB_PATH ?? './data/devices.db';
const { getDb } = await import('../gateway/db.mjs');

console.log(`数据库: ${dbPath}\n`);
const rows = getDb()
  .prepare('SELECT code, used, uses, max_uses, used_by_device, used_at FROM registration_codes ORDER BY used_at DESC')
  .all();

if (rows.length === 0) {
  console.log('（无注册码）');
  process.exit(0);
}

for (const row of rows) {
  const limit = row.max_uses >= 0 ? row.max_uses : '∞';
  const state = row.used ? `已用 ${row.uses}/${limit}` : `未用 0/${limit}`;
  const owner = row.used_by_device ?? '-';
  console.log(`${row.code}  [${state}]  绑定设备=${owner}${row.used_at ? `  时间=${row.used_at}` : ''}`);
}
