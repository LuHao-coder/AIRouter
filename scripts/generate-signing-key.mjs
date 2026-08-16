#!/usr/bin/env node
import { generateKeyPair } from 'node:crypto';
import { mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { promisify } from 'node:util';
import { join } from 'node:path';

const gen = promisify(generateKeyPair);

const keysDir = process.env.AI_ROUTER_KEYS_DIR ?? join(process.cwd(), 'keys');
const privPath = join(keysDir, 'jwt-signing.pem');
const pubPath = join(keysDir, 'jwt-signing.pub');

if (existsSync(privPath) || existsSync(pubPath)) {
  console.error('Signing keys already exist. Remove them first to regenerate.');
  process.exit(1);
}

mkdirSync(keysDir, { recursive: true, mode: 0o700 });

const { publicKey, privateKey } = await gen('ed25519');

const privPem = privateKey.export({ format: 'pem', type: 'pkcs8' });
const pubPem = publicKey.export({ format: 'pem', type: 'spki' });

writeFileSync(privPath, privPem, { mode: 0o600 });
writeFileSync(pubPath, pubPem, { mode: 0o600 });

console.log(`Private key: ${privPath}`);
console.log(`Public key:  ${pubPath}`);
console.log('Ed25519 signing key pair generated successfully.');
