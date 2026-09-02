import { readdirSync, statSync } from 'node:fs';
import path from 'node:path';

const ALLOWED_EXTENSIONS = new Set(['.pptx', '.docx', '.xlsx', '.pdf', '.md', '.txt', '.zip']);

export function resolveFilesRoot(env = process.env) {
  return env.FILES_ROOT?.trim() || env.OPENCODE_WORKDIR?.trim() || '';
}

export function isAllowedFile(name) {
  const ext = path.extname(name).toLowerCase();
  return ALLOWED_EXTENSIONS.has(ext);
}

/**
 * 递归罗列 FILES_ROOT 下所有白名单文件（相对路径），避免遍历 build 等大目录时可传入 maxDepth。
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
        try {
          const st = statSync(full);
          results.push({
            name: path.relative(root, full).split(path.sep).join('/'),
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
