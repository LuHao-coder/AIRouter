import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { OpenCodeServerClient } from './opencode-server.mjs';
import {
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
} from './auth.mjs';
import {
  registerLimiter,
  activateLimiter,
  challengeLimiter,
  verifyLimiter,
  refreshLimiter,
  reregisterLimiter,
  getClientIp,
} from './rate-limiter.mjs';
import {
  resolveFilesRoot,
  listGeneratedFiles,
  resolveDownloadPath,
  isAllowedFile,
} from './file-service.mjs';

const DEFAULT_HOST = '0.0.0.0';
const DEFAULT_PORT = 8443;

const PROJECT = {
  id: 'codex-router',
  name: 'AI Router',
  defaultBranch: 'master',
  status: 'ready',
  permissions: ['task:create', 'task:read', 'task:write', 'diff:read', 'approval:review']
};

function jsonResponse(response, statusCode, body) {
  response.writeHead(statusCode, {
    'content-type': 'application/json; charset=utf-8',
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET,POST,DELETE,OPTIONS',
    'access-control-allow-headers': 'authorization,content-type'
  });
  response.end(JSON.stringify(body));
}

function errorResponse(response, statusCode, code, message) {
  jsonResponse(response, statusCode, {
    error: { code, message, requestId: `req_${randomUUID()}` }
  });
}

function readJson(request) {
  return new Promise((resolve, reject) => {
    let raw = '';
    request.setEncoding('utf8');
    request.on('data', (chunk) => { raw += chunk; });
    request.on('end', () => {
      if (raw.trim().length === 0) { resolve({}); return; }
      try { resolve(JSON.parse(raw)); } catch (e) { reject(e); }
    });
    request.on('error', reject);
  });
}

function bearerToken(request) {
  const header = request.headers.authorization ?? '';
  if (!header.startsWith('Bearer ')) return '';
  return header.substring('Bearer '.length);
}

const MIME_TYPES = {
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.pdf': 'application/pdf',
  '.md': 'text/markdown; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.zip': 'application/zip'
};

function mimeTypeForFile(target) {
  return MIME_TYPES[path.extname(target).toLowerCase()] ?? 'application/octet-stream';
}

function normalizeResumeCwd(value) {
  const cwd = typeof value === 'string' ? value.trim() : '';
  return cwd.length > 0 ? cwd : '~';
}

function requireAuth(request, response) {
  const token = bearerToken(request);
  if (!token) {
    errorResponse(response, 401, 'token_missing', 'Authorization token required');
    return null;
  }
  const payload = verifyAccessToken(token);
  if (!payload) {
    errorResponse(response, 401, 'token_expired', 'Token is expired or invalid');
    return null;
  }
  return { deviceId: payload.sub };
}

