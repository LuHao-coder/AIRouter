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

    CREATE TABLE IF NOT EXISTS device_sessions (
      thread_id TEXT PRIMARY KEY,
      device_id TEXT NOT NULL,
      created_at TEXT
    );

    -- 会话产出的文件登记表：文件物理仍在 OPENCODE_WORKDIR，按会话归属到设备，
    -- 文件列表/下载按此表做设备隔离（不依赖 opencode 的目录隔离）。
    CREATE TABLE IF NOT EXISTS session_files (
      thread_id TEXT NOT NULL,
      device_id TEXT NOT NULL,
      path TEXT NOT NULL,
      name TEXT NOT NULL,
      size INTEGER DEFAULT 0,
      modified_at TEXT DEFAULT '',
      created_at TEXT,
      PRIMARY KEY (thread_id, path)
    );

    CREATE INDEX IF NOT EXISTS idx_session_files_device ON session_files(device_id);
  `);

  // 迁移兼容：旧库可能把多个码绑到同一设备，先按设备保留最早一条，再建唯一索引，
  // 避免 CREATE UNIQUE INDEX 因历史重复数据失败导致启动崩溃。
  conn.prepare(`
    DELETE FROM registration_codes
     WHERE used_by_device IS NOT NULL
       AND rowid NOT IN (
         SELECT MIN(rowid) FROM registration_codes
          WHERE used_by_device IS NOT NULL
          GROUP BY used_by_device
       )
  `).run();
  conn.exec(`
    CREATE UNIQUE INDEX IF NOT EXISTS idx_registration_codes_device
      ON registration_codes(used_by_device) WHERE used_by_device IS NOT NULL;
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

/** 管理员预生成注册码。maxUses=1 表示一次性码，激活即失效。 */
export function createRegistrationCode(code, maxUses = 1) {
  getDb()
    .prepare('INSERT INTO registration_codes (code, max_uses) VALUES (?, ?)')
    .run(code, maxUses);
  return code;
}

/** 按设备反向查询其注册码（用于自动分配 / 只读展示）。 */
export function getRegistrationCodeByDevice(deviceId) {
  return getDb()
    .prepare('SELECT * FROM registration_codes WHERE used_by_device = ?')
    .get(deviceId);
}

/**
 * 为设备插入自动分配的注册码。used_by_device 上的唯一索引保证“一设备一码”，
 * INSERT OR IGNORE 让并发注册时只落一条，之后由 getRegistrationCodeByDevice 读回。
 */
export function insertDeviceRegistrationCode(code, deviceId) {
  const now = new Date().toISOString();
  return getDb().prepare(`
    INSERT OR IGNORE INTO registration_codes (code, used, uses, max_uses, used_by_device, used_at)
    VALUES (?, 1, 1, -1, ?, ?)
  `).run(code, deviceId, now);
}

/**
 * 原子地把注册码绑定到设备：一码一设备、用满即失效。
 * 仅当“未绑定或已绑定到同一设备”且“未超过使用上限”时才成功，返回 true/false。
 */
export function bindRegistrationCode(code, deviceId) {
  const now = new Date().toISOString();
  const result = getDb().prepare(`
    UPDATE registration_codes
       SET used = 1, uses = uses + 1, used_by_device = ?, used_at = ?
     WHERE code = ?
       AND (used_by_device IS NULL OR used_by_device = ?)
       AND (max_uses < 0 OR uses < max_uses)
  `).run(deviceId, now, code, deviceId);
  return result.changes > 0;
}

export function saveDeviceSession(threadId, deviceId) {
  const now = new Date().toISOString();
  return getDb().prepare(`
    INSERT INTO device_sessions (thread_id, device_id, created_at)
    VALUES (?, ?, ?)
    ON CONFLICT(thread_id) DO UPDATE SET device_id = excluded.device_id
  `).run(threadId, deviceId, now);
}

export function getDeviceSessionOwner(threadId) {
  const row = getDb().prepare('SELECT device_id FROM device_sessions WHERE thread_id = ?').get(threadId);
  return row ? row.device_id : null;
}

export function listDeviceSessions(deviceId) {
  return getDb()
    .prepare('SELECT thread_id FROM device_sessions WHERE device_id = ?')
    .all(deviceId)
    .map((row) => row.thread_id);
}

export function deleteDeviceSession(threadId) {
  return getDb().prepare('DELETE FROM device_sessions WHERE thread_id = ?').run(threadId);
}

export function upsertSessionFile(threadId, deviceId, filePath, name, size, modifiedAt) {
  const now = new Date().toISOString();
  return getDb().prepare(`
    INSERT INTO session_files (thread_id, device_id, path, name, size, modified_at, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(thread_id, path) DO UPDATE SET
      size = excluded.size,
      modified_at = excluded.modified_at
  `).run(threadId, deviceId, filePath, name, size, modifiedAt, now);
}

/** 某设备所有会话产出的文件（按 name 去重，保留较新的 size/modified_at）。 */
export function listSessionFiles(deviceId) {
  return getDb().prepare(`
    SELECT name, MAX(size) AS size, MAX(modified_at) AS modified_at
      FROM session_files
     WHERE device_id = ?
     GROUP BY name
  `).all(deviceId);
}

/** 某设备的全部文件登记记录（含相对路径 name 与绝对路径 path）。 */
export function listSessionFileRecords(deviceId) {
  return getDb().prepare(`
    SELECT path, name FROM session_files
     WHERE device_id = ?
  `).all(deviceId);
}

/** 精确查某设备名下、指定 name 的文件记录（用于下载校验，杜绝越权/穿越）。 */
export function findSessionFile(deviceId, name) {
  return getDb().prepare(`
    SELECT path, name FROM session_files
     WHERE device_id = ? AND name = ?
     LIMIT 1
  `).get(deviceId, name);
}

export function cleanupExpiredNonces() {
  const now = new Date().toISOString();
  const conn = getDb();
  conn.prepare('DELETE FROM activation_nonces WHERE expires_at < ?').run(now);
  conn.prepare('DELETE FROM login_nonces WHERE expires_at < ?').run(now);
}
