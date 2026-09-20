import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { EventEmitter } from 'node:events';
import {
  OpenCodeServerClient,
  extractFilePathsFromDiff,
  extractFilePathsFromMessages,
  mapOpenCodeMessagesToResumeTurns,
  mapOpenCodeSessionToResumeItem,
  mapOpenCodeSessionToResumeSession
} from './opencode-server.mjs';

describe('opencode server adapter', () => {
  it('maps OpenCode sessions to resume items', () => {
    const item = mapOpenCodeSessionToResumeItem({
      id: 'ses_router',
      title: 'Port router to OpenCode',
      directory: '/srv/projects/codex-router',
      time: {
        created: 1783348800000,
        updated: 1783348860000
      }
    });

    assert.deepEqual(item, {
      id: 'ses_router',
      title: 'Port router to OpenCode',
      subtitle: '/srv/projects/codex-router',
      status: 'idle',
      updatedAt: '2026-07-06T14:41:00.000Z'
    });
  });

  it('maps OpenCode messages and text parts to resume turns', () => {
    const turns = mapOpenCodeMessagesToResumeTurns([
      {
        info: {
          id: 'msg_user',
          role: 'user',
          time: {
            created: 1783348800000
          }
        },
        parts: [
          {
            id: 'prt_user',
            type: 'text',
            text: '继续支持 opencode'
          }
        ]
      },
      {
        info: {
          id: 'msg_assistant',
          role: 'assistant',
          time: {
            created: 1783348801000,
            completed: 1783348802000
          }
        },
        parts: [
          {
            id: 'prt_assistant',
            type: 'text',
            text: '已切换到 OpenCode 会话。'
          },
          {
            id: 'prt_reasoning',
            type: 'reasoning',
            text: '先检查项目结构'
          },
          {
            id: 'prt_tool',
            type: 'tool',
            tool: 'bash',
            state: {
              input: 'git status',
              output: 'clean',
              status: 'completed'
            }
          },
          {
            id: 'prt_file',
            type: 'file',
            filename: 'entry/src/main/ets/pages/Index.ets'
          },
          {
            id: 'prt_unknown',
            type: 'metadata',
            summary: 'internal step'
          }
        ]
      }
    ]);

    assert.deepEqual(turns, [
      {
        id: 'msg_user',
        status: 'completed',
        startedAt: '2026-07-06T14:40:00.000Z',
        completedAt: '',
        items: [
          {
            id: 'msg_user:prt_user',
            role: 'user',
            kind: 'message',
            text: '继续支持 opencode',
            status: ''
          }
        ]
      },
      {
        id: 'msg_assistant',
        status: 'completed',
        startedAt: '2026-07-06T14:40:01.000Z',
        completedAt: '2026-07-06T14:40:02.000Z',
        items: [
          {
            id: 'msg_assistant:prt_assistant',
            role: 'assistant',
            kind: 'message',
            text: '已切换到 OpenCode 会话。',
            status: ''
          },
          {
            id: 'msg_assistant:prt_tool',
            role: 'tool',
            kind: 'tool',
            text: 'bash · completed',
            status: 'completed'
          },
          {
            id: 'msg_assistant:prt_file',
            role: 'tool',
            kind: 'file',
            text: 'Index.ets',
            status: ''
          }
        ]
      }
    ]);
  });

  it('extracts produced file paths from message parts (write/edit/file, ignores read)', () => {
    const files = extractFilePathsFromMessages([
      {
        parts: [
          { type: 'tool', tool: 'write', state: { input: { filePath: '/root/report.pptx', content: 'x' } } },
          { type: 'tool', tool: 'edit', state: { input: { file_path: 'notes.txt' } } },
          { type: 'tool', tool: 'read', state: { input: { filePath: '/root/secret.txt' } } },
          { type: 'file', filename: '/root/deck.docx' },
          { type: 'text', text: 'done' }
        ]
      }
    ]);

    assert.deepEqual(files.sort(), ['/root/deck.docx', '/root/report.pptx', 'notes.txt']);
  });

  it('extracts bash-created file paths from shell tool command/output', () => {
    const files = extractFilePathsFromMessages([
      {
        parts: [
          { type: 'tool', tool: 'bash', state: { input: { command: 'python gen.py -o /root/报告.docx' }, output: 'saved to /root/总结.md' } }
        ]
      }
    ]);

    assert.deepEqual(files.sort(), ['/root/总结.md', '/root/报告.docx', 'gen.py']);
  });

  it('extracts file paths from a session diff payload', () => {
    const files = extractFilePathsFromDiff([
      { file: '/root/a.docx', additions: 3 },
      { path: 'sub/b.pptx' },
      { filename: 'c.md' }
    ]);

    assert.deepEqual(files.sort(), ['/root/a.docx', 'c.md', 'sub/b.pptx']);
  });

  it('combines an OpenCode session and messages into a resume session', () => {
    const session = mapOpenCodeSessionToResumeSession({
      id: 'ses_router',
      title: 'Port router to OpenCode',
      directory: '/srv/projects/codex-router',
      time: {
        created: 1783348800000,
        updated: 1783348860000
      }
    }, [
      {
        info: {
          id: 'msg_assistant',
          role: 'assistant',
          time: {
            created: 1783348801000,
            completed: 1783348802000
          }
        },
        parts: [
          {
            id: 'prt_assistant',
            type: 'text',
            text: '已切换到 OpenCode 会话。'
          }
        ]
      }
    ]);

    assert.equal(session.threadId, 'ses_router');
    assert.equal(session.title, 'Port router to OpenCode');
    assert.equal(session.cwd, '/srv/projects/codex-router');
    assert.equal(session.status, 'idle');
    assert.equal(session.turns.length, 1);
  });

  it('sends via prompt_async (no wait) and returns a snapshot immediately', async () => {
    let promptAsyncUrl = '';
    const fetchImpl = async (url, options = {}) => {
      const target = String(url);
      const path = target.split('?')[0];
      const method = options.method ?? 'GET';
      if (method === 'POST' && path.endsWith('/prompt_async')) {
        promptAsyncUrl = target;
        return fakeJsonResponse(undefined, 204);
      }
      if (method === 'GET' && path.endsWith('/session/ses_long/message')) {
        return fakeJsonResponse([
          {
            info: { id: 'm_user', role: 'user', time: { created: 1 } },
            parts: [{ id: 'p_user', type: 'text', text: '帮我生成一份报告' }]
          }
        ]);
      }
      if (method === 'GET' && path.endsWith('/session/ses_long')) {
        return fakeJsonResponse({ id: 'ses_long', title: 'long', directory: '/work', time: { created: 1, updated: 2 } });
      }
      return fakeJsonResponse({});
    };
    const client = new OpenCodeServerClient({ url: 'http://127.0.0.1:4096', fetchImpl });

    const started = Date.now();
    const session = await client.sendResumeMessage({
      threadId: 'ses_long',
      message: '帮我生成一份报告',
      directory: '/work/workspaces/dev1'
    });
    const elapsed = Date.now() - started;

    assert.match(promptAsyncUrl, /\/prompt_async\?/);
    assert.match(promptAsyncUrl, /directory=%2Fwork%2Fworkspaces%2Fdev1/);
    assert.ok(elapsed < 1500, `应即时返回，实际耗时 ${elapsed}ms`);
    assert.equal(session.threadId, 'ses_long');
    assert.equal(session.turns[0].items[0].text, '帮我生成一份报告');
  });

  it('starts opencode serve from the configured work directory', async () => {
    const spawnCalls = [];
    const client = new OpenCodeServerClient({
      url: 'http://127.0.0.1:4096',
      workdir: '/root',
      spawnServer: (command, args, options) => {
        spawnCalls.push({ command, args, options });
        return new FakeChildProcess();
      }
    });

    await client.startServer();

    assert.equal(spawnCalls.length, 1);
    assert.equal(spawnCalls[0].options.cwd, '/root');
  });

  it('lists all OpenCode sessions from the database', async () => {
    const commands = [];
    const client = new OpenCodeServerClient({
      runCommand: async (args) => {
        commands.push(args);
        return JSON.stringify([
          {
            id: 'ses_root',
            title: 'Root session',
            directory: '/root',
            time_updated: 1783348860000,
            time_created: 1783348800000,
            time_archived: null
          },
          {
            id: 'ses_repo',
            title: 'Repo session',
            directory: '/mnt/d/code/codex-router',
            time_updated: 1783348800000,
            time_created: 1783348700000,
            time_archived: null
          }
        ]);
      },
      fetchImpl: async () => {
        throw new Error('listResumes should not call the cwd-filtered opencode server');
      }
    });

    const items = await client.listResumes({ limit: 10 });

    assert.deepEqual(items, [
      {
        id: 'ses_root',
        title: 'Root session',
        subtitle: '/root',
        status: 'idle',
        updatedAt: '2026-07-06T14:41:00.000Z'
      },
      {
        id: 'ses_repo',
        title: 'Repo session',
        subtitle: '/mnt/d/code/codex-router',
        status: 'idle',
        updatedAt: '2026-07-06T14:40:00.000Z'
      }
    ]);
    assert.equal(commands.length, 1);
    assert.equal(commands[0][0], 'db');
    assert.match(commands[0][1], /from session/i);
    assert.deepEqual(commands[0].slice(-2), ['--format', 'json']);

    // 短 TTL 内重复列举命中缓存，不再 spawn `opencode db`。
    const again = await client.listResumes({ limit: 10 });
    assert.deepEqual(again, items);
    assert.equal(commands.length, 1);

    // 显式失效后重新查询。
    client.invalidateSessionsCache();
    await client.listResumes({ limit: 10 });
    assert.equal(commands.length, 2);
  });

  it('archives an OpenCode session through the database', async () => {
    const commands = [];
    const client = new OpenCodeServerClient({
      now: () => 1783348860123,
      runCommand: async (args) => {
        commands.push(args);
        return '';
      },
      fetchImpl: async () => {
        throw new Error('archiveResume should not call the cwd-filtered opencode server');
      }
    });

    await client.archiveResume({ threadId: "ses_root'quoted" });

    assert.equal(commands.length, 1);
    assert.equal(commands[0][0], 'db');
    assert.match(commands[0][1], /update session/i);
    assert.match(commands[0][1], /time_archived = 1783348860123/i);
    assert.match(commands[0][1], /id = 'ses_root''quoted'/i);
  });

  it('deletes an OpenCode session through the session CLI', async () => {
    const commands = [];
    const client = new OpenCodeServerClient({
      runCommand: async (args) => {
        commands.push(args);
        return '';
      },
      fetchImpl: async () => {
        throw new Error('deleteResume should not call the cwd-filtered opencode server');
      }
    });

    await client.deleteResume({ threadId: 'ses_root' });

    assert.deepEqual(commands, [
      ['session', 'delete', 'ses_root']
    ]);
  });
});

function fakeJsonResponse(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    text: async () => (body === undefined ? '' : JSON.stringify(body))
  };
}

class FakeChildProcess extends EventEmitter {
  constructor() {
    super();
    this.stderr = new EventEmitter();
  }
}
