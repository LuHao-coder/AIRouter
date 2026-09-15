import { spawn } from 'node:child_process';
import { homedir } from 'node:os';

const DEFAULT_OPENCODE_COMMAND = 'opencode';
const DEFAULT_OPENCODE_SERVER_URL = 'http://127.0.0.1:4096';
const SERVER_READY_TIMEOUT_MS = 30000;
const SERVER_READY_INTERVAL_MS = 500;
const MAX_PART_TEXT_LENGTH = 6000;
const SESSIONS_CACHE_TTL_MS = 3000;

export function mapOpenCodeSessionToResumeItem(session) {
  const id = normalizeString(session?.id);
  const title = normalizeString(session?.title) || normalizeString(session?.slug) || id;
  const subtitle = normalizeString(session?.directory) || normalizeString(session?.path);

  return {
    id,
    title,
    subtitle,
    status: session?.time?.archived ? 'archived' : 'idle',
    updatedAt: timestampToIso(session?.time?.updated || session?.time?.created)
  };
}

export function mapOpenCodeMessagesToResumeTurns(messages) {
  if (!Array.isArray(messages)) {
    return [];
  }

  return messages.map((message, index) => {
    const info = message?.info ?? {};
    const messageId = normalizeString(info.id) || `message-${index + 1}`;
    const role = normalizeRole(info.role);
    const status = resolveMessageStatus(info);
    const turn = {
      id: messageId,
      status,
      startedAt: timestampToIso(info.time?.created),
      completedAt: timestampToIso(info.time?.completed),
      items: Array.isArray(message?.parts) ? message.parts
        .map((part, partIndex) => mapOpenCodePartToResumeContent(messageId, role, part, partIndex))
        .filter(Boolean) : []
    };
    return turn;
  }).filter((turn) => turn.items.length > 0 || isActiveStatus(turn.status));
}

export function mapOpenCodeSessionToResumeSession(session, messages = []) {
  const item = mapOpenCodeSessionToResumeItem(session);
  const turns = mapOpenCodeMessagesToResumeTurns(messages);
  const running = turns.some((turn) => isActiveStatus(turn.status));

  return {
    threadId: item.id,
    title: item.title,
    cwd: item.subtitle,
    status: running ? 'running' : item.status,
    turns
  };
}

export class OpenCodeServerClient {
  constructor(options = {}) {
    this.url = stripTrailingSlash(options.url ?? process.env.OPENCODE_SERVER_URL ?? DEFAULT_OPENCODE_SERVER_URL);
    this.command = options.command ?? process.env.OPENCODE_COMMAND ?? DEFAULT_OPENCODE_COMMAND;
    this.workdir = normalizeString(options.workdir ?? process.env.OPENCODE_WORKDIR ?? process.env.HOME ?? homedir()) ||
      process.cwd();
    this.process = null;
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.spawnServer = options.spawnServer ?? spawn;
    this.platform = options.platform ?? process.platform;
    this.runCommand = options.runCommand ?? ((args) => runCommand(this.spawnServer, this.command, args, {
      cwd: this.workdir,
      platform: this.platform
    }));
    this.now = options.now ?? Date.now;
    this.stderr = '';
    this.startupError = null;
    this.sessionsCacheTtlMs = options.sessionsCacheTtlMs ?? SESSIONS_CACHE_TTL_MS;
    this.sessionsCache = new Map();
  }

  async listResumes(options = {}) {
    const limit = options.limit ?? 20;
    const normalizedLimit = Number.isFinite(limit) && limit > 0 ? limit : 20;
    const rows = await this.loadSessionRows(normalizedLimit);
    const sessions = rows.map(mapOpenCodeDbSessionToSession);
    return sessions
      .filter((session) => !session?.time?.archived)
      .sort((left, right) => Number(right?.time?.updated || 0) - Number(left?.time?.updated || 0))
      .slice(0, normalizedLimit)
      .map(mapOpenCodeSessionToResumeItem);
  }

  /** 带短 TTL 缓存地读取会话列表，避免每次请求都 spawn `opencode db`。 */
  async loadSessionRows(limit) {
    const cached = this.sessionsCache.get(limit);
    const now = this.now();
    if (cached && now - cached.at < this.sessionsCacheTtlMs) {
      return cached.rows;
    }
    const rows = await this.querySessions(limit);
    this.sessionsCache.set(limit, { at: now, rows });
    return rows;
  }

  invalidateSessionsCache() {
    this.sessionsCache.clear();
  }

  async readResume(options = {}) {
    const threadId = requireThreadId(options.threadId);
    const directory = normalizeString(options.directory);
    const session = await this.request(`/session/${encodeURIComponent(threadId)}`, { directory });
    const messages = await this.request(`/session/${encodeURIComponent(threadId)}/message`, { directory });
    return mapOpenCodeSessionToResumeSession(session, messages);
  }

