export type ConnectionStatus = 'online' | 'offline' | 'needs_login' | 'unknown';
export type ConnectionSwitchIntent = 'turn_on_and_show_resumes' | 'turn_off' | 'require_login';
export type ResumeFeedbackAction = 'none' | 'relogin';
export type ConnectionAgent = 'OpenCode';

export interface SavedConnection {
  id: string;
  name: string;
  agent: ConnectionAgent;
  host: string;
  port: number;
  scheme: string;
  username: string;
  lastUsedAt: string;
  status: ConnectionStatus;
  accessTokenRef: string;
  refreshTokenRef: string;
  privateKeyRef: string;
}

export interface NormalizedServerAddress {
  scheme: string;
  host: string;
  port: number;
  baseUrl: string;
}

export interface EditableConnectionFields {
  id: string;
  name: string;
  agent: ConnectionAgent;
  host: string;
  port: number;
  scheme: string;
  username: string;
  lastUsedAt: string;
  accessTokenRef?: string;
  refreshTokenRef?: string;
  privateKeyRef?: string;
}

export interface ConnectionFormErrors {
  address: string;
  privateKey: string;
  hasError: boolean;
}

export interface ConnectionCarouselSelection {
  index: number;
  id: string;
}

export const MAX_CONNECTIONS: number = 5;

const DEFAULT_SCHEME: string = 'https';
const DEFAULT_PORT: number = 8443;
const RESUME_CONTENT_BASE_FONT_SCALE: number = 0.9;

export function normalizeServerAddress(input: string): NormalizedServerAddress {
  let trimmedInput = input.trim();
  let scheme = DEFAULT_SCHEME;
  let address = trimmedInput;

  const schemeSeparatorIndex = trimmedInput.indexOf('://');
  if (schemeSeparatorIndex >= 0) {
    scheme = trimmedInput.substring(0, schemeSeparatorIndex);
    address = trimmedInput.substring(schemeSeparatorIndex + 3);
  }

  let host = address;
  let port = DEFAULT_PORT;
  const portSeparatorIndex = address.lastIndexOf(':');
  if (portSeparatorIndex > -1) {
    const portText = address.substring(portSeparatorIndex + 1);
    const parsedPort = Number(portText);
    if (parsedPort === parsedPort && parsedPort > 0 && parsedPort <= 65535) {
      host = address.substring(0, portSeparatorIndex);
      port = parsedPort;
    }
  }

  return {
    scheme: scheme,
    host: host,
    port: port,
    baseUrl: scheme + '://' + host + ':' + port.toString()
  };
}

export function resolveConnectionName(
  customName: string,
  sessionName: string,
  username: string,
  host: string
): string {
  const normalizedCustomName = customName.trim();
  if (normalizedCustomName.length > 0) {
    return normalizedCustomName;
  }

  const normalizedHost = host.trim();
  if (normalizedHost.length > 0) {
    return normalizedHost;
  }

  const normalizedSessionName = sessionName.trim();
  if (normalizedSessionName.length > 0) {
    return normalizedSessionName;
  }

  return username.trim();
}

export function resolveConnectionDisplayName(
  connections: SavedConnection[],
  id: string,
  fallbackName: string
): string {
  const found = connections.find((item: SavedConnection) => item.id === id);
  if (found !== undefined) {
    return found.name;
  }

  return fallbackName;
}

export function resolveConnectionCardTitle(connection: SavedConnection): string {
  return connection.host.trim();
}

export function canAddConnection(connections: SavedConnection[]): boolean {
  return connections.length < MAX_CONNECTIONS;
}

function normalizeConnectionIp(ip: string): string {
  return ip.trim().toLowerCase();
}

export function generateSavedConnectionId(ip: string): string {
  return `OpenCode-${normalizeConnectionIp(ip)}`;
}

export function hasConnectionWithSameEndpoint(
  connections: SavedConnection[],
  scheme: string,
  host: string,
  port: number,
  ignoredConnectionId: string
): boolean {
  const targetId = generateSavedConnectionId(host);

  return connections.some((item: SavedConnection) => {
    if (ignoredConnectionId.length > 0 && item.id === ignoredConnectionId) {
      return false;
    }

    return generateSavedConnectionId(item.host) === targetId;
  });
}

export function sortConnectionsByLastUsed(connections: SavedConnection[]): SavedConnection[] {
  return connections.slice().sort((left: SavedConnection, right: SavedConnection) => {
    return Date.parse(right.lastUsedAt) - Date.parse(left.lastUsedAt);
  });
}

export function resolveCarouselIndex(currentIndex: number, itemCount: number): number {
  if (itemCount <= 0) {
    return 0;
  }

  if (currentIndex < 0) {
    return 0;
  }

  if (currentIndex >= itemCount) {
    return itemCount - 1;
  }

  return currentIndex;
}

