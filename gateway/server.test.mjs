import assert from 'node:assert/strict';
import { describe, it, after } from 'node:test';
import { mkdtempSync, writeFileSync, rmSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { deviceWorkspace } from './file-service.mjs';

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
const { getDb, saveDeviceSession } = await import('./db.mjs');

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
      // 强制关闭 keep-alive 连接，避免 server.close 等待闲置 socket 超时。
      if (typeof server.closeAllConnections === 'function') {
        server.closeAllConnections();
      }
    });
  }
}

function sign(buffer, privateKey) {
  return crypto.sign(null, buffer, privateKey).toString('base64');
}

async function registerDevice(baseUrl, { deviceId }) {
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
      deviceName: 'HarmonyOS Phone'
    })
  });

  return { response, publicKeyPem };
}

async function activateDevice(baseUrl, { deviceId }) {
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
      deviceName: 'HarmonyOS Phone'
    })
  });
  assert.equal(registerResponse.status, 200);
  const { activationToken, challenge, registrationCode } = await registerResponse.json();

  const signedChallenge = sign(Buffer.from(challenge, 'utf8'), privateKey);

  const activateResponse = await fetch(`${baseUrl}/api/auth/activate`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ deviceId, activationToken, signedChallenge })
  });

  assert.equal(activateResponse.status, 200);
  const body = await activateResponse.json();
  return {
    deviceId,
    privateKey,
    accessToken: body.accessToken,
    refreshToken: body.refreshToken,
    registrationCode: body.registrationCode ?? registrationCode
  };
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

  it('auto-assigns a distinct immutable registration code per device', async () => {
    await withServer(async (baseUrl) => {
      // 开放注册：不传注册码，服务器自动分配。
      const deviceA = await activateDevice(baseUrl, { deviceId: 'dev-auto-a' });
      const deviceB = await activateDevice(baseUrl, { deviceId: 'dev-auto-b' });

      assert.match(deviceA.registrationCode, /^air-[0-9a-f]{16}$/);
      assert.match(deviceB.registrationCode, /^air-[0-9a-f]{16}$/);
      assert.notEqual(deviceA.registrationCode, deviceB.registrationCode);

      // /me 返回同一个码（不可更改）。
      const meResponse = await fetch(`${baseUrl}/api/auth/me`, {
        headers: { authorization: `Bearer ${deviceA.accessToken}` }
      });
      assert.equal(meResponse.status, 200);
      const me = await meResponse.json();
      assert.equal(me.registrationCode, deviceA.registrationCode);

      // 同一设备再次注册（模拟重装）仍拿到原来的码。
      const { response } = await registerDevice(baseUrl, { deviceId: 'dev-auto-a' });
      const again = await response.json();
      assert.equal(again.registrationCode, deviceA.registrationCode);
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
    const filesRoot = mkdtempSync(path.join(tmpdir(), 'airouter-resumes-test-'));
    const originalRoot = process.env.FILES_ROOT;
    process.env.FILES_ROOT = filesRoot;
    const opencodeClient = {
      async startResume({ cwd }) {
        // cwd 被强制为该设备的专属工作区（目录名是 deviceId 的哈希）。
        assert.equal(cwd, deviceWorkspace(filesRoot, 'dev-resumes'));
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

    try {
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
    } finally {
      if (originalRoot === undefined) {
        delete process.env.FILES_ROOT;
      } else {
        process.env.FILES_ROOT = originalRoot;
      }
      rmSync(filesRoot, { recursive: true, force: true });
    }
  });

  it('keeps session ownership across a gateway restart', async () => {
    const filesRoot = mkdtempSync(path.join(tmpdir(), 'airouter-owner-persist-'));
    const originalRoot = process.env.FILES_ROOT;
    process.env.FILES_ROOT = filesRoot;
    const opencodeClient = {
      async startResume({ cwd }) {
        return { threadId: 'ses_persist', title: 'persist', cwd, status: 'idle' };
      },
      async listResumes() {
        return [
          { id: 'ses_persist', title: 'mine', subtitle: '', status: 'idle', updatedAt: '2026-07-06T12:00:00.000Z' },
          { id: 'ses_someone', title: 'other', subtitle: '', status: 'idle', updatedAt: '2026-07-06T12:00:00.000Z' }
        ];
      }
    };

    let device;
    try {
      // 第一个 gateway 实例：设备创建会话。
      await withServer(async (baseUrl) => {
        device = await activateDevice(baseUrl, { deviceId: 'dev-owner-persist' });
        const created = await fetch(`${baseUrl}/api/opencode/resumes`, {
          method: 'POST',
          headers: { authorization: `Bearer ${device.accessToken}`, 'content-type': 'application/json' },
          body: JSON.stringify({ cwd: '~' })
        });
        assert.equal(created.status, 200);
      }, { opencodeClient });

      // 模拟 gateway 重启（新实例、同一数据库）：归属依旧，只列本设备会话。
      await withServer(async (baseUrl) => {
        const response = await fetch(`${baseUrl}/api/opencode/resumes`, {
          headers: { authorization: `Bearer ${device.accessToken}` }
        });
        assert.equal(response.status, 200);
        const body = await response.json();
        assert.deepEqual(body.items.map((item) => item.id), ['ses_persist']);
      }, { opencodeClient });
    } finally {
      if (originalRoot === undefined) {
        delete process.env.FILES_ROOT;
      } else {
        process.env.FILES_ROOT = originalRoot;
      }
      rmSync(filesRoot, { recursive: true, force: true });
    }
  });

  it('blocks a device from accessing another device session', async () => {
    const filesRoot = mkdtempSync(path.join(tmpdir(), 'airouter-owner-guard-'));
    const originalRoot = process.env.FILES_ROOT;
    process.env.FILES_ROOT = filesRoot;
    const opencodeClient = {
      async startResume({ cwd }) {
        return { threadId: 'ses_guarded', title: 'guarded', cwd, status: 'idle' };
      },
      async readResume({ threadId }) {
        return { threadId, title: 'guarded', cwd: '', status: 'idle', turns: [] };
      },
      async deleteResume() {},
      async sendResumeMessage({ threadId }) {
        return { threadId, title: 'guarded', cwd: '', status: 'idle', turns: [] };
      }
    };

    try {
      await withServer(async (baseUrl) => {
        const owner = await activateDevice(baseUrl, { deviceId: 'dev-guard-owner' });
        const intruder = await activateDevice(baseUrl, { deviceId: 'dev-guard-intruder' });

        const created = await fetch(`${baseUrl}/api/opencode/resumes`, {
          method: 'POST',
          headers: { authorization: `Bearer ${owner.accessToken}`, 'content-type': 'application/json' },
          body: JSON.stringify({ cwd: '~' })
        });
        assert.equal(created.status, 200);

        const ownerAuth = { authorization: `Bearer ${owner.accessToken}` };
        const intruderAuth = { authorization: `Bearer ${intruder.accessToken}` };

        // 归属者可以打开；非归属者一律 404（不泄漏会话存在）。
        assert.equal((await fetch(`${baseUrl}/api/opencode/resumes/ses_guarded/resume`, {
          method: 'POST', headers: ownerAuth
        })).status, 200);
        assert.equal((await fetch(`${baseUrl}/api/opencode/resumes/ses_guarded/resume`, {
          method: 'POST', headers: intruderAuth
        })).status, 404);

        assert.equal((await fetch(`${baseUrl}/api/opencode/resumes/ses_guarded`, {
          method: 'DELETE', headers: intruderAuth
        })).status, 404);

        assert.equal((await fetch(`${baseUrl}/api/opencode/resumes/ses_guarded/messages`, {
          method: 'POST',
          headers: { ...intruderAuth, 'content-type': 'application/json' },
          body: JSON.stringify({ message: 'hi' })
        })).status, 404);
      }, { opencodeClient });
    } finally {
      if (originalRoot === undefined) {
        delete process.env.FILES_ROOT;
      } else {
        process.env.FILES_ROOT = originalRoot;
      }
      rmSync(filesRoot, { recursive: true, force: true });
    }
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
      // 该会话归属本设备（正常流程由创建会话时写入）。
      saveDeviceSession('ses_router', 'dev-message');
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

describe('files', () => {
  it('lists and downloads files from the device-exclusive workspace', async () => {
    const filesRoot = mkdtempSync(path.join(tmpdir(), 'airouter-files-test-'));
    const originalRoot = process.env.FILES_ROOT;
    process.env.FILES_ROOT = filesRoot;
    try {
      await withServer(async (baseUrl) => {
        const device = await activateDevice(baseUrl, { deviceId: 'dev-files-list' });
        // 文件落在设备专属工作区（<FILES_ROOT>/workspaces/<deviceId>），列表/下载只该目录。
        const devWorkspace = deviceWorkspace(filesRoot, 'dev-files-list');
        mkdirSync(devWorkspace, { recursive: true });
        writeFileSync(path.join(devWorkspace, 'report.pptx'), Buffer.from('fake-pptx-bytes'));
        writeFileSync(path.join(devWorkspace, 'notes.txt'), 'hello');
        writeFileSync(path.join(filesRoot, 'secret.sh'), '#!/bin/sh');
        writeFileSync(path.join(filesRoot, '.hidden.txt'), 'secret');

        const listResponse = await fetch(`${baseUrl}/api/files`, {
          headers: { authorization: `Bearer ${device.accessToken}` }
        });
        assert.equal(listResponse.status, 200);
        const { items } = await listResponse.json();
        const names = items.map((item) => item.name).sort();
        // 设备目录外的全局文件不可见 → 只列本设备工作区产物，越权文件天然不可达。
        assert.deepEqual(names, ['notes.txt', 'report.pptx']);

        const downloadResponse = await fetch(`${baseUrl}/api/files/report.pptx/download`, {
          headers: { authorization: `Bearer ${device.accessToken}` }
        });
        assert.equal(downloadResponse.status, 200);
        const blob = await downloadResponse.blob();
        assert.equal(blob.size, 15);
        const text = await blob.text();
        assert.equal(text, 'fake-pptx-bytes');

        const contentDisposition = downloadResponse.headers.get('content-disposition');
        assert.match(contentDisposition, /report\.pptx/);
      });
    } finally {
      if (originalRoot === undefined) {
        delete process.env.FILES_ROOT;
      } else {
        process.env.FILES_ROOT = originalRoot;
      }
      rmSync(filesRoot, { recursive: true, force: true });
    }
  });

  it('requires auth and rejects path traversal / disallowed files', async () => {
    const filesRoot = mkdtempSync(path.join(tmpdir(), 'airouter-files-test2-'));
    const originalRoot = process.env.FILES_ROOT;
    process.env.FILES_ROOT = filesRoot;
    try {
      await withServer(async (baseUrl) => {
        const device = await activateDevice(baseUrl, { deviceId: 'dev-files-auth' });

        const noAuth = await fetch(`${baseUrl}/api/files`);
        assert.equal(noAuth.status, 401);

        const traversal = await fetch(`${baseUrl}/api/files/..%2F..%2Fetc%2Fpasswd/download`, {
          headers: { authorization: `Bearer ${device.accessToken}` }
        });
        assert.equal(traversal.status, 400);

        const disallowed = await fetch(`${baseUrl}/api/files/whatever.exe/download`, {
          headers: { authorization: `Bearer ${device.accessToken}` }
        });
        assert.equal(disallowed.status, 400);

        const missing = await fetch(`${baseUrl}/api/files/nope.txt/download`, {
          headers: { authorization: `Bearer ${device.accessToken}` }
        });
        assert.equal(missing.status, 404);
      });
    } finally {
      if (originalRoot === undefined) {
        delete process.env.FILES_ROOT;
      } else {
        process.env.FILES_ROOT = originalRoot;
      }
      rmSync(filesRoot, { recursive: true, force: true });
    }
  });

  it('isolates files per device-exclusive workspace', async () => {
    const filesRoot = mkdtempSync(path.join(tmpdir(), 'airouter-files-test3-'));
    const originalRoot = process.env.FILES_ROOT;
    process.env.FILES_ROOT = filesRoot;
    try {
      await withServer(async (baseUrl) => {
        const deviceA = await activateDevice(baseUrl, { deviceId: 'dev-files-a' });
        const deviceB = await activateDevice(baseUrl, { deviceId: 'dev-files-b' });
        const authA = { authorization: `Bearer ${deviceA.accessToken}` };
        const authB = { authorization: `Bearer ${deviceB.accessToken}` };

        // 各设备产物分别落在自己的专属工作区。
        const wsA = deviceWorkspace(filesRoot, 'dev-files-a');
        const wsB = deviceWorkspace(filesRoot, 'dev-files-b');
        mkdirSync(wsA, { recursive: true });
        mkdirSync(wsB, { recursive: true });
        writeFileSync(path.join(wsA, 'report.pptx'), Buffer.from('a-report'));
        writeFileSync(path.join(wsB, 'notes.txt'), 'b-notes');

        // 各自只看到自己工作区内的文件。
        const listA = await (await fetch(`${baseUrl}/api/files`, { headers: authA })).json();
        const listB = await (await fetch(`${baseUrl}/api/files`, { headers: authB })).json();
        assert.deepEqual(listA.items.map((i) => i.name).sort(), ['report.pptx']);
        assert.deepEqual(listB.items.map((i) => i.name).sort(), ['notes.txt']);

        // A 能下载自己的文件。
        const downloadA = await fetch(`${baseUrl}/api/files/report.pptx/download`, { headers: authA });
        assert.equal(downloadA.status, 200);
        assert.equal(await downloadA.text(), 'a-report');

        // B 的工作区里没有该文件，无法越权下载。
        const downloadByB = await fetch(`${baseUrl}/api/files/report.pptx/download`, { headers: authB });
        assert.equal(downloadByB.status, 404);
      });
    } finally {
      if (originalRoot === undefined) {
        delete process.env.FILES_ROOT;
      } else {
        process.env.FILES_ROOT = originalRoot;
      }
      rmSync(filesRoot, { recursive: true, force: true });
    }
  });

  it('shares one workspace across re-registrations of the same device', async () => {
    const filesRoot = mkdtempSync(path.join(tmpdir(), 'airouter-files-test4-'));
    const originalRoot = process.env.FILES_ROOT;
    process.env.FILES_ROOT = filesRoot;
    try {
      await withServer(async (baseUrl) => {
        // 同一设备先后两次注册（模拟重装）→ 仍是同一 deviceId、同一注册码、同一工作区。
        const first = await activateDevice(baseUrl, { deviceId: 'dev-multi-code' });
        const ws = deviceWorkspace(filesRoot, 'dev-multi-code');
        mkdirSync(ws, { recursive: true });
        writeFileSync(path.join(ws, 'shared.md'), 'shared-bytes');

        const second = await activateDevice(baseUrl, { deviceId: 'dev-multi-code' });
        assert.equal(second.registrationCode, first.registrationCode);

        const headers = { authorization: `Bearer ${second.accessToken}` };
        const list = await (await fetch(`${baseUrl}/api/files`, { headers })).json();
        assert.deepEqual(list.items.map((i) => i.name), ['shared.md']);

        const download = await fetch(`${baseUrl}/api/files/shared.md/download`, { headers });
        assert.equal(download.status, 200);
        assert.equal(await download.text(), 'shared-bytes');

        // 旧的 token 也仍指向同一设备，同样能访问。
        const oldDownload = await fetch(`${baseUrl}/api/files/shared.md/download`, {
          headers: { authorization: `Bearer ${first.accessToken}` }
        });
        assert.equal(oldDownload.status, 200);
      });
    } finally {
      if (originalRoot === undefined) {
        delete process.env.FILES_ROOT;
      } else {
        process.env.FILES_ROOT = originalRoot;
      }
      rmSync(filesRoot, { recursive: true, force: true });
    }
  });

  it('returns 500 when files root is not configured', async () => {
    const originalRoot = process.env.FILES_ROOT;
    const originalWorkdir = process.env.OPENCODE_WORKDIR;
    delete process.env.FILES_ROOT;
    delete process.env.OPENCODE_WORKDIR;
    try {
      await withServer(async (baseUrl) => {
        const device = await activateDevice(baseUrl, { deviceId: 'dev-files-noroot' });
        const response = await fetch(`${baseUrl}/api/files`, {
          headers: { authorization: `Bearer ${device.accessToken}` }
        });
        assert.equal(response.status, 500);
        const body = await response.json();
        assert.equal(body.error.code, 'files_root_unset');
      });
    } finally {
      if (originalRoot !== undefined) process.env.FILES_ROOT = originalRoot;
      if (originalWorkdir !== undefined) process.env.OPENCODE_WORKDIR = originalWorkdir;
    }
  });

  it('maps device ids to collision-free workspaces', () => {
    const root = '/srv/files';
    // 确定性：同一 deviceId 始终同一目录。
    assert.equal(deviceWorkspace(root, 'device-x'), deviceWorkspace(root, 'device-x'));
    // 旧的字符替换方案会让 `a.b`/`a_b`、`a/b`/`a_b` 撞到同一目录，现用哈希区分。
    assert.notEqual(deviceWorkspace(root, 'a.b'), deviceWorkspace(root, 'a_b'));
    assert.notEqual(deviceWorkspace(root, 'a/b'), deviceWorkspace(root, 'a_b'));
    assert.notEqual(deviceWorkspace(root, 'a b'), deviceWorkspace(root, 'a_b'));
    // 非法输入返回 null。
    assert.equal(deviceWorkspace('', 'device-x'), null);
    assert.equal(deviceWorkspace(root, ''), null);
  });
});
