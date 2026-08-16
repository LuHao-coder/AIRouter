import { describe, expect, it } from '@ohos/hypium';
import {
  appendSavedConnection,
  canAddConnection,
  generateSavedConnectionId,
  hasConnectionWithSameEndpoint,
  ConnectionFormErrors,
  normalizeServerAddress,
  resolveCarouselIndex,
  resolveCarouselSwipeIndex,
  resolveConnectionSwiperReleaseIndex,
  resolveAddConnectionCardOffset,
  resolveAddConnectionCardWidth,
  resolveAddConnectionMeasuredCardHeight,
  resolveAddConnectionResponsiveCardOffset,
  resolveConnectionCardTitle,
  resolveConnectionDisplayName,
  resolveConnectionFormErrors,
  ConnectionCarouselSelection,
  resolveActiveConnectionId,
  resolveConnectionIndexById,
  resolveConnectionIdByIndex,
  resolveConnectionSelectionBySwiperIndex,
  resolveConnectionCardSwitchGapReduction,
  resolveConnectionCardSwitchOffset,
  resolveConnectionCardScale,
  shouldClearConnectionResumeCache,
  resolveConnectionSwiperAutoPlay,
  resolveConnectionSwiperDisableSwipe,
  resolveConnectionSwiperItemSpace,
  resolveConnectedCardListHorizontalPadding,
  resolveConnectedCardPageHorizontalInset,
  resolveConnectionReadinessError,
  resolveConnectionSwitchIntent,
  resolveConnectedTitleOffset,
  resolveConnectionName,
  resolveResumeCountText,
  resolveResumeCardActionLabel,
  resolveResumeContentScaledSize,
  resolveResumeContentInitialZoomScale,
  resolveResumeContentZoomScale,
  resolveResumeDiffLineContext,
  resolveResumeDirectoryText,
  resolveResumeDiffLineTextStyle,
  resolveResumeTimestampText,
  resolveResumeFeedbackAction,
  shouldApplyConnectionResumeRefresh,
  shouldShowAgentOutputDot,
  resolveWaitingResponseText,
  removeSavedConnection,
  SavedConnection,
  sortConnectionsByLastUsed,
  updateSavedConnection,
  updateSavedConnectionStatus,
  visibleResumePreviewCount
} from '../main/ets/model/ConnectionModel';

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

