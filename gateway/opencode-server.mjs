import { spawn } from 'node:child_process';
import { homedir } from 'node:os';
import { isAllowedFile } from './file-service.mjs';

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

// 会把文件写入磁盘的工具（read 之类的只读工具不计入）。
const FILE_PRODUCING_TOOLS = new Set([
  'write', 'edit', 'patch', 'apply_patch', 'multiedit', 'create', 'write_file', 'str_replace_editor'
]);

// shell 类工具：需从命令/输出里扫文件路径（bash 直接写文件不会被上面识别）。
const SHELL_TOOLS = new Set(['bash', 'shell', 'sh', 'console', 'terminal']);

// 会话兜底命名：取首条消息前 N 个字符。
const SESSION_TITLE_MAX_LENGTH = 20;

// 会被登记的产出文件扩展名（与 file-service 白名单一致）。
/**
 * 从会话消息 parts 中提取“产出/改动的文件路径”。
 * 用于把文件按会话归属到设备（不依赖 opencode 的目录隔离）。
 *
 * 覆盖：
 * - `file` part 的 filename/path
 * - 写文件类工具（write/edit/patch…）input/metadata 中含 file/path 的字段
 * - bash/shell 工具的命令与输出中以白名单扩展名结尾的路径（覆盖 `cat > x.docx`、脚本产出等）
 */
export function extractFilePathsFromMessages(messages) {
  if (!Array.isArray(messages)) {
    return [];
  }

  const paths = new Set();
  const add = (value) => {
    const path = normalizeString(value);
    if (path.length > 0) {
      paths.add(path);
    }
  };

  for (const message of messages) {
    const parts = Array.isArray(message?.parts) ? message.parts : [];
    for (const part of parts) {
      const type = normalizeString(part?.type);
      if (type === 'file') {
        add(part?.filename);
        add(part?.path);
        continue;
      }
      if (type !== 'tool') {
        continue;
      }

      const toolName = normalizeString(part?.tool).toLowerCase();
      const state = part?.state ?? {};

      if (FILE_PRODUCING_TOOLS.has(toolName)) {
        // 不同工具/版本字段名不一（filePath / file_path / path / filename …）。
        for (const value of pickPathLikeValues(state.input)) {
          add(value);
        }
        for (const value of pickPathLikeValues(state.metadata)) {
          add(value);
        }
      }

      // shell 类工具：从命令/输出里扫出以白名单扩展名结尾的路径（覆盖 bash/脚本产物）。
      if (SHELL_TOOLS.has(toolName)) {
        for (const value of collectStringValues(state.input)) {
          for (const token of extractPathTokens(value)) {
            add(token);
          }
        }
        for (const value of collectStringValues(state.metadata)) {
          for (const token of extractPathTokens(value)) {
            add(token);
          }
        }
        for (const token of extractPathTokens(normalizeString(state.output))) {
          add(token);
        }
      }
    }
  }

  return Array.from(paths);
}

/** 从 `/session/:id/diff` 的返回中提取文件路径（字段名未知，做通用兜底）。 */
export function extractFilePathsFromDiff(diff) {
  if (!Array.isArray(diff)) {
    return [];
  }
  const paths = new Set();
  const add = (value) => {
    const path = normalizeString(value);
    if (path.length > 0) {
      paths.add(path);
    }
  };
  for (const entry of diff) {
    if (!entry || typeof entry !== 'object') {
      continue;
    }
    add(entry.file);
    add(entry.path);
    add(entry.filename);
    for (const value of pickPathLikeValues(entry)) {
      add(value);
    }
    for (const value of collectStringValues(entry)) {
      for (const token of extractPathTokens(value)) {
        add(token);
      }
    }
  }
  return Array.from(paths);
}

/** 收集对象中所有字符串值（一层）。 */
function collectStringValues(source) {
  if (!source || typeof source !== 'object') {
    return [];
  }
  return Object.values(source).filter((value) => typeof value === 'string');
}

/** 从任意文本里提取“以白名单扩展名结尾”的路径 token。 */
function extractPathTokens(text) {
  const value = normalizeString(text);
  if (value.length === 0) {
    return [];
  }
  const tokens = value.split(/[\s"'`|<>,;()[\]{}]+/);
  const results = [];
  for (const raw of tokens) {
    const token = raw.replace(/[.,:;]+$/, '');
    if (token.length > 0 && token.length < 1024 && isAllowedFile(token)) {
      results.push(token);
    }
  }
  return results;
}

function pickPathLikeValues(source) {
  if (!source || typeof source !== 'object') {
    return [];
  }
  const values = [];
  for (const [key, value] of Object.entries(source)) {
    if (typeof value === 'string' && value.length > 0 && value.length < 1024 && /file|path/i.test(key)) {
      values.push(value);
    }
  }
  return values;
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
    const messageFiles = extractFilePathsFromMessages(messages);
    // 会话 diff 能覆盖 bash/脚本产出的文件；失败时静默降级为仅用消息解析结果。
    const diffFiles = await this.readSessionDiff(threadId, directory);
    return {
      ...mapOpenCodeSessionToResumeSession(session, messages),
      files: Array.from(new Set([...messageFiles, ...diffFiles]))
    };
  }

  async readSessionDiff(threadId, directory) {
    try {
      const diff = await this.request(`/session/${encodeURIComponent(threadId)}/diff`, {
        directory,
        timeout: 5000
      });
      return extractFilePathsFromDiff(diff);
    } catch (error) {
      return [];
    }
  }

  async startResume(options = {}) {
    // directory 决定 opencode 的项目/工作目录：不同设备各自的工作区。
    const directory = normalizeString(options.directory) || normalizeString(options.cwd);
    // 不复用目录当标题：让 opencode 按首句自动命名（未自动命名时由 sendResumeMessage 兜底）。
    const session = await this.request('/session', {
      method: 'POST',
      body: {},
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

    const session = await this.readResume({ threadId, directory: options.directory });

    // 兜底命名：若 opencode 还没按首句命名（标题仍为空/就是 session id），用本条消息前 20 字命名。
    if (isSessionTitleUnset(session.title, threadId)) {
      const title = deriveSessionTitle(message);
      if (title.length > 0) {
        try {
          await this.renameResume({ threadId, name: title, directory: normalizeString(options.directory) });
          session.title = title;
        } catch (error) {
          console.error(`[opencode] 会话兜底命名失败: ${error instanceof Error ? error.message : error}`);
        }
      }
    }

    return session;
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
    // 只展示文件名+后缀，不展示完整路径。
    return resumeContent(`${messageId}:${partId}`, 'tool', 'file', baseName(filename), '');
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

/** 只取路径的文件名部分（兼容 `/`、`\`）。 */
function baseName(value) {
  const text = normalizeString(value).replace(/\\/g, '/');
  const index = text.lastIndexOf('/');
  return index >= 0 ? text.slice(index + 1) : text;
}

/** 会话标题是否“未命名”（空 / 就是 session id / 形如 ses_xxx）。 */
function isSessionTitleUnset(title, threadId) {
  const value = normalizeString(title);
  if (value.length === 0) {
    return true;
  }
  if (value === normalizeString(threadId)) {
    return true;
  }
  return /^ses[_-]/i.test(value);
}

/** 兜底标题：取消息前 N 个字符（换行保留）。 */
function deriveSessionTitle(message) {
  const text = typeof message === 'string' ? message.replace(/\r\n/g, '\n').trim() : '';
  return Array.from(text).slice(0, SESSION_TITLE_MAX_LENGTH).join('');
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
