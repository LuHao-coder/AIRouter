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
const { getDb } = await import('./db.mjs');

let registrationCodeSeq = 0;
/** 随机生成一次性注册码并入库；激活时会绑定到使用它的设备（一码一设备）。 */
function issueRegistrationCode(maxUses = 1) {
  registrationCodeSeq += 1;
  const code = `test-${registrationCodeSeq}-${crypto.randomBytes(4).toString('hex')}`;
  getDb()
    .prepare('INSERT INTO registration_codes (code, max_uses) VALUES (?, ?)')
    .run(code, maxUses);
  return code;
}

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

async function registerDevice(baseUrl, { deviceId, registrationCode = issueRegistrationCode() }) {
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

async function activateDevice(baseUrl, { deviceId, registrationCode = issueRegistrationCode() }) {
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

  it('binds a registration code to the first device and rejects other devices', async () => {
    await withServer(async (baseUrl) => {
      const code = issueRegistrationCode();
      await activateDevice(baseUrl, { deviceId: 'dev-code-owner', registrationCode: code });

      const { response } = await registerDevice(baseUrl, {
        deviceId: 'dev-code-thief',
        registrationCode: code
      });

      assert.equal(response.status, 401);
      const body = await response.json();
      assert.equal(body.error.code, 'invalid_code');
    });
  });

  it('rejects reusing a one-time registration code for the same device', async () => {
    await withServer(async (baseUrl) => {
      const code = issueRegistrationCode();
      await activateDevice(baseUrl, { deviceId: 'dev-code-reuse', registrationCode: code });

      const { response } = await registerDevice(baseUrl, {
        deviceId: 'dev-code-reuse',
        registrationCode: code
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
    const filesRoot = mkdtempSync(path.join(tmpdir(), 'airouter-resumes-test-'));
    const originalRoot = process.env.FILES_ROOT;
    process.env.FILES_ROOT = filesRoot;
    const opencodeClient = {
      async startResume({ cwd }) {
        // cwd 现在强制为设备专属工作区目录（由服务器注入），任何该设备目录皆可。
        assert.match(cwd, /workspaces[/\\]dev-resumes$/);
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

  it('shares one workspace when a device registers with multiple codes', async () => {
    const filesRoot = mkdtempSync(path.join(tmpdir(), 'airouter-files-test4-'));
    const originalRoot = process.env.FILES_ROOT;
    process.env.FILES_ROOT = filesRoot;
    try {
      await withServer(async (baseUrl) => {
        // 同一设备先后用两个不同注册码激活 → 仍归属同一 deviceId，共享同一工作区。
        const first = await activateDevice(baseUrl, {
          deviceId: 'dev-multi-code',
          registrationCode: issueRegistrationCode()
        });
        const ws = deviceWorkspace(filesRoot, 'dev-multi-code');
        mkdirSync(ws, { recursive: true });
        writeFileSync(path.join(ws, 'shared.md'), 'shared-bytes');

        const second = await activateDevice(baseUrl, {
          deviceId: 'dev-multi-code',
          registrationCode: issueRegistrationCode()
        });

        const headers = { authorization: `Bearer ${second.accessToken}` };
        const list = await (await fetch(`${baseUrl}/api/files`, { headers })).json();
        assert.deepEqual(list.items.map((i) => i.name), ['shared.md']);

        const download = await fetch(`${baseUrl}/api/files/shared.md/download`, { headers });
        assert.equal(download.status, 200);
        assert.equal(await download.text(), 'shared-bytes');

        // 旧注册码换来的 token 也仍指向同一设备，同样能访问。
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
});
