import { rcp } from '@kit.RemoteCommunicationKit';

const DEFAULT_RESUME_CWD: string = '~';
const OPENCODE_RESUMES_PATH: string = '/api/opencode/resumes';
const FILES_PATH: string = '/api/files';

export interface LoginRequest {
  baseUrl: string;
  registrationCode: string;
  deviceName: string;
  deviceId: string;
  publicKey: string;
}

export interface RegisterRequest {
  baseUrl: string;
  deviceId: string;
  publicKey: string;
  registrationCode: string;
  deviceName: string;
}

export interface RegisterResponse {
  activationToken: string;
  challenge: string;
}

export interface ActivateRequest {
  baseUrl: string;
  deviceId: string;
  activationToken: string;
  signedChallenge: string;
}

export interface ChallengeRequest {
  baseUrl: string;
  deviceId: string;
}

export interface ChallengeResponse {
  nonce: string;
  expiresAt: string;
}

export interface VerifyRequest {
  baseUrl: string;
  deviceId: string;
  nonce: string;
  signature: string;
}

export interface RefreshRequest {
  baseUrl: string;
  refreshToken: string;
}

export interface RefreshResponse {
  accessToken: string;
}

export interface LogoutRequest {
  baseUrl: string;
  refreshToken: string;
}

export interface LoginResponse {
  accessToken: string;
  refreshToken: string;
  sessionName: string;
  expiresIn: number;
}

export interface ListResumesRequest {
  baseUrl: string;
  accessToken: string;
}

export interface StartResumeRequest {
  baseUrl: string;
  accessToken: string;
  cwd?: string;
}

export interface ResumeThreadRequest {
  baseUrl: string;
  accessToken: string;
  threadId: string;
}

export interface SendResumeMessageRequest {
  baseUrl: string;
  accessToken: string;
  threadId: string;
  message: string;
}

export interface ResumeMutationRequest {
  baseUrl: string;
  accessToken: string;
  threadId: string;
}

export interface RenameResumeRequest extends ResumeMutationRequest {
  name: string;
}

export interface ListFilesRequest {
  baseUrl: string;
  accessToken: string;
}

export interface ServerFile {
  name: string;
  size: number;
  modifiedAt: string;
}

export interface DownloadFileRequest {
  baseUrl: string;
  accessToken: string;
  fileName: string;
}

export interface DownloadedFile {
  name: string;
  bytes: ArrayBuffer;
}

export interface ResumeItem {
  id: string;
  title: string;
  subtitle: string;
  status: string;
  updatedAt: string;
}

export interface ResumeSession {
  threadId: string;
  title: string;
  cwd: string;
  status: string;
  turns: ResumeTurn[];
}

export interface ResumeTurn {
  id: string;
  status: string;
  startedAt: string;
  completedAt: string;
  items: ResumeContentItem[];
}

export interface ResumeContentItem {
  id: string;
  role: string;
  kind: string;
  text: string;
  status: string;
}

export interface GatewayClient {
  register(request: RegisterRequest): Promise<RegisterResponse>;
  activate(request: ActivateRequest): Promise<LoginResponse>;
  challenge(request: ChallengeRequest): Promise<ChallengeResponse>;
  verify(request: VerifyRequest): Promise<LoginResponse>;
  refresh(request: RefreshRequest): Promise<RefreshResponse>;
  logout(request: LogoutRequest): Promise<void>;
  checkHealth(baseUrl: string): Promise<boolean>;
  listResumes(request: ListResumesRequest): Promise<ResumeItem[]>;
  startResume(request: StartResumeRequest): Promise<ResumeSession>;
  resumeThread(request: ResumeThreadRequest): Promise<ResumeSession>;
  sendResumeMessage(request: SendResumeMessageRequest): Promise<ResumeSession>;
  renameResume(request: RenameResumeRequest): Promise<void>;
  deleteResume(request: ResumeMutationRequest): Promise<void>;
  listFiles(request: ListFilesRequest): Promise<ServerFile[]>;
  downloadFile(request: DownloadFileRequest): Promise<DownloadedFile>;
}

export interface RequestHeaders {
  contentType: string;
  authorization: string;
}

export interface RequestOptions {
  method: string;
  headers: RequestHeaders;
  body?: string;
}

