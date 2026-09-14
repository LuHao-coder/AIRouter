import { readdirSync, statSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const ALLOWED_EXTENSIONS = new Set(['.pptx', '.docx', '.xlsx', '.pdf', '.md', '.txt', '.zip']);
const REGISTRY_NAME = '.airouter_registry.json';

export function resolveFilesRoot(env = process.env) {
  return env.FILES_ROOT?.trim() || env.OPENCODE_WORKDIR?.trim() || '';
}

/**
 * 返回该设备的专属工作目录（FILES_ROOT/workspaces/<deviceId>）。
 * 目录不存在时返回 null。用于严格按设备隔离：设备只能访问自己目录下的文件。
 */
export function deviceWorkspace(root, deviceId) {
  if (!root || !deviceId) {
    return null;
  }
  const safeId = String(deviceId).replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 64);
  return path.join(root, 'workspaces', safeId);
}

/** 设备专属目录必须存在才是有效工作区（避免设备目录被恶意创建前返回空列表误导）。 */
export function deviceWorkspaceExists(root, deviceId) {
  const dir = deviceWorkspace(root, deviceId);
  if (!dir) {
    return false;
  }
  try {
    return statSync(dir).isDirectory();
  } catch {
    return false;
  }
}

export function isAllowedFile(name) {
  const ext = path.extname(name).toLowerCase();
  return ALLOWED_EXTENSIONS.has(ext);
}

export function registryPath(root) {
  return path.join(root, REGISTRY_NAME);
}

export function loadRegistry(root) {
  try {
    const raw = readFileSync(registryPath(root), 'utf8');
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object' && parsed.files && typeof parsed.files === 'object') {
      return parsed.files;
    }
    return {};
  } catch {
    return {};
  }
}

function saveRegistry(root, files) {
  try {
    writeFileSync(registryPath(root), JSON.stringify({ files }, null, 2), 'utf8');
  } catch (error) {
    console.error(`[FileService] 保存文件注册表失败: ${error}`);
  }
}

/**
 * 递归罗列 FILES_ROOT 下所有白名单文件（相对路径），避免遍历 build 等大目录时可传入 maxDepth。
 * 当提供 deviceId 时，仅返回未认领的文件或该设备已认领的文件（实现设备间隔离）。
 */
export function listGeneratedFiles(root, options = {}) {
  const maxDepth = options.maxDepth ?? 4;
  const deviceId = typeof options.deviceId === 'string' ? options.deviceId : '';
  const registry = deviceId.length > 0 ? loadRegistry(root) : {};
  const results = [];

  function walk(dir, depth) {
    if (depth > maxDepth) {
      return;
    }
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (isExcludedDir(entry.name) || isHidden(entry.name)) {
        continue;
      }
      if (entry.isDirectory()) {
        walk(full, depth + 1);
      } else if (entry.isFile() && isAllowedFile(entry.name)) {
        const relName = path.relative(root, full).split(path.sep).join('/');
        const owner = registry[relName];
        if (deviceId.length > 0 && owner !== undefined && owner !== deviceId) {
          continue;
        }
        try {
          const st = statSync(full);
          results.push({
            name: relName,
            size: st.size,
            modifiedAt: st.mtime.toISOString()
          });
        } catch {
          // skip unreadable files
        }
      }
    }
  }

  walk(root, 0);
  return results.sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * 检查设备是否有权下载文件（不修改注册表）。
 * 返回 { code, claim? }：code 为 'ok' | 'not_yours' | 'invalid'；claim 为 true 表示首次下载，需要后续认领。
 */
export function resolveDownloadAccess(root, requestedName, deviceId) {
  if (!root || !deviceId) {
    return { code: 'invalid' };
  }
  const target = resolveDownloadPath(root, requestedName);
  if (!target || !isAllowedFile(target)) {
    return { code: 'invalid' };
  }
  const relName = safeDecode(requestedName);
  const owner = loadRegistry(root)[relName];
  if (owner !== undefined && owner !== deviceId) {
    return { code: 'not_yours', owner };
  }
  return { code: 'ok', claim: owner === undefined };
}

/** 将文件认领给指定设备（仅在文件成功读取后调用）。 */
export function claimFile(root, requestedName, deviceId) {
  if (!root || !deviceId) {
    return;
  }
  const relName = safeDecode(requestedName);
  const registry = loadRegistry(root);
  if (registry[relName] === undefined) {
    registry[relName] = deviceId;
    saveRegistry(root, registry);
  }
}

export function resolveDownloadPath(root, requestedName) {
  if (!root) {
    return null;
  }
  const decoded = safeDecode(requestedName);
  // 拒绝绝对路径与路径穿越
  if (decoded.includes('\0') || decoded.startsWith('/') || decoded.includes('..')) {
    return null;
  }
  const target = path.normalize(path.join(root, decoded));
  const normalizedRoot = path.normalize(root);
  if (target !== normalizedRoot && !target.startsWith(normalizedRoot + path.sep)) {
    return null;
  }
  return target;
}

function isExcludedDir(name) {
  return [
    'node_modules', '.git', '.svn', '.hg', 'build', '.build',
    'cache', 'dist', 'out', 'target', 'cert', 'keys', 'data'
  ].includes(name);
}

function isHidden(name) {
  return name.startsWith('.');
}

function safeDecode(value) {
  try {
    return decodeURIComponent(String(value));
  } catch {
    return String(value);
  }
}
