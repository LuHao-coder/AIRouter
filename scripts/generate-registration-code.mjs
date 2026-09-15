#!/usr/bin/env node
import crypto from 'node:crypto';

const count = Math.max(1, Number(process.argv[2] ?? '1') || 1);
const maxUses = Number(process.argv[3] ?? '1');
const uses = Number.isFinite(maxUses) ? maxUses : 1;

const dbPath = process.env.AI_ROUTER_DB_PATH ?? './data/devices.db';
const { createRegistrationCode } = await import('../gateway/db.mjs');

console.log(`数据库: ${dbPath}`);
console.log(`使用上限: ${uses < 0 ? '不限次' : uses} | 绑定策略: 一码一设备（激活即绑定）\n`);

for (let i = 0; i < count; i += 1) {
  const code = `air-${crypto.randomBytes(8).toString('hex')}`;
  createRegistrationCode(code, uses);
  console.log(code);
}

console.log(`\n已生成 ${count} 个注册码，交给对应设备在 App 首次连接时输入。`);
