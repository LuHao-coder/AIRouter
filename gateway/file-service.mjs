import { readdirSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';

const ALLOWED_EXTENSIONS = new Set(['.pptx', '.docx', '.xlsx', '.pdf', '.md', '.txt', '.zip']);

export function resolveFilesRoot(env = process.env) {
  return env.FILES_ROOT?.trim() || env.OPENCODE_WORKDIR?.trim() || '';
}

/**
 * 返回该设备的专属工作目录（FILES_ROOT/workspaces/<sha256(deviceId) 前 32 位>）。
 * 目录名用哈希而非原始 deviceId，杜绝不同 deviceId 通过字符替换归一化后碰撞到同一目录
 * （例如 `a.b` 与 `a_b`），从而避免跨设备文件访问。目录不存在时返回 null。
 */
export function deviceWorkspace(root, deviceId) {
  if (!root || !deviceId) {
    return null;
  }
  const safeId = createHash('sha256').update(String(deviceId)).digest('hex').slice(0, 32);
  return path.join(root, 'workspaces', safeId);
}

/** 设备专属目录必须存在才是有效工作区（避免设备目录被创建前返回空列表误导）。 */
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

/**
 * 递归罗列工作区下所有白名单文件（相对路径），避免遍历 build 等大目录时可传入 maxDepth。
 */
export function listGeneratedFiles(root, options = {}) {
  const maxDepth = options.maxDepth ?? 4;
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
