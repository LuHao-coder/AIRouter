#!/usr/bin/env node
const code = (process.argv[2] ?? '').trim();
if (code.length === 0) {
  console.error('用法: node scripts/delete-registration-code.mjs <code>');
  process.exit(1);
}

const dbPath = process.env.AI_ROUTER_DB_PATH ?? './data/devices.db';
const { getDb, getRegistrationCode } = await import('../gateway/db.mjs');

const row = getRegistrationCode(code);
if (!row) {
  console.log(`未找到注册码 ${code}（数据库 ${dbPath}）`);
  process.exit(0);
}

getDb().prepare('DELETE FROM registration_codes WHERE code = ?').run(code);
console.log(`已删除注册码 ${code}（数据库 ${dbPath}）`);
console.log('提示：这只是删除注册码，不影响已激活设备现有的 access/refresh token。');
