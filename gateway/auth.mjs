import crypto from 'node:crypto';
import fs from 'node:fs';
import {
  getRegistrationCode,
  incrementRegistrationCodeUses,
  saveActivationNonce,
  getActivationNonce,
  markActivationNonceUsed,
  upsertDevice,
  getDevice,
  updateLastSeen,
  saveRefreshToken,
  getRefreshToken,
  deleteRefreshToken,
  deleteRefreshTokensForDevice,
  saveLoginNonce,
  getLoginNonce,
  markLoginNonceUsed,
  cleanupExpiredNonces as dbCleanupExpiredNonces,
} from './db.mjs';

const PRIVATE_KEY_PATH =
  process.env.AI_ROUTER_SIGNING_KEY_PATH ?? './keys/jwt-signing.pem';
const PUBLIC_KEY_PATH =
  process.env.AI_ROUTER_SIGNING_PUB_PATH ?? './keys/jwt-signing.pub';

const privateKey = fs.readFileSync(PRIVATE_KEY_PATH, 'utf8');
const publicKey = fs.readFileSync(PUBLIC_KEY_PATH, 'utf8');

const NONCE_TTL_MS = 2 * 60 * 1000;
const REFRESH_TOKEN_TTL_MS = 7 * 24 * 60 * 60 * 1000;

function hashToken(token) {
  return crypto.createHash('sha256').update(token).digest('hex');
}

function generateNonce() {
  return crypto.randomBytes(16).toString('base64url');
}

function generateActivationToken() {
  return 'act-' + crypto.randomUUID();
}

function generateRefreshToken() {
  return 'rt-' + crypto.randomUUID();
}

function expiresAtMs(ms) {
  return new Date(Date.now() + ms).toISOString();
}

function base64url(buf) {
  return (Buffer.isBuffer(buf) ? buf : Buffer.from(buf))
    .toString('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
}

function signAccessToken(deviceId) {
  const header = base64url(JSON.stringify({ alg: 'EdDSA', typ: 'JWT' }));
  const now = Math.floor(Date.now() / 1000);
  const payload = base64url(JSON.stringify({
    sub: deviceId,
    type: 'access',
    jti: crypto.randomUUID(),
    iat: now,
    exp: now + 15 * 60,
  }));
  const data = `${header}.${payload}`;
  const sig = crypto.sign(null, Buffer.from(data), privateKey);
  return `${data}.${base64url(sig)}`;
}

function verifyAccessToken(token) {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) return null;
    const [header, payload, sig] = parts;
    const data = `${header}.${payload}`;
    const valid = crypto.verify(
      null,
      Buffer.from(data),
      publicKey,
      Buffer.from(sig, 'base64')
    );
    if (!valid) return null;
    const decoded = JSON.parse(Buffer.from(payload, 'base64').toString('utf8'));
    if (decoded.exp && decoded.exp < Math.floor(Date.now() / 1000)) return null;
    return decoded;
  } catch {
    return null;
  }
}

function isRegistrationCodeValid(code) {
  const row = getRegistrationCode(code);
  if (!row) return false;
  if (row.max_uses < 0) return true;
  return (row.uses || 0) < row.max_uses;
}

function createActivationChallenge(deviceId, publicKeyPem, registrationCode) {
  const nonce = generateNonce();
  const activationToken = generateActivationToken();
  const exp = expiresAtMs(NONCE_TTL_MS);
  saveActivationNonce(nonce, deviceId, activationToken, publicKeyPem, registrationCode, exp);
  return { activationToken, challenge: nonce };
}

function verifyActivation(deviceId, activationToken, signedChallenge) {
  const nonceRow = getActivationNonce(activationToken);
  if (!nonceRow) return { error: 'invalid_token' };
  if (nonceRow.device_id !== deviceId) return { error: 'device_mismatch' };
  if (nonceRow.used) return { error: 'token_used' };
  if (new Date(nonceRow.expires_at) < new Date()) return { error: 'token_expired' };

  const publicKeyPem = nonceRow.public_key_pem;
  if (!publicKeyPem) return { error: 'no_public_key' };

  let valid;
  try {
    valid = crypto.verify(
      null,
      Buffer.from(nonceRow.nonce, 'utf8'),
      { key: publicKeyPem, format: 'pem', type: 'spki' },
      Buffer.from(signedChallenge, 'base64')
    );
  } catch (err) {
    console.error('[auth] verifyActivation crypto.verify error:', err.message);
    return { error: 'invalid_signature' };
  }
  if (!valid) return { error: 'invalid_signature' };

  markActivationNonceUsed(nonceRow.nonce);
  if (nonceRow.registration_code) {
    incrementRegistrationCodeUses(nonceRow.registration_code, deviceId);
  }
  upsertDevice(deviceId, publicKeyPem, '');

  const accessToken = signAccessToken(deviceId);
  const refreshTokenPlain = generateRefreshToken();
  const refreshTokenHash = hashToken(refreshTokenPlain);
  saveRefreshToken(refreshTokenHash, deviceId, expiresAtMs(REFRESH_TOKEN_TTL_MS));

  return { accessToken, refreshToken: refreshTokenPlain };
}