export interface GatewayHttpResponse {
  statusCode: number;
  result: string;
}

export interface GatewayBinaryResponse {
  statusCode: number;
  body: ArrayBuffer;
}

export interface GatewayTransport {
  request(url: string, options: RequestOptions): Promise<GatewayHttpResponse>;
  requestBinary(url: string, options: RequestOptions): Promise<GatewayBinaryResponse>;
}

export class GatewayHttpError extends Error {
  public statusCode: number;

  constructor(statusCode: number) {
    super(`Gateway request failed: ${statusCode}`);
    this.statusCode = statusCode;
  }
}

export class GatewayNetworkError extends Error {
  public detail: string;

  constructor(detail: string = '') {
    super('Gateway network request failed');
    this.detail = detail;
  }
}

export function isGatewayAuthenticationError(error: Object): boolean {
  if (!(error instanceof GatewayHttpError)) {
    return false;
  }

  return error.statusCode === 401 || error.statusCode === 403;
}

export function isGatewayNetworkError(error: Object): boolean {
  return error instanceof GatewayNetworkError;
}

interface LoginResponseBody {
  accessToken: string;
  refreshToken: string;
  sessionName: string;
  expiresIn: number;
}

interface RegisterResponseBody {
  activationToken: string;
  challenge: string;
}

interface ChallengeResponseBody {
  nonce: string;
  expiresAt: string;
}

interface RefreshResponseBody {
  accessToken: string;
}

interface HealthResponseBody {
  status: string;
}

interface ListResumesResponseBody {
  items: ResumeItem[];
}

interface ListFilesResponseBody {
  items: ServerFile[];
}

interface ThreadStatus {
  type?: string;
}

interface ResumeThreadBodyThread {
  id?: string;
  name?: string;
  preview?: string;
  cwd?: string;
  status?: string | ThreadStatus;
  turns?: ResumeTurn[];
}

interface ResumeThreadResponseBody {
  threadId?: string;
  title?: string;
  cwd?: string;
  status?: string | ThreadStatus;
  turns?: ResumeTurn[];
  thread?: ResumeThreadBodyThread;
}

class SystemGatewayTransport implements GatewayTransport {
  private session: rcp.Session;
  private caContent: string;

  constructor(caContent: string = '') {
    this.caContent = caContent;
    const timeoutCfg: rcp.Timeout = {
      connectMs: 30000,
      transferMs: 30000
    };
    if (caContent.length > 0) {
      console.info(`[SystemGatewayTransport] Creating session with CA cert, length=${caContent.length}`);
      const caCert: rcp.CertificateAuthority = { content: this.caContent };
      const sessionCfg: rcp.SessionConfiguration = {
        requestConfiguration: {
          transfer: {
            timeout: timeoutCfg
          },
          security: { remoteValidation: caCert }
        }
      };
      this.session = rcp.createSession(sessionCfg);
    } else {
      console.info('[SystemGatewayTransport] Creating session WITHOUT CA cert (default trust)');
      const sessionCfg: rcp.SessionConfiguration = {
        requestConfiguration: {
          transfer: {
            timeout: timeoutCfg
          }
        }
      };
      this.session = rcp.createSession(sessionCfg);
    }
  }

  async request(url: string, options: RequestOptions): Promise<GatewayHttpResponse> {
    const req = new rcp.Request(url, options.method);

    const headers: Record<string, string> = {};
    if (options.headers.contentType.length > 0) {
      headers['content-type'] = options.headers.contentType;
    }
    if (options.headers.authorization.length > 0) {
      headers['authorization'] = options.headers.authorization;
    }
    req.headers = headers;

    if (options.body !== undefined && options.body.length > 0) {
      req.content = options.body;
    }

    try {
      const response = await this.session.fetch(req);
      const result: string = JSON.stringify(response.toJSON());

      return {
        statusCode: response.statusCode,
        result: result
      };
    } catch (error) {
      const detail: string = typeof error === 'object' && error !== null ? JSON.stringify(error) : String(error);
      console.error(`[GatewayTransport] request failed: url=${url}, method=${options.method}, error=${detail}`);
      throw new GatewayNetworkError(detail);
    }
  }

