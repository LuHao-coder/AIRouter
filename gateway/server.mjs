import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { OpenCodeServerClient } from './opencode-server.mjs';
import {
  verifyAccessToken,
  ensureDeviceRegistrationCode,
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
  deviceWorkspace,
  isAllowedFile,
} from './file-service.mjs';
import {
  saveDeviceSession,
  getDeviceSessionOwner,
  listDeviceSessions,
  deleteDeviceSession,
  upsertSessionFile,
  listSessionFiles,
  findSessionFile,
} from './db.mjs';

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

/**
 * 会话归属校验：只有创建该会话的设备才能访问。非归属方返回 404（不泄漏会话是否存在）。
 */
function requireThreadOwnership(response, deviceId, threadId) {
  const owner = getDeviceSessionOwner(threadId);
  if (!owner || owner !== deviceId) {
    errorResponse(response, 404, 'session_not_found', 'Session not found');
    return false;
  }
  return true;
}

/**
 * 把会话产出的文件路径登记到 session_files（按设备归属）。
 * 只登记位于 filesRoot 之下、扩展名白名单、且当前存在的文件。
 */
function recordSessionFiles(deviceId, threadId, paths) {
  if (!deviceId || !threadId || !Array.isArray(paths) || paths.length === 0) {
    return;
  }
  const filesRoot = resolveFilesRoot();
  if (!filesRoot) {
    return;
  }
  const root = path.resolve(filesRoot);
  for (const raw of paths) {
    const candidate = typeof raw === 'string' ? raw.trim() : '';
    if (candidate.length === 0) {
      continue;
    }
    const absolute = path.resolve(path.isAbsolute(candidate) ? candidate : path.join(root, candidate));
    if (absolute !== root && !absolute.startsWith(root + path.sep)) {
      continue;
    }
    if (!isAllowedFile(absolute)) {
      continue;
    }
    let stats;
    try {
      stats = fs.statSync(absolute);
    } catch (error) {
      continue;
    }
    if (!stats.isFile()) {
      continue;
    }
    const name = path.relative(root, absolute).split(path.sep).join('/');
    try {
      upsertSessionFile(threadId, deviceId, absolute, name, stats.size, stats.mtime.toISOString());
    } catch (error) {
      console.error(`[gateway] 登记会话文件失败: ${error instanceof Error ? error.message : error}`);
    }
  }
}

