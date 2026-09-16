import { createHash } from 'node:crypto';
import path from 'node:path';

const ALLOWED_EXTENSIONS = new Set(['.pptx', '.docx', '.xlsx', '.pdf', '.md', '.txt', '.zip']);

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