export function resolveCarouselSwipeIndex(currentIndex: number, itemCount: number, offsetX: number): number {
  if (itemCount <= 1) {
    return 0;
  }

  const threshold = 24;
  if (offsetX < -threshold) {
    return currentIndex >= itemCount - 1 ? 0 : currentIndex + 1;
  }

  if (offsetX > threshold) {
    return currentIndex <= 0 ? itemCount - 1 : currentIndex - 1;
  }

  return resolveCarouselIndex(currentIndex, itemCount);
}

export function resolveConnectionSwiperReleaseThreshold(): number {
  return 0.2;
}

export function resolveConnectionSwiperReleaseIndex(currentIndex: number, itemCount: number, position: number): number {
  const current = resolveCarouselIndex(currentIndex, itemCount);
  if (itemCount <= 1 || Math.abs(position) < resolveConnectionSwiperReleaseThreshold()) {
    return current;
  }

  if (position < 0) {
    return current >= itemCount - 1 ? 0 : current + 1;
  }

  if (position > 0) {
    return current <= 0 ? itemCount - 1 : current - 1;
  }

  return current;
}

export function resolveConnectionIndexById(
  connections: SavedConnection[],
  id: string,
  fallbackIndex: number
): number {
  const sorted = sortConnectionsByLastUsed(connections);
  const foundIndex = sorted.findIndex((item: SavedConnection) => item.id === id);
  if (foundIndex >= 0) {
    return foundIndex;
  }

  return resolveCarouselIndex(fallbackIndex, sorted.length);
}

export function resolveConnectionIdByIndex(connections: SavedConnection[], index: number): string {
  const sorted = sortConnectionsByLastUsed(connections);
  if (sorted.length === 0) {
    return '';
  }

  return sorted[resolveCarouselIndex(index, sorted.length)].id;
}

export function resolveConnectionSelectionBySwiperIndex(
  connections: SavedConnection[],
  index: number
): ConnectionCarouselSelection {
  const sorted = sortConnectionsByLastUsed(connections);
  if (sorted.length === 0) {
    return {
      index: 0,
      id: ''
    };
  }

  const selectedIndex = resolveCarouselIndex(index, sorted.length);
  return {
    index: selectedIndex,
    id: sorted[selectedIndex].id
  };
}

export function resolveConnectionSwiperItemSpace(itemCount: number): number {
  return 0;
}

export function resolveConnectionSwiperAutoPlay(): boolean {
  return false;
}

export function resolveConnectionSwiperDisableSwipe(): boolean {
  return false;
}

export function resolveConnectionCardSwitchGapReduction(itemCount: number): number {
  return itemCount > 1 ? 20 : 0;
}

export function resolveConnectionCardSwitchOffset(position: number, gapReduction: number): number {
  if (gapReduction <= 0 || position === 0 || Math.abs(position) >= 1) {
    return 0;
  }

  const normalizedPosition = Math.abs(position);
  const switchProgress = normalizedPosition <= 0.5 ? normalizedPosition * 2 : (1 - normalizedPosition) * 2;
  const offset = Math.round((gapReduction / 2) * switchProgress * 1000) / 1000;
  return position < 0 ? offset : -offset;
}

export function resolveConnectionCardScale(position: number): number {
  const normalizedPosition = Math.min(1, Math.abs(position));
  return Math.round((1 - normalizedPosition * 0.35) * 1000) / 1000;
}

export function resolveActiveConnectionId(
  connections: SavedConnection[],
  activeConnectionId: string,
  fallbackIndex: number
): string {
  if (connections.some((item: SavedConnection) => item.id === activeConnectionId)) {
    return activeConnectionId;
  }

  return resolveConnectionIdByIndex(connections, fallbackIndex);
}

export function resolveConnectedTitleOffset(connectionCount: number): number {
  return connectionCount > 0 ? 10 : 0;
}

export function resolveConnectedCardListHorizontalPadding(): number {
  return 0;
}

export function resolveConnectedCardPageHorizontalInset(itemCount: number = 1): number {
  return 20;
}

export function resolveAddConnectionCardOffset(
  pageHeight: number,
  cardHeight: number,
  keyboardGap: number,
  keyboardHeight: number = 0
): number {
  if (pageHeight <= 0 || cardHeight <= 0) {
    return 0;
  }

  const visibleHeight = keyboardHeight > 0 && pageHeight > keyboardHeight ? pageHeight - keyboardHeight : pageHeight;
  const centeredTop = (pageHeight - cardHeight) / 2;
  const safeBottom = visibleHeight - keyboardGap;
  const centeredBottom = centeredTop + cardHeight;

  if (centeredBottom <= safeBottom) {
    return 0;
  }

  return safeBottom - centeredBottom;
}