  async requestBinary(url: string, options: RequestOptions): Promise<GatewayBinaryResponse> {
    const req = new rcp.Request(url, options.method);

    const headers: Record<string, string> = {};
    if (options.headers.contentType.length > 0) {
      headers['content-type'] = options.headers.contentType;
    }
    if (options.headers.authorization.length > 0) {
      headers['authorization'] = options.headers.authorization;
    }
    req.headers = headers;

    try {
      const response = await this.session.fetch(req);
      return {
        statusCode: response.statusCode,
        body: response.body !== undefined ? response.body : new ArrayBuffer(0)
      };
    } catch (error) {
      const detail: string = typeof error === 'object' && error !== null ? JSON.stringify(error) : String(error);
      console.error(`[GatewayTransport] requestBinary failed: url=${url}, method=${options.method}, error=${detail}`);
      throw new GatewayNetworkError(detail);
    }
  }
}

export class HttpGatewayClient implements GatewayClient {
  private transport: GatewayTransport;

  constructor(transport: GatewayTransport = new SystemGatewayTransport()) {
    this.transport = transport;
  }

  static createWithCert(certContent: string): HttpGatewayClient {
    return new HttpGatewayClient(new SystemGatewayTransport(certContent));
  }

  async register(request: RegisterRequest): Promise<RegisterResponse> {
    const response = await this.transport.request(joinUrl(request.baseUrl, '/api/auth/register'), {
      method: 'POST',
      headers: {
        contentType: 'application/json',
        authorization: ''
      },
      body: JSON.stringify({
        deviceId: request.deviceId,
        publicKey: request.publicKey,
        registrationCode: request.registrationCode,
        deviceName: request.deviceName
      })
    });
    ensureSuccess(response);

    const body = JSON.parse(response.result) as RegisterResponseBody;
    return {
      activationToken: body.activationToken,
      challenge: body.challenge
    };
  }

  async activate(request: ActivateRequest): Promise<LoginResponse> {
    const response = await this.transport.request(joinUrl(request.baseUrl, '/api/auth/activate'), {
      method: 'POST',
      headers: {
        contentType: 'application/json',
        authorization: ''
      },
      body: JSON.stringify({
        deviceId: request.deviceId,
        activationToken: request.activationToken,
        signedChallenge: request.signedChallenge
      })
    });
    ensureSuccess(response);

    const body = JSON.parse(response.result) as LoginResponseBody;
    return {
      accessToken: body.accessToken,
      refreshToken: body.refreshToken,
      sessionName: 'opencode-main',
      expiresIn: 900
    };
  }

  async challenge(request: ChallengeRequest): Promise<ChallengeResponse> {
    const response = await this.transport.request(joinUrl(request.baseUrl, '/api/auth/challenge'), {
      method: 'POST',
      headers: {
        contentType: 'application/json',
        authorization: ''
      },
      body: JSON.stringify({
        deviceId: request.deviceId
      })
    });
    ensureSuccess(response);

    const body = JSON.parse(response.result) as ChallengeResponseBody;
    return {
      nonce: body.nonce,
      expiresAt: body.expiresAt
    };
  }

  async verify(request: VerifyRequest): Promise<LoginResponse> {
    const response = await this.transport.request(joinUrl(request.baseUrl, '/api/auth/verify'), {
      method: 'POST',
      headers: {
        contentType: 'application/json',
        authorization: ''
      },
      body: JSON.stringify({
        deviceId: request.deviceId,
        nonce: request.nonce,
        signature: request.signature
      })
    });
    ensureSuccess(response);

    const body = JSON.parse(response.result) as LoginResponseBody;
    return {
      accessToken: body.accessToken,
      refreshToken: body.refreshToken,
      sessionName: 'opencode-main',
      expiresIn: 900
    };
  }

  async refresh(request: RefreshRequest): Promise<RefreshResponse> {
    const response = await this.transport.request(joinUrl(request.baseUrl, '/api/auth/refresh'), {
      method: 'POST',
      headers: {
        contentType: 'application/json',
        authorization: ''
      },
      body: JSON.stringify({
        refreshToken: request.refreshToken
      })
    });
    ensureSuccess(response);

    const body = JSON.parse(response.result) as RefreshResponseBody;
    return {
      accessToken: body.accessToken
    };
  }

