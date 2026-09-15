#!/usr/bin/env node
const dbPath = process.env.AI_ROUTER_DB_PATH ?? './data/devices.db';
const { getDb } = await import('../gateway/db.mjs');

console.log(`数据库: ${dbPath}\n`);
const devices = getDb()
  .prepare('SELECT device_id, device_name, status, registered_at, last_seen_at FROM devices ORDER BY last_seen_at DESC')
  .all();
const sessionCounts = new Map(
  getDb()
    .prepare('SELECT device_id, COUNT(*) AS total FROM device_sessions GROUP BY device_id')
    .all()
    .map((row) => [row.device_id, row.total])
);

if (devices.length === 0) {
  console.log('（无设备）');
  process.exit(0);
}

for (const device of devices) {
  const name = device.device_name ? ` (${device.device_name})` : '';
  console.log(`${device.device_id}${name}`);
  console.log(`  状态=${device.status}  会话数=${sessionCounts.get(device.device_id) ?? 0}  最近活跃=${device.last_seen_at ?? '-'}`);
}