function createGatewayHandler(options = {}) {
  const tasks = new Map();
  const opencodeClient = options.opencodeClient ?? new OpenCodeServerClient();
  const deviceSessions = new Map();

  setInterval(() => {
    cleanupExpiredNonces();
  }, 60 * 1000).unref();

  return async (request, response) => {
    try {
      const url = new URL(request.url ?? '/', 'http://localhost');

      if (request.method === 'OPTIONS') {
        jsonResponse(response, 204, {});
        return;
      }

      // ─── Health ───
      if (request.method === 'GET' && url.pathname === '/health') {
        jsonResponse(response, 200, { status: 'ok', sessionName: 'opencode-main' });
        return;
      }

      // ─── Auth: Register (get activation challenge) ───
      if (request.method === 'POST' && url.pathname === '/api/auth/register') {
        const ip = getClientIp(request);
        if (!registerLimiter.check(ip)) {
          errorResponse(response, 429, 'rate_limited', 'Too many registration attempts');
          return;
        }

        const body = await readJson(request);
        const deviceId = typeof body.deviceId === 'string' ? body.deviceId.trim() : '';
        const publicKey = typeof body.publicKey === 'string' ? body.publicKey.trim() : '';
        const registrationCode = typeof body.registrationCode === 'string' ? body.registrationCode.trim() : '';
        const deviceName = typeof body.deviceName === 'string' ? body.deviceName.trim() : '';

        if (!deviceId || !publicKey || !registrationCode) {
          errorResponse(response, 400, 'invalid_request', 'deviceId, publicKey, and registrationCode are required');
          return;
        }

        if (!isRegistrationCodeValid(registrationCode)) {
          errorResponse(response, 401, 'invalid_code', 'Registration code is invalid or already used');
          return;
        }

        const challenge = createActivationChallenge(deviceId, publicKey, registrationCode);
        jsonResponse(response, 200, challenge);
        return;
      }

      // ─── Auth: Activate (complete registration with signature) ───
      if (request.method === 'POST' && url.pathname === '/api/auth/activate') {
        const body = await readJson(request);
        const deviceId = typeof body.deviceId === 'string' ? body.deviceId.trim() : '';
        const activationToken = typeof body.activationToken === 'string' ? body.activationToken.trim() : '';
        const signedChallenge = typeof body.signedChallenge === 'string' ? body.signedChallenge.trim() : '';

        if (!deviceId || !activationToken || !signedChallenge) {
          errorResponse(response, 400, 'invalid_request', 'deviceId, activationToken, and signedChallenge are required');
          return;
        }

        if (!activateLimiter.check(activationToken)) {
          errorResponse(response, 429, 'rate_limited', 'Too many activation attempts');
          return;
        }

        const result = await verifyActivation(deviceId, activationToken, signedChallenge);
        if (result.error) {
          const statusMap = {
            invalid_token: 400, device_mismatch: 403, token_used: 400,
            token_expired: 400, no_public_key: 500, invalid_signature: 403
          };
          errorResponse(response, statusMap[result.error] ?? 400, result.error, result.error);
          return;
        }

        jsonResponse(response, 200, result);
        return;
      }

      // ─── Auth: Challenge (get login nonce) ───
      if (request.method === 'POST' && url.pathname === '/api/auth/challenge') {
        const body = await readJson(request);
        const deviceId = typeof body.deviceId === 'string' ? body.deviceId.trim() : '';

        if (!deviceId) {
          errorResponse(response, 400, 'invalid_request', 'deviceId is required');
          return;
        }

        if (!challengeLimiter.check(deviceId)) {
          errorResponse(response, 429, 'rate_limited', 'Too many challenge requests');
          return;
        }

        const result = createLoginChallenge(deviceId);
        if (!result) {
          errorResponse(response, 401, 'device_not_found', 'Device not registered or revoked');
          return;
        }

        jsonResponse(response, 200, result);
        return;
      }

      // ─── Auth: Verify (login with signature) ───
      if (request.method === 'POST' && url.pathname === '/api/auth/verify') {
        const body = await readJson(request);
        const deviceId = typeof body.deviceId === 'string' ? body.deviceId.trim() : '';
        const nonce = typeof body.nonce === 'string' ? body.nonce.trim() : '';
        const signature = typeof body.signature === 'string' ? body.signature.trim() : '';

        if (!deviceId || !nonce || !signature) {
          errorResponse(response, 400, 'invalid_request', 'deviceId, nonce, and signature are required');
          return;
        }

        if (!verifyLimiter.check(deviceId)) {
          errorResponse(response, 429, 'rate_limited', 'Too many verification attempts');
          return;
        }

        const result = await verifyLogin(deviceId, nonce, signature);
        if (result.error) {
          const statusMap = {
            invalid_nonce: 400, device_mismatch: 403, nonce_used: 400,
            nonce_expired: 400, device_not_found: 401, invalid_signature: 403
          };
          errorResponse(response, statusMap[result.error] ?? 400, result.error, result.error);
          return;
        }

        jsonResponse(response, 200, result);
        return;
      }

      // ─── Auth: Refresh ───
      if (request.method === 'POST' && url.pathname === '/api/auth/refresh') {
        const body = await readJson(request);
        const refreshToken = typeof body.refreshToken === 'string' ? body.refreshToken.trim() : '';

        if (!refreshToken) {
          errorResponse(response, 400, 'invalid_request', 'refreshToken is required');
          return;
        }

        if (!refreshLimiter.check(refreshToken)) {
          errorResponse(response, 429, 'rate_limited', 'Too many refresh attempts');
          return;
        }

        const result = refreshAccessToken(refreshToken);
        if (result.error) {
          errorResponse(response, 401, result.error, result.error);
          return;
        }

        jsonResponse(response, 200, result);
        return;
      }

      // ─── Auth: Logout ───
      if (request.method === 'POST' && url.pathname === '/api/auth/logout') {
        const body = await readJson(request);
        const refreshToken = typeof body.refreshToken === 'string' ? body.refreshToken.trim() : '';
        if (refreshToken) {
          logoutDevice(refreshToken);
        }
        jsonResponse(response, 200, { ok: true });
        return;
      }

      // ─── Auth: Reregister ───
      if (request.method === 'POST' && url.pathname === '/api/auth/reregister') {
        const ip = getClientIp(request);
        if (!reregisterLimiter.check(ip)) {
          errorResponse(response, 429, 'rate_limited', 'Too many reregistration attempts');
          return;
        }

        const body = await readJson(request);
        const deviceId = typeof body.deviceId === 'string' ? body.deviceId.trim() : '';
        const publicKey = typeof body.publicKey === 'string' ? body.publicKey.trim() : '';
        const registrationCode = typeof body.registrationCode === 'string' ? body.registrationCode.trim() : '';
        const deviceName = typeof body.deviceName === 'string' ? body.deviceName.trim() : '';
        const mode = typeof body.mode === 'string' ? body.mode.trim() : 'reset';

        if (!deviceId || !publicKey || !registrationCode) {
          errorResponse(response, 400, 'invalid_request', 'deviceId, publicKey, and registrationCode are required');
          return;
        }

        const result = await reregisterDevice(deviceId, publicKey, registrationCode, deviceName, mode);
        if (result.error) {
          errorResponse(response, 401, result.error, result.error);
          return;
        }

        jsonResponse(response, 200, result);
        return;
      }

      // ─── Auth: Me ───
      if (request.method === 'GET' && url.pathname === '/api/auth/me') {
        const auth = requireAuth(request, response);
        if (!auth) return;
        jsonResponse(response, 200, { deviceId: auth.deviceId, sessionName: 'opencode-main' });
        return;
      }

      // ─── ICE Config ───
      if (request.method === 'GET' && url.pathname === '/api/turn/ice-config') {
        const auth = requireAuth(request, response);
        if (!auth) return;

        const turnHost = process.env.COTURN_HOST ?? '127.0.0.1';
        const turnPort = process.env.COTURN_PORT ?? '3478';
        const turnUser = process.env.COTURN_USER ?? 'codexrouter';
        const turnPass = process.env.COTURN_PASS ?? '';

        const iceServers = [{ urls: `stun:${turnHost}:${turnPort}` }];
        if (turnPass.length > 0) {
          iceServers.push({ urls: `turn:${turnHost}:${turnPort}`, username: turnUser, credential: turnPass });
        }
        jsonResponse(response, 200, { iceServers });
        return;
      }

      // ─── Projects ───
      if (request.method === 'GET' && url.pathname === '/api/projects') {
        const auth = requireAuth(request, response);
        if (!auth) return;
        jsonResponse(response, 200, { items: [PROJECT] });
        return;
      }

      // ─── OpenCode Resumes ───
      if (request.method === 'GET' && url.pathname === '/api/opencode/resumes') {
        const auth = requireAuth(request, response);
        if (!auth) return;

        const limit = Number(url.searchParams.get('limit') ?? '20');
        const allItems = await opencodeClient.listResumes({ limit: 1000 });
        const deviceThreadIds = deviceSessions.get(auth.deviceId) ?? new Set();
        const items = allItems
          .filter((item) => deviceThreadIds.has(item.id))
          .slice(0, Number.isFinite(limit) && limit > 0 ? limit : 20);
        jsonResponse(response, 200, { items });
        return;
      }

      if (request.method === 'POST' && url.pathname === '/api/opencode/resumes') {
        const auth = requireAuth(request, response);
        if (!auth) return;

        const body = await readJson(request);
        const cwd = normalizeResumeCwd(body.cwd);
        const session = await opencodeClient.startResume({ cwd });
        if (auth.deviceId && session.threadId) {
          if (!deviceSessions.has(auth.deviceId)) {
            deviceSessions.set(auth.deviceId, new Set());
          }
          deviceSessions.get(auth.deviceId).add(session.threadId);
        }
        jsonResponse(response, 200, session);
        return;
      }

      const opencodeResumeMatch = url.pathname.match(/^\/api\/opencode\/resumes\/([^/]+)\/resume$/);
      if (request.method === 'POST' && opencodeResumeMatch) {
        const auth = requireAuth(request, response);
        if (!auth) return;

        const threadId = decodeURIComponent(opencodeResumeMatch[1]);
        if (threadId.trim().length === 0) {
          errorResponse(response, 400, 'invalid_request', 'Thread id is required');
          return;
        }
        const session = await opencodeClient.readResume({ threadId });
        jsonResponse(response, 200, session);
        return;
      }

      const opencodeArchiveResumeMatch = url.pathname.match(/^\/api\/opencode\/resumes\/([^/]+)\/archive$/);
      if (request.method === 'POST' && opencodeArchiveResumeMatch) {
        const auth = requireAuth(request, response);
        if (!auth) return;

        const threadId = decodeURIComponent(opencodeArchiveResumeMatch[1]);
        if (threadId.trim().length === 0) {
          errorResponse(response, 400, 'invalid_request', 'Thread id is required');
          return;
        }
        await opencodeClient.archiveResume({ threadId });
        if (auth.deviceId) {
          const deviceThreadIds = deviceSessions.get(auth.deviceId);
          if (deviceThreadIds) deviceThreadIds.delete(threadId);
        }
        jsonResponse(response, 200, { ok: true });
        return;
      }

      const opencodeRenameResumeMatch = url.pathname.match(/^\/api\/opencode\/resumes\/([^/]+)\/name$/);
      if (request.method === 'POST' && opencodeRenameResumeMatch) {
        const auth = requireAuth(request, response);
        if (!auth) return;

        const threadId = decodeURIComponent(opencodeRenameResumeMatch[1]);
        const body = await readJson(request);
        const name = typeof body.name === 'string' ? body.name.trim() : '';
        if (threadId.trim().length === 0 || name.length === 0) {
          errorResponse(response, 400, 'invalid_request', 'Thread id and name are required');
          return;
        }
        await opencodeClient.renameResume({ threadId, name });
        jsonResponse(response, 200, { ok: true });
        return;
      }

      const opencodeDeleteResumeMatch = url.pathname.match(/^\/api\/opencode\/resumes\/([^/]+)$/);
      if (request.method === 'DELETE' && opencodeDeleteResumeMatch) {
        const auth = requireAuth(request, response);
        if (!auth) return;

        const threadId = decodeURIComponent(opencodeDeleteResumeMatch[1]);
        if (threadId.trim().length === 0) {
          errorResponse(response, 400, 'invalid_request', 'Thread id is required');
          return;
        }
        await opencodeClient.deleteResume({ threadId });
        if (auth.deviceId) {
          const deviceThreadIds = deviceSessions.get(auth.deviceId);
          if (deviceThreadIds) deviceThreadIds.delete(threadId);
        }
        jsonResponse(response, 200, { ok: true });
        return;
      }

      const opencodeMessageMatch = url.pathname.match(/^\/api\/opencode\/resumes\/([^/]+)\/messages$/);
      if (request.method === 'POST' && opencodeMessageMatch) {
        const auth = requireAuth(request, response);
        if (!auth) return;

        const threadId = decodeURIComponent(opencodeMessageMatch[1]);
        const body = await readJson(request);
        const message = typeof body.message === 'string' ? body.message : '';
        if (threadId.trim().length === 0 || message.trim().length === 0) {
          errorResponse(response, 400, 'invalid_request', 'Thread id and message are required');
          return;
        }
        const session = await opencodeClient.sendResumeMessage({ threadId, message });
        jsonResponse(response, 200, session);
        return;
      }

      // ─── Tasks ───
      const createTaskMatch = url.pathname.match(/^\/api\/projects\/([^/]+)\/tasks$/);
      if (request.method === 'POST' && createTaskMatch) {
        const auth = requireAuth(request, response);
        if (!auth) return;

        const projectId = createTaskMatch[1];
        if (projectId !== PROJECT.id) {
          errorResponse(response, 404, 'project_not_found', 'Project not found');
          return;
        }

        const body = await readJson(request);
        const taskId = `task_${randomUUID()}`;
        const task = {
          id: taskId, taskId, projectId, status: 'queued',
          message: typeof body.message === 'string' ? body.message : '',
          sandbox: typeof body.sandbox === 'string' ? body.sandbox : 'workspace-write',
          networkEnabled: Boolean(body.networkEnabled),
          createdAt: new Date().toISOString()
        };
        tasks.set(taskId, task);
        jsonResponse(response, 200, { taskId, status: task.status });
        return;
      }

      const taskMatch = url.pathname.match(/^\/api\/tasks\/([^/]+)$/);
      if (request.method === 'GET' && taskMatch) {
        const auth = requireAuth(request, response);
        if (!auth) return;

        const task = tasks.get(taskMatch[1]);
        if (!task) {
          errorResponse(response, 404, 'task_not_found', 'Task not found');
          return;
        }
        jsonResponse(response, 200, task);
        return;
      }

      // ─── Files: List generated files ───
      if (request.method === 'GET' && url.pathname === '/api/files') {
        const auth = requireAuth(request, response);
        if (!auth) return;
        const filesRoot = resolveFilesRoot();
        if (!filesRoot) {
          errorResponse(response, 500, 'files_root_unset', 'FILES_ROOT or OPENCODE_WORKDIR is not configured');
          return;
        }
        jsonResponse(response, 200, { items: listGeneratedFiles(filesRoot) });
        return;
      }

      // ─── Files: Download ───
      const downloadMatch = url.pathname.match(/^\/api\/files\/(.+)\/download$/);
      if (request.method === 'GET' && downloadMatch) {
        const auth = requireAuth(request, response);
        if (!auth) return;
        const filesRoot = resolveFilesRoot();
        if (!filesRoot) {
          errorResponse(response, 500, 'files_root_unset', 'FILES_ROOT or OPENCODE_WORKDIR is not configured');
          return;
        }

        const target = resolveDownloadPath(filesRoot, downloadMatch[1]);
        if (!target || !isAllowedFile(target)) {
          errorResponse(response, 400, 'invalid_file', 'File name is invalid or not allowed');
          return;
        }

        try {
          const content = fs.readFileSync(target);
          const type = mimeTypeForFile(target);
          response.writeHead(200, {
            'content-type': type,
            'content-length': content.length,
            'content-disposition': `attachment; filename="${encodeURIComponent(path.basename(target))}"`
          });
          response.end(content);
        } catch (error) {
          errorResponse(response, 404, 'file_not_found', 'File does not exist');
        }
        return;
      }

      errorResponse(response, 404, 'not_found', 'Not found');
    } catch (error) {
      console.error(`[gateway] ${request.method} ${request.url} 500:`, error);
      errorResponse(response, 500, 'gateway_unavailable', error instanceof Error ? error.message : 'Gateway error');
    }
  };
}

