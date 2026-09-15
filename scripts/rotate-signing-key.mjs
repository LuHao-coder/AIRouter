#!/usr/bin/env node
import { generateKeyPair } from 'node:crypto';
import { mkdirSync, writeFileSync, copyFileSync, existsSync } from 'node:fs';
import { promisify } from 'node:util';
import { join, dirname } from 'node:path';

const gen = promisify(generateKeyPair);

const keysDir = process.env.AI_ROUTER_KEYS_DIR ?? join(process.cwd(), 'keys');
const privPath = process.env.AI_ROUTER_SIGNING_KEY_PATH ?? join(keysDir, 'jwt-signing.pem');
const pubPath = process.env.AI_ROUTER_SIGNING_PUB_PATH ?? join(keysDir, 'jwt-signing.pub');
const prevPrivPath = `${privPath}.prev`;
const prevPubPath = `${pubPath}.prev`;

mkdirSync(dirname(privPath), { recursive: true, mode: 0o700 });

// 保留上一对密钥：旧 AccessToken 在过期前（≤15 分钟）仍可校验，RefreshToken 存 DB 不受影响。
if (existsSync(privPath)) {
  copyFileSync(privPath, prevPrivPath);
}
if (existsSync(pubPath)) {
  copyFileSync(pubPath, prevPubPath);
}

const { publicKey, privateKey } = await gen('ed25519');

writeFileSync(privPath, privateKey.export({ format: 'pem', type: 'pkcs8' }), { mode: 0o600 });
writeFileSync(pubPath, publicKey.export({ format: 'pem', type: 'spki' }), { mode: 0o600 });

console.log(`新私钥:   ${privPath}`);
console.log(`新公钥:   ${pubPath}`);
if (existsSync(prevPubPath)) {
  console.log(`上一公钥: ${prevPubPath}（保留供旧 AccessToken 过渡）`);
}
console.log('轮换完成。重启网关生效: systemctl restart codex-router');
console.log('注意：已存在的 RefreshToken 不受影响；AccessToken 最长 15 分钟后全部使用新密钥。');
