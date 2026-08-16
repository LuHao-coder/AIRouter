import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { EventEmitter } from 'node:events';
import {
  OpenCodeServerClient,
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
          }
        ]
      }
    ]);
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

class FakeChildProcess extends EventEmitter {
  constructor() {
    super();
    this.stderr = new EventEmitter();
  }
}