function createGatewayHandler(options = {}) {
  const tasks = new Map();
  const opencodeClient = options.opencodeClient ?? new OpenCodeServerClient();

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

        if (!deviceId || !publicKey) {
          errorResponse(response, 400, 'invalid_request', 'deviceId and publicKey are required');
          return;
        }

        // 开放注册：首次注册时服务器为该设备随机分配注册码并绑定（此后不可更改/换绑）。
        const registrationCode = ensureDeviceRegistrationCode(deviceId);
        const challenge = createActivationChallenge(deviceId, publicKey);
        jsonResponse(response, 200, { ...challenge, registrationCode });
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
        const deviceName = typeof body.deviceName === 'string' ? body.deviceName.trim() : '';
        const mode = typeof body.mode === 'string' ? body.mode.trim() : 'reset';

        if (!deviceId || !publicKey) {
          errorResponse(response, 400, 'invalid_request', 'deviceId and publicKey are required');
          return;
        }

        // 注册码无需输入：沿用该设备首次注册时自动分配的码。
        const result = await reregisterDevice(deviceId, publicKey, deviceName, mode);
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
        jsonResponse(response, 200, {
          deviceId: auth.deviceId,
          sessionName: 'opencode-main',
          registrationCode: ensureDeviceRegistrationCode(auth.deviceId)
        });
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
        // 归属持久化在 SQLite，gateway 重启后依然只列表本设备会话。
        const deviceThreadIds = new Set(listDeviceSessions(auth.deviceId));
        const items = allItems
          .filter((item) => deviceThreadIds.has(item.id))
          .slice(0, Number.isFinite(limit) && limit > 0 ? limit : 20);
        jsonResponse(response, 200, { items });
        return;
      }

      if (request.method === 'POST' && url.pathname === '/api/opencode/resumes') {
        const auth = requireAuth(request, response);
        if (!auth) return;

        const filesRoot = resolveFilesRoot();
        if (!filesRoot) {
          errorResponse(response, 500, 'files_root_unset', 'FILES_ROOT or OPENCODE_WORKDIR is not configured');
          return;
        }

        // 设备专属工作目录：强制会话 cwd 指向该设备目录，实现文件天然按设备隔离。
        const workspace = deviceWorkspace(filesRoot, auth.deviceId);
        if (!workspace) {
          errorResponse(response, 400, 'invalid_device', 'Device id is required');
          return;
        }
        try {
          fs.mkdirSync(workspace, { recursive: true });
        } catch (error) {
          errorResponse(response, 500, 'workspace_create_failed', 'Could not create device workspace directory');
          return;
        }

        const cwd = workspace;
        // directory 让 opencode 把该会话的读写限制在设备工作区（文件隔离的关键）。
        const session = await opencodeClient.startResume({ cwd, directory: workspace });
        if (auth.deviceId && session.threadId) {
          saveDeviceSession(session.threadId, auth.deviceId);
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
        if (!requireThreadOwnership(response, auth.deviceId, threadId)) return;
        const directory = deviceWorkspace(resolveFilesRoot(), auth.deviceId) ?? '';
        const session = await opencodeClient.readResume({ threadId, directory });
        recordSessionFiles(auth.deviceId, threadId, session.files);
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
        if (!requireThreadOwnership(response, auth.deviceId, threadId)) return;
        await opencodeClient.archiveResume({ threadId });
        deleteDeviceSession(threadId);
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
        if (!requireThreadOwnership(response, auth.deviceId, threadId)) return;
        const directory = deviceWorkspace(resolveFilesRoot(), auth.deviceId) ?? '';
        await opencodeClient.renameResume({ threadId, name, directory });
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
        if (!requireThreadOwnership(response, auth.deviceId, threadId)) return;
        await opencodeClient.deleteResume({ threadId });
        deleteDeviceSession(threadId);
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
        if (!requireThreadOwnership(response, auth.deviceId, threadId)) return;
        const directory = deviceWorkspace(resolveFilesRoot(), auth.deviceId) ?? '';
        const session = await opencodeClient.sendResumeMessage({ threadId, message, directory });
        recordSessionFiles(auth.deviceId, threadId, session.files);
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

      // ─── Files: List（按设备汇总其会话产出的文件；登记式隔离，不依赖目录） ───
      if (request.method === 'GET' && url.pathname === '/api/files') {
        const auth = requireAuth(request, response);
        if (!auth) return;
        const filesRoot = resolveFilesRoot();
        if (!filesRoot) {
          errorResponse(response, 500, 'files_root_unset', 'FILES_ROOT or OPENCODE_WORKDIR is not configured');
          return;
        }
        const root = path.resolve(filesRoot);
        const items = [];
        for (const row of listSessionFiles(auth.deviceId)) {
          const absolute = path.resolve(root, row.name);
          if (absolute !== root && !absolute.startsWith(root + path.sep)) {
            continue;
          }
          if (!isAllowedFile(absolute)) {
            continue;
          }
          let stats;
          try {
            stats = fs.statSync(absolute);
          } catch (error) {
            continue;
          }
          if (!stats.isFile()) {
            continue;
          }
          items.push({ name: row.name, size: stats.size, modifiedAt: stats.mtime.toISOString() });
        }
        items.sort((left, right) => left.name.localeCompare(right.name));
        jsonResponse(response, 200, { items });
        return;
      }

      // ─── Files: Download（仅限本设备会话登记过的文件，精确查表，杜绝越权/穿越） ───
      const downloadMatch = url.pathname.match(/^\/api\/files\/(.+)\/download$/);
      if (request.method === 'GET' && downloadMatch) {
        const auth = requireAuth(request, response);
        if (!auth) return;
        const filesRoot = resolveFilesRoot();
        if (!filesRoot) {
          errorResponse(response, 500, 'files_root_unset', 'FILES_ROOT or OPENCODE_WORKDIR is not configured');
          return;
        }

        let requestedName;
        try {
          requestedName = decodeURIComponent(downloadMatch[1]);
        } catch (error) {
          requestedName = downloadMatch[1];
        }

        const record = findSessionFile(auth.deviceId, requestedName);
        if (!record) {
          errorResponse(response, 404, 'file_not_found', 'File does not exist');
          return;
        }

        const root = path.resolve(filesRoot);
        const target = path.resolve(root, record.name);
        if (target !== root && !target.startsWith(root + path.sep)) {
          errorResponse(response, 404, 'file_not_found', 'File does not exist');
          return;
        }
        if (!isAllowedFile(target)) {
          errorResponse(response, 400, 'invalid_file', 'File name is invalid or not allowed');
          return;
        }

        let stats;
        try {
          stats = fs.statSync(target);
        } catch (error) {
          errorResponse(response, 404, 'file_not_found', 'File does not exist');
          return;
        }
        if (!stats.isFile()) {
          errorResponse(response, 404, 'file_not_found', 'File does not exist');
          return;
        }

        // 流式发送，避免大文件整块读入内存。
        response.writeHead(200, {
          'content-type': mimeTypeForFile(target),
          'content-length': stats.size,
          'content-disposition': `attachment; filename="${encodeURIComponent(path.basename(target))}"`
        });
        const stream = fs.createReadStream(target);
        stream.on('error', () => {
          response.destroy();
        });
        response.on('close', () => {
          stream.destroy();
        });
        stream.pipe(response);
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