  async logout(request: LogoutRequest): Promise<void> {
    try {
      await this.transport.request(joinUrl(request.baseUrl, '/api/auth/logout'), {
        method: 'POST',
        headers: {
          contentType: 'application/json',
          authorization: ''
        },
        body: JSON.stringify({
          refreshToken: request.refreshToken
        })
      });
    } catch {
      // Best-effort
    }
  }

  async checkHealth(baseUrl: string): Promise<boolean> {
    const response = await this.transport.request(joinUrl(baseUrl, '/health'), {
      method: 'GET',
      headers: {
        contentType: '',
        authorization: ''
      }
    });
    if (response.statusCode !== 200) {
      return false;
    }
    try {
      const body = JSON.parse(response.result) as HealthResponseBody;
      return body.status === 'ok';
    } catch {
      return false;
    }
  }

  async listResumes(request: ListResumesRequest): Promise<ResumeItem[]> {
    const url = joinUrl(request.baseUrl, OPENCODE_RESUMES_PATH);
    console.info(`[listResumes] 请求 URL: ${url}`);
    const response = await this.transport.request(url, {
      method: 'GET',
      headers: {
        contentType: '',
        authorization: `Bearer ${request.accessToken}`
      }
    });
    ensureSuccess(response);

    const body = JSON.parse(response.result) as ListResumesResponseBody;
    return body.items;
  }

  async startResume(request: StartResumeRequest): Promise<ResumeSession> {
    const response = await this.transport.request(joinUrl(request.baseUrl, OPENCODE_RESUMES_PATH), {
      method: 'POST',
      headers: {
        contentType: 'application/json',
        authorization: `Bearer ${request.accessToken}`
      },
      body: JSON.stringify({
        cwd: normalizeString(request.cwd)
      })
    });
    ensureSuccess(response);

    return toResumeSession(JSON.parse(response.result) as ResumeThreadResponseBody, '');
  }

  async resumeThread(request: ResumeThreadRequest): Promise<ResumeSession> {
    const response = await this.transport.request(
      joinUrl(request.baseUrl, `${OPENCODE_RESUMES_PATH}/${encodeURIComponent(request.threadId)}/resume`),
      {
        method: 'POST',
        headers: {
          contentType: 'application/json',
          authorization: `Bearer ${request.accessToken}`
        },
        body: JSON.stringify({
          threadId: request.threadId
        })
      }
    );
    ensureSuccess(response);

    return toResumeSession(JSON.parse(response.result) as ResumeThreadResponseBody, request.threadId);
  }

  async sendResumeMessage(request: SendResumeMessageRequest): Promise<ResumeSession> {
    const response = await this.transport.request(
      joinUrl(request.baseUrl, `${OPENCODE_RESUMES_PATH}/${encodeURIComponent(request.threadId)}/messages`),
      {
        method: 'POST',
        headers: {
          contentType: 'application/json',
          authorization: `Bearer ${request.accessToken}`
        },
        body: JSON.stringify({
          message: request.message
        })
      }
    );
    ensureSuccess(response);

    return toResumeSession(JSON.parse(response.result) as ResumeThreadResponseBody, request.threadId);
  }

  async renameResume(request: RenameResumeRequest): Promise<void> {
    const response = await this.transport.request(
      joinUrl(request.baseUrl, `${OPENCODE_RESUMES_PATH}/${encodeURIComponent(request.threadId)}/name`),
      {
        method: 'POST',
        headers: {
          contentType: 'application/json',
          authorization: `Bearer ${request.accessToken}`
        },
        body: JSON.stringify({
          name: request.name
        })
      }
    );
    ensureSuccess(response);
  }

  async deleteResume(request: ResumeMutationRequest): Promise<void> {
    const response = await this.transport.request(
      joinUrl(request.baseUrl, `${OPENCODE_RESUMES_PATH}/${encodeURIComponent(request.threadId)}`),
      {
        method: 'DELETE',
        headers: {
          contentType: '',
          authorization: `Bearer ${request.accessToken}`
        }
      }
    );
    ensureSuccess(response);
  }

