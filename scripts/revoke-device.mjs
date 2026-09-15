#!/usr/bin/env node
const deviceId = (process.argv[2] ?? '').trim();
if (deviceId.length === 0) {
  console.error('用法: node scripts/revoke-device.mjs <deviceId>');
  process.exit(1);
}

const dbPath = process.env.AI_ROUTER_DB_PATH ?? './data/devices.db';
const { revokeDevice, deleteRefreshTokensForDevice } = await import('../gateway/db.mjs');

revokeDevice(deviceId);
deleteRefreshTokensForDevice(deviceId);

console.log(`数据库: ${dbPath}`);
console.log(`已吊销设备 ${deviceId}，并清除其全部 refresh token。`);
console.log('该设备需用新注册码重新激活: POST /api/auth/reregister (mode: reset) 或重新注册。');
