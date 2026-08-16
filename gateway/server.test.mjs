import assert from 'node:assert/strict';
import { describe, it, after } from 'node:test';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

const tmp = mkdtempSync(path.join(tmpdir(), 'airouter-gateway-test-'));

const { privateKey: serverPrivateKey, publicKey: serverPublicKey } =
  crypto.generateKeyPairSync('ed25519');
writeFileSync(
  path.join(tmp, 'jwt-signing.pem'),
  serverPrivateKey.export({ type: 'pkcs8', format: 'pem' })
);
writeFileSync(
  path.join(tmp, 'jwt-signing.pub'),
  serverPublicKey.export({ type: 'spki', format: 'pem' })
);

process.env.AI_ROUTER_SIGNING_KEY_PATH = path.join(tmp, 'jwt-signing.pem');
process.env.AI_ROUTER_SIGNING_PUB_PATH = path.join(tmp, 'jwt-signing.pub');
process.env.AI_ROUTER_DB_PATH = path.join(tmp, 'test.db');

const { createGatewayServer } = await import('./server.mjs');
const { getDb } = await import('./db.mjs');

const REGISTRATION_CODE = 'test-registration-code';
getDb()
  .prepare('INSERT INTO registration_codes (code, max_uses) VALUES (?, -1)')
  .run(REGISTRATION_CODE);

after(() => {
  try {
    getDb().close();
  } catch {
    // db may already be closed
  }
  rmSync(tmp, { recursive: true, force: true });
});

let ipCounter = 0;
function uniqueIp() {
  ipCounter += 1;
  return `198.51.100.${ipCounter}`;
}

async function withServer(testBody, options = {}) {
  const server = createGatewayServer(options);
  await new Promise((resolve) => {
    server.listen(0, '127.0.0.1', resolve);
  });

  const baseUrl = `http://127.0.0.1:${server.address().port}`;

  try {
    await testBody(baseUrl);
  } finally {
    await new Promise((resolve, reject) => {
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve();
      });
    });
  }
}

function sign(buffer, privateKey) {
  return crypto.sign(null, buffer, privateKey).toString('base64');
}

async function registerDevice(baseUrl, { deviceId, registrationCode = REGISTRATION_CODE }) {
  const { publicKey } = crypto.generateKeyPairSync('ed25519');
  const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' });

  const response = await fetch(`${baseUrl}/api/auth/register`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-forwarded-for': uniqueIp()
    },
    body: JSON.stringify({
      deviceId,
      publicKey: publicKeyPem,
      registrationCode,
      deviceName: 'HarmonyOS Phone'
    })
  });

  return { response, publicKeyPem };
}

async function activateDevice(baseUrl, { deviceId, registrationCode = REGISTRATION_CODE }) {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' });

  const registerResponse = await fetch(`${baseUrl}/api/auth/register`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-forwarded-for': uniqueIp()
    },
    body: JSON.stringify({
      deviceId,
      publicKey: publicKeyPem,
      registrationCode,
      deviceName: 'HarmonyOS Phone'
    })
  });
  assert.equal(registerResponse.status, 200);
  const { activationToken, challenge } = await registerResponse.json();

  const signedChallenge = sign(Buffer.from(challenge, 'utf8'), privateKey);

  const activateResponse = await fetch(`${baseUrl}/api/auth/activate`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ deviceId, activationToken, signedChallenge })
  });

  assert.equal(activateResponse.status, 200);
  const body = await activateResponse.json();
  return { deviceId, privateKey, accessToken: body.accessToken, refreshToken: body.refreshToken };
}

async function loginDevice(baseUrl, { deviceId, privateKey }) {
  const challengeResponse = await fetch(`${baseUrl}/api/auth/challenge`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-forwarded-for': uniqueIp()
    },
    body: JSON.stringify({ deviceId })
  });

  assert.equal(challengeResponse.status, 200);
  const { nonce } = await challengeResponse.json();

  const signature = sign(Buffer.from(nonce, 'utf8'), privateKey);

  const verifyResponse = await fetch(`${baseUrl}/api/auth/verify`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ deviceId, nonce, signature })
  });

  assert.equal(verifyResponse.status, 200);
  const body = await verifyResponse.json();
  return { accessToken: body.accessToken, refreshToken: body.refreshToken };
}

