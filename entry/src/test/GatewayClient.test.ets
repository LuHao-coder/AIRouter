import { describe, expect, it } from '@ohos/hypium';
import {
  ActivateRequest,
  ChallengeRequest,
  RegisterRequest,
  RefreshRequest,
  ResumeItem,
  ResumeSession,
  VerifyRequest,
  GatewayHttpError,
  GatewayHttpResponse,
  GatewayNetworkError,
  GatewayTransport,
  HttpGatewayClient,
  isGatewayAuthenticationError,
  isGatewayNetworkError,
  MockGatewayClient,
  RequestOptions
} from '../main/ets/api/GatewayClient';

export default function gatewayClientTest() {
  describe('gatewayClient', () => {
    it('registers a device through the mock client', 0, async () => {
      const client = new MockGatewayClient();

      const result = await client.register({
        baseUrl: 'https://192.168.1.10:8443',
        deviceId: 'dev-1',
        publicKey: 'public-key',
        registrationCode: 'code-1',
        deviceName: 'HarmonyOS Phone'
      });

      expect(result.activationToken).assertEqual('act-mock-001');
      expect(result.challenge).assertEqual('mock-challenge');
    });

    it('activates a device and returns tokens through the mock client', 0, async () => {
      const client = new MockGatewayClient();

      const result = await client.activate({
        baseUrl: 'https://192.168.1.10:8443',
        deviceId: 'dev-1',
        activationToken: 'act-mock-001',
        signedChallenge: 'signed'
      });

      expect(result.sessionName).assertEqual('opencode-main');
      expect(result.accessToken).assertEqual('router_access_mock');
      expect(result.refreshToken).assertEqual('router_refresh_mock');
      expect(result.expiresIn).assertEqual(900);
    });

    it('challenges an already-registered device through the mock client', 0, async () => {
      const client = new MockGatewayClient();

      const result = await client.challenge({
        baseUrl: 'https://192.168.1.10:8443',
        deviceId: 'dev-1'
      });

      expect(result.nonce).assertEqual('mock-nonce');
      expect(result.expiresAt.length > 0).assertEqual(true);
    });

    it('verifies a challenge signature and returns tokens through the mock client', 0, async () => {
      const client = new MockGatewayClient();

      const result = await client.verify({
        baseUrl: 'https://192.168.1.10:8443',
        deviceId: 'dev-1',
        nonce: 'mock-nonce',
        signature: 'signed'
      });

      expect(result.sessionName).assertEqual('opencode-main');
      expect(result.accessToken).assertEqual('router_access_mock');
      expect(result.refreshToken).assertEqual('router_refresh_mock');
      expect(result.expiresIn).assertEqual(900);
    });

    it('refreshes an access token through the mock client', 0, async () => {
      const client = new MockGatewayClient();

      const result = await client.refresh({
        baseUrl: 'https://192.168.1.10:8443',
        refreshToken: 'router_refresh_mock'
      });

      expect(result.accessToken).assertEqual('router_access_mock_refreshed');
    });

    it('returns resume items from gateway', 0, async () => {
      const client = new MockGatewayClient();

      const result: ResumeItem[] = await client.listResumes({
        baseUrl: 'https://192.168.1.10:8443',
        accessToken: 'router_access_mock'
      });

      expect(result.length).assertEqual(2);
      expect(result[0].id).assertEqual('thread-login-fix');
      expect(result[0].title).assertEqual('Fix router login');
      expect(result[0].status).assertEqual('completed');
    });

    it('starts a new mock resume session', 0, async () => {
      const client = new MockGatewayClient();

      const result: ResumeSession = await client.startResume({
        baseUrl: 'https://192.168.1.10:8443',
        accessToken: 'router_access_mock',
        cwd: '/srv/projects/codex-router'
      });

      expect(result.threadId).assertEqual('thread-new');
      expect(result.title).assertEqual('New OpenCode Resume');
      expect(result.cwd).assertEqual('/srv/projects/codex-router');
      expect(result.turns.length).assertEqual(0);
    });

    it('starts a new mock resume session in home by default', 0, async () => {
      const client = new MockGatewayClient();

      const result: ResumeSession = await client.startResume({
        baseUrl: 'https://192.168.1.10:8443',
        accessToken: 'router_access_mock'
      });

      expect(result.threadId).assertEqual('thread-new');
      expect(result.cwd).assertEqual('~');
      expect(result.turns.length).assertEqual(0);
    });

    it('posts register request to gateway https api', 0, async () => {
      const transport = new RecordingTransport();
      transport.nextResponse = {
        statusCode: 200,
        result: '{"activationToken":"act-1","challenge":"challenge-1"}'
      };
      const client = new HttpGatewayClient(transport);

      const request: RegisterRequest = {
        baseUrl: 'https://192.168.1.10:8443',
        deviceId: 'dev-1',
        publicKey: 'public-key',
        registrationCode: 'code-1',
        deviceName: 'HarmonyOS Phone'
      };
      const result = await client.register(request);

      expect(transport.lastUrl).assertEqual('https://192.168.1.10:8443/api/auth/register');
      expect(transport.lastOptions.method).assertEqual('POST');
      expect(transport.lastOptions.headers.contentType).assertEqual('application/json');
      expect(transport.lastOptions.body)
        .assertEqual('{"deviceId":"dev-1","publicKey":"public-key","registrationCode":"code-1","deviceName":"HarmonyOS Phone"}');
      expect(result.activationToken).assertEqual('act-1');
      expect(result.challenge).assertEqual('challenge-1');
    });

    it('posts activate request to gateway https api', 0, async () => {
      const transport = new RecordingTransport();
      transport.nextResponse = {
        statusCode: 200,
        result: '{"accessToken":"access-1","refreshToken":"refresh-1"}'
      };
      const client = new HttpGatewayClient(transport);

      const request: ActivateRequest = {
        baseUrl: 'https://192.168.1.10:8443',
        deviceId: 'dev-1',
        activationToken: 'act-1',
        signedChallenge: 'signed-1'
      };
      const result = await client.activate(request);

      expect(transport.lastUrl).assertEqual('https://192.168.1.10:8443/api/auth/activate');
      expect(transport.lastOptions.method).assertEqual('POST');
      expect(transport.lastOptions.headers.contentType).assertEqual('application/json');
      expect(transport.lastOptions.body)
        .assertEqual('{"deviceId":"dev-1","activationToken":"act-1","signedChallenge":"signed-1"}');
      expect(result.accessToken).assertEqual('access-1');
      expect(result.refreshToken).assertEqual('refresh-1');
      expect(result.sessionName).assertEqual('opencode-main');
      expect(result.expiresIn).assertEqual(900);
    });

    it('posts challenge request to gateway https api', 0, async () => {
      const transport = new RecordingTransport();
      transport.nextResponse = {
        statusCode: 200,
        result: '{"nonce":"nonce-1","expiresAt":"2026-07-02T12:00:00.000Z"}'
      };
      const client = new HttpGatewayClient(transport);

      const request: ChallengeRequest = {
        baseUrl: 'https://192.168.1.10:8443',
        deviceId: 'dev-1'
      };
      const result = await client.challenge(request);

      expect(transport.lastUrl).assertEqual('https://192.168.1.10:8443/api/auth/challenge');
      expect(transport.lastOptions.method).assertEqual('POST');
      expect(transport.lastOptions.body).assertEqual('{"deviceId":"dev-1"}');
      expect(result.nonce).assertEqual('nonce-1');
      expect(result.expiresAt).assertEqual('2026-07-02T12:00:00.000Z');
    });

    it('posts verify request to gateway https api', 0, async () => {
      const transport = new RecordingTransport();
      transport.nextResponse = {
        statusCode: 200,
        result: '{"accessToken":"access-1","refreshToken":"refresh-1"}'
      };
      const client = new HttpGatewayClient(transport);

      const request: VerifyRequest = {
        baseUrl: 'https://192.168.1.10:8443',
        deviceId: 'dev-1',
        nonce: 'nonce-1',
        signature: 'signed-1'
      };
      const result = await client.verify(request);

      expect(transport.lastUrl).assertEqual('https://192.168.1.10:8443/api/auth/verify');
      expect(transport.lastOptions.method).assertEqual('POST');
      expect(transport.lastOptions.body)
        .assertEqual('{"deviceId":"dev-1","nonce":"nonce-1","signature":"signed-1"}');
      expect(result.accessToken).assertEqual('access-1');
      expect(result.refreshToken).assertEqual('refresh-1');
    });

    it('posts refresh request to gateway https api', 0, async () => {
      const transport = new RecordingTransport();
      transport.nextResponse = {
        statusCode: 200,
        result: '{"accessToken":"access-2"}'
      };
      const client = new HttpGatewayClient(transport);

      const request: RefreshRequest = {
        baseUrl: 'https://192.168.1.10:8443',
        refreshToken: 'refresh-1'
      };
      const result = await client.refresh(request);

      expect(transport.lastUrl).assertEqual('https://192.168.1.10:8443/api/auth/refresh');
      expect(transport.lastOptions.method).assertEqual('POST');
      expect(transport.lastOptions.body).assertEqual('{"refreshToken":"refresh-1"}');
      expect(result.accessToken).assertEqual('access-2');
    });

    it('propagates network errors without trying another gateway address', 0, async () => {
      const transport = new FailingTransport();
      const client = new HttpGatewayClient(transport);
      let failed = false;

      try {
        await client.register({
          baseUrl: 'https://172.16.1.186:8443',
          deviceId: 'dev-1',
          publicKey: 'public-key',
          registrationCode: 'code-1',
          deviceName: 'HarmonyOS Phone'
        });
      } catch (error) {
        failed = true;
      }

      expect(failed).assertEqual(true);
      expect(transport.requestedUrls.length).assertEqual(1);
      expect(transport.requestedUrls[0]).assertEqual('https://172.16.1.186:8443/api/auth/register');
    });

    it('gets resume items from gateway https api with bearer token', 0, async () => {
      const transport = new RecordingTransport();
      transport.nextResponse = {
        statusCode: 200,
        result: '{"items":[{"id":"thread-1","title":"Fix router login","subtitle":"/srv/projects/codex-router","status":"notLoaded","updatedAt":"2026-07-02T11:05:40.000Z"}]}'
      };
      const client = new HttpGatewayClient(transport);

      const result: ResumeItem[] = await client.listResumes({
        baseUrl: 'https://192.168.1.10:8443/',
        accessToken: 'access-1'
      });

      expect(transport.lastUrl).assertEqual('https://192.168.1.10:8443/api/opencode/resumes');
      expect(transport.lastOptions.method).assertEqual('GET');
      expect(transport.lastOptions.headers.authorization).assertEqual('Bearer access-1');
      expect(result.length).assertEqual(1);
      expect(result[0].id).assertEqual('thread-1');
      expect(result[0].status).assertEqual('notLoaded');
    });

    it('routes OpenCode resume requests to the opencode backend path', 0, async () => {
      const transport = new RecordingTransport();
      transport.nextResponse = {
        statusCode: 200,
        result: '{"threadId":"thread-new","title":"New OpenCode Resume","cwd":"~","status":"running","turns":[]}'
      };
      const client = new HttpGatewayClient(transport);

      await client.startResume({
        baseUrl: 'https://192.168.1.10:8443/',
        accessToken: 'access-1'
      });

      expect(transport.lastUrl).assertEqual('https://192.168.1.10:8443/api/opencode/resumes');
    });

    it('starts a new resume session through gateway https api', 0, async () => {
      const transport = new RecordingTransport();
      transport.nextResponse = {
        statusCode: 200,
        result: '{"threadId":"thread-new","title":"New OpenCode Resume","cwd":"/srv/projects/codex-router","status":"running","turns":[]}'
      };
      const client = new HttpGatewayClient(transport);

      const result: ResumeSession = await client.startResume({
        baseUrl: 'https://192.168.1.10:8443/',
        accessToken: 'access-1',
        cwd: '/srv/projects/codex-router'
      });

      expect(transport.lastUrl).assertEqual('https://192.168.1.10:8443/api/opencode/resumes');
      expect(transport.lastOptions.method).assertEqual('POST');
      expect(transport.lastOptions.headers.authorization).assertEqual('Bearer access-1');
      expect(transport.lastOptions.headers.contentType).assertEqual('application/json');
      expect(transport.lastOptions.body).assertEqual('{"cwd":"/srv/projects/codex-router"}');
      expect(result.threadId).assertEqual('thread-new');
      expect(result.status).assertEqual('running');
      expect(result.turns.length).assertEqual(0);
    });

    it('resumes a thread through gateway https api with bearer token', 0, async () => {
      const transport = new RecordingTransport();
      transport.nextResponse = {
        statusCode: 200,
        result: '{"threadId":"thread-1","title":"Fix router login","cwd":"/srv/projects/codex-router","status":"running","turns":[{"id":"turn-1","status":"completed","startedAt":"2026-07-02T10:54:44.000Z","completedAt":"2026-07-02T10:55:00.000Z","items":[{"id":"turn-1:item-1","role":"user","kind":"message","text":"真机调试失败","status":""},{"id":"turn-1:item-2","role":"assistant","kind":"message","text":"检查 HDC reverse。","status":""}]}]}'
      };
      const client = new HttpGatewayClient(transport);

      const result: ResumeSession = await client.resumeThread({
        baseUrl: 'https://192.168.1.10:8443/',
        accessToken: 'access-1',
        threadId: 'thread-1'
      });

      expect(transport.lastUrl).assertEqual('https://192.168.1.10:8443/api/opencode/resumes/thread-1/resume');
      expect(transport.lastOptions.method).assertEqual('POST');
      expect(transport.lastOptions.headers.authorization).assertEqual('Bearer access-1');
      expect(result.threadId).assertEqual('thread-1');
      expect(result.title).assertEqual('Fix router login');
      expect(result.cwd).assertEqual('/srv/projects/codex-router');
      expect(result.status).assertEqual('running');
      expect(result.turns.length).assertEqual(1);
      expect(result.turns[0].items.length).assertEqual(2);
      expect(result.turns[0].items[0].text).assertEqual('真机调试失败');
    });

    it('sends a message to a resume thread through gateway https api', 0, async () => {
      const transport = new RecordingTransport();
      transport.nextResponse = {
        statusCode: 200,
        result: '{"threadId":"thread-1","title":"Fix router login","cwd":"/srv/projects/codex-router","status":"running","turns":[{"id":"turn-2","status":"completed","startedAt":"2026-07-02T11:00:00.000Z","completedAt":"2026-07-02T11:01:00.000Z","items":[{"id":"turn-2:item-1","role":"user","kind":"message","text":"继续检查真机交互","status":""},{"id":"turn-2:item-2","role":"assistant","kind":"message","text":"已收到，继续处理。","status":""}]}]}'
      };
      const client = new HttpGatewayClient(transport);

      const result: ResumeSession = await client.sendResumeMessage({
        baseUrl: 'https://192.168.1.10:8443/',
        accessToken: 'access-1',
        threadId: 'thread-1',
        message: '继续检查真机交互'
      });

      expect(transport.lastUrl).assertEqual('https://192.168.1.10:8443/api/opencode/resumes/thread-1/messages');
      expect(transport.lastOptions.method).assertEqual('POST');
      expect(transport.lastOptions.headers.authorization).assertEqual('Bearer access-1');
      expect(transport.lastOptions.body).assertEqual('{"message":"继续检查真机交互"}');
      expect(result.turns.length).assertEqual(1);
      expect(result.turns[0].items[1].text).assertEqual('已收到，继续处理。');
    });

    it('renames a resume thread through gateway https api', 0, async () => {
      const transport = new RecordingTransport();
      const client = new HttpGatewayClient(transport);

      await client.renameResume({
        baseUrl: 'https://192.168.1.10:8443/',
        accessToken: 'access-1',
        threadId: 'thread-1',
        name: '真机调试'
      });

      expect(transport.lastUrl).assertEqual('https://192.168.1.10:8443/api/opencode/resumes/thread-1/name');
      expect(transport.lastOptions.method).assertEqual('POST');
      expect(transport.lastOptions.headers.authorization).assertEqual('Bearer access-1');
      expect(transport.lastOptions.headers.contentType).assertEqual('application/json');
      expect(transport.lastOptions.body).assertEqual('{"name":"真机调试"}');
    });

    it('deletes a resume thread through gateway https api', 0, async () => {
      const transport = new RecordingTransport();
      const client = new HttpGatewayClient(transport);

      await client.deleteResume({
        baseUrl: 'https://192.168.1.10:8443/',
        accessToken: 'access-1',
        threadId: 'thread-1'
      });

      expect(transport.lastUrl).assertEqual('https://192.168.1.10:8443/api/opencode/resumes/thread-1');
      expect(transport.lastOptions.method).assertEqual('DELETE');
      expect(transport.lastOptions.headers.authorization).assertEqual('Bearer access-1');
    });

    it('throws when gateway http api returns an error status', 0, async () => {
      const transport = new RecordingTransport();
      transport.nextResponse = {
        statusCode: 500,
        result: '{"error":{"code":"gateway_unavailable"}}'
      };
      const client = new HttpGatewayClient(transport);
      let failed = false;

      try {
        await client.listResumes({
          baseUrl: 'https://192.168.1.10:8443',
          accessToken: 'access-1'
        });
      } catch (error) {
        failed = true;
      }

      expect(failed).assertEqual(true);
    });

    it('identifies gateway authentication errors', 0, () => {
      expect(isGatewayAuthenticationError(new GatewayHttpError(401))).assertEqual(true);
      expect(isGatewayAuthenticationError(new GatewayHttpError(403))).assertEqual(true);
      expect(isGatewayAuthenticationError(new GatewayHttpError(500))).assertEqual(false);
      expect(isGatewayAuthenticationError(new Error('network'))).assertEqual(false);
    });

    it('identifies gateway network errors', 0, () => {
      expect(isGatewayNetworkError(new GatewayNetworkError())).assertEqual(true);
      expect(isGatewayNetworkError(new GatewayHttpError(500))).assertEqual(false);
      expect(isGatewayNetworkError(new Error('network'))).assertEqual(false);
    });
  });
}

class RecordingTransport implements GatewayTransport {
  public lastUrl: string = '';
  public lastOptions: RequestOptions = {
    method: 'GET',
    headers: {
      contentType: '',
      authorization: ''
    }
  };
  public nextResponse: GatewayHttpResponse = {
    statusCode: 200,
    result: '{}'
  };

  async request(url: string, options: RequestOptions): Promise<GatewayHttpResponse> {
    this.lastUrl = url;
    this.lastOptions = options;
    return this.nextResponse;
  }
}

class FailingTransport implements GatewayTransport {
  public requestedUrls: string[] = [];

  async request(url: string, _options: RequestOptions): Promise<GatewayHttpResponse> {
    this.requestedUrls.push(url);
    throw new Error('network timeout');
  }
}