  async listFiles(request: ListFilesRequest): Promise<ServerFile[]> {
    const url = joinUrl(request.baseUrl, FILES_PATH);
    console.info(`[listFiles] 请求 URL: ${url}`);
    const response = await this.transport.request(url, {
      method: 'GET',
      headers: {
        contentType: '',
        authorization: `Bearer ${request.accessToken}`
      }
    });
    ensureSuccess(response);

    const body = JSON.parse(response.result) as ListFilesResponseBody;
    return body.items;
  }

  async downloadFile(request: DownloadFileRequest): Promise<DownloadedFile> {
    const url = joinUrl(request.baseUrl, `${FILES_PATH}/${encodeURIComponent(request.fileName)}/download`);
    console.info(`[downloadFile] 请求 URL: ${url}`);
    const response = await this.transport.requestBinary(url, {
      method: 'GET',
      headers: {
        contentType: '',
        authorization: `Bearer ${request.accessToken}`
      }
    });
    ensureSuccessCode(response.statusCode);

    return {
      name: request.fileName,
      bytes: response.body
    };
  }
}

export class MockGatewayClient implements GatewayClient {
  async checkHealth(baseUrl: string): Promise<boolean> {
    return true;
  }

  async register(request: RegisterRequest): Promise<RegisterResponse> {
    return {
      activationToken: 'act-mock-001',
      challenge: 'mock-challenge'
    };
  }

  async activate(request: ActivateRequest): Promise<LoginResponse> {
    return {
      accessToken: 'router_access_mock',
      refreshToken: 'router_refresh_mock',
      sessionName: 'opencode-main',
      expiresIn: 900
    };
  }

  async challenge(request: ChallengeRequest): Promise<ChallengeResponse> {
    return {
      nonce: 'mock-nonce',
      expiresAt: new Date(Date.now() + 120000).toISOString()
    };
  }

  async verify(request: VerifyRequest): Promise<LoginResponse> {
    return {
      accessToken: 'router_access_mock',
      refreshToken: 'router_refresh_mock',
      sessionName: 'opencode-main',
      expiresIn: 900
    };
  }

  async refresh(request: RefreshRequest): Promise<RefreshResponse> {
    return {
      accessToken: 'router_access_mock_refreshed'
    };
  }

  async logout(request: LogoutRequest): Promise<void> {
  }

  async listResumes(request: ListResumesRequest): Promise<ResumeItem[]> {
    return [
      {
        id: 'thread-login-fix',
        title: 'Fix router login',
        subtitle: '/srv/projects/codex-router',
        status: 'completed',
        updatedAt: '2026-07-02T10:54:44.000Z'
      },
      {
        id: 'thread-backend',
        title: 'Bridge OpenCode app-server',
        subtitle: '/srv/projects/codex-router',
        status: 'running',
        updatedAt: '2026-07-02T11:20:00.000Z'
      }
    ];
  }

  async startResume(request: StartResumeRequest): Promise<ResumeSession> {
    return {
      threadId: 'thread-new',
      title: 'New OpenCode Resume',
      cwd: normalizeString(request.cwd) || DEFAULT_RESUME_CWD,
      status: 'running',
      turns: []
    };
  }

  async resumeThread(request: ResumeThreadRequest): Promise<ResumeSession> {
    return {
      threadId: request.threadId,
      title: request.threadId === 'thread-login-fix' ? 'Fix router login' : 'Bridge OpenCode app-server',
      cwd: '/srv/projects/codex-router',
      status: 'running',
      turns: [
        {
          id: 'turn-mock',
          status: 'completed',
          startedAt: '2026-07-02T10:54:44.000Z',
          completedAt: '2026-07-02T10:55:00.000Z',
          items: [
            {
              id: 'turn-mock:item-1',
              role: 'user',
              kind: 'message',
              text: 'Open saved OpenCode session',
              status: ''
            },
            {
              id: 'turn-mock:item-2',
              role: 'assistant',
              kind: 'message',
              text: 'Loaded session content from OpenCode.',
              status: ''
            }
          ]
        }
      ]
    };
  }

