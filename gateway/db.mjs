import Database from 'better-sqlite3';
import { mkdirSync } from 'fs';
import { dirname } from 'path';

const DB_PATH = process.env.AI_ROUTER_DB_PATH || './data/devices.db';

let db = null;

function initDb() {
  mkdirSync(dirname(DB_PATH), { recursive: true });
  const conn = new Database(DB_PATH);
  conn.pragma('journal_mode = WAL');

  conn.exec(`
    CREATE TABLE IF NOT EXISTS devices (
      device_id TEXT PRIMARY KEY,
      public_key_pem TEXT NOT NULL,
      device_name TEXT DEFAULT '',
      registered_at TEXT,
      last_seen_at TEXT,
      status TEXT DEFAULT 'active'
    );

    CREATE TABLE IF NOT EXISTS refresh_tokens (
      token_hash TEXT PRIMARY KEY,
      device_id TEXT,
      created_at TEXT,
      expires_at TEXT
    );

    CREATE TABLE IF NOT EXISTS activation_nonces (
      nonce TEXT PRIMARY KEY,
      device_id TEXT,
      activation_token TEXT UNIQUE,
      public_key_pem TEXT,
      registration_code TEXT,
      created_at TEXT,
      expires_at TEXT,
      used INTEGER DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS login_nonces (
      nonce TEXT PRIMARY KEY,
      device_id TEXT,
      created_at TEXT,
      expires_at TEXT,
      used INTEGER DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS registration_codes (
      code TEXT PRIMARY KEY,
      used INTEGER DEFAULT 0,
      uses INTEGER DEFAULT 0,
      max_uses INTEGER DEFAULT -1,
      used_by_device TEXT DEFAULT NULL,
      used_at TEXT DEFAULT NULL
    );
  `);

  try {
    conn.prepare('ALTER TABLE registration_codes ADD COLUMN uses INTEGER DEFAULT 0').run();
  } catch (e) { /* column already exists */ }
  try {
    conn.prepare('ALTER TABLE registration_codes ADD COLUMN max_uses INTEGER DEFAULT -1').run();
  } catch (e) { /* column already exists */ }
  try {
    conn.prepare('ALTER TABLE activation_nonces ADD COLUMN registration_code TEXT').run();
  } catch (e) { /* column already exists */ }

  return conn;
}

export function getDb() {
  if (!db) {
    db = initDb();
  }
  return db;
}

export function getDevice(deviceId) {
  return getDb().prepare('SELECT * FROM devices WHERE device_id = ?').get(deviceId);
}

export function upsertDevice(deviceId, publicKeyPem, deviceName) {
  const now = new Date().toISOString();
  return getDb().prepare(`
    INSERT INTO devices (device_id, public_key_pem, device_name, registered_at, last_seen_at)
    VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(device_id) DO UPDATE SET
      public_key_pem = excluded.public_key_pem,
      device_name = excluded.device_name
  `).run(deviceId, publicKeyPem, deviceName || '', now, now);
}

export function updateLastSeen(deviceId) {
  const now = new Date().toISOString();
  return getDb().prepare('UPDATE devices SET last_seen_at = ? WHERE device_id = ?').run(now, deviceId);
}

export function revokeDevice(deviceId) {
  return getDb().prepare("UPDATE devices SET status = 'revoked' WHERE device_id = ?").run(deviceId);
}

export function saveRefreshToken(tokenHash, deviceId, expiresAt) {
  const now = new Date().toISOString();
  return getDb().prepare('INSERT INTO refresh_tokens (token_hash, device_id, created_at, expires_at) VALUES (?, ?, ?, ?)').run(tokenHash, deviceId, now, expiresAt);
}

export function getRefreshToken(tokenHash) {
  return getDb().prepare('SELECT * FROM refresh_tokens WHERE token_hash = ?').get(tokenHash);
}

export function deleteRefreshTokensForDevice(deviceId) {
  return getDb().prepare('DELETE FROM refresh_tokens WHERE device_id = ?').run(deviceId);
}

export function deleteRefreshToken(tokenHash) {
  return getDb().prepare('DELETE FROM refresh_tokens WHERE token_hash = ?').run(tokenHash);
}

export function saveActivationNonce(nonce, deviceId, activationToken, publicKeyPem, registrationCode, expiresAt) {
  const now = new Date().toISOString();
  return getDb().prepare('INSERT INTO activation_nonces (nonce, device_id, activation_token, public_key_pem, registration_code, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)').run(nonce, deviceId, activationToken, publicKeyPem, registrationCode, now, expiresAt);
}

export function getActivationNonce(activationToken) {
  return getDb().prepare('SELECT * FROM activation_nonces WHERE activation_token = ?').get(activationToken);
}

export function markActivationNonceUsed(nonce) {
  return getDb().prepare('UPDATE activation_nonces SET used = 1 WHERE nonce = ?').run(nonce);
}

export function saveLoginNonce(nonce, deviceId, expiresAt) {
  const now = new Date().toISOString();
  return getDb().prepare('INSERT INTO login_nonces (nonce, device_id, created_at, expires_at) VALUES (?, ?, ?, ?)').run(nonce, deviceId, now, expiresAt);
}

export function getLoginNonce(nonce) {
  return getDb().prepare('SELECT * FROM login_nonces WHERE nonce = ?').get(nonce);
}

export function markLoginNonceUsed(nonce) {
  return getDb().prepare('UPDATE login_nonces SET used = 1 WHERE nonce = ?').run(nonce);
}

export function getRegistrationCode(code) {
  return getDb().prepare('SELECT * FROM registration_codes WHERE code = ?').get(code);
}

export function incrementRegistrationCodeUses(code, deviceId) {
  const now = new Date().toISOString();
  return getDb().prepare('UPDATE registration_codes SET used = 1, uses = uses + 1, used_by_device = ?, used_at = ? WHERE code = ?').run(deviceId, now, code);
}

export function cleanupExpiredNonces() {
  const now = new Date().toISOString();
  const conn = getDb();
  conn.prepare('DELETE FROM activation_nonces WHERE expires_at < ?').run(now);
  conn.prepare('DELETE FROM login_nonces WHERE expires_at < ?').run(now);
}
