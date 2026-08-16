import {
  canAddConnection,
  ConnectionStatus,
  generateSavedConnectionId,
  MAX_CONNECTIONS,
  SavedConnection,
  sortConnectionsByLastUsed
} from './ConnectionModel';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  decryptConnectionStore,
  encryptConnectionStore,
  isEncryptedConnectionStore
} from './HuksConnectionCrypto';

const CONNECTION_PREFERENCES_NAME: string = 'codex_router_connections';
const CONNECTION_PREFERENCES_KEY: string = 'connections';

interface StoredConnectionsPayload {
  version?: number;
  connections?: SavedConnection[];
}

export interface ConnectionRepository {
  list(): SavedConnection[];
  add(connection: SavedConnection): boolean;
  update(connection: SavedConnection): boolean;
  delete(id: string): boolean;
}

export class InMemoryConnectionRepository implements ConnectionRepository {
  private connections: SavedConnection[] = [];

  list(): SavedConnection[] {
    return sortConnectionsByLastUsed(this.connections);
  }

  add(connection: SavedConnection): boolean {
    if (!canAddConnection(this.connections)) {
      return false;
    }

    this.connections = sortConnectionsByLastUsed(this.connections.concat([connection]));
    return true;
  }

  update(connection: SavedConnection): boolean {
    let found = false;
    this.connections = this.connections.map((item: SavedConnection) => {
      if (item.id !== connection.id) {
        return item;
      }

      found = true;
      return connection;
    });

    if (found) {
      this.connections = sortConnectionsByLastUsed(this.connections);
    }

    return found;
  }

  delete(id: string): boolean {
    const before = this.connections.length;
    this.connections = this.connections.filter((item: SavedConnection) => item.id !== id);
    return this.connections.length !== before;
  }
}

export interface PersistentConnectionRepository {
  list(): Promise<SavedConnection[]>;
  save(connections: SavedConnection[]): Promise<void>;
}

export class PreferencesConnectionRepository implements PersistentConnectionRepository {
  private context: common.Context;
  private store: preferences.Preferences | null = null;

  constructor(context: common.Context) {
    this.context = context;
  }

  async list(): Promise<SavedConnection[]> {
    try {
      const store = await this.getStore();
      const saved = await store.get(CONNECTION_PREFERENCES_KEY, '');
      if (typeof saved !== 'string') {
        return [];
      }

      let plainValue: string;
      let needsMigration: boolean = false;
      if (isEncryptedConnectionStore(saved)) {
        const decrypted = await decryptConnectionStore(saved);
        if (decrypted === null) {
          return [];
        }
        plainValue = decrypted;
      } else {
        plainValue = saved;
        needsMigration = true;
      }

      const connections = deserializeSavedConnections(plainValue);
      const normalizedSaved = serializeSavedConnections(connections);
      if (normalizedSaved !== plainValue || needsMigration) {
        try {
          await this.save(connections);
        } catch (error) {
        }
      }

      return connections;
    } catch (error) {
      return [];
    }
  }

  async save(connections: SavedConnection[]): Promise<void> {
    try {
      const store = await this.getStore();
      const encrypted = await encryptConnectionStore(serializeSavedConnections(connections));
      await store.put(CONNECTION_PREFERENCES_KEY, encrypted);
      await store.flush();
    } catch (error) {
      throw new Error('Failed to save connections');
    }
  }

  private async getStore(): Promise<preferences.Preferences> {
    if (this.store !== null) {
      return this.store;
    }

    try {
      this.store = await preferences.getPreferences(this.context, CONNECTION_PREFERENCES_NAME);
      return this.store;
    } catch (error) {
      throw new Error('Failed to open connection preferences');
    }
  }
}

export function serializeSavedConnections(connections: SavedConnection[]): string {
  const payload: StoredConnectionsPayload = {
    version: 1,
    connections: uniqueConnectionHosts(sortConnectionsByLastUsed(connections).map((connection: SavedConnection) => {
      return normalizeConnectionId(connection);
    }))
      .slice(0, MAX_CONNECTIONS)
  };
  return JSON.stringify(payload);
}

export function deserializeSavedConnections(value: string): SavedConnection[] {
  if (value.trim().length === 0) {
    return [];
  }

  try {
    const payload: StoredConnectionsPayload = JSON.parse(value) as StoredConnectionsPayload;
    let source: SavedConnection[] = [];

    if (Array.isArray(payload.connections)) {
      source = payload.connections as SavedConnection[];
    }

    const normalized: SavedConnection[] = [];
    source.forEach((item: SavedConnection) => {
      const connection = normalizeStoredConnection(item);
      if (connection !== null) {
        normalized.push(connection);
      }
    });

    return uniqueConnectionHosts(sortConnectionsByLastUsed(normalized).map((connection: SavedConnection) => {
      return normalizeConnectionId(connection);
    }))
      .slice(0, MAX_CONNECTIONS);
  } catch (error) {
    return [];
  }
}

function normalizeStoredConnection(item: SavedConnection): SavedConnection | null {
  if (item === null || item === undefined) {
    return null;
  }

  if (typeof item.host !== 'string' || item.host.trim().length === 0) {
    return null;
  }

  const scheme = typeof item.scheme === 'string' && item.scheme.trim().length > 0 ? item.scheme.trim() : 'https';
  const port = typeof item.port === 'number' && item.port > 0 && item.port <= 65535 ? item.port : 8443;
  const lastUsedAt = normalizeLastUsedAt(item.lastUsedAt);

  return normalizeConnectionId({
    id: typeof item.id === 'string' ? item.id : '',
    name: typeof item.name === 'string' && item.name.trim().length > 0 ? item.name : item.host,
    agent: 'OpenCode',
    host: item.host,
    port,
    scheme,
    username: typeof item.username === 'string' ? item.username : '',
    lastUsedAt,
    status: normalizeStoredStatus(item.status),
    accessTokenRef: typeof item.accessTokenRef === 'string' ? item.accessTokenRef : '',
    refreshTokenRef: typeof item.refreshTokenRef === 'string' ? item.refreshTokenRef : '',
    privateKeyRef: typeof item.privateKeyRef === 'string' ? item.privateKeyRef : ''
  });
}

function normalizeStoredStatus(status: ConnectionStatus): ConnectionStatus {
  if (status === 'needs_login') {
    return 'needs_login';
  }

  return 'offline';
}

function normalizeLastUsedAt(value: string): string {
  if (typeof value !== 'string') {
    return '1970-01-01T00:00:00.000Z';
  }

  const parsedAt = Date.parse(value);
  if (parsedAt !== parsedAt) {
    return '1970-01-01T00:00:00.000Z';
  }

  return value;
}

function normalizeConnectionId(connection: SavedConnection): SavedConnection {
  return {
    id: generateSavedConnectionId(connection.host),
    name: connection.name,
    agent: connection.agent,
    host: connection.host,
    port: connection.port,
    scheme: connection.scheme,
    username: connection.username,
    lastUsedAt: connection.lastUsedAt,
    status: connection.status,
    accessTokenRef: connection.accessTokenRef,
    refreshTokenRef: connection.refreshTokenRef,
    privateKeyRef: connection.privateKeyRef
  };
}

function uniqueConnectionHosts(connections: SavedConnection[]): SavedConnection[] {
  const hosts: string[] = [];
  const result: SavedConnection[] = [];

  connections.forEach((connection: SavedConnection) => {
    const host = `${'OpenCode'}:${connection.host.trim().toLowerCase()}`;
    if (hosts.indexOf(host) >= 0) {
      return;
    }

    hosts.push(host);
    result.push(connection);
  });

  return result;
}