  async sendResumeMessage(request: SendResumeMessageRequest): Promise<ResumeSession> {
    const session = await this.resumeThread({
      baseUrl: request.baseUrl,
      accessToken: request.accessToken,
      threadId: request.threadId
    });
    return {
      threadId: session.threadId,
      title: session.title,
      cwd: session.cwd,
      status: 'running',
      turns: session.turns.concat([
        {
          id: 'turn-mock-reply',
          status: 'completed',
          startedAt: '2026-07-02T11:00:00.000Z',
          completedAt: '2026-07-02T11:01:00.000Z',
          items: [
            {
              id: 'turn-mock-reply:item-1',
              role: 'user',
              kind: 'message',
              text: request.message,
              status: ''
            },
            {
              id: 'turn-mock-reply:item-2',
              role: 'assistant',
              kind: 'message',
              text: 'Mock reply from OpenCode.',
              status: ''
            }
          ]
        }
      ])
    };
  }

  async renameResume(_request: RenameResumeRequest): Promise<void> {
  }

  async deleteResume(_request: ResumeMutationRequest): Promise<void> {
  }

  async listFiles(_request: ListFilesRequest): Promise<ServerFile[]> {
    return [
      {
        name: '红楼梦第一节课.pptx',
        size: 39610,
        modifiedAt: '2026-09-02T08:43:38.000Z'
      },
      {
        name: '调研报告.docx',
        size: 25410,
        modifiedAt: '2026-09-01T03:20:00.000Z'
      }
    ];
  }

  async downloadFile(_request: DownloadFileRequest): Promise<DownloadedFile> {
    return {
      name: _request.fileName,
      bytes: new ArrayBuffer(0)
    };
  }
}

function toResumeSession(body: ResumeThreadResponseBody, fallbackThreadId: string): ResumeSession {
  const thread = body.thread;
  const status = body.status !== undefined ? body.status : thread?.status;
  const title = normalizeString(body.title) || normalizeString(thread?.name) || normalizeString(thread?.preview) ||
    fallbackThreadId;

  return {
    threadId: normalizeString(body.threadId) || normalizeString(thread?.id) || fallbackThreadId,
    title,
    cwd: normalizeString(body.cwd) || normalizeString(thread?.cwd),
    status: normalizeStatus(status),
    turns: normalizeTurns(body.turns !== undefined ? body.turns : thread?.turns)
  };
}

function normalizeTurns(value: ResumeTurn[] | undefined): ResumeTurn[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.map((turn: ResumeTurn, turnIndex: number) => {
    const turnId = normalizeString(turn.id) || `turn-${turnIndex + 1}`;
    const normalized: ResumeTurn = {
      id: turnId,
      status: normalizeString(turn.status) || 'unknown',
      startedAt: normalizeString(turn.startedAt),
      completedAt: normalizeString(turn.completedAt),
      items: normalizeItems(turn.items, turnId)
    };
    return normalized;
  }).filter((turn: ResumeTurn) => turn.items.length > 0 || isActiveResumeTurnStatus(turn.status));
}

function normalizeItems(value: ResumeContentItem[], turnId: string): ResumeContentItem[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.map((item: ResumeContentItem, itemIndex: number) => {
    const normalized: ResumeContentItem = {
      id: normalizeString(item.id) || `${turnId}:item-${itemIndex + 1}`,
      role: normalizeString(item.role) || 'system',
      kind: normalizeString(item.kind) || 'message',
      text: normalizeString(item.text),
      status: normalizeString(item.status)
    };
    return normalized;
  }).filter((item: ResumeContentItem) => item.text.length > 0);
}

function normalizeString(value: string | undefined): string {
  if (typeof value !== 'string') {
    return '';
  }

  return value.trim();
}

function normalizeStatus(value: string | ThreadStatus | undefined): string {
  if (typeof value === 'string') {
    return value;
  }

  if (value && typeof value.type === 'string') {
    return value.type;
  }

  return 'unknown';
}

function isActiveResumeTurnStatus(status: string): boolean {
  return status === 'inProgress' || status === 'running' || status === 'queued' || status === 'in_progress';
}

function joinUrl(baseUrl: string, path: string): string {
  return `${baseUrl.replace(/\/+$/, '')}${path}`;
}

function ensureSuccess(response: GatewayHttpResponse): void {
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw new GatewayHttpError(response.statusCode);
  }
}

function ensureSuccessCode(statusCode: number): void {
  if (statusCode < 200 || statusCode >= 300) {
    throw new GatewayHttpError(statusCode);
  }
}
