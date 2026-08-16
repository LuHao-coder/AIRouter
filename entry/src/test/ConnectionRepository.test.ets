import { describe, expect, it } from '@ohos/hypium';
import {
  deserializeSavedConnections,
  InMemoryConnectionRepository,
  serializeSavedConnections
} from '../main/ets/model/ConnectionRepository';
import { SavedConnection } from '../main/ets/model/ConnectionModel';

function connection(id: string, lastUsedAt: string): SavedConnection {
  return {
    id,
    name: `codex-${id}`,
    agent: 'OpenCode',
    host: `192.168.1.${id}`,
    port: 8443,
    scheme: 'https',
    username: 'alice',
    lastUsedAt,
    status: 'unknown',
    accessTokenRef: `access-${id}`,
    refreshTokenRef: `refresh-${id}`,
    privateKeyRef: `private-key-${id}`
  };
}

export default function connectionRepositoryTest() {
  describe('connectionRepository', () => {
    it('adds and lists newest connections first', 0, () => {
      const repository = new InMemoryConnectionRepository();
      repository.add(connection('1', '2026-07-01T10:00:00+08:00'));
      repository.add(connection('2', '2026-07-01T11:00:00+08:00'));

      const result = repository.list();

      expect(result.length).assertEqual(2);
      expect(result[0].id).assertEqual('2');
      expect(result[1].id).assertEqual('1');
    });

    it('updates an existing connection by id', 0, () => {
      const repository = new InMemoryConnectionRepository();
      repository.add(connection('1', '2026-07-01T10:00:00+08:00'));

      const updated = connection('1', '2026-07-01T12:00:00+08:00');
      updated.name = 'renamed';
      const saved = repository.update(updated);

      expect(saved).assertEqual(true);
      expect(repository.list()[0].name).assertEqual('renamed');
    });

    it('deletes a connection by id', 0, () => {
      const repository = new InMemoryConnectionRepository();
      repository.add(connection('1', '2026-07-01T10:00:00+08:00'));

      const deleted = repository.delete('1');

      expect(deleted).assertEqual(true);
      expect(repository.list().length).assertEqual(0);
    });

    it('blocks adding more than five connections', 0, () => {
      const repository = new InMemoryConnectionRepository();
      repository.add(connection('1', '2026-07-01T10:00:00+08:00'));
      repository.add(connection('2', '2026-07-01T10:01:00+08:00'));
      repository.add(connection('3', '2026-07-01T10:02:00+08:00'));
      repository.add(connection('4', '2026-07-01T10:03:00+08:00'));
      repository.add(connection('5', '2026-07-01T10:04:00+08:00'));

      const added = repository.add(connection('6', '2026-07-01T10:05:00+08:00'));

      expect(added).assertEqual(false);
      expect(repository.list().length).assertEqual(5);
    });

    it('serializes and restores saved connections newest first', 0, () => {
      const saved = serializeSavedConnections([
        connection('1', '2026-07-01T10:00:00+08:00'),
        connection('2', '2026-07-01T11:00:00+08:00')
      ]);

      const restored = deserializeSavedConnections(saved);

      expect(restored.length).assertEqual(2);
      expect(restored[0].id).assertEqual('192.168.1.2');
      expect(restored[1].id).assertEqual('192.168.1.1');
      expect(restored[0].privateKeyRef).assertEqual('private-key-2');
      expect(restored[0].agent).assertEqual('OpenCode');
    });

    it('keeps only the newest same-agent same-host connection', 0, () => {
      const first = connection('local-a', '2026-07-01T10:00:00+08:00');
      first.name = '手机连接';
      first.host = '172.16.1.186';
      first.port = 8443;
      const second = connection('local-b', '2026-07-01T11:00:00+08:00');
      second.name = '电脑连接';
      second.host = '172.16.1.186';
      second.port = 9000;

      const restored = deserializeSavedConnections(serializeSavedConnections([first, second]));

      expect(restored.length).assertEqual(1);
      expect(restored[0].id).assertEqual('172.16.1.186');
      expect(restored[0].host).assertEqual('172.16.1.186');
    });

    it('restores historical connections without an agent as OpenCode', 0, () => {
      const legacy = '{"version":1,"connections":[{"id":"legacy","name":"Legacy","host":"172.16.1.186",' +
        '"port":8443,"scheme":"https","username":"","lastUsedAt":"2026-07-01T10:00:00+08:00",' +
        '"status":"online","accessTokenRef":"access","refreshTokenRef":"refresh","privateKeyRef":"private"}]}';

      const restored = deserializeSavedConnections(legacy);

      expect(restored.length).assertEqual(1);
      expect(restored[0].agent).assertEqual('OpenCode');
      expect(restored[0].id).assertEqual('172.16.1.186');
    });

    it('migrates historical local ids to ip ids for different addresses', 0, () => {
      const first = connection('conn_duplicate', '2026-07-01T10:00:00+08:00');
      first.name = '手机连接';
      first.host = '172.16.1.186';
      const second = connection('conn_duplicate', '2026-07-01T11:00:00+08:00');
      second.name = '电脑连接';
      second.host = '172.16.1.187';

      const restored = deserializeSavedConnections(JSON.stringify({
        version: 1,
        connections: [first, second]
      }));

      expect(restored.length).assertEqual(2);
      expect(restored[0].id === restored[1].id).assertEqual(false);
      expect(restored[0].id).assertEqual('172.16.1.187');
      expect(restored[1].id).assertEqual('172.16.1.186');
      expect(restored[0].host).assertEqual('172.16.1.187');
      expect(restored[1].host).assertEqual('172.16.1.186');
    });

    it('restores saved connections as offline on app launch', 0, () => {
      const onlineConnection = connection('1', '2026-07-01T10:00:00+08:00');
      onlineConnection.status = 'online';

      const restored = deserializeSavedConnections(serializeSavedConnections([onlineConnection]));

      expect(restored[0].status).assertEqual('offline');
    });

    it('ignores malformed saved connection data', 0, () => {
      const restored = deserializeSavedConnections('not-json');

      expect(restored.length).assertEqual(0);
    });
  });
}