  async startResume(options = {}) {
    // directory 决定 opencode 的项目/工作目录：不同设备各自的工作区。
    const directory = normalizeString(options.directory) || normalizeString(options.cwd);
    const body = {};
    if (directory.length > 0 && directory !== '~') {
      body.title = directory;
    }

    const session = await this.request('/session', {
      method: 'POST',
      body,
      directory: directory !== '~' ? directory : ''
    });
    this.invalidateSessionsCache();
    return mapOpenCodeSessionToResumeSession(session, []);
  }

  async sendResumeMessage(options = {}) {
    const threadId = requireThreadId(options.threadId);
    const message = normalizeString(options.message);
    if (message.length === 0) {
      throw new Error('message is required');
    }

    // prompt_async：发送即返回 204，不等待生成完成；结果由客户端轮询 /resume 获取（不阻塞、不取消生成）。
    await this.request(`/session/${encodeURIComponent(threadId)}/prompt_async`, {
      method: 'POST',
      body: {
        parts: [
          {
            type: 'text',
            text: message
          }
        ]
      },
      directory: normalizeString(options.directory)
    });

    return this.readResume({ threadId, directory: options.directory });
  }

  async archiveResume(options = {}) {
    const threadId = requireThreadId(options.threadId);
    const now = Number(this.now());
    await this.runCommand([
      'db',
      `update session set time_archived = ${now}, time_updated = ${now} where id = '${escapeSqlLiteral(threadId)}'`
    ]);
    this.invalidateSessionsCache();
  }

  async renameResume(options = {}) {
    const threadId = requireThreadId(options.threadId);
    const name = normalizeString(options.name);
    if (name.length === 0) {
      throw new Error('name is required');
    }

    await this.request(`/session/${encodeURIComponent(threadId)}`, {
      method: 'PATCH',
      body: {
        title: name
      },
      directory: normalizeString(options.directory)
    });
    this.invalidateSessionsCache();
  }

  async deleteResume(options = {}) {
    const threadId = requireThreadId(options.threadId);
    await this.runCommand(['session', 'delete', threadId]);
    this.invalidateSessionsCache();
  }

  async querySessions(limit) {
    const stdout = await this.runCommand([
      'db',
      `select id, title, slug, directory, path, time_created, time_updated, time_archived from session where time_archived is null order by time_updated desc limit ${limit}`,
      '--format',
      'json'
    ]);
    const text = normalizeString(stdout);
    return text.length > 0 ? JSON.parse(text) : [];
  }

  async request(path, options = {}) {
    await this.ensureReady();

    // opencode 按 `directory` 解析项目/工作目录；用它把不同设备隔离到各自工作区。
    let target = `${this.url}${path}`;
    if (normalizeString(options.directory).length > 0) {
      const url = new URL(target);
      url.searchParams.set('directory', normalizeString(options.directory));
      target = url.toString();
    }

    const timeoutMs = options.timeout ?? 300000;
    const response = await this.fetchImpl(target, {
      method: options.method ?? 'GET',
      headers: options.body !== undefined ? {
        'content-type': 'application/json'
      } : undefined,
      body: options.body !== undefined ? JSON.stringify(options.body) : undefined,
      signal: AbortSignal.timeout(timeoutMs)
    });
    if (!response?.ok) {
      throw new Error(`opencode server request failed: ${response?.status ?? 'no response'}`);
    }

    const text = await response.text();
    return text.trim().length > 0 ? JSON.parse(text) : {};
  }

  async ensureReady() {
    if (await this.isReady()) {
      return;
    }

    await this.startServer();
    const startedAt = Date.now();
    while (Date.now() - startedAt < SERVER_READY_TIMEOUT_MS) {
      if (await this.isReady()) {
        return;
      }
      if (!this.process) {
        if (this.startupError) {
          throw this.startupError;
        }
        throw new Error(this.describeStartupError('opencode serve exited before ready'));
      }
      await wait(SERVER_READY_INTERVAL_MS);
    }

    throw new Error(this.describeStartupError('Timed out waiting for opencode serve'));
  }

  async isReady() {
    try {
      const response = await this.fetchImpl(`${this.url}/session`);
      return Boolean(response?.ok);
    } catch (_error) {
      return false;
    }
  }

