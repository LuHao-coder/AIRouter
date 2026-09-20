import { createHash } from 'node:crypto';
import path from 'node:path';

// 支持的文件类型（扩展名 → MIME）。ALLOWED_EXTENSIONS 由此派生，保持单一来源。
const MIME_TYPES = {
  // 文档
  '.pdf': 'application/pdf',
  '.doc': 'application/msword',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.ppt': 'application/vnd.ms-powerpoint',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8',
  '.rtf': 'application/rtf',
  '.csv': 'text/csv; charset=utf-8',
  '.odt': 'application/vnd.oasis.opendocument.text',
  '.ods': 'application/vnd.oasis.opendocument.spreadsheet',
  '.odp': 'application/vnd.oasis.opendocument.presentation',
  // 图片
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.bmp': 'image/bmp',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.tif': 'image/tiff',
  '.tiff': 'image/tiff',
  '.heic': 'image/heic',
  '.avif': 'image/avif',
  // 音频
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.m4a': 'audio/mp4',
  '.aac': 'audio/aac',
  '.flac': 'audio/flac',
  '.ogg': 'audio/ogg',
  '.opus': 'audio/ogg',
  // 视频
  '.mp4': 'video/mp4',
  '.m4v': 'video/x-m4v',
  '.mov': 'video/quicktime',
  '.webm': 'video/webm',
  '.mkv': 'video/x-matroska',
  '.avi': 'video/x-msvideo',
  // 压缩包
  '.zip': 'application/zip',
  '.rar': 'application/vnd.rar',
  '.7z': 'application/x-7z-compressed',
  '.tar': 'application/x-tar',
  '.gz': 'application/gzip',
  '.tgz': 'application/gzip',
  '.bz2': 'application/x-bzip2',
  '.xz': 'application/x-xz',
  // 文本 / 代码 / 配置
  '.json': 'application/json; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.yaml': 'text/yaml; charset=utf-8',
  '.yml': 'text/yaml; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.cjs': 'text/javascript; charset=utf-8',
  '.ts': 'text/plain; charset=utf-8',
  '.jsx': 'text/plain; charset=utf-8',
  '.tsx': 'text/plain; charset=utf-8',
  '.py': 'text/x-python; charset=utf-8',
  '.java': 'text/x-java-source; charset=utf-8',
  '.c': 'text/x-c; charset=utf-8',
  '.cpp': 'text/x-c; charset=utf-8',
  '.h': 'text/x-c; charset=utf-8',
  '.hpp': 'text/x-c; charset=utf-8',
  '.go': 'text/x-go; charset=utf-8',
  '.rs': 'text/x-rust; charset=utf-8',
  '.rb': 'text/x-ruby; charset=utf-8',
  '.php': 'text/x-php; charset=utf-8',
  '.kt': 'text/plain; charset=utf-8',
  '.swift': 'text/plain; charset=utf-8',
  '.sh': 'text/x-sh; charset=utf-8',
  '.bat': 'text/plain; charset=utf-8',
  '.ps1': 'text/plain; charset=utf-8',
  '.sql': 'text/x-sql; charset=utf-8',
  '.log': 'text/plain; charset=utf-8',
  '.ini': 'text/plain; charset=utf-8',
  '.conf': 'text/plain; charset=utf-8',
  '.toml': 'text/plain; charset=utf-8',
  '.properties': 'text/plain; charset=utf-8',
  '.vue': 'text/plain; charset=utf-8',
  '.svelte': 'text/plain; charset=utf-8'
};

const ALLOWED_EXTENSIONS = new Set(Object.keys(MIME_TYPES));

export function resolveFilesRoot(env = process.env) {
  return env.FILES_ROOT?.trim() || env.OPENCODE_WORKDIR?.trim() || '';
}

/**
 * 返回该设备的工作目录（FILES_ROOT/workspaces/<sha256(deviceId) 前 32 位>）。
 * 目录名用哈希而非原始 deviceId，避免不同 deviceId 归一化后碰撞到同一目录。
 *
 * 说明：当前 opencode 版本不支持按请求切换目录，文件实际仍写在 OPENCODE_WORKDIR；
 * 该路径仅用于会话标题/前向兼容的 `directory` 参数，文件隔离靠 session_files 登记。
 */
export function deviceWorkspace(root, deviceId) {
  if (!root || !deviceId) {
    return null;
  }
  const safeId = createHash('sha256').update(String(deviceId)).digest('hex').slice(0, 32);
  return path.join(root, 'workspaces', safeId);
}

export function isAllowedFile(name) {
  const ext = path.extname(name).toLowerCase();
  return ALLOWED_EXTENSIONS.has(ext);
}

export function mimeTypeForFile(name) {
  return MIME_TYPES[path.extname(name).toLowerCase()] ?? 'application/octet-stream';
}