export function resolveAddConnectionCardWidth(
  pageWidth: number,
  horizontalMargin: number,
  maxWidth: number
): number {
  if (pageWidth <= 0) {
    return maxWidth;
  }

  return Math.max(0, Math.min(maxWidth, pageWidth - horizontalMargin * 2));
}

export function resolveAddConnectionMeasuredCardHeight(
  measuredHeight: number,
  naturalHeight: number,
  minimumNaturalHeight: number
): number {
  return Math.max(0, measuredHeight, naturalHeight, minimumNaturalHeight);
}

export function resolveAddConnectionResponsiveCardOffset(
  currentPageHeight: number,
  maxPageHeight: number,
  cardHeight: number,
  keyboardGap: number,
  keyboardHeight: number = 0
): number {
  const visiblePageHeight = currentPageHeight > 0 ? currentPageHeight : maxPageHeight;
  const fullPageHeight = Math.max(maxPageHeight, visiblePageHeight);

  if (visiblePageHeight > 0 && fullPageHeight > visiblePageHeight) {
    return resolveAddConnectionCardOffset(visiblePageHeight, cardHeight, keyboardGap, 0);
  }

  return resolveAddConnectionCardOffset(fullPageHeight, cardHeight, keyboardGap, keyboardHeight);
}

export function updateSavedConnection(
  connections: SavedConnection[],
  fields: EditableConnectionFields
): SavedConnection[] {
  const nextId = generateSavedConnectionId(fields.host);
  return sortConnectionsByLastUsed(connections.map((item: SavedConnection) => {
    if (item.id !== fields.id) {
      return item;
    }

      return {
      id: nextId,
      name: fields.name,
      agent: fields.agent,
      host: fields.host,
      port: fields.port,
      scheme: fields.scheme,
      username: fields.username,
      lastUsedAt: fields.lastUsedAt,
      status: item.status,
      accessTokenRef: fields.accessTokenRef !== undefined ? fields.accessTokenRef : item.accessTokenRef,
      refreshTokenRef: fields.refreshTokenRef !== undefined ? fields.refreshTokenRef : item.refreshTokenRef,
      privateKeyRef: fields.privateKeyRef !== undefined ? fields.privateKeyRef : item.privateKeyRef
    };
  }));
}

export function shouldClearConnectionResumeCache(previous: SavedConnection, next: SavedConnection): boolean {
  return previous.scheme.trim().toLowerCase() !== next.scheme.trim().toLowerCase() ||
    previous.host.trim().toLowerCase() !== next.host.trim().toLowerCase() ||
    previous.port !== next.port;
}

export function appendSavedConnection(
  connections: SavedConnection[],
  connection: SavedConnection
): SavedConnection[] {
  if (!canAddConnection(connections) || hasConnectionWithSameEndpoint(connections, connection.scheme,
    connection.host, connection.port, '')) {
    return connections;
  }

  return sortConnectionsByLastUsed(connections.concat([{
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
  }]));
}

export function updateSavedConnectionStatus(
  connections: SavedConnection[],
  id: string,
  status: ConnectionStatus,
  lastUsedAt: string,
  touchLastUsedAt: boolean
): SavedConnection[] {
  return sortConnectionsByLastUsed(connections.map((item: SavedConnection) => {
    if (item.id !== id) {
      return item;
    }

    return {
      id: item.id,
      name: item.name,
      agent: item.agent,
      host: item.host,
      port: item.port,
      scheme: item.scheme,
      username: item.username,
      lastUsedAt: touchLastUsedAt ? lastUsedAt : item.lastUsedAt,
      status,
      accessTokenRef: item.accessTokenRef,
      refreshTokenRef: item.refreshTokenRef,
      privateKeyRef: item.privateKeyRef
    };
  }));
}

export function removeSavedConnection(connections: SavedConnection[], id: string): SavedConnection[] {
  return connections.filter((item: SavedConnection) => item.id !== id);
}

export function resolveConnectionFormErrors(
  address: string,
  registrationCode: string,
  requireRegistrationCode: boolean
): ConnectionFormErrors {
  const addressError = address.trim().length === 0 ? '请填写服务器地址' : '';
  const privateKeyError = requireRegistrationCode && registrationCode.trim().length === 0 ? '请填写注册码' : '';

  return {
    address: addressError,
    privateKey: privateKeyError,
    hasError: addressError.length > 0 || privateKeyError.length > 0
  };
}

export function resolveConnectionReadinessError(connection: SavedConnection): string {
  if (connection.host.trim().length === 0 || connection.accessTokenRef.trim().length === 0 ||
    connection.refreshTokenRef.trim().length === 0) {
    return '请先编辑连接，补全服务器地址。';
  }

  return '';
}