  async startServer() {
    if (this.process) {
      return;
    }

    const listenUrl = new URL(this.url);
    const spawnOptions = {
      stdio: ['ignore', 'ignore', 'pipe'],
      cwd: this.workdir
    };
    if (this.platform === 'win32') {
      spawnOptions.shell = true;
      spawnOptions.windowsHide = true;
    }

    const child = this.spawnServer(this.command, [
      'serve',
      '--hostname',
      listenUrl.hostname,
      '--port',
      listenUrl.port || '4096',
      '--print-logs'
    ], spawnOptions);
    this.process = child;
    this.startupError = null;

    child.stderr?.on('data', (chunk) => {
      this.stderr += chunk.toString();
      if (this.stderr.length > 4000) {
        this.stderr = this.stderr.slice(-4000);
      }
    });

    child.once('error', (error) => {
      this.process = null;
      this.startupError = error;
    });

    child.once('exit', () => {
      this.process = null;
    });
  }

  describeStartupError(message) {
    const stderr = this.stderr.trim();
    if (stderr.length === 0) {
      return message;
    }

    return `${message}\n${stderr}`;
  }
}

function mapOpenCodeDbSessionToSession(row) {
  return {
    id: row?.id,
    title: row?.title,
    slug: row?.slug,
    directory: row?.directory,
    path: row?.path,
    time: {
      created: row?.time_created,
      updated: row?.time_updated,
      archived: row?.time_archived
    }
  };
}

function mapOpenCodePartToResumeContent(messageId, role, part, partIndex) {
  const partId = normalizeString(part?.id) || `part-${partIndex + 1}`;
  const type = normalizeString(part?.type) || 'part';

  if (type === 'text') {
    if (role !== 'user' && role !== 'assistant') {
      return null;
    }

    return resumeContent(`${messageId}:${partId}`, role, 'message', part?.text, '');
  }

  // 工具调用 / 文件产物也映射为内容项，让“生成文件/调用工具”这类长任务在客户端有进度可看。
  if (type === 'tool') {
    const toolName = normalizeString(part?.tool) || 'tool';
    const status = normalizeString(part?.state?.status);
    const text = status.length > 0 ? `${toolName} · ${status}` : toolName;
    return resumeContent(`${messageId}:${partId}`, 'tool', 'tool', text, status);
  }

  if (type === 'file') {
    const filename = normalizeString(part?.filename) || normalizeString(part?.path) || 'file';
    return resumeContent(`${messageId}:${partId}`, 'tool', 'file', filename, '');
  }

  return null;
}

function resumeContent(id, role, kind, text, status) {
  const normalizedText = truncateText(normalizePartText(text));
  if (normalizedText.length === 0) {
    return null;
  }

  return {
    id,
    role,
    kind,
    text: normalizedText,
    status
  };
}

function normalizePartText(value) {
  if (typeof value === 'string') {
    return value.trim();
  }

  if (Array.isArray(value)) {
    return value.map(normalizePartText).filter(Boolean).join('\n');
  }

  if (value && typeof value === 'object') {
    return JSON.stringify(value);
  }

  return '';
}

function normalizeRole(role) {
  if (role === 'assistant' || role === 'user' || role === 'tool' || role === 'system') {
    return role;
  }

  return 'system';
}

function resolveMessageStatus(info) {
  if (info?.error) {
    return 'error';
  }

  if (info?.role === 'assistant' && !info?.time?.completed) {
    return 'running';
  }

  return 'completed';
}

function isActiveStatus(status) {
  return status === 'running' || status === 'inProgress' || status === 'in_progress' || status === 'queued';
}

function timestampToIso(value) {
  const timestamp = Number(value || 0);
  return timestamp > 0 ? new Date(timestamp).toISOString() : '';
}

function truncateText(value) {
  if (value.length <= MAX_PART_TEXT_LENGTH) {
    return value;
  }

  return `${value.slice(0, MAX_PART_TEXT_LENGTH)}\n...`;
}

function normalizeString(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function requireThreadId(threadId) {
  const normalized = normalizeString(threadId);
  if (normalized.length === 0) {
    throw new Error('threadId is required');
  }

  return normalized;
}

function stripTrailingSlash(value) {
  return normalizeString(value).replace(/\/+$/, '');
}

function escapeSqlLiteral(value) {
  return normalizeString(value).replace(/'/g, "''");
}

function runCommand(spawnCommand, command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const spawnOptions = {
      cwd: options.cwd,
      stdio: ['ignore', 'pipe', 'pipe']
    };
    if (options.platform === 'win32') {
      spawnOptions.shell = true;
      spawnOptions.windowsHide = true;
    }

    const child = spawnCommand(command, args, spawnOptions);
    let stdout = '';
    let stderr = '';

    child.stdout?.on('data', (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr?.on('data', (chunk) => {
      stderr += chunk.toString();
    });
    child.once('error', reject);
    child.once('exit', (code) => {
      if (code === 0) {
        resolve(stdout);
        return;
      }

      reject(new Error(`opencode command failed (${code}): ${stderr.trim()}`));
    });
  });
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