describe('gateway', () => {
  it('creates an https listener when tls key and cert are provided', () => {
    const server = createGatewayServer({
      tlsKey: 'test-key',
      tlsCert: 'test-cert',
      createSecureServer: (tlsOptions, handler) => {
        assert.deepEqual(tlsOptions, {
          key: 'test-key',
          cert: 'test-cert'
        });
        assert.equal(typeof handler, 'function');
        return { protocol: 'https' };
      }
    });

    assert.deepEqual(server, { protocol: 'https' });
  });

  it('reports health on /health', async () => {
    await withServer(async (baseUrl) => {
      const response = await fetch(`${baseUrl}/health`);
      assert.equal(response.status, 200);
      const body = await response.json();
      assert.equal(body.status, 'ok');
      assert.equal(body.sessionName, 'opencode-main');
    });
  });

  it('rejects register when fields are missing', async () => {
    await withServer(async (baseUrl) => {
      const response = await fetch(`${baseUrl}/api/auth/register`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-forwarded-for': uniqueIp()
        },
        body: JSON.stringify({ deviceId: 'dev-1' })
      });

      assert.equal(response.status, 400);
      const body = await response.json();
      assert.equal(body.error.code, 'invalid_request');
    });
  });

  it('rejects register with an invalid registration code', async () => {
    await withServer(async (baseUrl) => {
      const { response } = await registerDevice(baseUrl, {
        deviceId: 'dev-invalid-code',
        registrationCode: 'not-a-real-code'
      });

      assert.equal(response.status, 401);
      const body = await response.json();
      assert.equal(body.error.code, 'invalid_code');
    });
  });

  it('registers and activates a device, then refreshes tokens', async () => {
    await withServer(async (baseUrl) => {
      const device = await activateDevice(baseUrl, { deviceId: 'dev-activate' });

      assert.match(device.accessToken, /^[^.]+\.[^.]+\.[^.]+$/);
      assert.match(device.refreshToken, /^rt-/);

      const meResponse = await fetch(`${baseUrl}/api/auth/me`, {
        headers: { authorization: `Bearer ${device.accessToken}` }
      });
      assert.equal(meResponse.status, 200);
      const me = await meResponse.json();
      assert.equal(me.deviceId, 'dev-activate');

      const refreshResponse = await fetch(`${baseUrl}/api/auth/refresh`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ refreshToken: device.refreshToken })
      });
      assert.equal(refreshResponse.status, 200);
      const refreshed = await refreshResponse.json();
      assert.match(refreshed.accessToken, /^[^.]+\.[^.]+\.[^.]+$/);
    });
  });

  it('rejects activation with a bad signature', async () => {
    await withServer(async (baseUrl) => {
      const { response } = await registerDevice(baseUrl, { deviceId: 'dev-bad-sig' });
      const { activationToken, challenge } = await response.json();

      const wrongKey = crypto.generateKeyPairSync('ed25519').privateKey;
      const signedChallenge = sign(Buffer.from(challenge, 'utf8'), wrongKey);

      const activateResponse = await fetch(`${baseUrl}/api/auth/activate`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          deviceId: 'dev-bad-sig',
          activationToken,
          signedChallenge
        })
      });

      assert.equal(activateResponse.status, 403);
      const body = await activateResponse.json();
      assert.equal(body.error.code, 'invalid_signature');
    });
  });

  it('logs in an already-registered device via challenge + verify', async () => {
    await withServer(async (baseUrl) => {
      const device = await activateDevice(baseUrl, { deviceId: 'dev-login' });
      const login = await loginDevice(baseUrl, {
        deviceId: 'dev-login',
        privateKey: device.privateKey
      });

      assert.match(login.accessToken, /^[^.]+\.[^.]+\.[^.]+$/);
      assert.match(login.refreshToken, /^rt-/);
    });
  });

  it('rejects login for an unknown device', async () => {
    await withServer(async (baseUrl) => {
      const response = await fetch(`${baseUrl}/api/auth/challenge`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-forwarded-for': uniqueIp()
        },
        body: JSON.stringify({ deviceId: 'dev-unknown' })
      });

      assert.equal(response.status, 401);
      const body = await response.json();
      assert.equal(body.error.code, 'device_not_found');
    });
  });

  it('requires an access token for authenticated routes', async () => {
    await withServer(async (baseUrl) => {
      const response = await fetch(`${baseUrl}/api/projects`);
      assert.equal(response.status, 401);
      const body = await response.json();
      assert.equal(body.error.code, 'token_missing');
    });
  });

  it('returns the allowlisted project', async () => {
    await withServer(async (baseUrl) => {
      const device = await activateDevice(baseUrl, { deviceId: 'dev-project' });
      const response = await fetch(`${baseUrl}/api/projects`, {
        headers: { authorization: `Bearer ${device.accessToken}` }
      });

      assert.equal(response.status, 200);
      const body = await response.json();
      assert.equal(body.items.length, 1);
      assert.equal(body.items[0].id, 'codex-router');
    });
  });

  it('returns ICE config for the configured coturn', async () => {
    await withServer(async (baseUrl) => {
      const device = await activateDevice(baseUrl, { deviceId: 'dev-ice' });
      const response = await fetch(`${baseUrl}/api/turn/ice-config`, {
        headers: { authorization: `Bearer ${device.accessToken}` }
      });

      assert.equal(response.status, 200);
      const body = await response.json();
      assert.deepEqual(body.iceServers[0], { urls: 'stun:127.0.0.1:3478' });
    });
  });

  it('lists only sessions created by the device', async () => {
    const opencodeClient = {
      async startResume({ cwd }) {
        assert.equal(cwd, '~');
        return { threadId: 'ses_router', title: 'Port router to OpenCode', cwd, status: 'idle' };
      },
      async listResumes({ limit }) {
        return [
          {
            id: 'ses_router',
            title: 'Port router to OpenCode',
            subtitle: '/srv/projects/codex-router',
            status: 'idle',
            updatedAt: '2026-07-06T12:00:00.000Z'
          },
          {
            id: 'ses_other_device',
            title: 'Someone else',
            subtitle: '/srv/projects/other',
            status: 'idle',
            updatedAt: '2026-07-06T12:00:00.000Z'
          }
        ];
      }
    };

    await withServer(async (baseUrl) => {
      const device = await activateDevice(baseUrl, { deviceId: 'dev-resumes' });

      const createResponse = await fetch(`${baseUrl}/api/opencode/resumes`, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${device.accessToken}`,
          'content-type': 'application/json'
        },
        body: JSON.stringify({ cwd: '~' })
      });
      assert.equal(createResponse.status, 200);

      const response = await fetch(`${baseUrl}/api/opencode/resumes`, {
        headers: { authorization: `Bearer ${device.accessToken}` }
      });

      assert.equal(response.status, 200);
      const body = await response.json();
      assert.equal(body.items.length, 1);
      assert.equal(body.items[0].id, 'ses_router');
    }, { opencodeClient });
  });

  it('sends a message to an OpenCode resume session', async () => {
    const opencodeClient = {
      async sendResumeMessage({ threadId, message }) {
        assert.equal(threadId, 'ses_router');
        assert.equal(message, '继续');
        return {
          threadId: 'ses_router',
          title: 'Port router to OpenCode',
          cwd: '/srv/projects/codex-router',
          status: 'idle',
          turns: [
            {
              id: 'msg_assistant',
              status: 'completed',
              items: [
                {
                  id: 'msg_assistant:prt_text',
                  role: 'assistant',
                  kind: 'message',
                  text: '已回复。',
                  status: ''
                }
              ]
            }
          ]
        };
      }
    };

    await withServer(async (baseUrl) => {
      const device = await activateDevice(baseUrl, { deviceId: 'dev-message' });
      const response = await fetch(`${baseUrl}/api/opencode/resumes/ses_router/messages`, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${device.accessToken}`,
          'content-type': 'application/json'
        },
        body: JSON.stringify({ message: '继续' })
      });

      assert.equal(response.status, 200);
      const body = await response.json();
      assert.equal(body.threadId, 'ses_router');
      assert.equal(body.turns[0].items[0].text, '已回复。');
    }, { opencodeClient });
  });

  it('creates and reads a gateway task', async () => {
    await withServer(async (baseUrl) => {
      const device = await activateDevice(baseUrl, { deviceId: 'dev-task' });
      const createResponse = await fetch(`${baseUrl}/api/projects/codex-router/tasks`, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${device.accessToken}`,
          'content-type': 'application/json'
        },
        body: JSON.stringify({ message: 'test task' })
      });

      assert.equal(createResponse.status, 200);
      const created = await createResponse.json();
      assert.equal(created.status, 'queued');
      assert.match(created.taskId, /^task_/);

      const readResponse = await fetch(`${baseUrl}/api/tasks/${created.taskId}`, {
        headers: { authorization: `Bearer ${device.accessToken}` }
      });

      assert.equal(readResponse.status, 200);
      const task = await readResponse.json();
      assert.equal(task.id, created.taskId);
      assert.equal(task.projectId, 'codex-router');
      assert.equal(task.message, 'test task');
    });
  });

  it('logs out and invalidates the refresh token', async () => {
    await withServer(async (baseUrl) => {
      const device = await activateDevice(baseUrl, { deviceId: 'dev-logout' });

      const logoutResponse = await fetch(`${baseUrl}/api/auth/logout`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ refreshToken: device.refreshToken })
      });
      assert.equal(logoutResponse.status, 200);

      const refreshResponse = await fetch(`${baseUrl}/api/auth/refresh`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ refreshToken: device.refreshToken })
      });
      assert.equal(refreshResponse.status, 401);
      const body = await refreshResponse.json();
      assert.equal(body.error.code, 'invalid_token');
    });
  });
});