export default function connectionModelTest() {
  describe('connectionModel', () => {
    it('normalizes bare ip to https gateway default port', 0, () => {
      const result = normalizeServerAddress('192.168.1.10');

      expect(result.scheme).assertEqual('https');
      expect(result.host).assertEqual('192.168.1.10');
      expect(result.port).assertEqual(8443);
      expect(result.baseUrl).assertEqual('https://192.168.1.10:8443');
    });

    it('normalizes host with explicit port', 0, () => {
      const result = normalizeServerAddress('192.168.1.10:9000');

      expect(result.scheme).assertEqual('https');
      expect(result.host).assertEqual('192.168.1.10');
      expect(result.port).assertEqual(9000);
      expect(result.baseUrl).assertEqual('https://192.168.1.10:9000');
    });

    it('normalizes https domain without explicit port', 0, () => {
      const result = normalizeServerAddress('https://codex.example.com');

      expect(result.scheme).assertEqual('https');
      expect(result.host).assertEqual('codex.example.com');
      expect(result.port).assertEqual(8443);
      expect(result.baseUrl).assertEqual('https://codex.example.com:8443');
    });

    it('resolves connection name by custom name then host', 0, () => {
      expect(resolveConnectionName('Work Server', 'codex-main', 'alice', '192.168.1.10'))
        .assertEqual('Work Server');
      expect(resolveConnectionName('', 'codex-main', 'alice', '192.168.1.10'))
        .assertEqual('192.168.1.10');
      expect(resolveConnectionName('', '', 'alice', '192.168.1.10'))
        .assertEqual('192.168.1.10');
    });

    it('formats connection card title as ip', 0, () => {
      const saved = connection('10', '2026-07-01T10:00:00+08:00');
      saved.host = '172.16.1.186';

      expect(resolveConnectionCardTitle(saved)).assertEqual('172.16.1.186');
    });

    it('allows no more than five saved connections', 0, () => {
      const fourConnections: SavedConnection[] = [
        connection('1', '2026-07-01T10:00:00+08:00'),
        connection('2', '2026-07-01T10:01:00+08:00'),
        connection('3', '2026-07-01T10:02:00+08:00'),
        connection('4', '2026-07-01T10:03:00+08:00')
      ];
      const fiveConnections = fourConnections.concat([connection('5', '2026-07-01T10:04:00+08:00')]);

      expect(canAddConnection(fourConnections)).assertEqual(true);
      expect(canAddConnection(fiveConnections)).assertEqual(false);
    });

    it('uses ip as the saved connection id', 0, () => {
      expect(generateSavedConnectionId('172.16.1.186')).assertEqual('172.16.1.186');
      expect(generateSavedConnectionId(' 172.16.1.186 ')).assertEqual('172.16.1.186');
      expect(generateSavedConnectionId('LOCALHOST')).assertEqual('localhost');
    });

    it('detects duplicate saved ip identities while ignoring the current connection', 0, () => {
      const first = connection('172.16.1.186', '2026-07-01T10:00:00+08:00');
      first.host = '172.16.1.186';
      first.port = 8443;
      first.scheme = 'https';
      const second = connection('172.16.1.187', '2026-07-01T11:00:00+08:00');
      second.host = '172.16.1.187';
      second.port = 8443;
      second.scheme = 'https';

      expect(hasConnectionWithSameEndpoint([first, second], 'https', '172.16.1.186', 8443, ''))
        .assertEqual(true);
      expect(hasConnectionWithSameEndpoint([first, second], 'https', '172.16.1.186', 8443,
        '172.16.1.186'))
        .assertEqual(false);
      expect(hasConnectionWithSameEndpoint([first, second], 'http', '172.16.1.186', 9000, ''))
        .assertEqual(true);
    });

    it('sorts connections by last used time descending without mutating input', 0, () => {
      const older = connection('1', '2026-07-01T10:00:00+08:00');
      const newer = connection('2', '2026-07-01T11:00:00+08:00');
      const input = [older, newer];

      const result = sortConnectionsByLastUsed(input);

      expect(result[0].id).assertEqual('2');
      expect(result[1].id).assertEqual('1');
      expect(input[0].id).assertEqual('1');
    });

    it('updates selected connection without changing id when ip stays the same', 0, () => {
      const original = connection('172.16.1.186', '2026-07-01T10:00:00+08:00');
      original.agent = 'OpenCode';
      original.host = '172.16.1.186';
      original.status = 'online';
      const other = connection('172.16.1.187', '2026-07-01T11:00:00+08:00');
      const result = updateSavedConnection([original, other], {
        id: '172.16.1.186',
        name: 'Work Router',
        agent: 'OpenCode',
        host: '172.16.1.186',
        port: 9443,
        scheme: 'http',
        username: 'bob',
        lastUsedAt: '2026-07-01T12:00:00+08:00'
      });

      expect(result.length).assertEqual(2);
      expect(result[0].id).assertEqual('172.16.1.186');
      expect(result[0].name).assertEqual('Work Router');
      expect(result[0].agent).assertEqual('OpenCode');
      expect(result[0].host).assertEqual('172.16.1.186');
      expect(result[0].port).assertEqual(9443);
      expect(result[0].username).assertEqual('bob');
      expect(result[0].status).assertEqual('online');
      expect(result[0].accessTokenRef).assertEqual('access-172.16.1.186');
      expect(result[0].privateKeyRef).assertEqual('private-key-172.16.1.186');
      expect(result[1].id).assertEqual('172.16.1.187');
    });

    it('replaces the saved connection id when editing changes ip', 0, () => {
      const original = connection('172.16.1.235', '2026-07-01T10:00:00+08:00');
      original.agent = 'OpenCode';
      original.host = '172.16.1.235';

      const result = updateSavedConnection([original], {
        id: '172.16.1.235',
        name: 'Win Router',
        agent: 'OpenCode',
        host: '172.16.1.186',
        port: 8443,
        scheme: 'https',
        username: '',
        lastUsedAt: '2026-07-01T12:00:00+08:00',
        accessTokenRef: 'access-new',
        refreshTokenRef: 'refresh-new',
        privateKeyRef: 'private-new'
      });

      expect(result.length).assertEqual(1);
      expect(result[0].id).assertEqual('172.16.1.186');
      expect(result[0].host).assertEqual('172.16.1.186');
      expect(result[0].accessTokenRef).assertEqual('access-new');
      expect(result[0].privateKeyRef).assertEqual('private-new');
    });

    it('resolves display name from the latest connection state', 0, () => {
      const stale = connection('1', '2026-07-01T10:00:00+08:00');
      stale.name = 'Old Router';
      const latest = updateSavedConnection([stale], {
        id: '1',
        name: 'New Router',
        agent: stale.agent,
        host: stale.host,
        port: stale.port,
        scheme: stale.scheme,
        username: stale.username,
        lastUsedAt: '2026-07-01T12:00:00+08:00'
      });

      expect(resolveConnectionDisplayName(latest, generateSavedConnectionId(stale.host), stale.name))
        .assertEqual('New Router');
      expect(resolveConnectionDisplayName(latest, 'missing', stale.name)).assertEqual('Old Router');
    });

    it('updates credential references only when provided', 0, () => {
      const original = connection('1', '2026-07-01T10:00:00+08:00');
      const result = updateSavedConnection([original], {
        id: '1',
        name: 'Work Router',
        agent: original.agent,
        host: '10.0.0.12',
        port: 9443,
        scheme: 'https',
        username: 'bob',
        lastUsedAt: '2026-07-01T12:00:00+08:00',
        accessTokenRef: 'new-access',
        refreshTokenRef: 'new-refresh',
        privateKeyRef: 'new-private-key'
      });

      expect(result[0].accessTokenRef).assertEqual('new-access');
      expect(result[0].refreshTokenRef).assertEqual('new-refresh');
      expect(result[0].privateKeyRef).assertEqual('new-private-key');
    });

    it('keeps saved private key when credentials are not updated', 0, () => {
      const original = connection('1', '2026-07-01T10:00:00+08:00');
      const result = updateSavedConnection([original], {
        id: '1',
        name: 'Work Router',
        agent: original.agent,
        host: '10.0.0.12',
        port: 9443,
        scheme: 'https',
        username: 'bob',
        lastUsedAt: '2026-07-01T12:00:00+08:00'
      });

      expect(result[0].privateKeyRef).assertEqual('private-key-1');
    });

    it('clears cached resume previews when the saved endpoint changes', 0, () => {
      const original = connection('1', '2026-07-01T10:00:00+08:00');
      original.agent = 'OpenCode';
      original.host = '172.16.1.235';
      original.port = 8443;
      original.scheme = 'https';
      const sameEndpoint = connection('1', '2026-07-01T11:00:00+08:00');
      sameEndpoint.agent = 'OpenCode';
      sameEndpoint.host = '172.16.1.235';
      sameEndpoint.port = 8443;
      sameEndpoint.scheme = 'https';
      const nextEndpoint = connection('1', '2026-07-01T12:00:00+08:00');
      nextEndpoint.agent = 'OpenCode';
      nextEndpoint.host = '172.16.1.186';
      nextEndpoint.port = 8443;
      nextEndpoint.scheme = 'https';

      expect(shouldClearConnectionResumeCache(original, sameEndpoint)).assertFalse();
      expect(shouldClearConnectionResumeCache(original, nextEndpoint)).assertTrue();
    });

    it('updates connection status without moving carousel order when last used time is preserved', 0, () => {
      const older = connection('1', '2026-07-01T10:00:00+08:00');
      const newer = connection('2', '2026-07-01T11:00:00+08:00');

      const result = updateSavedConnectionStatus([older, newer], '1', 'offline',
        '2026-07-01T12:00:00+08:00', false);

      expect(result[0].id).assertEqual('2');
      expect(result[1].id).assertEqual('1');
      expect(result[1].status).assertEqual('offline');
      expect(result[1].lastUsedAt).assertEqual('2026-07-01T10:00:00+08:00');
    });

    it('does not append a duplicate connection when another add completed first', 0, () => {
      const existing = connection('1', '2026-07-01T10:00:00+08:00');
      existing.host = '172.16.1.186';
      const firstAdded = connection('2', '2026-07-01T11:00:00+08:00');
      firstAdded.host = '172.16.1.188';
      const duplicateAdd = connection('3', '2026-07-01T12:00:00+08:00');
      duplicateAdd.host = '172.16.1.188';

      const result = appendSavedConnection([firstAdded, existing], duplicateAdd);

      expect(result.length).assertEqual(2);
      expect(result[0].id).assertEqual('2');
      expect(result[1].id).assertEqual('1');
    });

    it('removes a saved connection by id without mutating the input list', 0, () => {
      const first = connection('1', '2026-07-01T10:00:00+08:00');
      const second = connection('2', '2026-07-01T11:00:00+08:00');
      const input = [first, second];

      const result = removeSavedConnection(input, '1');

      expect(result.length).assertEqual(1);
      expect(result[0].id).assertEqual('2');
      expect(input.length).assertEqual(2);
    });

    it('removes the final saved connection by id', 0, () => {
      const only = connection('1', '2026-07-01T10:00:00+08:00');

      const result = removeSavedConnection([only], '1');

      expect(result.length).assertEqual(0);
    });

    it('requires address and credentials before connecting', 0, () => {
      const incomplete = connection('1', '2026-07-01T10:00:00+08:00');
      incomplete.host = '';
      incomplete.username = '';
      incomplete.accessTokenRef = '';
      incomplete.refreshTokenRef = '';

      expect(resolveConnectionReadinessError(incomplete))
        .assertEqual('请先编辑连接，补全服务器地址和密钥。');
      expect(resolveConnectionReadinessError(connection('2', '2026-07-01T11:00:00+08:00')))
        .assertEqual('');
    });

    it('returns field errors for missing add connection inputs', 0, () => {
      const result: ConnectionFormErrors = resolveConnectionFormErrors('', '', true);

      expect(result.address).assertEqual('请填写服务器地址');
      expect(result.privateKey).assertEqual('请填写密钥');
      expect(result.hasError).assertEqual(true);
    });

    it('does not require a separate port because server address defaults to gateway port', 0, () => {
      const result: ConnectionFormErrors = resolveConnectionFormErrors('192.168.1.10', '', false);

      expect(result.address).assertEqual('');
      expect(result.privateKey).assertEqual('');
      expect(result.hasError).assertEqual(false);
    });

    it('does not require private key when editing an existing connection', 0, () => {
      const result: ConnectionFormErrors = resolveConnectionFormErrors('192.168.1.10', '', false);

      expect(result.address).assertEqual('');
      expect(result.privateKey).assertEqual('');
      expect(result.hasError).assertEqual(false);
    });

    it('resolves switch intent by connection status', 0, () => {
      expect(resolveConnectionSwitchIntent('online')).assertEqual('turn_off');
      expect(resolveConnectionSwitchIntent('offline')).assertEqual('turn_on_and_show_resumes');
      expect(resolveConnectionSwitchIntent('unknown')).assertEqual('turn_on_and_show_resumes');
      expect(resolveConnectionSwitchIntent('needs_login')).assertEqual('require_login');
    });

    it('prompts relogin when clicking the login expired resume feedback row', 0, () => {
      expect(resolveResumeFeedbackAction('needs_login', '登录已失效，请重新登录', 0)).assertEqual('relogin');
      expect(resolveResumeFeedbackAction('online', '无法获取会话', 0)).assertEqual('none');
      expect(resolveResumeFeedbackAction('needs_login', '', 0)).assertEqual('none');
      expect(resolveResumeFeedbackAction('needs_login', '登录已失效，请重新登录', 1)).assertEqual('none');
    });

    it('labels the resume card action by connection status', 0, () => {
      expect(resolveResumeCardActionLabel('needs_login', true)).assertEqual('重新连接');
      expect(resolveResumeCardActionLabel('online', true)).assertEqual('重新连接');
      expect(resolveResumeCardActionLabel('offline', true)).assertEqual('重新连接');
      expect(resolveResumeCardActionLabel('unknown', true)).assertEqual('重新连接');
      expect(resolveResumeCardActionLabel('needs_login', false)).assertEqual('新建会话');
      expect(resolveResumeCardActionLabel('online', false)).assertEqual('新建会话');
      expect(resolveResumeCardActionLabel('offline', false)).assertEqual('新建会话');
      expect(resolveResumeCardActionLabel('unknown', false)).assertEqual('新建会话');
    });

    it('keeps carousel index within saved connection bounds', 0, () => {
      expect(resolveCarouselIndex(0, 0)).assertEqual(0);
      expect(resolveCarouselIndex(2, 5)).assertEqual(2);
      expect(resolveCarouselIndex(8, 5)).assertEqual(4);
      expect(resolveCarouselIndex(-1, 5)).assertEqual(0);
    });

    it('wraps carousel swipe navigation at both ends', 0, () => {
      expect(resolveCarouselSwipeIndex(0, 3, -40)).assertEqual(1);
      expect(resolveCarouselSwipeIndex(2, 3, -40)).assertEqual(0);
      expect(resolveCarouselSwipeIndex(0, 3, 40)).assertEqual(2);
      expect(resolveCarouselSwipeIndex(1, 3, 8)).assertEqual(1);
      expect(resolveCarouselSwipeIndex(1, 1, -40)).assertEqual(0);
    });

    it('commits native swiper release before half-page distance', 0, () => {
      expect(resolveConnectionSwiperReleaseIndex(1, 3, -0.19)).assertEqual(1);
      expect(resolveConnectionSwiperReleaseIndex(1, 3, -0.2)).assertEqual(2);
      expect(resolveConnectionSwiperReleaseIndex(2, 3, -0.2)).assertEqual(0);
      expect(resolveConnectionSwiperReleaseIndex(1, 3, 0.2)).assertEqual(0);
      expect(resolveConnectionSwiperReleaseIndex(0, 3, 0.2)).assertEqual(2);
      expect(resolveConnectionSwiperReleaseIndex(1, 1, -0.2)).assertEqual(0);
    });

    it('finds the carousel index for a connection after sorting by last used time', 0, () => {
      const older = connection('1', '2026-07-01T10:00:00+08:00');
      const newer = connection('2', '2026-07-01T11:00:00+08:00');

      expect(resolveConnectionIndexById([older, newer], '1', 0)).assertEqual(1);
      expect(resolveConnectionIndexById([older, newer], 'missing', 8)).assertEqual(1);
    });

    it('resolves connection ids from the sorted carousel order', 0, () => {
      const older = connection('1', '2026-07-01T10:00:00+08:00');
      const newer = connection('2', '2026-07-01T11:00:00+08:00');

      expect(resolveConnectionIdByIndex([older, newer], 0)).assertEqual('2');
      expect(resolveConnectionIdByIndex([older, newer], 1)).assertEqual('1');
      expect(resolveConnectionIdByIndex([older, newer], 8)).assertEqual('1');
      expect(resolveConnectionIdByIndex([], 0)).assertEqual('');
    });

    it('keeps the active connection id stable after saved connections reorder', 0, () => {
      const active = connection('1', '2026-07-01T10:00:00+08:00');
      const other = connection('2', '2026-07-01T11:00:00+08:00');
      const reordered = updateSavedConnectionStatus([active, other], '2', 'online',
        '2026-07-01T12:00:00+08:00', true);

      expect(resolveActiveConnectionId(reordered, '1', 0)).assertEqual('1');
      expect(resolveConnectionIndexById(reordered, '1', 0)).assertEqual(1);
      expect(resolveActiveConnectionId(reordered, 'missing', 0)).assertEqual('2');
    });

    it('resolves native swiper selection from the sorted carousel order', 0, () => {
      const oldest = connection('1', '2026-07-01T10:00:00+08:00');
      const middle = connection('2', '2026-07-01T11:00:00+08:00');
      const newest = connection('3', '2026-07-01T12:00:00+08:00');

      const selected: ConnectionCarouselSelection = resolveConnectionSelectionBySwiperIndex(
        [oldest, newest, middle],
        1
      );
      const overflow: ConnectionCarouselSelection = resolveConnectionSelectionBySwiperIndex(
        [oldest, newest, middle],
        8
      );
      const empty: ConnectionCarouselSelection = resolveConnectionSelectionBySwiperIndex([], 0);

      expect(selected.index).assertEqual(1);
      expect(selected.id).assertEqual('2');
      expect(overflow.index).assertEqual(2);
      expect(overflow.id).assertEqual('1');
      expect(empty.index).assertEqual(0);
      expect(empty.id).assertEqual('');
    });

    it('keeps native swiper selection aligned with the stable active connection id', 0, () => {
      const active = connection('1', '2026-07-01T10:00:00+08:00');
      const other = connection('2', '2026-07-01T11:00:00+08:00');
      const reordered = updateSavedConnectionStatus([active, other], '1', 'online',
        '2026-07-01T12:00:00+08:00', true);
      const activeId = resolveActiveConnectionId(reordered, '1', 1);
      const activeIndex = resolveConnectionIndexById(reordered, activeId, 1);
      const selected = resolveConnectionSelectionBySwiperIndex(reordered, activeIndex);

      expect(activeId).assertEqual('1');
      expect(selected.index).assertEqual(0);
      expect(selected.id).assertEqual('1');
    });

    it('keeps native swiper drag enabled so card movement follows the finger', 0, () => {
      expect(resolveConnectionSwiperDisableSwipe()).assertFalse();
    });

    it('does not add extra swiper item space between card pages', 0, () => {
      expect(resolveConnectionSwiperItemSpace(0)).assertEqual(0);
      expect(resolveConnectionSwiperItemSpace(1)).assertEqual(0);
      expect(resolveConnectionSwiperItemSpace(2)).assertEqual(0);
      expect(resolveConnectionSwiperItemSpace(5)).assertEqual(0);
    });

    it('keeps connected cards visually inset inside the full-width swiper surface', 0, () => {
      expect(resolveConnectedCardPageHorizontalInset(1)).assertEqual(20);
      expect(resolveConnectedCardPageHorizontalInset(2)).assertEqual(20);
      expect(resolveConnectedCardPageHorizontalInset(5)).assertEqual(20);
    });

    it('smoothly pulls adjacent swiper cards closer only during the middle of switching', 0, () => {
      expect(resolveConnectionCardSwitchGapReduction(0)).assertEqual(0);
      expect(resolveConnectionCardSwitchGapReduction(1)).assertEqual(0);
      expect(resolveConnectionCardSwitchGapReduction(2)).assertEqual(20);
      expect(resolveConnectionCardSwitchOffset(0, 20)).assertEqual(0);
      expect(resolveConnectionCardSwitchOffset(1, 20)).assertEqual(0);
      expect(resolveConnectionCardSwitchOffset(-1, 20)).assertEqual(0);
      expect(resolveConnectionCardSwitchOffset(0.05, 20)).assertEqual(-1);
      expect(resolveConnectionCardSwitchOffset(0.5, 20)).assertEqual(-10);
      expect(resolveConnectionCardSwitchOffset(0.95, 20)).assertEqual(-1);
      expect(resolveConnectionCardSwitchOffset(-0.25, 20)).assertEqual(5);
      expect(resolveConnectionCardSwitchOffset(-0.95, 20)).assertEqual(1);
      expect(resolveConnectionCardSwitchOffset(0.5, 0)).assertEqual(0);
    });

    it('scales connection cards from 0.65 to 1 based on swiper distance', 0, () => {
      expect(resolveConnectionCardScale(0)).assertEqual(1);
      expect(resolveConnectionCardScale(0.25)).assertEqual(0.913);
      expect(resolveConnectionCardScale(0.5)).assertEqual(0.825);
      expect(resolveConnectionCardScale(1)).assertEqual(0.65);
      expect(resolveConnectionCardScale(-0.5)).assertEqual(0.825);
      expect(resolveConnectionCardScale(1.5)).assertEqual(0.65);
    });

    it('keeps the connection swiper from auto-playing', 0, () => {
      expect(resolveConnectionSwiperAutoPlay()).assertFalse();
    });

    it('uses the full screen width as the connected card swipe surface', 0, () => {
      expect(resolveConnectedCardListHorizontalPadding()).assertEqual(0);
    });

    it('applies only the latest resume refresh for the active connection', 0, () => {
      expect(shouldApplyConnectionResumeRefresh('conn-1', 'conn-1', 2, 2)).assertEqual(true);
      expect(shouldApplyConnectionResumeRefresh('conn-1', 'conn-1', 2, 1)).assertEqual(false);
      expect(shouldApplyConnectionResumeRefresh('conn-2', 'conn-1', 2, 2)).assertEqual(false);
    });

    it('formats the resume count for the history header', 0, () => {
      expect(resolveResumeCountText(0)).assertEqual('0 个');
      expect(resolveResumeCountText(1)).assertEqual('1 个');
      expect(resolveResumeCountText(12)).assertEqual('12 个');
    });

    it('styles leading diff markers only inside file diff content', 0, () => {
      expect(resolveResumeDiffLineContext('file entry/src/main/ets/App.ets\n', false)).assertTrue();
      expect(resolveResumeDiffLineContext('-old line\n', true)).assertTrue();
      expect(resolveResumeDiffLineContext('ordinary text\n', true)).assertFalse();
      expect(resolveResumeDiffLineTextStyle('-plain list', 'plain', 'removed', 'added')).assertEqual('plain');
      expect(resolveResumeDiffLineTextStyle('-old line', 'plain', 'removed', 'added', true)).assertEqual('removed');
      expect(resolveResumeDiffLineTextStyle('+new line', 'plain', 'removed', 'added', true)).assertEqual('added');
      expect(resolveResumeDiffLineTextStyle('--- a/file', 'plain', 'removed', 'added', true)).assertEqual('plain');
      expect(resolveResumeDiffLineTextStyle('+++ b/file', 'plain', 'removed', 'added', true)).assertEqual('plain');
      expect(resolveResumeDiffLineTextStyle(' context line', 'plain', 'removed', 'added', true)).assertEqual('plain');
      expect(resolveResumeDiffLineTextStyle('text - not a diff prefix', 'plain', 'removed', 'added'))
        .assertEqual('plain');
    });

    it('clamps resume content zoom while applying pinch scale', 0, () => {
      expect(resolveResumeContentInitialZoomScale()).assertEqual(1);
      expect(resolveResumeContentZoomScale(1, 1.2)).assertEqual(1.2);
      expect(resolveResumeContentZoomScale(1.1, 1.05)).assertEqual(1.155);
      expect(resolveResumeContentZoomScale(1, 0.2)).assertEqual(0.8);
      expect(resolveResumeContentZoomScale(1.2, 2)).assertEqual(1.2);
      expect(resolveResumeContentZoomScale(0, 0)).assertEqual(1);
    });

    it('formats resume timestamps as month day and local minute', 0, () => {
      expect(resolveResumeTimestampText('2026-07-02T18:54:44+08:00')).assertEqual('07-02 18:54');
      expect(resolveResumeTimestampText('')).assertEqual('');
      expect(resolveResumeTimestampText('not a date')).assertEqual('');
    });

    it('scales resume content text sizes with the zoom factor', 0, () => {
      expect(resolveResumeContentScaledSize(13, 1)).assertEqual(11.7);
      expect(resolveResumeContentScaledSize(13, 1.2)).assertEqual(14.04);
    });

    it('moves the title down only after a connection exists', 0, () => {
      expect(resolveConnectedTitleOffset(0)).assertEqual(0);
      expect(resolveConnectedTitleOffset(1)).assertEqual(10);
      expect(resolveConnectedTitleOffset(5)).assertEqual(10);
    });

    it('moves the add connection card as one piece above the keyboard without resizing it', 0, () => {
      expect(resolveAddConnectionCardOffset(0, 360, 60)).assertEqual(0);
      expect(resolveAddConnectionCardOffset(720, 360, 60)).assertEqual(0);
      expect(resolveAddConnectionCardOffset(430, 360, 60)).assertEqual(-25);
      expect(resolveAddConnectionCardOffset(390, 360, 60)).assertEqual(-45);
      expect(resolveAddConnectionCardOffset(320, 420, 60)).assertEqual(-110);
      expect(resolveAddConnectionCardOffset(900, 360, 60, 340)).assertEqual(-130);
      expect(resolveAddConnectionCardOffset(706, 520, 60, 314)).assertEqual(-281);
    });

    it('keeps the add connection card inset from the page edges', 0, () => {
      expect(resolveAddConnectionCardWidth(0, 20, 420)).assertEqual(420);
      expect(resolveAddConnectionCardWidth(440, 20, 420)).assertEqual(400);
      expect(resolveAddConnectionCardWidth(520, 20, 420)).assertEqual(420);
      expect(resolveAddConnectionCardWidth(36, 20, 420)).assertEqual(0);
    });

    it('keeps the add connection card natural height when keyboard clips the measured area', 0, () => {
      expect(resolveAddConnectionMeasuredCardHeight(392, 0, 438)).assertEqual(438);
      expect(resolveAddConnectionMeasuredCardHeight(392, 420, 438)).assertEqual(438);
      expect(resolveAddConnectionMeasuredCardHeight(392, 450, 438)).assertEqual(450);
      expect(resolveAddConnectionResponsiveCardOffset(393, 707, 438, 60, 314)).assertEqual(-82.5);
    });

    it('does not subtract keyboard height again after the page is already resized', 0, () => {
      expect(resolveAddConnectionResponsiveCardOffset(1178, 2120, 1314, 60, 942)).assertEqual(-128);
      expect(resolveAddConnectionResponsiveCardOffset(2120, 2120, 1314, 60, 942)).assertEqual(-599);
    });

    it('cycles waiting response dots by half second phase', 0, () => {
      expect(resolveWaitingResponseText(0)).assertEqual('等待回复');
      expect(resolveWaitingResponseText(1)).assertEqual('等待回复.');
      expect(resolveWaitingResponseText(2)).assertEqual('等待回复..');
      expect(resolveWaitingResponseText(3)).assertEqual('等待回复...');
      expect(resolveWaitingResponseText(4)).assertEqual('等待回复');
      expect(resolveWaitingResponseText(5)).assertEqual('等待回复.');
    });

    it('shows only the resume directory under the session title', 0, () => {
      expect(resolveResumeDirectoryText('/srv/projects/codex-router')).assertEqual('/srv/projects/codex-router');
      expect(resolveResumeDirectoryText('  /srv/projects/codex-router  ')).assertEqual('/srv/projects/codex-router');
      expect(resolveResumeDirectoryText('')).assertEqual('~');
    });

    it('caps visible resume previews at four items', 0, () => {
      expect(visibleResumePreviewCount(0)).assertEqual(0);
      expect(visibleResumePreviewCount(1)).assertEqual(1);
      expect(visibleResumePreviewCount(4)).assertEqual(4);
      expect(visibleResumePreviewCount(8)).assertEqual(4);
    });

    it('shows an output dot for agent replies but not user input', 0, () => {
      expect(shouldShowAgentOutputDot('assistant')).assertTrue();
      expect(shouldShowAgentOutputDot('agent')).assertTrue();
      expect(shouldShowAgentOutputDot('user')).assertFalse();
      expect(shouldShowAgentOutputDot('tool')).assertFalse();
    });
  });
}