export function resolveConnectionSwitchIntent(status: ConnectionStatus): ConnectionSwitchIntent {
  if (status === 'online') {
    return 'turn_off';
  }

  if (status === 'needs_login') {
    return 'require_login';
  }

  return 'turn_on_and_show_resumes';
}

export function resolveResumeFeedbackAction(
  status: ConnectionStatus,
  feedback: string,
  resumeCount: number
): ResumeFeedbackAction {
  if (status === 'needs_login' && feedback.length > 0 && resumeCount === 0) {
    return 'relogin';
  }

  return 'none';
}

export function resolveResumeCardActionLabel(status: ConnectionStatus, autoConnectFailed: boolean): string {
  return autoConnectFailed ? '重新连接' : '新建会话';
}

export function shouldApplyConnectionResumeRefresh(
  requestConnectionId: string,
  activeConnectionId: string,
  requestId: number,
  latestRequestId: number
): boolean {
  return requestConnectionId === activeConnectionId && requestId === latestRequestId;
}

export function resolveWaitingResponseText(phase: number): string {
  const normalizedPhase = phase % 4;
  if (normalizedPhase <= 0) {
    return '等待回复';
  }

  return `等待回复${'.'.repeat(normalizedPhase)}`;
}

export function resolveResumeDirectoryText(cwd: string): string {
  const normalizedCwd = cwd.trim();
  return normalizedCwd.length > 0 ? normalizedCwd : '~';
}

export function resolveResumeContentInitialZoomScale(): number {
  return 1;
}

export function resolveResumeContentZoomScale(baseScale: number, gestureScale: number): number {
  const normalizedBaseScale = baseScale > 0 ? baseScale : 1;
  const normalizedGestureScale = gestureScale > 0 ? gestureScale : 1;
  const scaled = normalizedBaseScale * normalizedGestureScale;
  const clamped = Math.min(1.2, Math.max(0.8, scaled));
  return Math.round(clamped * 1000) / 1000;
}

export function resolveResumeContentScaledSize(baseSize: number, scale: number): number {
  const normalizedScale = scale > 0 ? scale : 1;
  return Math.round(baseSize * RESUME_CONTENT_BASE_FONT_SCALE * normalizedScale * 1000) / 1000;
}

export function resolveResumeTimestampText(timestamp: string): string {
  const normalizedTimestamp = timestamp.trim();
  if (normalizedTimestamp.length === 0) {
    return '';
  }

  const parsedTimestamp = Date.parse(normalizedTimestamp);
  if (parsedTimestamp !== parsedTimestamp) {
    return '';
  }

  const date = new Date(parsedTimestamp);
  return `${twoDigit(date.getMonth() + 1)}-${twoDigit(date.getDate())} ` +
    `${twoDigit(date.getHours())}:${twoDigit(date.getMinutes())}`;
}

function twoDigit(value: number): string {
  return value < 10 ? `0${value.toString()}` : value.toString();
}

export function resolveResumeDiffLineContext(line: string, inFileDiffContext: boolean): boolean {
  const normalizedLine = line.trim();
  if (normalizedLine.length === 0) {
    return false;
  }

  const lowerLine = normalizedLine.toLowerCase();
  if (lowerLine.startsWith('diff --git ') || lowerLine === '```diff' || lowerLine.startsWith('file ') ||
    lowerLine.startsWith('file:') || lowerLine.startsWith('文件 ') || lowerLine.startsWith('文件:') ||
    normalizedLine.startsWith('--- ') || normalizedLine.startsWith('+++ ') || normalizedLine.startsWith('@@')) {
    return true;
  }

  if (!inFileDiffContext) {
    return false;
  }

  const marker = line.charAt(0);
  return marker === '-' || marker === '+' || marker === ' ' || normalizedLine.startsWith('\\ No newline');
}

export function resolveResumeDiffLineTextStyle(
  line: string,
  fallbackStyle: string,
  removedStyle: string,
  addedStyle: string,
  inFileDiffContext: boolean = false
): string {
  if (line.length === 0 || !inFileDiffContext || line.startsWith('---') || line.startsWith('+++')) {
    return fallbackStyle;
  }

  const marker = line.charAt(0);
  if (marker === '-') {
    return removedStyle;
  }

  if (marker === '+') {
    return addedStyle;
  }

  return fallbackStyle;
}

export function resolveResumeCountText(count: number): string {
  return `${count.toString()} 个`;
}

export function visibleResumePreviewCount(totalCount: number): number {
  if (totalCount <= 0) {
    return 0;
  }

  return totalCount > 4 ? 4 : totalCount;
}

export function shouldShowAgentOutputDot(role: string): boolean {
  const normalizedRole = role.trim().toLowerCase();
  return normalizedRole === 'assistant' || normalizedRole === 'agent';
}