export function createGatewayListener(options = {}) {
  const handler = createGatewayHandler(options);
  if (options.tlsKey && options.tlsCert) {
    const createSecureServer = options.createSecureServer ?? https.createServer;
    return createSecureServer({ key: options.tlsKey, cert: options.tlsCert }, handler);
  }
  return http.createServer(handler);
}

export function createGatewayServer(options = {}) {
  return createGatewayListener(options);
}

export function startGatewayServer(options = {}) {
  const host = options.host ?? process.env.GATEWAY_HOST ?? DEFAULT_HOST;
  const port = Number(options.port ?? process.env.GATEWAY_PORT ?? DEFAULT_PORT);
  const httpPort = Number(options.httpPort ?? process.env.GATEWAY_HTTP_PORT ?? 8080);
  const tlsKeyPath = options.tlsKeyPath ?? process.env.GATEWAY_TLS_KEY;
  const tlsCertPath = options.tlsCertPath ?? process.env.GATEWAY_TLS_CERT;
  const tlsOptions = tlsKeyPath && tlsCertPath ? {
    tlsKey: fs.readFileSync(tlsKeyPath),
    tlsCert: fs.readFileSync(tlsCertPath)
  } : {};
  const handler = createGatewayHandler(options);

  const servers = [];

  if (tlsKeyPath && tlsCertPath) {
    const httpsServer = https.createServer({ key: tlsOptions.tlsKey, cert: tlsOptions.tlsCert }, handler);
    httpsServer.listen(port, host, () => {
      const address = httpsServer.address();
      const actualPort = typeof address === 'object' && address ? address.port : port;
      console.log(`AI Router Gateway listening on https://${host}:${actualPort}`);
    });
    servers.push(httpsServer);
  }

  const httpServer = http.createServer(handler);
  httpServer.listen(httpPort, host, () => {
    const address = httpServer.address();
    const actualPort = typeof address === 'object' && address ? address.port : httpPort;
    console.log(`AI Router Gateway listening on http://${host}:${actualPort}`);
  });
  servers.push(httpServer);

  return servers;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  startGatewayServer();
}