function createLoginChallenge(deviceId) {
  const device = getDevice(deviceId);
  if (!device || device.status !== 'active') return null;

  const nonce = generateNonce();
  const exp = expiresAtMs(NONCE_TTL_MS);
  saveLoginNonce(nonce, deviceId, exp);

  return { nonce, expiresAt: exp };
}

function verifyLogin(deviceId, nonce, signature) {
  const nonceRow = getLoginNonce(nonce);
  if (!nonceRow) return { error: 'invalid_nonce' };
  if (nonceRow.device_id !== deviceId) return { error: 'device_mismatch' };
  if (nonceRow.used) return { error: 'nonce_used' };
  if (new Date(nonceRow.expires_at) < new Date()) return { error: 'nonce_expired' };

  const device = getDevice(deviceId);
  if (!device || !device.public_key_pem) return { error: 'device_not_found' };

  let valid;
  try {
    valid = crypto.verify(
      null,
      Buffer.from(nonce, 'utf8'),
      { key: device.public_key_pem, format: 'pem', type: 'spki' },
      Buffer.from(signature, 'base64')
    );
  } catch (err) {
    console.error('[auth] verifyLogin crypto.verify error:', err.message);
    return { error: 'invalid_signature' };
  }
  if (!valid) return { error: 'invalid_signature' };

  markLoginNonceUsed(nonce);
  updateLastSeen(deviceId);

  const accessToken = signAccessToken(deviceId);
  const refreshTokenPlain = generateRefreshToken();
  const refreshTokenHash = hashToken(refreshTokenPlain);
  saveRefreshToken(refreshTokenHash, deviceId, expiresAtMs(REFRESH_TOKEN_TTL_MS));

  return { accessToken, refreshToken: refreshTokenPlain };
}

function refreshAccessToken(refreshToken) {
  const tokenHash = hashToken(refreshToken);
  const row = getRefreshToken(tokenHash);
  if (!row) return { error: 'invalid_token' };
  if (new Date(row.expires_at) < new Date()) return { error: 'token_expired' };

  const accessToken = signAccessToken(row.device_id);
  return { accessToken };
}

function reregisterDevice(deviceId, publicKeyPem, registrationCode, deviceName, mode) {
  const row = getRegistrationCode(registrationCode);
  if (!row) return { error: 'invalid_registration_code' };
  if (row.max_uses >= 0 && (row.uses || 0) >= row.max_uses) return { error: 'invalid_registration_code' };

  if (mode === 'reset') {
    incrementRegistrationCodeUses(registrationCode, deviceId);
    upsertDevice(deviceId, publicKeyPem, deviceName || '');
    deleteRefreshTokensForDevice(deviceId);

    const accessToken = signAccessToken(deviceId);
    const refreshTokenPlain = generateRefreshToken();
    const refreshTokenHash = hashToken(refreshTokenPlain);
    saveRefreshToken(refreshTokenHash, deviceId, expiresAtMs(REFRESH_TOKEN_TTL_MS));

    return { status: 'completed', accessToken, refreshToken: refreshTokenPlain };
  }

  if (mode === 'compromise') {
    return { status: 'pending_approval' };
  }

  return { error: 'invalid_mode' };
}

function logoutDevice(refreshToken) {
  const tokenHash = hashToken(refreshToken);
  deleteRefreshToken(tokenHash);
}

function cleanupExpiredNonces() {
  dbCleanupExpiredNonces();
}

export {
  hashToken,
  generateNonce,
  generateActivationToken,
  generateRefreshToken,
  signAccessToken,
  verifyAccessToken,
  isRegistrationCodeValid,
  createActivationChallenge,
  verifyActivation,
  createLoginChallenge,
  verifyLogin,
  refreshAccessToken,
  reregisterDevice,
  logoutDevice,
  cleanupExpiredNonces,
};
