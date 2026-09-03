import { common, ConfigurationConstant, Want } from '@kit.AbilityKit';
import { deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { KeyCode } from '@kit.InputKit';
import { buffer } from '@kit.ArkTS';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { getDeviceId } from '../model/DeviceIdManager';
import { ensureDeviceKeyPair, signChallenge } from '../model/DeviceKeyManager';
import {
  GatewayClient,
  GatewayHttpError,
  GatewayNetworkError,
  HttpGatewayClient,
  isGatewayAuthenticationError,
  isGatewayNetworkError,
  LoginResponse,
  RenameResumeRequest,
  ResumeContentItem,
  ResumeItem,
  ResumeMutationRequest,
  ResumeSession,
  ResumeTurn,
  ServerFile,
} from '../api/GatewayClient';
import {
  appendSavedConnection,
  canAddConnection,
  ConnectionFormErrors,
  ConnectionStatus,
  hasConnectionWithSameEndpoint,
  normalizeServerAddress,
  resolveCarouselIndex,
  resolveActiveConnectionId,
  resolveAddConnectionMeasuredCardHeight,
  resolveAddConnectionResponsiveCardOffset,
  ConnectionCarouselSelection,
  resolveConnectionCardSwitchGapReduction,
  resolveConnectionCardSwitchOffset,
  resolveConnectionCardScale,
  resolveConnectionCardTitle,
  resolveConnectionIndexById,
  resolveConnectionSelectionBySwiperIndex,
  shouldClearConnectionResumeCache,
  resolveConnectionSwiperAutoPlay,
  resolveConnectionSwiperDisableSwipe,
  resolveConnectionSwiperItemSpace,
  resolveConnectionSwiperReleaseIndex,
  resolveConnectedCardListHorizontalPadding,
  resolveConnectedTitleOffset,
  generateSavedConnectionId,
  resolveConnectionFormErrors,
  resolveConnectionReadinessError,
  resolveConnectionSwitchIntent,
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
} from '../model/ConnectionModel';
import { PreferencesConnectionRepository } from '../model/ConnectionRepository';

enum ConnectionDialog {
  NONE,
  ADD,
  EDIT,
  RESUME_LIST,
  RELOGIN,
  DELETE
}

enum AppTab {
  CONNECT,
  FILES
}

interface ResumeTextSegment {
  id: string;
  text: string;
  style: string;
}

interface ResumeKeywordMatch {
  start: number;
  end: number;
  style: string;
}

interface ResumeMdInlineSegment {
  id: string;
  text: string;
  kind: string;
  href: string;
}

interface ResumeMdBlock {
  id: string;
  kind: string;
  level: number;
  language: string;
  text: string;
  inline: ResumeMdInlineSegment[];
}

interface ResumeMdBlockCacheEntry {
  text: string;
  blocks: ResumeMdBlock[];
}

interface ResumeMdInlineMarker {
  start: number;
  end: number;
  kind: string;
  content: string;
  href: string;
}

const RESUME_MD_BLOCK_TEXT: string = 'text';
const RESUME_MD_BLOCK_BOLD: string = 'bold';
const RESUME_MD_BLOCK_ITALIC: string = 'italic';
const RESUME_MD_BLOCK_CODE: string = 'code';
const RESUME_MD_BLOCK_LINK: string = 'link';
const RESUME_MD_BLOCK_HEADING: string = 'heading';
const RESUME_MD_BLOCK_LIST: string = 'list';
const RESUME_MD_BLOCK_QUOTE: string = 'quote';
const RESUME_MD_BLOCK_DIVIDER: string = 'divider';
const RESUME_MD_BLOCK_PARAGRAPH: string = 'paragraph';

function resolveMimeType(fileName: string): string {
  const lower = fileName.toLowerCase();
  if (lower.endsWith('.pptx')) {
    return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
  }
  if (lower.endsWith('.ppt')) {
    return 'application/vnd.ms-powerpoint';
  }
  if (lower.endsWith('.docx')) {
    return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  }
  if (lower.endsWith('.doc')) {
    return 'application/msword';
  }
  if (lower.endsWith('.xlsx')) {
    return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  }
  if (lower.endsWith('.xls')) {
    return 'application/vnd.ms-excel';
  }
  if (lower.endsWith('.pdf')) {
    return 'application/pdf';
  }
  if (lower.endsWith('.md')) {
    return 'text/markdown';
  }
  if (lower.endsWith('.txt')) {
    return 'text/plain';
  }
  if (lower.endsWith('.zip')) {
    return 'application/zip';
  }
  return 'application/octet-stream';
}

function emptyResumeSession(): ResumeSession {
  return {
    threadId: '',
    title: '',
    cwd: '',
    status: '',
    turns: []
  };
}

function appendResumeMdInlineSegment(segments: ResumeMdInlineSegment[], text: string, kind: string, href: string): void {
  if (text.length === 0) {
    return;
  }
  const lastIndex = segments.length - 1;
  if (lastIndex >= 0 && segments[lastIndex].kind === kind && segments[lastIndex].href === href) {
    segments[lastIndex] = {
      id: segments[lastIndex].id,
      text: `${segments[lastIndex].text}${text}`,
      kind,
      href
    };
    return;
  }
  segments.push({
    id: `${segments.length}-${kind}`,
    text,
    kind,
    href
  });
}

function findNextResumeMdBoldMarker(text: string, start: number): ResumeMdInlineMarker {
  for (let index = start; index < text.length - 1; index++) {
    if (text.charAt(index) === '*' && text.charAt(index + 1) === '*') {
      const contentStart = index + 2;
      const closeIndex = text.indexOf('**', contentStart);
      if (closeIndex > contentStart) {
        return {
          start: index,
          end: closeIndex + 2,
          kind: RESUME_MD_BLOCK_BOLD,
          content: text.substring(contentStart, closeIndex),
          href: ''
        };
      }
    }
  }
  return { start: -1, end: -1, kind: RESUME_MD_BLOCK_TEXT, content: '', href: '' };
}

function findNextResumeMdItalicMarker(text: string, start: number): ResumeMdInlineMarker {
  for (let index = start; index < text.length; index++) {
    if (text.charAt(index) !== '*') {
      continue;
    }
    if (index + 1 < text.length && text.charAt(index + 1) === '*') {
      continue;
    }
    if (index - 1 >= start && text.charAt(index - 1) === '*') {
      continue;
    }
    const closeIndex = text.indexOf('*', index + 1);
    if (closeIndex > index + 1 && text.charAt(closeIndex + 1) !== '*') {
      return {
        start: index,
        end: closeIndex + 1,
        kind: RESUME_MD_BLOCK_ITALIC,
        content: text.substring(index + 1, closeIndex),
        href: ''
      };
    }
  }
  return { start: -1, end: -1, kind: RESUME_MD_BLOCK_TEXT, content: '', href: '' };
}

function findNextResumeMdCodeMarker(text: string, start: number): ResumeMdInlineMarker {
  for (let index = start; index < text.length; index++) {
    if (text.charAt(index) !== '`') {
      continue;
    }
    const closeIndex = text.indexOf('`', index + 1);
    if (closeIndex > index + 1) {
      return {
        start: index,
        end: closeIndex + 1,
        kind: RESUME_MD_BLOCK_CODE,
        content: text.substring(index + 1, closeIndex),
        href: ''
      };
    }
  }
  return { start: -1, end: -1, kind: RESUME_MD_BLOCK_TEXT, content: '', href: '' };
}

function findNextResumeMdLinkMarker(text: string, start: number): ResumeMdInlineMarker {
  for (let index = start; index < text.length; index++) {
    if (text.charAt(index) !== '[') {
      continue;
    }
    const linkStart = text.indexOf('](', index + 1);
    if (linkStart < 0) {
      continue;
    }
    const hrefEnd = text.indexOf(')', linkStart + 2);
    if (hrefEnd < 0) {
      continue;
    }
    const label = text.substring(index + 1, linkStart);
    const href = text.substring(linkStart + 2, hrefEnd);
    if (label.length > 0 && href.length > 0) {
      return {
        start: index,
        end: hrefEnd + 1,
        kind: RESUME_MD_BLOCK_LINK,
        content: label,
        href
      };
    }
  }
  return { start: -1, end: -1, kind: RESUME_MD_BLOCK_TEXT, content: '', href: '' };
}

function findNextResumeMdInlineMarker(text: string, start: number): ResumeMdInlineMarker {
  const bold = findNextResumeMdBoldMarker(text, start);
  const italic = findNextResumeMdItalicMarker(text, start);
  const code = findNextResumeMdCodeMarker(text, start);
  const link = findNextResumeMdLinkMarker(text, start);
  let result = bold;
  if (result.start < 0 || (italic.start >= 0 && italic.start < result.start)) {
    result = italic;
  }
  if (result.start < 0 || (code.start >= 0 && code.start < result.start)) {
    result = code;
  }
  if (result.start < 0 || (link.start >= 0 && link.start < result.start)) {
    result = link;
  }
  return result;
}

function resolveResumeMarkdownInline(text: string): ResumeMdInlineSegment[] {
  const segments: ResumeMdInlineSegment[] = [];
  let cursor = 0;
  while (cursor < text.length) {
    const match = findNextResumeMdInlineMarker(text, cursor);
    if (match.start < 0) {
      appendResumeMdInlineSegment(segments, text.substring(cursor), RESUME_MD_BLOCK_TEXT, '');
      return segments;
    }
    if (match.start > cursor) {
      appendResumeMdInlineSegment(segments, text.substring(cursor, match.start), RESUME_MD_BLOCK_TEXT, '');
    }
    appendResumeMdInlineSegment(segments, match.content, match.kind, match.href);
    cursor = match.end;
  }
  return segments;
}

function resolveResumeMdHeadingLevel(line: string): number {
  if (line.startsWith('### ')) {
    return 3;
  }
  if (line.startsWith('## ')) {
    return 2;
  }
  if (line.startsWith('# ')) {
    return 1;
  }
  return 0;
}

function resolveResumeMdListText(line: string): string {
  const trimmed = line.trim();
  if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
    return trimmed.substring(2);
  }
  const orderedMatch = trimmed.match(new RegExp('^\\d+[.)]\\s+'));
  if (orderedMatch !== null) {
    return trimmed.substring(orderedMatch[0].length);
  }
  return trimmed;
}

function resolveResumeMarkdownBlocks(text: string): ResumeMdBlock[] {
  const blocks: ResumeMdBlock[] = [];
  const lines = text.split('\n');
  let paragraphLines: string[] = [];
  let blockIndex = 0;

  const flushParagraph = (): void => {
    if (paragraphLines.length > 0) {
      const paragraphText = paragraphLines.join('\n');
      blocks.push({
        id: `md-${blockIndex++}-paragraph`,
        kind: RESUME_MD_BLOCK_PARAGRAPH,
        level: 0,
        language: '',
        text: paragraphText,
        inline: resolveResumeMarkdownInline(paragraphText)
      });
      paragraphLines = [];
    }
  };

  let index = 0;
  while (index < lines.length) {
    const line = lines[index];
    const trimmed = line.trim();

    if (trimmed.startsWith('```')) {
      flushParagraph();
      const language = trimmed.substring(3).trim();
      const codeLines: string[] = [];
      index++;
      while (index < lines.length && !lines[index].trim().startsWith('```')) {
        codeLines.push(lines[index]);
        index++;
      }
      index++;
      blocks.push({
        id: `md-${blockIndex++}-code`,
        kind: RESUME_MD_BLOCK_CODE,
        level: 0,
        language,
        text: codeLines.join('\n'),
        inline: []
      });
      continue;
    }

    const headingLevel = resolveResumeMdHeadingLevel(trimmed);
    if (headingLevel > 0) {
      flushParagraph();
      const headingText = trimmed.substring(headingLevel + 1).trim();
      blocks.push({
        id: `md-${blockIndex++}-heading`,
        kind: RESUME_MD_BLOCK_HEADING,
        level: headingLevel,
        language: '',
        text: headingText,
        inline: resolveResumeMarkdownInline(headingText)
      });
      index++;
      continue;
    }

    if (trimmed.startsWith('- ') || trimmed.startsWith('* ') || new RegExp('^\\d+[.)]\\s+').test(trimmed)) {
      flushParagraph();
      const listText = resolveResumeMdListText(trimmed);
      blocks.push({
        id: `md-${blockIndex++}-list`,
        kind: RESUME_MD_BLOCK_LIST,
        level: 0,
        language: '',
        text: listText,
        inline: resolveResumeMarkdownInline(listText)
      });
      index++;
      continue;
    }

    if (trimmed.startsWith('>')) {
      flushParagraph();
      const quoteText = trimmed.substring(1).trim();
      blocks.push({
        id: `md-${blockIndex++}-quote`,
        kind: RESUME_MD_BLOCK_QUOTE,
        level: 0,
        language: '',
        text: quoteText,
        inline: resolveResumeMarkdownInline(quoteText)
      });
      index++;
      continue;
    }

    if (trimmed === '---' || trimmed === '***') {
      flushParagraph();
      blocks.push({
        id: `md-${blockIndex++}-divider`,
        kind: RESUME_MD_BLOCK_DIVIDER,
        level: 0,
        language: '',
        text: '',
        inline: []
      });
      index++;
      continue;
    }

    if (trimmed.length === 0) {
      flushParagraph();
      index++;
      continue;
    }

    paragraphLines.push(line);
    index++;
  }

  flushParagraph();
  return blocks;
}

const RESUME_INPUT_GUARD = '\u200B';
const DEFAULT_RESUME_CWD: string = '~';
const DARK_MODE_PREFERENCES_NAME: string = 'codex_router_dark_mode';
const DARK_MODE_PREFERENCES_KEY: string = 'dark_mode';
const RESUME_COMPOSER_MAX_LINES: number = 4;
const RESUME_COMPOSER_LINE_HEIGHT: number = 24;
const RESUME_COMPOSER_BASE_HEIGHT: number = 20;

// 多设备响应式布局常量 — 使用屏幕百分比 + 最大宽度
const PHONE_CARD_MARGIN: number = 16;
const TABLET_CARD_MARGIN: number = 48;
const PC_CARD_MARGIN: number = 80;
const PHONE_RESUME_PANEL_MARGIN: number = 16;
const TABLET_RESUME_PANEL_MARGIN: number = 48;
const PC_RESUME_PANEL_MARGIN: number = 80;
const TABLET_CARD_MAX_WIDTH: number = 520;
const PC_CARD_MAX_WIDTH: number = 600;
const TABLET_RESUME_PANEL_MAX_WIDTH: number = 700;
const PC_RESUME_PANEL_MAX_WIDTH: number = 800;

const RESUME_PREVIEW_ROW_HEIGHT: number = 51.3;
const RESUME_PREVIEW_ROW_GAP: number = 6;
const RESUME_LIST_ROW_GAP: number = 6;
const FILES_OUTPUT_DIR: string = 'AIRouter输出';
const RESUME_AGENT_OUTPUT_DOT_SIZE: number = 5.2;
const RESUME_AGENT_OUTPUT_DOT_OFFSET_X: number = -9.6;
const RESUME_AGENT_OUTPUT_DOT_TRAILING_MARGIN: number = -8.4;
const CARD_AUTO_CONNECT_MAX_ATTEMPTS: number = 3;
const ADD_CONNECTION_KEYBOARD_GAP: number = 60;
const ADD_CONNECTION_CARD_MIN_NATURAL_HEIGHT: number = 438;
const CONNECTION_CARD_SWIPER_DURATION_MS: number = 300;
const TERMINAL_FONT_FAMILY: string = 'HarmonyOS-Sans';
const TERMINAL_BACKGROUND_COLOR: Resource = $r('app.color.terminal_background');
const TERMINAL_PANEL_COLOR: Resource = $r('app.color.terminal_panel');
const TERMINAL_PANEL_ELEVATED_COLOR: Resource = $r('app.color.terminal_panel_elevated');
const TERMINAL_ROW_COLOR: Resource = $r('app.color.terminal_row');
const TERMINAL_INPUT_COLOR: Resource = $r('app.color.terminal_input');
const TERMINAL_TOOLBAR_COLOR: Resource = $r('app.color.terminal_toolbar');
const TERMINAL_TRANSCRIPT_COLOR: Resource = $r('app.color.terminal_transcript');
const TERMINAL_BORDER_COLOR: Resource = $r('app.color.terminal_border');
const TERMINAL_BORDER_STRONG_COLOR: Resource = $r('app.color.terminal_border_strong');
const TERMINAL_SUBTLE_BORDER_COLOR: Resource = $r('app.color.terminal_subtle_border');
const TERMINAL_TEXT_COLOR: Resource = $r('app.color.terminal_text');
const TERMINAL_MUTED_TEXT_COLOR: Resource = $r('app.color.terminal_muted_text');
const TERMINAL_DIM_TEXT_COLOR: Resource = $r('app.color.terminal_dim_text');
const TERMINAL_ACCENT_COLOR: Resource = $r('app.color.terminal_accent');
const TERMINAL_ACCENT_TEXT_COLOR: Resource = $r('app.color.terminal_accent_text');
const TERMINAL_RENAME_BUTTON_COLOR: Resource = $r('app.color.terminal_rename_button');
const TERMINAL_RENAME_BUTTON_TEXT_COLOR: Resource = $r('app.color.terminal_rename_button_text');
const TERMINAL_GREEN_COLOR: Resource = $r('app.color.terminal_green');
const TERMINAL_BLUE_COLOR: Resource = $r('app.color.terminal_blue');
const TERMINAL_AMBER_COLOR: Resource = $r('app.color.terminal_amber');
const TERMINAL_RED_COLOR: Resource = $r('app.color.terminal_red');
const TERMINAL_BUTTON_SECONDARY_COLOR: Resource = $r('app.color.terminal_button_secondary');
const TERMINAL_BUTTON_NEUTRAL_COLOR: Resource = $r('app.color.terminal_button_neutral');
const TERMINAL_CANCEL_BUTTON_COLOR: Resource = $r('app.color.terminal_cancel_button');
const TERMINAL_DANGER_SURFACE_COLOR: Resource = $r('app.color.terminal_danger_surface');
const TERMINAL_DANGER_TEXT_COLOR: Resource = $r('app.color.terminal_danger_text');
const TERMINAL_SUCCESS_SURFACE_COLOR: Resource = $r('app.color.terminal_success_surface');
const TERMINAL_SUCCESS_TEXT_COLOR: Resource = $r('app.color.terminal_success_text');
const TERMINAL_NOTICE_SURFACE_COLOR: Resource = $r('app.color.terminal_notice_surface');
const TERMINAL_NOTICE_BORDER_COLOR: Resource = $r('app.color.terminal_notice_border');
const TERMINAL_SHADOW_COLOR: Resource = $r('app.color.terminal_shadow');
const TERMINAL_CARD_SHADOW_COLOR: Resource = $r('app.color.terminal_card_shadow');
const TERMINAL_DIALOG_SHADOW_COLOR: Resource = $r('app.color.terminal_dialog_shadow');
const TERMINAL_FLOATING_SHADOW_COLOR: Resource = $r('app.color.terminal_floating_shadow');
const TERMINAL_ACCENT_GLOW_COLOR: Resource = $r('app.color.terminal_accent_glow');
const TERMINAL_ACCENT_CARD_GLOW_COLOR: Resource = $r('app.color.terminal_accent_card_glow');
const TERMINAL_LABEL_COLOR: Resource = $r('app.color.terminal_label');
const TERMINAL_DIALOG_TITLE_COLOR: Resource = $r('app.color.terminal_dialog_title');
const TERMINAL_APP_TITLE_COLOR: Resource = $r('app.color.terminal_app_title');
const TERMINAL_SECTION_TITLE_COLOR: Resource = $r('app.color.terminal_section_title');
const TERMINAL_RESUME_TITLE_COLOR: Resource = $r('app.color.terminal_resume_title');
const TERMINAL_USER_MESSAGE_SURFACE_COLOR: Resource = $r('app.color.terminal_user_message_surface');
const TERMINAL_WAITING_MESSAGE_SURFACE_COLOR: Resource = $r('app.color.terminal_waiting_message_surface');
const TERMINAL_USER_BODY_TEXT_COLOR: Resource = $r('app.color.terminal_user_body_text');
const TERMINAL_REASONING_BODY_TEXT_COLOR: Resource = $r('app.color.terminal_reasoning_body_text');
const TERMINAL_TOOL_BODY_TEXT_COLOR: Resource = $r('app.color.terminal_tool_body_text');
const TERMINAL_INLINE_CODE_COLOR: Resource = $r('app.color.terminal_inline_code');
const TERMINAL_INLINE_PATH_COLOR: Resource = $r('app.color.terminal_inline_path');
const TERMINAL_CODE_BLOCK_BACKGROUND_COLOR: Resource = $r('app.color.terminal_code_block_background');
const TERMINAL_CODE_BLOCK_BORDER_COLOR: Resource = $r('app.color.terminal_code_block_border');
const TERMINAL_HEADING_COLOR: Resource = $r('app.color.terminal_heading');
const TERMINAL_QUOTE_BORDER_COLOR: Resource = $r('app.color.terminal_quote_border');
const TERMINAL_LINK_COLOR: Resource = $r('app.color.terminal_link');
const TERMINAL_TRANSPARENT_COLOR: Resource = $r('app.color.terminal_transparent');
const RESUME_TEXT_STYLE_USER: string = 'user';
const RESUME_TEXT_STYLE_ASSISTANT: string = 'assistant';
const RESUME_TEXT_STYLE_REASONING: string = 'reasoning';
const RESUME_TEXT_STYLE_TOOL: string = 'tool';
const RESUME_TEXT_STYLE_CODE: string = 'code';
const RESUME_TEXT_STYLE_PATH: string = 'path';
const RESUME_TEXT_STYLE_SUCCESS: string = 'success';
const RESUME_TEXT_STYLE_WARNING: string = 'warning';
const RESUME_TEXT_STYLE_DANGER: string = 'danger';
const RESUME_DANGER_TOKENS: string[] = [
  'error', 'failed', 'failure', 'fatal', 'exception', 'denied', 'timeout',
  '失败', '错误', '异常', '拒绝', '超时'
];
const RESUME_WARNING_TOKENS: string[] = [
  'warning', 'warn', 'deprecated', 'skipped', 'skip',
  '警告', '跳过'
];
const RESUME_SUCCESS_TOKENS: string[] = [
  'success', 'successful', 'completed', 'done',
  '成功', '完成', '通过'
];

@Component
export struct ConnectionHome {
  @Link @Watch('handleBackRequestTokenChange') backRequestToken: number;
  @State private connections: SavedConnection[] = [];
  @State private dialog: ConnectionDialog = ConnectionDialog.NONE;
  @State private selectedTab: AppTab = AppTab.CONNECT;
  @State private selectedConnectionId: string = '';
  @State private deleteConnectionId: string = '';
  @State private reloginConnectionId: string = '';
  @State private draftAddress: string = '';
  @State private draftUsername: string = '';
  @State private draftPassword: string = 'huaweI1234';
  @State private draftName: string = '';
  @State private feedback: string = '';
  @State private dialogFeedback: string = '';
  @State private addressFeedback: string = '';
  @State private usernameFeedback: string = '';
  @State private passwordFeedback: string = '';
  @State private connectionSubmitting: boolean = false;
  @State private testingConnection: boolean = false;
  @State private connectionTestResult: string = '';
  @State private connectionTestPassed: boolean = false;
  @State private swipedConnectionId: string = '';
  @State private activeConnectionId: string = '';
  @State private activeConnectionIndex: number = 0;
  @State private connectionCardScrollPositions: number[] = [];
  @State private serverFiles: ServerFile[] = [];
  @State private serverFilesConnectionId: string = '';
  @State private serverFilesLoading: boolean = false;
  @State private serverFilesFeedback: string = '';
  @State private downloadingFileId: string = '';
  @State private downloadedFileName: string = '';
  @State private downloadFeedback: string = '';
  @State private openingFileName: string = '';
  @State private filesRefreshing: boolean = false;
  @State private filesRefreshTick: number = 0;
  @State private resumes: ResumeItem[] = [];
  @State private resumesConnectionId: string = '';
  @State private resumesLoading: boolean = false;
  @State private resumesFeedback: string = '';
  @State private autoConnectingConnectionId: string = '';
  @State private autoConnectFailedConnectionId: string = '';
  @State private resumeActionFeedback: string = '';
  @State private resumeCenterNotice: string = '';
  @State private openingResumeId: string = '';
  @State private resumeActionMenuId: string = '';
  @State private connectionActionMenuId: string = '';
  @State private suppressNextCardActionClick: boolean = false;
  @State private resumeMutatingId: string = '';
  @State private resumeRenamingId: string = '';
  @State private resumeRenameDraft: string = '';
  @State private resumeStarting: boolean = false;
  @State private hasActiveResumeSession: boolean = false;
  @State private activeResumeSession: ResumeSession = emptyResumeSession();
  @State private resumeMessageDraft: string = '';
  @State private resumeMessageSending: boolean = false;
  @State private pendingResumeMessage: string = '';
  @State private pendingResumeMessageTimestamp: string = '';
  @State private resumeComposerVisible: boolean = true;
  @State private resumeDarkMode: boolean = false;
  @State private resumeContentZoomScale: number = 1;
  @State private waitingDotsPhase: number = 0;
  @State private resumeRefreshToken: number = 0;
  @State private addConnectionPageHeight: number = 0;
  @State private addConnectionCardHeight: number = 0;
  @State private addConnectionNaturalCardHeight: number = 0;
  @State private addConnectionScreenHeight: number = 0;
  @State private addConnectionPageWidth: number = 0;
  @StorageLink('aiRouterKeyboardHeightPx') private keyboardHeightPx: number = 0;
  private gatewayClient: GatewayClient = new HttpGatewayClient();
  private certContentLoaded: boolean = false;
  private deviceId: string = '';
  private connectionRepository: PreferencesConnectionRepository | null = null;
  private persistConnectionsQueue: Promise<void> = Promise.resolve();
  private resumeContentScroller: Scroller = new Scroller();
  private connectionSwiperController: SwiperController = new SwiperController();
  private waitingDotsTimer: number = -1;
  private resumeAutoRefreshTimer: number = -1;
  private resumeCenterNoticeTimer: number = -1;
  private resumePageTapTimer: number = -1;
  private cardActionClickSuppressTimer: number = -1;
  private resumePinchStartScale: number = 1;
  private connectionResumeRefreshId: number = 0;
  private connectionResumePrefetchId: number = 0;
  private connectionResumePrefetchIds: Map<string, number> = new Map();
  private connectionSwiperReleasePosition: number = 0;
  private connectionSwiperEarlyReleaseTargetIndex: number = -1;
  private connectionSwiperPrefetchedTargetId: string = '';
  private addConnectionRequestId: number = 0;
  private resumeWasWaitingForResponse: boolean = false;
  private resumeShouldFollowOutput: boolean = true;
  private resumeScrollAwayVersion: number = 0;
  private resumeJustSent: boolean = false;
  private resumeStopRequested: boolean = false;
  private resumesCache: Map<string, ResumeItem[]> = new Map();
  private deviceType: string = deviceInfo.deviceType;

  aboutToAppear(): void {
    this.updateBackAvailability();
    this.loadDarkModePreference();
    this.loadCertContent();
    this.loadSavedConnections();
    this.loadDeviceId();
  }

  private async loadDarkModePreference(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }

    try {
      const store = await preferences.getPreferences(context as common.Context, DARK_MODE_PREFERENCES_NAME);
      const saved = await store.get(DARK_MODE_PREFERENCES_KEY, '');
      if (typeof saved !== 'string') {
        this.applyResumeDarkMode(false);
        return;
      }

      if (saved === 'dark') {
        this.resumeDarkMode = true;
      } else if (saved === 'light') {
        this.resumeDarkMode = false;
      } else {
        const abilityContext = context as common.UIAbilityContext;
        this.resumeDarkMode = abilityContext.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      }
      this.applyResumeDarkMode(this.resumeDarkMode);
    } catch (error) {
      this.applyResumeDarkMode(false);
    }
  }

  private applyResumeDarkMode(dark: boolean): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }

    try {
      context.getApplicationContext().setColorMode(dark
        ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (error) {
    }
  }

  private toggleResumeDarkMode(): void {
    this.resumeDarkMode = !this.resumeDarkMode;
    this.applyResumeDarkMode(this.resumeDarkMode);
    this.persistResumeDarkMode(this.resumeDarkMode);
  }

  private async persistResumeDarkMode(dark: boolean): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }

    try {
      const store = await preferences.getPreferences(context as common.Context, DARK_MODE_PREFERENCES_NAME);
      await store.put(DARK_MODE_PREFERENCES_KEY, dark ? 'dark' : 'light');
      await store.flush();
    } catch (error) {
    }
  }

  private async loadDeviceId(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    this.deviceId = await getDeviceId(context);
  }

  private async loadCertContent(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      console.error('[ConnectionHome] loadCertContent: hostContext is undefined');
      return;
    }
    try {
      const certFile: Uint8Array = await context.resourceManager.getRawFileContent('codex-router-cert.pem');
      const certContent: string = buffer.from(certFile.buffer).toString();
      console.info(`[ConnectionHome] loadCertContent: cert loaded, length=${certContent.length}`);
      this.gatewayClient = HttpGatewayClient.createWithCert(certContent);
      this.certContentLoaded = true;
      console.info('[ConnectionHome] loadCertContent: gatewayClient updated with cert');
    } catch (error) {
      console.error(`[ConnectionHome] Failed to load cert: ${JSON.stringify(error)}`);
      console.error(`[ConnectionHome] certContentLoaded remains: ${this.certContentLoaded}`);
    }
  }

  // 多设备响应式布局方法
  private isTabletOrPC(): boolean {
    return this.deviceType === 'tablet' || this.deviceType === '2in1' || this.deviceType === 'default';
  }

  private getCardMargin(): number {
    if (this.deviceType === '2in1' || this.deviceType === 'default') {
      return PC_CARD_MARGIN;
    }
    if (this.deviceType === 'tablet') {
      return TABLET_CARD_MARGIN;
    }
    return PHONE_CARD_MARGIN;
  }

  private getCardMaxWidth(): number {
    if (this.deviceType === '2in1' || this.deviceType === 'default') {
      return PC_CARD_MAX_WIDTH;
    }
    if (this.deviceType === 'tablet') {
      return TABLET_CARD_MAX_WIDTH;
    }
    return 9999;
  }

  private getResumePanelMargin(): number {
    if (this.deviceType === '2in1' || this.deviceType === 'default') {
      return PC_RESUME_PANEL_MARGIN;
    }
    if (this.deviceType === 'tablet') {
      return TABLET_RESUME_PANEL_MARGIN;
    }
    return PHONE_RESUME_PANEL_MARGIN;
  }

  private getResumePanelMaxWidth(): number {
    if (this.deviceType === '2in1' || this.deviceType === 'default') {
      return PC_RESUME_PANEL_MAX_WIDTH;
    }
    if (this.deviceType === 'tablet') {
      return TABLET_RESUME_PANEL_MAX_WIDTH;
    }
    return 9999;
  }

  aboutToDisappear(): void {
    this.stopResumeWaitingIndicator();
    this.stopResumeAutoRefresh();
    this.clearResumePageTapTimer();
    this.clearCardActionClickSuppression();
    this.clearResumeCenterNotice();
  }

  private handleBackRequestTokenChange(): void {
    this.handlePageBack();
  }

  private updateBackAvailability(): void {
    AppStorage.setOrCreate<boolean>('codexRouterCanBack', this.canBackInApp());
  }

  private async loadSavedConnections(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      this.feedback = '无法读取本地连接';
      return;
    }

    this.connectionRepository = new PreferencesConnectionRepository(context as common.Context);

    try {
      this.connections = await this.connectionRepository.list();
      this.keepActiveConnectionInBounds();
      this.loadActiveConnectionResumes();
    } catch (error) {
      this.feedback = '无法读取本地连接';
    }
  }

  private persistConnections(): void {
    if (this.connectionRepository === null) {
      return;
    }

    const snapshot = this.connections.slice();
    this.persistConnectionsQueue = this.persistConnectionsQueue.then(() => {
      if (this.connectionRepository === null) {
        return Promise.resolve();
      }

      return this.connectionRepository.save(snapshot);
    }).catch(() => {
      this.feedback = '保存连接失败';
    });
  }

  private selectedConnection(): SavedConnection {
    const found = this.connectionById(this.selectedConnectionId);
    if (found) {
      return found;
    }

    return {
      id: '',
      name: '',
      agent: 'OpenCode',
      host: '',
      port: 8443,
      scheme: 'https',
      username: '',
      lastUsedAt: '',
      status: 'unknown',
      accessTokenRef: '',
      refreshTokenRef: '',
      privateKeyRef: ''
    };
  }

  private connectionById(id: string): SavedConnection | undefined {
    return this.connections.find((item: SavedConnection) => item.id === id);
  }

  private openAddDialog(): void {
    if (!canAddConnection(this.connections)) {
      this.feedback = '最多支持 5 个连接，请删除一个连接后再添加。';
      return;
    }

    this.connectionActionMenuId = '';
    this.draftAddress = '';
    this.draftUsername = '';
    this.draftPassword = 'huaweI1234';
    this.draftName = '';
    this.feedback = '';
    this.dialogFeedback = '';
    this.clearFieldFeedback();
    this.connectionSubmitting = false;
    this.testingConnection = false;
    this.connectionTestResult = '';
    this.connectionTestPassed = false;
    this.dialog = ConnectionDialog.ADD;
    this.updateBackAvailability();
  }

  private sortedConnections(): SavedConnection[] {
    return sortConnectionsByLastUsed(this.connections);
  }

  private activeConnection(): SavedConnection {
    const sorted = this.sortedConnections();
    const activeId = resolveActiveConnectionId(this.connections, this.activeConnectionId, this.activeConnectionIndex);
    const found = sorted.find((item: SavedConnection) => item.id === activeId);
    if (found !== undefined) {
      return found;
    }

    if (sorted.length > 0) {
      return sorted[resolveCarouselIndex(this.activeConnectionIndex, sorted.length)];
    }

    return this.selectedConnection();
  }

  private activeConnectionPosition(): number {
    const activeId = resolveActiveConnectionId(this.connections, this.activeConnectionId, this.activeConnectionIndex);
    return resolveConnectionIndexById(this.connections, activeId, this.activeConnectionIndex);
  }

  private keepActiveConnectionInBounds(): void {
    const activeId = resolveActiveConnectionId(this.connections, this.activeConnectionId, this.activeConnectionIndex);
    this.activeConnectionId = activeId;
    this.activeConnectionIndex = resolveConnectionIndexById(this.connections, activeId, this.activeConnectionIndex);
  }

  private handleConnectionSwiperChange(index: number): void {
    const selection: ConnectionCarouselSelection = resolveConnectionSelectionBySwiperIndex(this.connections, index);
    if (selection.id.length === 0) {
      return;
    }

    this.activeConnectionIndex = selection.index;
    this.activeConnectionId = selection.id;
    this.swipedConnectionId = '';
    this.connectionActionMenuId = '';
    this.connectionSwiperReleasePosition = 0;
    this.connectionSwiperEarlyReleaseTargetIndex = -1;
    this.connectionSwiperPrefetchedTargetId = '';
    this.loadActiveConnectionResumes();
  }

  private handleConnectionSwiperContentScroll(selectedIndex: number, index: number, position: number): void {
    if (index < 0) {
      return;
    }

    const nextPositions = this.connectionCardScrollPositions.slice();
    nextPositions[index] = position;
    this.connectionCardScrollPositions = nextPositions;
    if (index === selectedIndex) {
      this.connectionSwiperReleasePosition = position;
      this.prefetchConnectionSwiperReleaseTarget(selectedIndex, position);
    }
  }

  private handleConnectionSwiperAnimationStart(index: number, targetIndex: number): void {
    if (this.connectionSwiperEarlyReleaseTargetIndex >= 0 || targetIndex !== index) {
      return;
    }

    const releaseIndex = resolveConnectionSwiperReleaseIndex(index, this.connections.length,
      this.connectionSwiperReleasePosition);
    if (releaseIndex === index) {
      return;
    }

    this.connectionSwiperEarlyReleaseTargetIndex = releaseIndex;
    setTimeout(() => {
      this.connectionSwiperController.changeIndex(releaseIndex, true);
    }, 0);
  }

  private clearConnectionCardScrollPositions(): void {
    if (this.connectionCardScrollPositions.length > 0) {
      this.connectionCardScrollPositions = [];
    }

    this.connectionSwiperReleasePosition = 0;
    this.connectionSwiperEarlyReleaseTargetIndex = -1;
    this.connectionSwiperPrefetchedTargetId = '';
  }

  private connectionCardSwitchOffset(index: number): number {
    if (index < 0 || index >= this.connectionCardScrollPositions.length) {
      return 0;
    }

    return resolveConnectionCardSwitchOffset(this.connectionCardScrollPositions[index],
      resolveConnectionCardSwitchGapReduction(this.connections.length));
  }

  private connectionCardScale(index: number): number {
    if (index < 0 || index >= this.connectionCardScrollPositions.length) {
      return index === this.activeConnectionPosition() ? 1 : resolveConnectionCardScale(1);
    }

    return resolveConnectionCardScale(this.connectionCardScrollPositions[index]);
  }

  private loadActiveConnectionResumes(): void {
    const connection = this.activeConnection();
    if (connection.id.length === 0) {
      this.resumes = [];
      this.resumesConnectionId = '';
      this.resumesFeedback = '';
      return;
    }

    if (this.resumesConnectionId === connection.id && (this.resumes.length > 0 || this.resumesLoading ||
      (this.resumesFeedback.length > 0 && !this.hasCardAutoConnectFailed(connection)))) {
      return;
    }

    this.loadCardResumes(connection);
  }

  private async loadCardResumes(connection: SavedConnection): Promise<void> {
    const refreshId = ++this.connectionResumeRefreshId;
    const cached = this.resumesCache.get(connection.id);
    this.resumesConnectionId = connection.id;
    this.resumes = cached !== undefined ? cached : [];
    this.resumesFeedback = '';
    this.resumeActionFeedback = '';
    this.openingResumeId = '';
    this.resumeActionMenuId = '';
    this.resumesLoading = cached === undefined;
    this.autoConnectingConnectionId = connection.id;
    this.clearCardAutoConnectFailure(connection.id);
    this.updateConnectionStatus(connection, 'offline', false);

    let attempt = 0;
    let activeConnection: SavedConnection | undefined = connection;
    let lastError: Error | undefined;
    while (attempt < CARD_AUTO_CONNECT_MAX_ATTEMPTS) {
      attempt++;
      const currentConnection: SavedConnection | undefined = activeConnection !== undefined ? activeConnection :
        this.connectionById(connection.id);
      if (currentConnection === undefined || !shouldApplyConnectionResumeRefresh(connection.id, this.resumesConnectionId,
        refreshId, this.connectionResumeRefreshId)) {
        break;
      }

      const refreshedConnection: SavedConnection | undefined =
        await this.ensureConnectionCredentialsForCard(currentConnection);
      if (!shouldApplyConnectionResumeRefresh(connection.id, this.resumesConnectionId, refreshId,
        this.connectionResumeRefreshId)) {
        break;
      }

      if (refreshedConnection !== undefined) {
        activeConnection = refreshedConnection;
      }

      const requestConnection: SavedConnection = activeConnection !== undefined ? activeConnection : currentConnection;
      try {
        const loadedResumes = await this.gatewayClient.listResumes({
          baseUrl: `${requestConnection.scheme}://${requestConnection.host}:${requestConnection.port}`,
          accessToken: requestConnection.accessTokenRef
        });
        if (!shouldApplyConnectionResumeRefresh(connection.id, this.resumesConnectionId, refreshId,
          this.connectionResumeRefreshId)) {
          break;
        }

        this.setResumes(connection.id, loadedResumes);
        this.resumesFeedback = this.resumes.length === 0 ? '暂无会话' : '';
        this.clearCardAutoConnectFailure(connection.id);
        this.updateConnectionStatus(requestConnection, 'online', false);
        this.resumesLoading = false;
        this.autoConnectingConnectionId = '';
        return;
      } catch (error) {
        const err = error as Error;
        console.error(`[loadCardResumes] 第${attempt}次尝试失败: name=${err.name}, message=${err.message}, stack=${err.stack}`);
        lastError = err;

        if (!shouldApplyConnectionResumeRefresh(connection.id, this.resumesConnectionId, refreshId,
          this.connectionResumeRefreshId)) {
          break;
        }

        if (isGatewayNetworkError(err)) {
          break;
        }

        if (isGatewayAuthenticationError(err)) {
          const retryConnection: SavedConnection | undefined =
            await this.refreshConnectionCredentials(requestConnection, 'online', false);
          if (!shouldApplyConnectionResumeRefresh(connection.id, this.resumesConnectionId, refreshId,
            this.connectionResumeRefreshId)) {
            break;
          }

          if (retryConnection !== undefined) {
            activeConnection = retryConnection;
          }
        } else {
          break;
        }
      }
    }

    if (shouldApplyConnectionResumeRefresh(connection.id, this.resumesConnectionId, refreshId,
      this.connectionResumeRefreshId)) {
      this.resumes = [];
      if (lastError !== undefined) {
        if (isGatewayNetworkError(lastError)) {
          this.resumesFeedback = `网络连接失败: ${lastError.message}`;
        } else if (isGatewayAuthenticationError(lastError)) {
          const authError = lastError as GatewayHttpError;
          this.resumesFeedback = `认证失败(${authError.statusCode})`;
        } else {
          this.resumesFeedback = `连接失败: ${lastError.message}`;
        }
      } else {
        this.resumesFeedback = '无法自动连接服务器';
      }
      this.autoConnectFailedConnectionId = connection.id;
      this.updateConnectionStatus(connection, 'offline', false);
      this.resumesLoading = false;
      this.autoConnectingConnectionId = '';
    }
  }

  private prefetchConnectionSwiperReleaseTarget(index: number, position: number): void {
    const targetIndex = resolveConnectionSwiperReleaseIndex(index, this.connections.length, position);
    if (targetIndex === index) {
      return;
    }

    const selection: ConnectionCarouselSelection = resolveConnectionSelectionBySwiperIndex(this.connections, targetIndex);
    if (selection.id.length === 0 || selection.id === this.connectionSwiperPrefetchedTargetId) {
      return;
    }

    const connection = this.connectionById(selection.id);
    if (connection === undefined) {
      return;
    }

    this.connectionSwiperPrefetchedTargetId = selection.id;
    this.prefetchCardResumes(connection);
  }

  private shouldApplyConnectionResumePrefetch(connectionId: string, prefetchId: number): boolean {
    return this.connectionResumePrefetchIds.get(connectionId) === prefetchId &&
      this.connectionById(connectionId) !== undefined;
  }

  private async prefetchCardResumes(connection: SavedConnection): Promise<void> {
    if (connection.id.length === 0 || this.connectionResumePrefetchIds.has(connection.id)) {
      return;
    }

    const prefetchId = ++this.connectionResumePrefetchId;
    this.connectionResumePrefetchIds.set(connection.id, prefetchId);

    let attempt = 0;
    let activeConnection: SavedConnection | undefined = connection;
    try {
      while (attempt < CARD_AUTO_CONNECT_MAX_ATTEMPTS) {
        attempt++;
        const currentConnection: SavedConnection | undefined = activeConnection !== undefined ? activeConnection :
          this.connectionById(connection.id);
        if (currentConnection === undefined ||
          !this.shouldApplyConnectionResumePrefetch(connection.id, prefetchId)) {
          break;
        }

        const refreshedConnection: SavedConnection | undefined =
          await this.ensureConnectionCredentialsForCard(currentConnection);
        if (!this.shouldApplyConnectionResumePrefetch(connection.id, prefetchId)) {
          break;
        }

        if (refreshedConnection !== undefined) {
          activeConnection = refreshedConnection;
        }

        const requestConnection: SavedConnection = activeConnection !== undefined ? activeConnection : currentConnection;
        try {
          const loadedResumes = await this.gatewayClient.listResumes({
            baseUrl: `${requestConnection.scheme}://${requestConnection.host}:${requestConnection.port}`,
            accessToken: requestConnection.accessTokenRef
          });
          if (!this.shouldApplyConnectionResumePrefetch(connection.id, prefetchId)) {
            break;
          }

          this.resumesCache.set(connection.id, loadedResumes);
          if (this.resumesConnectionId === connection.id) {
            this.resumes = loadedResumes;
            this.resumesFeedback = loadedResumes.length === 0 ? '暂无会话' : '';
            this.resumesLoading = false;
          }
          this.clearCardAutoConnectFailure(connection.id);
          this.updateConnectionStatus(requestConnection, 'online', false);
          return;
        } catch (error) {
          if (!this.shouldApplyConnectionResumePrefetch(connection.id, prefetchId)) {
            break;
          }

          if (isGatewayAuthenticationError(error as Error)) {
            const retryConnection: SavedConnection | undefined =
              await this.refreshConnectionCredentials(requestConnection, 'online', false);
            if (!this.shouldApplyConnectionResumePrefetch(connection.id, prefetchId)) {
              break;
            }

            if (retryConnection !== undefined) {
              activeConnection = retryConnection;
            }
          }
        }
      }

      if (this.shouldApplyConnectionResumePrefetch(connection.id, prefetchId)) {
        this.updateConnectionStatus(connection, 'offline', false);
      }
    } finally {
      if (this.connectionResumePrefetchIds.get(connection.id) === prefetchId) {
        this.connectionResumePrefetchIds.delete(connection.id);
      }
    }
  }

  private async ensureConnectionCredentialsForCard(connection: SavedConnection): Promise<SavedConnection | undefined> {
    if (connection.accessTokenRef.trim().length > 0 && connection.status !== 'needs_login') {
      return connection;
    }

    return await this.refreshConnectionCredentials(connection, 'online', false);
  }

  private clearCardAutoConnectFailure(connectionId: string): void {
    if (this.autoConnectFailedConnectionId === connectionId) {
      this.autoConnectFailedConnectionId = '';
    }
  }

  private hasCardAutoConnectFailed(connection: SavedConnection): boolean {
    return this.autoConnectFailedConnectionId === connection.id;
  }

  private isCardAutoConnecting(connection: SavedConnection): boolean {
    return this.autoConnectingConnectionId === connection.id && this.resumesLoading;
  }

  private retryCardAutoConnect(connection: SavedConnection): void {
    const latestConnection = this.connectionById(connection.id);
    this.loadCardResumes(latestConnection !== undefined ? latestConnection : connection);
  }

  private cardResumes(connection: SavedConnection): ResumeItem[] {
    if (this.resumesConnectionId === connection.id) {
      return this.resumes;
    }

    const cached = this.resumesCache.get(connection.id);
    return cached !== undefined ? cached : [];
  }

  private setResumes(connectionId: string, resumes: ResumeItem[]): void {
    this.resumes = resumes;
    if (connectionId.length > 0) {
      this.resumesCache.set(connectionId, resumes);
    }
  }

  private resumePreviewHeight(connection: SavedConnection): number {
    const visibleCount = visibleResumePreviewCount(this.cardResumes(connection).length);
    if (visibleCount <= 0) {
      return RESUME_PREVIEW_ROW_HEIGHT;
    }

    return visibleCount * RESUME_PREVIEW_ROW_HEIGHT + (visibleCount - 1) * RESUME_PREVIEW_ROW_GAP;
  }

  private clearFieldFeedback(): void {
    this.addressFeedback = '';
    this.usernameFeedback = '';
    this.passwordFeedback = '';
  }

  private applyFieldFeedback(errors: ConnectionFormErrors): void {
    this.addressFeedback = errors.address;
    this.usernameFeedback = '';
    this.passwordFeedback = errors.privateKey;
  }

  private async saveEditedConnection(): Promise<void> {
    const selected = this.selectedConnection();
    if (selected.id.length === 0) {
      this.closeDialog();
      return;
    }

    const errors = resolveConnectionFormErrors(this.draftAddress, this.draftPassword, false);
    if (errors.hasError) {
      this.applyFieldFeedback(errors);
      this.dialogFeedback = '';
      this.feedback = '';
      return;
    }

    const normalized = normalizeServerAddress(this.draftAddress);
    const nextConnectionId = generateSavedConnectionId(normalized.host);
    const identityChanged = generateSavedConnectionId(selected.host) !== nextConnectionId;
    if (hasConnectionWithSameEndpoint(this.connections, normalized.scheme, normalized.host, normalized.port,
      selected.id)) {
      this.addressFeedback = '该服务器地址已存在';
      this.dialogFeedback = '同一个 Agent 和 IP 只能添加一个连接';
      this.feedback = '';
      return;
    }
    if (identityChanged && this.draftPassword.trim().length === 0) {
      this.passwordFeedback = '更改服务器地址时需要重新输入注册码';
      this.dialogFeedback = '';
      this.feedback = '';
      return;
    }

    const name = resolveConnectionName(this.draftName, '', '', normalized.host);
    let nextAccessTokenRef: string | undefined = undefined;
    let nextRefreshTokenRef: string | undefined = undefined;

    if (this.draftPassword.trim().length > 0) {
      try {
        const keyPair = await ensureDeviceKeyPair();
        const registerResult = await this.gatewayClient.register({
          baseUrl: normalized.baseUrl,
          deviceId: this.deviceId,
          publicKey: keyPair.publicKeyPem,
          registrationCode: this.draftPassword,
          deviceName: 'HarmonyOS Phone'
        });
        const sig = await signChallenge(registerResult.challenge);
        const activateResult = await this.gatewayClient.activate({
          baseUrl: normalized.baseUrl,
          deviceId: this.deviceId,
          activationToken: registerResult.activationToken,
          signedChallenge: sig
        });
        nextAccessTokenRef = activateResult.accessToken;
        nextRefreshTokenRef = activateResult.refreshToken;
      } catch (error) {
        this.dialogFeedback = this.resolveLoginFailureText(error as Error);
        this.feedback = '';
        return;
      }
    }

    this.connections = updateSavedConnection(this.connections, {
      id: selected.id,
      name,
      agent: 'OpenCode',
      host: normalized.host,
      port: normalized.port,
      scheme: normalized.scheme,
      username: '',
      lastUsedAt: new Date().toISOString(),
      accessTokenRef: nextAccessTokenRef,
      refreshTokenRef: nextRefreshTokenRef,
      privateKeyRef: this.draftPassword.trim().length > 0 ? this.draftPassword : undefined
    });
    const updatedConnection = this.connectionById(nextConnectionId);
    if (updatedConnection !== undefined && shouldClearConnectionResumeCache(selected, updatedConnection)) {
      this.resumesCache.delete(selected.id);
    }
    if (identityChanged) {
      this.resumesCache.delete(selected.id);
      this.resumesCache.delete(nextConnectionId);
    }
    this.activeConnectionId = nextConnectionId;
    this.activeConnectionIndex = resolveConnectionIndexById(this.connections, this.activeConnectionId,
      this.activeConnectionIndex);
    this.persistConnections();
    this.closeDialog();
    this.resumesConnectionId = '';
    if (this.connections.length === 0) {
      this.resumes = [];
      this.resumesFeedback = '';
      this.feedback = '';
      return;
    }

    this.loadActiveConnectionResumes();
  }

  private openResumeList(connection: SavedConnection): void {
    this.showResumeList(connection);
  }

  private showResumeList(connection: SavedConnection): void {
    this.swipedConnectionId = '';
    this.connectionActionMenuId = '';
    this.selectedConnectionId = connection.id;
    this.feedback = '';
    this.dialogFeedback = '';
    this.resumesFeedback = '';
    this.resumeActionFeedback = '';
    this.openingResumeId = '';
    this.resumeActionMenuId = '';
    this.resumeMutatingId = '';
    this.resumeRenamingId = '';
    this.resumeRenameDraft = '';
    this.resumeStarting = false;
    this.clearActiveResumeSession();
    this.resumeMessageDraft = '';
    this.resumeMessageSending = false;
    this.pendingResumeMessage = '';
    this.pendingResumeMessageTimestamp = '';
    this.resumeRefreshToken++;
    this.clearFieldFeedback();
    this.dialog = ConnectionDialog.RESUME_LIST;
    this.updateBackAvailability();
    this.loadResumes(connection);
  }

  private async loadResumes(connection: SavedConnection): Promise<void> {
    this.resumesLoading = true;
    this.resumes = [];
    this.resumesConnectionId = connection.id;
    this.resumesFeedback = '';
    this.resumeActionFeedback = '';
    this.openingResumeId = '';
    this.resumeActionMenuId = '';
    this.resumeMutatingId = '';
    this.resumeRenamingId = '';
    this.resumeRenameDraft = '';
    this.resumeStarting = false;
    this.clearActiveResumeSession();
    this.resumeMessageDraft = '';
    this.resumeMessageSending = false;
    this.pendingResumeMessage = '';
    this.pendingResumeMessageTimestamp = '';
    this.resumeRefreshToken++;

    try {
      const baseUrl = `${connection.scheme}://${connection.host}:${connection.port}`;
      const loadedResumes = await this.gatewayClient.listResumes({
        baseUrl,
        accessToken: connection.accessTokenRef
      });
      this.setResumes(connection.id, loadedResumes);
      this.updateConnectionStatus(connection, 'online');
      if (this.resumes.length === 0) {
        this.resumesFeedback = '暂无会话';
      }
    } catch (error) {
      if (isGatewayAuthenticationError(error as Error)) {
        const refreshedConnection = await this.refreshConnectionCredentials(connection);
        if (refreshedConnection !== undefined) {
          this.loadResumes(refreshedConnection);
          return;
        }

        this.promptRelogin(connection, '登录已失效，正在重新认证');
        return;
      }

      this.resumesFeedback = '无法获取会话';
    } finally {
      this.resumesLoading = false;
    }
  }

  private async resumeSelectedThread(resume: ResumeItem): Promise<void> {
    const connection = this.selectedConnection();
    if (connection.id.length === 0 || this.openingResumeId.length > 0 || this.resumeStarting) {
      return;
    }

    this.openingResumeId = resume.id;
    this.resumeActionFeedback = `正在打开 ${resume.title}`;

    try {
      const session: ResumeSession = await this.gatewayClient.resumeThread({
        baseUrl: `${connection.scheme}://${connection.host}:${connection.port}`,
        accessToken: connection.accessTokenRef,
        threadId: resume.id
      });
      this.activeResumeSession = session;
      this.resumeStopRequested = false;
      this.resetResumeContentZoomScale();
      this.hasActiveResumeSession = true;
      this.resumeComposerVisible = true;
      this.clearResumePageTapTimer();
      this.syncResumeWaitingIndicator();
      this.syncResumeAutoRefresh();
      if (session.turns.length === 0) {
        this.resumeActionFeedback = '已载入会话，但没有可展示的历史内容';
      } else {
        this.resumeActionFeedback = '';
      }
      this.dialog = ConnectionDialog.NONE;
      this.updateBackAvailability();
      this.scrollActiveResumeToBottom();
    } catch (error) {
      if (isGatewayAuthenticationError(error as Error)) {
        const refreshedConnection = await this.refreshConnectionCredentials(connection);
        if (refreshedConnection !== undefined) {
          this.openingResumeId = '';
          this.resumeSelectedThread(resume);
          return;
        }

        this.promptRelogin(connection, '登录已失效，正在重新认证');
        return;
      }

      this.resumeActionFeedback = '无法打开会话';
    } finally {
      this.openingResumeId = '';
    }
  }

  private async startNewResume(): Promise<void> {
    const connection = this.selectedConnection();
    await this.startNewResumeForConnection(connection);
  }

  private async startNewResumeForConnection(connection: SavedConnection): Promise<void> {
    if (this.resumeStarting || this.openingResumeId.length > 0) {
      return;
    }

    if (connection.id.length === 0) {
      this.resumeActionFeedback = '连接不可用';
      this.feedback = '连接不可用';
      return;
    }

    this.selectedConnectionId = connection.id;
    this.resumeStarting = true;
    this.resumeActionFeedback = '正在新建会话';
    this.clearActiveResumeSession();
    this.resumeMessageDraft = '';
    this.resumeMessageSending = false;
    this.pendingResumeMessage = '';
    this.pendingResumeMessageTimestamp = '';
    this.resumeRefreshToken++;
    this.resetResumeContentZoomScale();
    const startToken = this.resumeRefreshToken;
    this.activeResumeSession = {
      threadId: '',
      title: '新建会话',
      cwd: DEFAULT_RESUME_CWD,
      status: 'starting',
      turns: []
    };
    this.resumeStopRequested = false;
    this.hasActiveResumeSession = true;
    this.resumeComposerVisible = true;
    this.resumeActionFeedback = '';
    this.clearResumePageTapTimer();
    this.dialog = ConnectionDialog.NONE;
    this.updateBackAvailability();
    this.showResumeCenterNotice('正在新建会话');
    this.scrollActiveResumeToBottom();

    try {
      const session: ResumeSession = await this.gatewayClient.startResume({
        baseUrl: `${connection.scheme}://${connection.host}:${connection.port}`,
        accessToken: connection.accessTokenRef,
        cwd: DEFAULT_RESUME_CWD
      });
      if (startToken !== this.resumeRefreshToken) {
        return;
      }

      this.activeResumeSession = session;
      this.hasActiveResumeSession = true;
      this.updateConnectionStatus(connection, 'online');
      this.resumeComposerVisible = true;
      this.clearResumePageTapTimer();
      this.syncResumeWaitingIndicator();
      this.syncResumeAutoRefresh();
      this.resumeActionFeedback = '';
      this.showResumeCenterNotice('已新建会话，可直接发送消息');
      this.updateBackAvailability();
      this.scrollActiveResumeToBottom();
      this.loadResumesWithoutClearingSession(connection);
    } catch (error) {
      if (startToken !== this.resumeRefreshToken) {
        return;
      }
      if (isGatewayAuthenticationError(error as Error)) {
        const refreshedConnection = await this.refreshConnectionCredentials(connection);
        if (refreshedConnection !== undefined) {
          this.resumeStarting = false;
          this.clearActiveResumeSession();
          this.startNewResumeForConnection(refreshedConnection);
          return;
        }

        this.clearActiveResumeSession();
        this.promptRelogin(connection, '登录已失效，正在重新认证');
        return;
      }

      this.resumeActionFeedback = '新建会话失败';
    } finally {
      if (startToken === this.resumeRefreshToken) {
        this.resumeStarting = false;
      }
    }
  }

  private async loadResumesWithoutClearingSession(connection: SavedConnection): Promise<void> {
    const refreshId = ++this.connectionResumeRefreshId;
    try {
      this.resumesConnectionId = connection.id;
      const loadedResumes = await this.gatewayClient.listResumes({
        baseUrl: `${connection.scheme}://${connection.host}:${connection.port}`,
        accessToken: connection.accessTokenRef
      });
      if (!shouldApplyConnectionResumeRefresh(connection.id, this.resumesConnectionId, refreshId,
        this.connectionResumeRefreshId)) {
        return;
      }

      this.setResumes(connection.id, loadedResumes);
      this.resumesFeedback = '';
      this.updateConnectionStatus(connection, 'online');
    } catch (error) {
      if (!shouldApplyConnectionResumeRefresh(connection.id, this.resumesConnectionId, refreshId,
        this.connectionResumeRefreshId)) {
        return;
      }

      if (isGatewayAuthenticationError(error as Error)) {
        const refreshedConnection = await this.refreshConnectionCredentials(connection);
        if (refreshedConnection !== undefined) {
          this.loadResumesWithoutClearingSession(refreshedConnection);
          return;
        }

        this.promptRelogin(connection, '登录已失效，正在重新认证');
        return;
      }

      if (this.resumes.length === 0) {
        this.resumesFeedback = '刷新 Resume 列表失败';
      }
    }
  }

  private removeResumeFromList(threadId: string): void {
    this.setResumes(this.resumesConnectionId, this.resumes.filter((item: ResumeItem) => item.id !== threadId));
    this.resumeActionMenuId = '';
    if (this.resumes.length === 0) {
        this.resumesFeedback = '暂无会话';
    }
  }

  private async deleteResumeItem(resume: ResumeItem): Promise<void> {
    await this.mutateResumeItem(resume);
  }

  private startRenameResumeItem(resume: ResumeItem): void {
    if (this.resumeMutatingId.length > 0 || this.openingResumeId.length > 0) {
      return;
    }

    this.resumeRenamingId = resume.id;
    this.resumeRenameDraft = resume.title;
    this.resumeActionMenuId = '';
    this.resumeActionFeedback = '';
  }

  private cancelRenameResumeItem(): void {
    this.resumeRenamingId = '';
    this.resumeRenameDraft = '';
    this.resumeActionFeedback = '';
  }

  private async confirmRenameResumeItem(resume: ResumeItem): Promise<void> {
    const connection = this.selectedConnection();
    const name = this.resumeRenameDraft.trim();
    if (connection.id.length === 0 || this.resumeMutatingId.length > 0 || this.openingResumeId.length > 0) {
      return;
    }

    if (name.length === 0) {
      this.resumeActionFeedback = '请输入会话名称';
      return;
    }

    this.resumeMutatingId = resume.id;
    this.resumeActionFeedback = '正在重命名会话';
    try {
      const request: RenameResumeRequest = {
        baseUrl: `${connection.scheme}://${connection.host}:${connection.port}`,
        accessToken: connection.accessTokenRef,
        threadId: resume.id,
        name
      };
      await this.gatewayClient.renameResume(request);
      this.updateConnectionStatus(connection, 'online');
      this.setResumes(this.resumesConnectionId, this.resumes.map((item: ResumeItem) => {
        if (item.id !== resume.id) {
          return item;
        }
        return {
          id: item.id,
          title: name,
          subtitle: item.subtitle,
          status: item.status,
          updatedAt: item.updatedAt
        };
      }));
      this.resumeRenamingId = '';
      this.resumeRenameDraft = '';
      this.resumeActionMenuId = '';
      this.resumeActionFeedback = '已重命名会话';
    } catch (error) {
      if (isGatewayAuthenticationError(error as Error)) {
        const refreshedConnection = await this.refreshConnectionCredentials(connection);
        if (refreshedConnection !== undefined) {
          this.resumeMutatingId = '';
          this.confirmRenameResumeItem(resume);
          return;
        }

        this.promptRelogin(connection, '登录已失效，正在重新认证');
        return;
      }

      this.resumeActionFeedback = '重命名会话失败';
    } finally {
      this.resumeMutatingId = '';
    }
  }

  private async mutateResumeItem(resume: ResumeItem): Promise<void> {
    const connection = this.selectedConnection();
    if (connection.id.length === 0 || this.resumeMutatingId.length > 0 || this.openingResumeId.length > 0) {
      return;
    }

    this.resumeMutatingId = resume.id;
    this.resumeActionFeedback = '正在删除会话';
    try {
      const request: ResumeMutationRequest = {
        baseUrl: `${connection.scheme}://${connection.host}:${connection.port}`,
        accessToken: connection.accessTokenRef,
        threadId: resume.id
      };
      await this.gatewayClient.deleteResume(request);

      this.updateConnectionStatus(connection, 'online');
      this.removeResumeFromList(resume.id);
      this.resumeActionFeedback = '已删除会话';
    } catch (error) {
      if (isGatewayAuthenticationError(error as Error)) {
        const refreshedConnection = await this.refreshConnectionCredentials(connection);
        if (refreshedConnection !== undefined) {
          this.resumeMutatingId = '';
          this.mutateResumeItem(resume);
          return;
        }

        this.promptRelogin(connection, '登录已失效，正在重新认证');
        return;
      }

      this.resumeActionFeedback = '删除会话失败';
    } finally {
      this.resumeMutatingId = '';
    }
  }

  private closeDialog(): void {
    this.dialog = ConnectionDialog.NONE;
    this.selectedConnectionId = '';
    this.deleteConnectionId = '';
    this.reloginConnectionId = '';
    this.connectionActionMenuId = '';
    this.connectionSubmitting = false;
    this.testingConnection = false;
    this.connectionTestResult = '';
    this.connectionTestPassed = false;
    this.addConnectionRequestId++;
    this.dialogFeedback = '';
    this.resumeActionFeedback = '';
    this.openingResumeId = '';
    this.resumeActionMenuId = '';
    this.resumeMutatingId = '';
    this.resumeRenamingId = '';
    this.resumeRenameDraft = '';
    this.resumeStarting = false;
    this.clearActiveResumeSession();
    this.resumeMessageDraft = '';
    this.resumeMessageSending = false;
    this.pendingResumeMessage = '';
    this.pendingResumeMessageTimestamp = '';
    this.resumeRefreshToken++;
    this.clearFieldFeedback();
    this.updateBackAvailability();
  }

  private async testConnection(): Promise<void> {
    if (this.testingConnection) {
      return;
    }
    this.connectionTestResult = '';
    if (this.draftAddress.trim().length === 0) {
      this.connectionTestResult = '请输入服务器地址';
      this.connectionTestPassed = false;
      return;
    }
    const normalized = normalizeServerAddress(this.draftAddress);
    this.testingConnection = true;
    try {
      const ok = await this.gatewayClient.checkHealth(normalized.baseUrl);
      if (ok) {
        this.connectionTestResult = '连接成功，服务器运行正常';
        this.connectionTestPassed = true;
      } else {
        this.connectionTestResult = '服务器已连接，但服务状态异常';
        this.connectionTestPassed = false;
      }
    } catch (error) {
      this.connectionTestPassed = false;
      const networkError = error as GatewayNetworkError;
      this.connectionTestResult = this.resolveTestFailureText(networkError);
    } finally {
      this.testingConnection = false;
    }
  }

  private resolveTestFailureText(error: GatewayNetworkError): string {
    const detail: string = error.detail.length > 0 ? error.detail.toLowerCase() : '';
    if (detail.includes('certificate') || detail.includes('cert')) {
      return '证书校验失败：该服务器的证书不受信任，请联系管理员';
    }
    if (detail.includes('timeout') || detail.includes('timed out')) {
      return '连接超时：请检查服务器地址和网络';
    }
    if (detail.includes('refused') || detail.includes('econnrefused')) {
      return '连接被拒绝：端口未开放或服务未启动';
    }
    if (detail.includes('dns') || detail.includes('eai_again') || detail.includes('ehostunreach')) {
      return '无法解析主机：请检查服务器地址是否正确';
    }
    return '网络异常，无法连接服务器，请检查地址和网络';
  }

  private async addConnection(): Promise<void> {
    if (this.connectionSubmitting) {
      return;
    }

    if (!canAddConnection(this.connections)) {
      this.dialogFeedback = '最多支持 5 个连接，请删除一个连接后再添加。';
      this.feedback = '';
      return;
    }

    const errors = resolveConnectionFormErrors(this.draftAddress, this.draftPassword, true);
    if (errors.hasError) {
      this.applyFieldFeedback(errors);
      this.dialogFeedback = '';
      this.feedback = '';
      return;
    }

    const normalized = normalizeServerAddress(this.draftAddress);
    if (hasConnectionWithSameEndpoint(this.connections, normalized.scheme, normalized.host, normalized.port, '')) {
      this.addressFeedback = '该服务器地址已存在';
      this.dialogFeedback = '同一个 Agent 和 IP 只能添加一个连接';
      this.feedback = '';
      return;
    }

    const requestId = ++this.addConnectionRequestId;
    this.connectionSubmitting = true;
    let loginResponse: LoginResponse;
    console.info(`[addConnection] certContentLoaded=${this.certContentLoaded}`);
    console.info(`[addConnection] 登录 baseUrl: ${normalized.baseUrl}, scheme: ${normalized.scheme}`);
    try {
      const keyPair = await ensureDeviceKeyPair();
      const registerResult = await this.gatewayClient.register({
        baseUrl: normalized.baseUrl,
        deviceId: this.deviceId,
        publicKey: keyPair.publicKeyPem,
        registrationCode: this.draftPassword,
        deviceName: 'HarmonyOS Phone'
      });
      const sig = await signChallenge(registerResult.challenge);
      loginResponse = await this.gatewayClient.activate({
        baseUrl: normalized.baseUrl,
        deviceId: this.deviceId,
        activationToken: registerResult.activationToken,
        signedChallenge: sig
      });
    } catch (error) {
      if (requestId !== this.addConnectionRequestId) {
        return;
      }

      this.connectionSubmitting = false;
      this.dialogFeedback = this.resolveLoginFailureText(error as Error);
      this.feedback = '';
      return;
    }

    if (requestId !== this.addConnectionRequestId || this.dialog !== ConnectionDialog.ADD) {
      return;
    }

    const now = new Date().toISOString();
    const id = generateSavedConnectionId(normalized.host);
    const name = resolveConnectionName(this.draftName, loginResponse.sessionName, '', normalized.host);

    const nextConnection: SavedConnection = {
      id,
      name,
      agent: 'OpenCode',
      host: normalized.host,
      port: normalized.port,
      scheme: normalized.scheme,
      username: '',
      lastUsedAt: now,
      status: 'online',
      accessTokenRef: loginResponse.accessToken,
      refreshTokenRef: loginResponse.refreshToken,
      privateKeyRef: ''
    };

    const nextConnections = appendSavedConnection(this.connections, nextConnection);
    if (nextConnections.length === this.connections.length) {
      this.connectionSubmitting = false;
      if (!canAddConnection(this.connections)) {
        this.dialogFeedback = '最多支持 5 个连接，请删除一个连接后再添加。';
      } else {
        this.addressFeedback = '该服务器地址已存在';
        this.dialogFeedback = '同一个 Agent 和 IP 只能添加一个连接';
      }
      this.feedback = '';
      return;
    }

    this.connections = nextConnections;
    this.activeConnectionId = nextConnection.id;
    this.activeConnectionIndex = resolveConnectionIndexById(this.connections, this.activeConnectionId, 0);
    this.persistConnections();
    this.connectionSubmitting = false;
    this.closeDialog();
    this.loadCardResumes(nextConnection);
  }

  private deleteSelectedConnection(): void {
    const id = this.deleteConnectionId.length > 0 ? this.deleteConnectionId : this.selectedConnectionId;
    if (id.length === 0) {
      this.closeDialog();
      return;
    }

    this.connections = removeSavedConnection(this.connections, id);
    this.keepActiveConnectionInBounds();
    this.persistConnections();
    this.connectionResumeRefreshId++;
    this.resumesCache.delete(id);
    this.resumesConnectionId = '';
    this.resumes = [];
    this.resumesLoading = false;
    this.resumesFeedback = '';
    this.resumeActionFeedback = '';
    if (this.autoConnectingConnectionId === id) {
      this.autoConnectingConnectionId = '';
    }
    if (this.autoConnectFailedConnectionId === id) {
      this.autoConnectFailedConnectionId = '';
    }
    this.feedback = '';
    this.closeDialog();
    if (this.connections.length > 0) {
      this.loadActiveConnectionResumes();
    }
  }

  private openDeleteDialog(connection: SavedConnection): void {
    this.selectedConnectionId = connection.id;
    this.deleteConnectionId = connection.id;
    this.swipedConnectionId = '';
    this.connectionActionMenuId = '';
    this.feedback = '';
    this.dialogFeedback = '';
    this.clearFieldFeedback();
    this.dialog = ConnectionDialog.DELETE;
    this.updateBackAvailability();
  }

  private openEditDialog(connection: SavedConnection): void {
    this.draftName = connection.name;
    this.draftAddress = connection.port === 8443 ? connection.host : `${connection.host}:${connection.port}`;
    this.draftUsername = '';
    this.draftPassword = '';
    this.selectedConnectionId = connection.id;
    this.swipedConnectionId = '';
    this.connectionActionMenuId = '';
    this.feedback = '';
    this.dialogFeedback = '';
    this.clearFieldFeedback();
    this.dialog = ConnectionDialog.EDIT;
    this.updateBackAvailability();
  }

  private updateConnectionStatus(
    connection: SavedConnection,
    status: ConnectionStatus,
    touchLastUsedAt: boolean = true
  ): void {
    this.connections = updateSavedConnectionStatus(this.connections, connection.id, status, new Date().toISOString(),
      touchLastUsedAt);
    this.keepActiveConnectionInBounds();
    this.persistConnections();
  }

  private applyConnectionCredentials(
    connection: SavedConnection,
    accessToken: string,
    refreshToken: string,
    privateKey: string,
    status: ConnectionStatus = 'online',
    touchLastUsedAt: boolean = true
  ): SavedConnection | undefined {
    this.connections = updateSavedConnection(this.connections, {
      id: connection.id,
      name: connection.name,
      agent: connection.agent,
      host: connection.host,
      port: connection.port,
      scheme: connection.scheme,
      username: connection.username,
      lastUsedAt: touchLastUsedAt ? new Date().toISOString() : connection.lastUsedAt,
      accessTokenRef: accessToken,
      refreshTokenRef: refreshToken,
      privateKeyRef: ''
    }).map((item: SavedConnection) => {
      if (item.id !== connection.id) {
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
        lastUsedAt: item.lastUsedAt,
        status,
        accessTokenRef: item.accessTokenRef,
        refreshTokenRef: item.refreshTokenRef,
        privateKeyRef: item.privateKeyRef
      };
    });
    this.keepActiveConnectionInBounds();
    this.persistConnections();
    return this.connectionById(connection.id);
  }

  private async refreshConnectionCredentials(
    connection: SavedConnection,
    status: ConnectionStatus = 'online',
    touchLastUsedAt: boolean = true
  ): Promise<SavedConnection | undefined> {
    const refreshToken = connection.refreshTokenRef.trim();
    if (refreshToken.length > 0) {
      try {
        const refreshResult = await this.gatewayClient.refresh({
          baseUrl: `${connection.scheme}://${connection.host}:${connection.port}`,
          refreshToken
        });
        return this.applyConnectionCredentials(connection, refreshResult.accessToken, refreshToken, '',
          status, touchLastUsedAt);
      } catch {
        // Refresh token expired, fall through to challenge+verify
      }
    }

    try {
      const nonceResult = await this.gatewayClient.challenge({
        baseUrl: `${connection.scheme}://${connection.host}:${connection.port}`,
        deviceId: this.deviceId
      });
      const sig = await signChallenge(nonceResult.nonce);
      const loginResponse = await this.gatewayClient.verify({
        baseUrl: `${connection.scheme}://${connection.host}:${connection.port}`,
        deviceId: this.deviceId,
        nonce: nonceResult.nonce,
        signature: sig
      });
      return this.applyConnectionCredentials(connection, loginResponse.accessToken, loginResponse.refreshToken, '',
        status, touchLastUsedAt);
    } catch (error) {
      return undefined;
    }
  }

  private async handleConnectionSwitch(connection: SavedConnection): Promise<void> {
    const intent = resolveConnectionSwitchIntent(connection.status);
    if (intent === 'turn_off') {
      this.updateConnectionStatus(connection, 'offline');
      this.feedback = `${connection.name} 已断开`;
      return;
    }

    const readinessError = resolveConnectionReadinessError(connection);
    if (readinessError.length > 0) {
      this.swipedConnectionId = '';
      this.dialogFeedback = '';
      this.feedback = readinessError;
      return;
    }

    if (intent === 'require_login') {
      const refreshedConnection = await this.refreshConnectionCredentials(connection);
      if (refreshedConnection !== undefined) {
        this.feedback = '';
        this.showResumeList(refreshedConnection);
        return;
      }

      this.selectedConnectionId = connection.id;
      this.reloginConnectionId = connection.id;
      this.dialogFeedback = '';
      this.dialog = ConnectionDialog.RELOGIN;
      this.updateBackAvailability();
      return;
    }

    this.updateConnectionStatus(connection, 'online');
    this.feedback = '';
    this.showResumeList(connection);
  }

  private openConnectionActionMenu(connection: SavedConnection): void {
    this.connectionActionMenuId = connection.id;
    this.clearCardActionClickSuppression();
    this.resumeActionMenuId = '';
    this.feedback = '';
  }

  private closeConnectionActionMenu(): void {
    this.connectionActionMenuId = '';
  }

  private consumeSuppressedCardActionClick(): boolean {
    if (!this.suppressNextCardActionClick) {
      return false;
    }

    this.clearCardActionClickSuppression();
    return true;
  }

  private clearCardActionClickSuppression(): void {
    if (this.cardActionClickSuppressTimer >= 0) {
      clearTimeout(this.cardActionClickSuppressTimer);
      this.cardActionClickSuppressTimer = -1;
    }

    this.suppressNextCardActionClick = false;
  }

  private suppressCardActionClickForCurrentTouch(): void {
    this.suppressNextCardActionClick = true;
    if (this.cardActionClickSuppressTimer >= 0) {
      clearTimeout(this.cardActionClickSuppressTimer);
    }

    this.cardActionClickSuppressTimer = setTimeout(() => {
      this.suppressNextCardActionClick = false;
      this.cardActionClickSuppressTimer = -1;
    }, 300);
  }

  private closeConnectionActionMenuIfOpen(connection: SavedConnection): boolean {
    if (this.connectionActionMenuId !== connection.id) {
      return false;
    }

    this.closeConnectionActionMenu();
    return true;
  }

  private handleCardActionOutsideTouch(event: TouchEvent): void {
    if ((this.connectionActionMenuId.length === 0 && this.resumeActionMenuId.length === 0 &&
      this.resumeRenamingId.length === 0) ||
      event.type !== TouchType.Down) {
      return;
    }

    event.stopPropagation();
    this.suppressCardActionClickForCurrentTouch();
    this.closeConnectionActionMenu();
    this.resumeActionMenuId = '';
    this.cancelRenameResumeItem();
  }

  private async addResumeFromCard(connection: SavedConnection): Promise<void> {
    this.connectionActionMenuId = '';
    let targetConnection: SavedConnection = this.connectionById(connection.id) ?? connection;
    if (targetConnection.host.trim().length === 0) {
      this.resumesConnectionId = targetConnection.id;
      this.resumes = [];
      this.resumesFeedback = '无法自动连接服务器';
      this.autoConnectFailedConnectionId = targetConnection.id;
      this.updateConnectionStatus(targetConnection, 'offline');
      return;
    }

    if (targetConnection.accessTokenRef.trim().length === 0 || targetConnection.status === 'needs_login') {
      const refreshedConnection = await this.refreshConnectionCredentials(targetConnection, 'offline');
      if (refreshedConnection !== undefined) {
        targetConnection = refreshedConnection;
      } else {
        this.resumesConnectionId = targetConnection.id;
        this.resumes = [];
        this.resumesFeedback = '无法自动连接服务器';
        this.autoConnectFailedConnectionId = targetConnection.id;
        this.updateConnectionStatus(targetConnection, 'offline');
        return;
      }
    }

    this.selectedConnectionId = targetConnection.id;
    this.connectionActionMenuId = '';
    this.feedback = '';
    this.clearCardAutoConnectFailure(targetConnection.id);
    this.startNewResumeForConnection(targetConnection);
  }

  private async handleResumeFeedbackClick(connection: SavedConnection): Promise<void> {
    if (this.consumeSuppressedCardActionClick()) {
      return;
    }

    if (this.closeConnectionActionMenuIfOpen(connection)) {
      return;
    }

    const action = resolveResumeFeedbackAction(connection.status, this.resumesFeedback, this.cardResumes(connection).length);
    if (action === 'relogin') {
      const refreshedConnection = await this.refreshConnectionCredentials(connection);
      if (refreshedConnection !== undefined) {
        this.loadCardResumes(refreshedConnection);
        return;
      }

      this.promptRelogin(connection, '登录已失效，正在重新认证');
    }
  }

  private promptRelogin(connection: SavedConnection, message: string): void {
    this.selectedConnectionId = connection.id;
    this.reloginConnectionId = connection.id;
    this.draftPassword = '';
    this.dialogFeedback = message;
    this.feedback = '';
    this.resumesFeedback = '';
    this.resumeActionFeedback = '';
    this.openingResumeId = '';
    this.resumeStarting = false;
    this.resumeMessageSending = false;
    this.clearFieldFeedback();
    this.updateConnectionStatus(connection, 'needs_login');
    this.dialog = ConnectionDialog.RELOGIN;
    this.updateBackAvailability();
    this.attemptAutoRelogin(connection);
  }

  private async attemptAutoRelogin(connection: SavedConnection): Promise<void> {
    try {
      const nonceResult = await this.gatewayClient.challenge({
        baseUrl: `${connection.scheme}://${connection.host}:${connection.port}`,
        deviceId: this.deviceId
      });
      const sig = await signChallenge(nonceResult.nonce);
      const loginResponse = await this.gatewayClient.verify({
        baseUrl: `${connection.scheme}://${connection.host}:${connection.port}`,
        deviceId: this.deviceId,
        nonce: nonceResult.nonce,
        signature: sig
      });
      this.applyConnectionCredentials(connection, loginResponse.accessToken, loginResponse.refreshToken, '');
      this.dialog = ConnectionDialog.NONE;
      this.selectedConnectionId = '';
      this.reloginConnectionId = '';
      this.dialogFeedback = '';
      this.updateBackAvailability();
      this.loadCardResumes(connection);
    } catch {
      this.dialogFeedback = '设备密钥已丢失，请重新添加连接';
      this.feedback = '';
    }
  }

  private async reloginSelected(): Promise<void> {
    const targetId = this.reloginConnectionId.length > 0 ? this.reloginConnectionId : this.selectedConnectionId;
    const foundConnection = this.connectionById(targetId);
    if (foundConnection === undefined) {
      this.dialogFeedback = '连接已不存在';
      this.feedback = '';
      return;
    }

    if (this.draftPassword.trim().length === 0) {
      this.passwordFeedback = '请填写注册码';
      this.dialogFeedback = '';
      this.feedback = '';
      return;
    }

    const connection = foundConnection;
    try {
      const nonceResult = await this.gatewayClient.challenge({
        baseUrl: `${connection.scheme}://${connection.host}:${connection.port}`,
        deviceId: this.deviceId
      });
      const sig = await signChallenge(nonceResult.nonce);
      const loginResponse = await this.gatewayClient.verify({
        baseUrl: `${connection.scheme}://${connection.host}:${connection.port}`,
        deviceId: this.deviceId,
        nonce: nonceResult.nonce,
        signature: sig
      });
      this.applyConnectionCredentials(connection, loginResponse.accessToken, loginResponse.refreshToken, '');
      this.feedback = '';
      const refreshedConnection = this.connectionById(connection.id);
      this.dialog = ConnectionDialog.NONE;
      this.selectedConnectionId = '';
      this.reloginConnectionId = '';
      this.dialogFeedback = '';
      this.draftPassword = '';
      this.updateBackAvailability();
      if (refreshedConnection !== undefined) {
        this.loadCardResumes(refreshedConnection);
      }
    } catch (error) {
      this.dialogFeedback = this.resolveLoginFailureText(error as Error);
      this.feedback = '';
    }
  }

  private resolveLoginFailureText(error: Error): string {
    if (isGatewayNetworkError(error)) {
      const networkError = error as GatewayNetworkError;
      const detail: string = networkError.detail.length > 0 ? networkError.detail.toLowerCase() : '';
      if (detail.includes('certificate') || detail.includes('cert')) {
        return '证书校验失败：服务器证书不受信任，请联系管理员更新证书';
      }
      if (detail.includes('timeout') || detail.includes('timed out')) {
        return '连接超时：请检查服务器是否在线及网络连接';
      }
      if (detail.includes('refused') || detail.includes('econnrefused')) {
        return '连接被拒绝：请检查服务器端口是否开放';
      }
      if (detail.includes('dns') || detail.includes('eai_again') || detail.includes('ehostunreach')) {
        return '无法解析主机：请检查服务器地址是否正确';
      }
      return '网络异常，无法连接服务器，请检查地址和网络';
    }

    if (isGatewayAuthenticationError(error)) {
      const authError = error as GatewayHttpError;
      if (authError.statusCode === 401) {
        return '认证失败：注册码错误或已被使用';
      }
      return `认证失败(${authError.statusCode})：设备无权访问`;
    }

    return '服务器异常，请稍后重试';
  }

  private addConnectionCardOffsetY(): number {
    const keyboardHeight = this.keyboardHeight();
    const visiblePageHeight = this.addConnectionPageHeight > 0 ? this.addConnectionPageHeight :
      Math.max(0, this.addConnectionScreenHeight - keyboardHeight);
    return resolveAddConnectionResponsiveCardOffset(visiblePageHeight, this.addConnectionScreenHeight,
      this.addConnectionMeasuredCardHeight(), ADD_CONNECTION_KEYBOARD_GAP, keyboardHeight);
  }

  private addConnectionMeasuredCardHeight(): number {
    return resolveAddConnectionMeasuredCardHeight(this.addConnectionCardHeight, this.addConnectionNaturalCardHeight,
      ADD_CONNECTION_CARD_MIN_NATURAL_HEIGHT);
  }

  private keyboardHeight(): number {
    return Math.max(0, this.getUIContext().px2vp(this.keyboardHeightPx));
  }

  private areaLengthToNumber(value: Length): number {
    if (typeof value === 'number') {
      return value;
    }

    if (typeof value === 'string') {
      const parsed = Number(value.replace('vp', '').replace('px', '').replace('%', '').trim());
      return parsed === parsed ? parsed : 0;
    }

    return 0;
  }

  private activeResumeTitle(): string {
    if (!this.hasActiveResumeSession) {
      return '';
    }

    return this.activeResumeSession.title;
  }

  private activeResumeShortTitle(): string {
    const title = this.activeResumeTitle();
    if (title.length === 0) {
      return '会话';
    }

    if (title.length <= 8) {
      return title;
    }

    return `${title.substring(0, 8)}...`;
  }

  private activeResumeCwd(): string {
    if (!this.hasActiveResumeSession) {
      return '';
    }

    return this.activeResumeSession.cwd;
  }

  private activeResumeDirectoryText(): string {
    return resolveResumeDirectoryText(this.activeResumeCwd());
  }

  private activeResumeTurns(): ResumeTurn[] {
    if (!this.hasActiveResumeSession) {
      return [];
    }

    return this.activeResumeSession.turns;
  }

  private resumeCanSubmitMessage(): boolean {
    return !this.resumeMessageSending && !this.resumeStarting && this.hasActiveResumeSession &&
      this.activeResumeSession.threadId.length > 0;
  }

  private resumeSendButtonLabel(): string {
    if (this.resumeStarting) {
      return '创建中';
    }

    if (this.activeResumeSession.threadId.length === 0) {
      return '不可用';
    }

    return this.resumeMessageSending ? '等待中' : '发送';
  }

  private resumeInputText(): string {
    return this.resumeMessageDraft.length === 0 ? RESUME_INPUT_GUARD : this.resumeMessageDraft;
  }

  private normalizeResumeInputText(text: string): string {
    return text.split(RESUME_INPUT_GUARD).join('');
  }

  private resumeTextIsBlank(text: string): boolean {
    if (text.length === 0) {
      return true;
    }

    for (let i = 0; i < text.length; i++) {
      const char: string = text.charAt(i);
      if (char !== ' ' && char !== '\n' && char !== '\t' && char !== '\r') {
        return false;
      }
    }
    return true;
  }

  private resumeComposerInputHeight(): number {
    const explicitLines = this.resumeMessageDraft.split('\n').length;
    const lines = Math.max(1, Math.min(RESUME_COMPOSER_MAX_LINES, explicitLines));
    return RESUME_COMPOSER_BASE_HEIGHT + lines * RESUME_COMPOSER_LINE_HEIGHT;
  }

  private handleResumeComposerKeyEvent(event: KeyEvent): void {
    if (event.type !== KeyType.Down) {
      return;
    }
    if (event.keyCode !== KeyCode.KEYCODE_ENTER) {
      return;
    }
    if (event.metaKey !== 0) {
      return;
    }
    this.sendResumeMessage();
  }

  private copyResumeText(text: string, successFeedback: string): void {
    if (text.length === 0) {
      return;
    }

    pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)).then(() => {
      this.resumeActionFeedback = successFeedback;
    }).catch(() => {
      this.resumeActionFeedback = '复制失败';
    });
  }

  private openResumeMarkdownLink(address: string): void {
    if (address.length === 0) {
      return;
    }

    const hostContext = this.getUIContext().getHostContext();
    if (hostContext === undefined) {
      return;
    }

    const context = hostContext as common.UIAbilityContext;
    context.openLink(address).then(() => {
    }).catch(() => {
      this.resumeActionFeedback = '链接打开失败';
    });
  }

  private resumeContentSize(baseSize: number): number {
    return resolveResumeContentScaledSize(baseSize, this.resumeContentZoomScale);
  }

  private resumeTurnItemTimestampText(turn: ResumeTurn, item: ResumeContentItem): string {
    if (item.role === 'user') {
      return resolveResumeTimestampText(turn.startedAt);
    }

    return resolveResumeTimestampText(turn.completedAt.length > 0 ? turn.completedAt : turn.startedAt);
  }

  private resetResumeContentZoomScale(): void {
    this.resumeContentZoomScale = resolveResumeContentInitialZoomScale();
    this.resumePinchStartScale = this.resumeContentZoomScale;
  }

  private handleResumeContentPinchStart(): void {
    this.resumePinchStartScale = this.resumeContentZoomScale;
  }

  private handleResumeContentPinchUpdate(event: GestureEvent): void {
    this.resumeContentZoomScale = resolveResumeContentZoomScale(this.resumePinchStartScale, event.scale);
  }

  private handleResumeContentPinchEnd(event: GestureEvent): void {
    this.resumeContentZoomScale = resolveResumeContentZoomScale(this.resumePinchStartScale, event.scale);
    this.resumePinchStartScale = this.resumeContentZoomScale;
  }

  private handleResumeContentPinchCancel(): void {
    this.resumePinchStartScale = this.resumeContentZoomScale;
  }

  private clearActiveResumeSession(): void {
    this.stopResumeWaitingIndicator();
    this.stopResumeAutoRefresh();
    this.clearResumePageTapTimer();
    this.clearResumeCenterNotice();
    this.resumeShouldFollowOutput = true;
    this.resumeScrollAwayVersion++;
    this.hasActiveResumeSession = false;
    this.activeResumeSession = emptyResumeSession();
    this.resumeStopRequested = false;
    this.resumeComposerVisible = true;
    this.updateBackAvailability();
  }

  private backToResumeList(): void {
    const connection = this.selectedConnection();
    this.clearActiveResumeSession();
    this.resumeActionFeedback = '';
    this.openingResumeId = '';
    this.resumeStarting = false;
    this.resumeMessageDraft = '';
    this.resumeMessageSending = false;
    this.pendingResumeMessage = '';
    this.pendingResumeMessageTimestamp = '';
    this.resumeComposerVisible = true;
    this.resumeRefreshToken++;
    if (connection.id.length > 0) {
      this.dialog = ConnectionDialog.NONE;
      this.updateBackAvailability();
      this.loadCardResumes(connection);
    }
  }

  private canBackInApp(): boolean {
    return this.hasActiveResumeSession || this.dialog !== ConnectionDialog.NONE || this.selectedTab === AppTab.FILES;
  }

  private handlePageBack(): boolean {
    if (this.selectedTab === AppTab.FILES && !this.hasActiveResumeSession && this.dialog === ConnectionDialog.NONE) {
      this.selectedTab = AppTab.CONNECT;
      this.updateBackAvailability();
      return true;
    }

    if (this.hasActiveResumeSession) {
      this.backToResumeList();
      return true;
    }

    if (this.dialog !== ConnectionDialog.NONE) {
      this.closeDialog();
      return true;
    }

    return false;
  }

  private handlePageLeftSwipe(offsetX: number): void {
    if (offsetX >= -60) {
      return;
    }

    this.handlePageBack();
  }

  private shouldShowRightEdgeBackGesture(): boolean {
    return this.hasActiveResumeSession || this.dialog === ConnectionDialog.ADD ||
      this.dialog === ConnectionDialog.RESUME_LIST;
  }

  private resolveConnectionForFiles(): SavedConnection | null {
    if (this.selectedTab !== AppTab.FILES) {
      return null;
    }

    const activeId = resolveActiveConnectionId(this.connections, this.activeConnectionId,
      this.activeConnectionIndex);
    const found = this.connections.find((item: SavedConnection) => item.id === activeId);
    if (found === undefined) {
      return null;
    }

    if (found.accessTokenRef.trim().length === 0) {
      return null;
    }

    return found;
  }

  private refreshServerFilesOnTabOpen(): void {
    const connection = this.resolveConnectionForFiles();
    if (connection === null) {
      this.serverFilesFeedback = '请先添加并登录一个连接';
      return;
    }
    this.loadServerFiles(connection);
  }

  private async loadServerFiles(connection: SavedConnection | null): Promise<void> {
    if (connection === null || connection.accessTokenRef.trim().length === 0) {
      return;
    }

    this.serverFilesLoading = true;
    this.serverFiles = [];
    this.serverFilesConnectionId = connection.id;
    this.serverFilesFeedback = '';
    this.downloadFeedback = '';
    this.downloadedFileName = '';
    this.openingFileName = '';

    try {
      const baseUrl = `${connection.scheme}://${connection.host}:${connection.port}`;
      const loadedFiles = await this.gatewayClient.listFiles({
        baseUrl,
        accessToken: connection.accessTokenRef
      });
      this.serverFiles = loadedFiles;
      if (this.serverFiles.length === 0) {
        this.serverFilesFeedback = '暂无文件';
      }
    } catch (error) {
      console.error(`[ServerFiles] 获取文件失败: ${JSON.stringify(error)}`);
      this.serverFilesFeedback = isGatewayNetworkError(error) ?
        '无法连接到服务器' :
        isGatewayAuthenticationError(error) ? '登录已失效，请重新登录' : '获取文件失败';
    } finally {
      this.serverFilesLoading = false;
    }
  }

  private async downloadServerFile(connection: SavedConnection | null, file: ServerFile): Promise<void> {
    if (connection === null || connection.accessTokenRef.trim().length === 0 ||
      this.downloadingFileId.length > 0) {
      return;
    }

    if (!this.isSafeServerFileName(file.name)) {
      this.downloadFeedback = '文件名不合法';
      return;
    }

    this.downloadingFileId = file.name;
    this.downloadFeedback = '';
    this.downloadedFileName = '';

    try {
      const baseUrl = `${connection.scheme}://${connection.host}:${connection.port}`;
      const downloaded = await this.gatewayClient.downloadFile({
        baseUrl,
        accessToken: connection.accessTokenRef,
        fileName: file.name
      });
      const savedName = await this.saveFileToOutputDir(downloaded.name, downloaded.bytes);
      this.downloadFeedback = `已保存 ${savedName}`;
      this.downloadedFileName = file.name;
    } catch (error) {
      console.error(`[ServerFiles] 下载失败: ${JSON.stringify(error)}`);
      this.downloadFeedback = isGatewayNetworkError(error) ?
        '下载失败：网络错误' :
        (isGatewayAuthenticationError(error) ? '登录已失效，请重新登录' : '下载失败');
    } finally {
      this.downloadingFileId = '';
    }
  }

  private isSafeServerFileName(name: string): boolean {
    return name.length > 0 && !name.includes('/') && !name.includes('\\') && !name.includes('..');
  }

  private async saveFileToOutputDir(fileName: string, bytes: ArrayBuffer): Promise<string> {
    const hostContext = this.getUIContext().getHostContext();
    if (hostContext === null || hostContext === undefined) {
      throw new Error('no host context');
    }

    const context = hostContext as common.UIAbilityContext;
    let filesDir: string = '';
    try {
      filesDir = context.filesDir;
    } catch (error) {
      console.error(`[ServerFiles] 获取 filesDir 失败: ${JSON.stringify(error)}`);
      throw new Error('无法获取存储目录');
    }

    const outputDir = `${filesDir}/${FILES_OUTPUT_DIR}`;
    let dirExists = false;
    try {
      dirExists = await fileIo.access(outputDir);
    } catch (error) {
      dirExists = false;
    }
    if (!dirExists) {
      try {
        await fileIo.mkdir(outputDir, true);
      } catch (error) {
        console.error(`[ServerFiles] 创建目录失败: ${JSON.stringify(error)}`);
        throw new Error('无法创建输出目录');
      }
    }

    const destination = `${outputDir}/${fileName}`;
    let fileDescriptor: number = -1;
    try {
      const openedFile = await fileIo.open(destination,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileDescriptor = openedFile.fd;
    } catch (error) {
      console.error(`[ServerFiles] 打开文件失败: ${JSON.stringify(error)}`);
      throw new Error('无法创建文件');
    }
    try {
      await fileIo.write(fileDescriptor, bytes);
    } catch (error) {
      console.error(`[ServerFiles] 写入文件失败: ${JSON.stringify(error)}`);
      throw new Error('写入文件失败');
    } finally {
      try {
        await fileIo.close(fileDescriptor);
      } catch (error) {
        console.error(`[ServerFiles] 关闭文件失败: ${JSON.stringify(error)}`);
      }
    }

    return fileName;
  }

  private formatServerFileSize(size: number): string {
    if (size < 1024) {
      return `${size.toString()} B`;
    }
    if (size < 1024 * 1024) {
      return `${(size / 1024).toFixed(1)} KB`;
    }
    return `${(size / (1024 * 1024)).toFixed(1)} MB`;
  }

  private formatServerFileDate(value: string): string {
    const trimmed = value.trim();
    if (trimmed.length === 0) {
      return '';
    }
    const parsed = Date.parse(trimmed);
    if (Number.isNaN(parsed)) {
      return trimmed;
    }
    const date = new Date(parsed);
    return `${date.getFullYear()}-${this.padServerFileNumber(date.getMonth() + 1)}-` +
      `${this.padServerFileNumber(date.getDate())} ${this.padServerFileNumber(date.getHours())}:` +
      `${this.padServerFileNumber(date.getMinutes())}`;
  }

  private padServerFileNumber(value: number): string {
    return value < 10 ? `0${value.toString()}` : value.toString();
  }

  private async openDownloadedFile(fileName: string): Promise<void> {
    const connection = this.resolveConnectionForFiles();
    if (connection === null || connection.accessTokenRef.trim().length === 0 ||
      this.openingFileName.length > 0) {
      return;
    }

    this.openingFileName = fileName;
    this.downloadFeedback = '';

    try {
      const baseUrl = `${connection.scheme}://${connection.host}:${connection.port}`;
      const downloaded = await this.gatewayClient.downloadFile({
        baseUrl,
        accessToken: connection.accessTokenRef,
        fileName
      });

      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentPicker = new picker.DocumentViewPicker(context);
      const uris = await documentPicker.save({ newFileNames: [fileName] });

      if (uris.length === 0) {
        this.openingFileName = '';
        return;
      }

      const file = await fileIo.open(uris[0],
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        await fileIo.write(file.fd, downloaded.bytes);
      } finally {
        await fileIo.close(file);
      }

      const want: Want = {
        uri: uris[0],
        type: resolveMimeType(fileName)
      };
      await context.startAbility(want);
      this.downloadFeedback = `已打开 ${fileName}`;
    } catch (error) {
      console.error(`[ServerFiles] 打开文件失败: ${JSON.stringify(error)}`);
      this.downloadFeedback = '打开失败';
    } finally {
      this.openingFileName = '';
    }
  }

  private async sendResumeMessage(): Promise<void> {
    if (!this.hasActiveResumeSession || this.resumeMessageSending) {
      return;
    }

    if (this.resumeStarting || this.activeResumeSession.threadId.length === 0) {
      this.resumeActionFeedback = '会话创建中';
      return;
    }

    const message = this.normalizeResumeInputText(this.resumeMessageDraft).trim();
    if (message.length === 0) {
      this.resumeActionFeedback = '请输入消息';
      return;
    }

    const connection = this.selectedConnection();
    if (connection.id.length === 0) {
      this.resumeActionFeedback = '连接不可用';
      return;
    }

    this.resumeMessageSending = true;
    this.pendingResumeMessage = message;
    this.pendingResumeMessageTimestamp = resolveResumeTimestampText(new Date().toISOString());
    this.resumeMessageDraft = '';
    this.resumeJustSent = true;
    this.resumeStopRequested = false;
    this.resumeRefreshToken++;
    this.resumeActionFeedback = '';
    this.startResumeWaitingIndicator();
    this.scrollActiveResumeToBottom();
    try {
      const session: ResumeSession = await this.gatewayClient.sendResumeMessage({
        baseUrl: `${connection.scheme}://${connection.host}:${connection.port}`,
        accessToken: connection.accessTokenRef,
        threadId: this.activeResumeSession.threadId,
        message
      });
      this.activeResumeSession = session;
      this.hasActiveResumeSession = true;
      this.updateConnectionStatus(connection, 'online');
      this.pendingResumeMessage = '';
      this.pendingResumeMessageTimestamp = '';
      if (session.turns.length === 0) {
        this.resumeActionFeedback = '已发送，但没有可展示的历史内容';
        this.resumeMessageSending = false;
        this.syncResumeWaitingIndicator();
        this.syncResumeAutoRefresh();
        return;
      }

      this.resumeActionFeedback = '';
      this.resumeMessageSending = false;
      this.resumeComposerVisible = true;
      this.syncResumeWaitingIndicator();
      this.syncResumeAutoRefresh();
      this.scrollActiveResumeToBottom(false);
    } catch (error) {
      if (isGatewayAuthenticationError(error as Error)) {
        const refreshedConnection = await this.refreshConnectionCredentials(connection);
        if (refreshedConnection !== undefined) {
          this.resumeMessageSending = false;
          this.resumeMessageDraft = this.pendingResumeMessage;
          this.pendingResumeMessage = '';
          this.pendingResumeMessageTimestamp = '';
          this.resumeComposerVisible = true;
          this.syncResumeWaitingIndicator();
          this.syncResumeAutoRefresh();
          this.sendResumeMessage();
          return;
        }

        this.promptRelogin(connection, '登录已失效，正在重新认证');
        this.resumeMessageSending = false;
        this.pendingResumeMessage = '';
        this.pendingResumeMessageTimestamp = '';
        this.resumeComposerVisible = true;
        this.syncResumeWaitingIndicator();
        this.syncResumeAutoRefresh();
        return;
      }

      this.resumeActionFeedback = '消息已发送，等待回复中...';
      this.resumeMessageSending = false;
      this.pendingResumeMessage = '';
      this.pendingResumeMessageTimestamp = '';
      this.resumeComposerVisible = true;
      this.syncResumeWaitingIndicator();
      this.scheduleTimeoutRetryRefresh();
    }
  }

  private resumeHasInProgressTurn(session: ResumeSession): boolean {
    return session.turns.some((turn: ResumeTurn) => turn.status === 'inProgress');
  }

  private resumeIsWaitingForResponse(): boolean {
    if (!this.hasActiveResumeSession) {
      return false;
    }

    if (this.resumeStopRequested) {
      return false;
    }

    return this.resumeMessageSending || this.pendingResumeMessage.length > 0 ||
      this.resumeHasInProgressTurn(this.activeResumeSession);
  }

  private startResumeWaitingIndicator(): void {
    this.waitingDotsPhase = 0;
    if (this.waitingDotsTimer >= 0) {
      return;
    }

    this.waitingDotsTimer = setInterval(() => {
      if (!this.resumeShouldFollowOutput) {
        if (this.waitingDotsPhase !== 0) {
          this.waitingDotsPhase = 0;
        }
        return;
      }

      this.waitingDotsPhase = this.waitingDotsPhase >= 3 ? 1 : this.waitingDotsPhase + 1;
    }, 500);
  }

  private stopResumeWaitingIndicator(): void {
    if (this.waitingDotsTimer >= 0) {
      clearInterval(this.waitingDotsTimer);
      this.waitingDotsTimer = -1;
    }
    this.waitingDotsPhase = 0;
    this.resumeWasWaitingForResponse = false;
  }

  private syncResumeWaitingIndicator(): void {
    const isWaiting = this.resumeIsWaitingForResponse();
    if (isWaiting) {
      this.resumeWasWaitingForResponse = true;
      this.startResumeWaitingIndicator();
      return;
    }

    this.stopResumeWaitingIndicator();
  }

  private scheduleResumeAutoRefresh(): void {
    if (this.resumeAutoRefreshTimer >= 0 || !this.hasActiveResumeSession || this.resumeStopRequested) {
      return;
    }

    const threadId = this.activeResumeSession.threadId;
    const refreshToken = this.resumeRefreshToken;
    const hasInProgress = this.resumeHasInProgressTurn(this.activeResumeSession);
    const delay = hasInProgress ? 3000 : 10000;
    this.resumeAutoRefreshTimer = setTimeout(() => {
      this.resumeAutoRefreshTimer = -1;
      this.refreshActiveResumeSilently(threadId, refreshToken);
    }, delay);
  }

  private stopResumeAutoRefresh(): void {
    if (this.resumeAutoRefreshTimer >= 0) {
      clearTimeout(this.resumeAutoRefreshTimer);
      this.resumeAutoRefreshTimer = -1;
    }
  }

  private syncResumeAutoRefresh(): void {
    if (this.hasActiveResumeSession) {
      this.scheduleResumeAutoRefresh();
      return;
    }

    this.stopResumeAutoRefresh();
  }

  private stopResumeGeneration(): void {
    this.resumeMessageSending = false;
    this.pendingResumeMessage = '';
    this.pendingResumeMessageTimestamp = '';
    this.resumeRefreshToken++;
    this.resumeStopRequested = true;
    this.resumeComposerVisible = true;
    this.stopResumeAutoRefresh();
    this.stopResumeWaitingIndicator();
    this.resumeActionFeedback = '已停止接收更新';
  }

  private scheduleTimeoutRetryRefresh(): void {
    if (!this.hasActiveResumeSession) {
      return;
    }

    const threadId = this.activeResumeSession.threadId;
    const refreshToken = this.resumeRefreshToken;
    let retries = 0;
    const maxRetries = 20;
    const interval = 3000;

    const poll = () => {
      if (retries >= maxRetries || refreshToken !== this.resumeRefreshToken) {
        return;
      }
      retries++;
      this.resumeAutoRefreshTimer = setTimeout(() => {
        this.resumeAutoRefreshTimer = -1;
        this.refreshActiveResumeSilently(threadId, refreshToken);
        if (this.hasActiveResumeSession && this.resumeHasInProgressTurn(this.activeResumeSession)) {
          poll();
        }
      }, interval);
    };
    poll();
  }

  private showResumeCenterNotice(message: string): void {
    this.clearResumeCenterNotice();
    this.resumeCenterNotice = message;
    this.resumeCenterNoticeTimer = setTimeout(() => {
      if (this.resumeCenterNotice === message) {
        this.resumeCenterNotice = '';
      }
      this.resumeCenterNoticeTimer = -1;
    }, 3000);
  }

  private clearResumeCenterNotice(): void {
    if (this.resumeCenterNoticeTimer >= 0) {
      clearTimeout(this.resumeCenterNoticeTimer);
      this.resumeCenterNoticeTimer = -1;
    }
    this.resumeCenterNotice = '';
  }

  private revealResumeComposer(): void {
    if (!this.resumeComposerVisible) {
      this.resumeComposerVisible = true;
    }
  }

  private hideResumeComposer(): void {
    if (this.resumeComposerVisible) {
      this.resumeComposerVisible = false;
    }
  }

  private clearResumePageTapTimer(): void {
    if (this.resumePageTapTimer >= 0) {
      clearTimeout(this.resumePageTapTimer);
      this.resumePageTapTimer = -1;
    }
  }

  private handleResumePageTap(): void {
    if (this.resumePageTapTimer >= 0) {
      this.clearResumePageTapTimer();
      return;
    }

    this.resumePageTapTimer = setTimeout(() => {
      this.resumePageTapTimer = -1;
    }, 300);
  }

  private waitingDotsText(): string {
    if (!this.resumeShouldFollowOutput) {
      return resolveWaitingResponseText(0);
    }

    return resolveWaitingResponseText(this.waitingDotsPhase);
  }

  private updateResumeScrollFollowAnchor(): void {
    try {
      const isAtEnd = this.resumeContentScroller.isAtEnd();
      if (isAtEnd && !this.resumeShouldFollowOutput && this.resumeIsWaitingForResponse()) {
        this.waitingDotsPhase = 1;
      }
      this.resumeShouldFollowOutput = isAtEnd;
      if (!isAtEnd) {
        this.resumeScrollAwayVersion++;
      }
    } catch (error) {
    }
  }

  private scrollActiveResumeToBottom(force: boolean = true): void {
    if (!force && !this.resumeShouldFollowOutput) {
      return;
    }

    const scrollAwayVersion = this.resumeScrollAwayVersion;
    setTimeout(() => {
      if (!force && !this.resumeShouldFollowOutput) {
        return;
      }

      if (force && scrollAwayVersion !== this.resumeScrollAwayVersion) {
        return;
      }

      try {
        this.resumeContentScroller.scrollEdge(Edge.Bottom);
        this.resumeShouldFollowOutput = true;
      } catch (error) {
      }
    }, 80);
  }

  private async refreshActiveResume(): Promise<void> {
    if (!this.hasActiveResumeSession) {
      return;
    }

    const connection = this.selectedConnection();
    if (connection.id.length === 0) {
      this.resumeActionFeedback = '连接不可用';
      return;
    }

    try {
      const session: ResumeSession = await this.gatewayClient.resumeThread({
        baseUrl: `${connection.scheme}://${connection.host}:${connection.port}`,
        accessToken: connection.accessTokenRef,
        threadId: this.activeResumeSession.threadId
      });
      this.activeResumeSession = session;
      this.hasActiveResumeSession = true;
      this.updateConnectionStatus(connection, 'online');
      if (!this.resumeHasInProgressTurn(session) && this.resumeActionFeedback.indexOf('仍在处理中') === 0) {
        this.resumeActionFeedback = '';
        this.resumeMessageSending = false;
      }
      this.syncResumeWaitingIndicator();
      this.syncResumeAutoRefresh();
      this.scrollActiveResumeToBottom(false);
    } catch (error) {
      if (isGatewayAuthenticationError(error as Error)) {
        const refreshedConnection = await this.refreshConnectionCredentials(connection);
        if (refreshedConnection !== undefined) {
          this.refreshActiveResume();
          return;
        }

        this.promptRelogin(connection, '登录已失效，正在重新认证');
        return;
      }

      this.resumeActionFeedback = '刷新会话失败';
    }
  }

  private async refreshActiveResumeSilently(threadId: string, refreshToken: number): Promise<void> {
    if (!this.hasActiveResumeSession || this.activeResumeSession.threadId !== threadId ||
      this.resumeRefreshToken !== refreshToken) {
      return;
    }

    const connection = this.selectedConnection();
    if (connection.id.length === 0) {
      this.syncResumeAutoRefresh();
      return;
    }

    try {
      const session: ResumeSession = await this.gatewayClient.resumeThread({
        baseUrl: `${connection.scheme}://${connection.host}:${connection.port}`,
        accessToken: connection.accessTokenRef,
        threadId
      });
      if (!this.hasActiveResumeSession || this.activeResumeSession.threadId !== threadId ||
        this.resumeRefreshToken !== refreshToken) {
        return;
      }

      this.activeResumeSession = session;
      this.hasActiveResumeSession = true;
      this.updateConnectionStatus(connection, 'online');
      if (!this.resumeHasInProgressTurn(session)) {
        this.resumeMessageSending = false;
        this.pendingResumeMessage = '';
        this.pendingResumeMessageTimestamp = '';
      }
      this.syncResumeWaitingIndicator();
      this.syncResumeAutoRefresh();
      this.scrollActiveResumeToBottom(false);
    } catch (error) {
      if (isGatewayAuthenticationError(error as Error)) {
        const refreshedConnection = await this.refreshConnectionCredentials(connection);
        if (refreshedConnection !== undefined) {
          this.refreshActiveResumeSilently(threadId, refreshToken);
          return;
        }

        this.promptRelogin(connection, '登录已失效，正在重新认证');
        return;
      }

      this.stopResumeAutoRefresh();
    }
  }

  private resumePromptText(item: ResumeContentItem): string {
    if (item.role === 'user') {
      return '用户';
    }

    if (item.role === 'assistant') {
      return 'OpenCode';
    }

    if (item.role === 'tool') {
      return `OpenCode ${item.kind}`;
    }

    return 'OpenCode';
  }

  private resumeItemColor(item: ResumeContentItem): Resource {
    if (item.role === 'user') {
      return TERMINAL_BLUE_COLOR;
    }

    if (item.role === 'assistant') {
      return item.kind === 'reasoning' ? TERMINAL_AMBER_COLOR : TERMINAL_GREEN_COLOR;
    }

    if (item.role === 'tool') {
      return TERMINAL_AMBER_COLOR;
    }

    return TERMINAL_MUTED_TEXT_COLOR;
  }

  private resumeBodyTextStyle(item: ResumeContentItem): string {
    if (item.role === 'user') {
      return RESUME_TEXT_STYLE_USER;
    }

    if (item.role === 'assistant') {
      return item.kind === 'reasoning' ? RESUME_TEXT_STYLE_REASONING : RESUME_TEXT_STYLE_ASSISTANT;
    }

    if (item.role === 'tool') {
      return RESUME_TEXT_STYLE_TOOL;
    }

    return RESUME_TEXT_STYLE_ASSISTANT;
  }

  private resumeBodyTextColor(item: ResumeContentItem): Resource {
    const style = this.resumeBodyTextStyle(item);
    if (style === RESUME_TEXT_STYLE_USER) {
      return TERMINAL_USER_BODY_TEXT_COLOR;
    }

    if (style === RESUME_TEXT_STYLE_REASONING) {
      return TERMINAL_REASONING_BODY_TEXT_COLOR;
    }

    if (style === RESUME_TEXT_STYLE_TOOL) {
      return TERMINAL_TOOL_BODY_TEXT_COLOR;
    }

    return TERMINAL_TEXT_COLOR;
  }

  private resumeItemSurfaceColor(item: ResumeContentItem): Resource {
    if (item.role === 'user') {
      return TERMINAL_USER_MESSAGE_SURFACE_COLOR;
    }

    return TERMINAL_TRANSPARENT_COLOR;
  }

  private resumeSegmentTextColor(segment: ResumeTextSegment, item: ResumeContentItem): Resource {
    if (segment.style === RESUME_TEXT_STYLE_CODE) {
      return TERMINAL_INLINE_CODE_COLOR;
    }

    if (segment.style === RESUME_TEXT_STYLE_PATH) {
      return TERMINAL_INLINE_PATH_COLOR;
    }

    if (segment.style === RESUME_TEXT_STYLE_SUCCESS) {
      return TERMINAL_GREEN_COLOR;
    }

    if (segment.style === RESUME_TEXT_STYLE_WARNING) {
      return TERMINAL_AMBER_COLOR;
    }

    if (segment.style === RESUME_TEXT_STYLE_DANGER) {
      return TERMINAL_DANGER_TEXT_COLOR;
    }

    return this.resumeBodyTextColor(item);
  }

  private resumeSegmentFontWeight(segment: ResumeTextSegment): FontWeight {
    if (segment.style === RESUME_TEXT_STYLE_CODE || segment.style === RESUME_TEXT_STYLE_PATH ||
      segment.style === RESUME_TEXT_STYLE_DANGER) {
      return FontWeight.Medium;
    }

    return FontWeight.Regular;
  }

  private resumeInlineCodeStyle(text: string): string {
    if (this.resumeLooksLikePath(text)) {
      return RESUME_TEXT_STYLE_PATH;
    }

    return RESUME_TEXT_STYLE_CODE;
  }

  private resumeLooksLikePath(text: string): boolean {
    return text.indexOf('/') >= 0 || text.indexOf('\\') >= 0 ||
      text.endsWith('.ets') || text.endsWith('.ts') || text.endsWith('.js') ||
      text.endsWith('.json') || text.endsWith('.json5') || text.endsWith('.md') ||
      text.endsWith('.txt') || text.endsWith('.ps1') || text.endsWith('.bat');
  }

  private findResumeKeywordMatch(text: string, start: number, tokens: string[], style: string): ResumeKeywordMatch {
    let bestStart = -1;
    let bestEnd = -1;
    const normalized = text.toLowerCase();
    for (let index = 0; index < tokens.length; index++) {
      const matchStart = normalized.indexOf(tokens[index], start);
      if (matchStart < 0) {
        continue;
      }

      const matchEnd = matchStart + tokens[index].length;
      if (bestStart < 0 || matchStart < bestStart || (matchStart === bestStart && matchEnd > bestEnd)) {
        bestStart = matchStart;
        bestEnd = matchEnd;
      }
    }

    return {
      start: bestStart,
      end: bestEnd,
      style
    };
  }

  private nextResumeKeywordMatch(text: string, start: number): ResumeKeywordMatch {
    const danger = this.findResumeKeywordMatch(text, start, RESUME_DANGER_TOKENS, RESUME_TEXT_STYLE_DANGER);
    const warning = this.findResumeKeywordMatch(text, start, RESUME_WARNING_TOKENS, RESUME_TEXT_STYLE_WARNING);
    const success = this.findResumeKeywordMatch(text, start, RESUME_SUCCESS_TOKENS, RESUME_TEXT_STYLE_SUCCESS);
    let result = danger;

    if (result.start < 0 || (warning.start >= 0 && warning.start < result.start)) {
      result = warning;
    }

    if (result.start < 0 || (success.start >= 0 && success.start < result.start)) {
      result = success;
    }

    return result;
  }

  private appendResumeTextSegment(segments: ResumeTextSegment[], text: string, style: string): void {
    if (text.length === 0) {
      return;
    }

    const lastIndex = segments.length - 1;
    if (lastIndex >= 0 && segments[lastIndex].style === style) {
      segments[lastIndex] = {
        id: segments[lastIndex].id,
        text: `${segments[lastIndex].text}${text}`,
        style
      };
      return;
    }

    segments.push({
      id: `${segments.length}-${style}`,
      text,
      style
    });
  }

  private appendResumePlainTextSegments(segments: ResumeTextSegment[], text: string, fallbackStyle: string): void {
    let lineStart = 0;
    let inFileDiffContext = false;
    for (let index = 0; index <= text.length; index++) {
      if (index < text.length && text.charAt(index) !== '\n') {
        continue;
      }

      const lineEnd = index < text.length ? index + 1 : index;
      const line = text.substring(lineStart, lineEnd);
      inFileDiffContext = resolveResumeDiffLineContext(line, inFileDiffContext);
      const lineStyle = resolveResumeDiffLineTextStyle(line, fallbackStyle, RESUME_TEXT_STYLE_DANGER,
        RESUME_TEXT_STYLE_SUCCESS, inFileDiffContext);
      if (lineStyle !== fallbackStyle) {
        this.appendResumeTextSegment(segments, line, lineStyle);
      } else {
        this.appendResumePlainLineSegments(segments, line, fallbackStyle);
      }
      lineStart = index + 1;
    }
  }

  private appendResumePlainLineSegments(segments: ResumeTextSegment[], text: string, fallbackStyle: string): void {
    let cursor = 0;
    while (cursor < text.length) {
      const match = this.nextResumeKeywordMatch(text, cursor);
      if (match.start < 0) {
        this.appendResumeTextSegment(segments, text.substring(cursor), fallbackStyle);
        return;
      }

      if (match.start > cursor) {
        this.appendResumeTextSegment(segments, text.substring(cursor, match.start), fallbackStyle);
      }

      this.appendResumeTextSegment(segments, text.substring(match.start, match.end), match.style);
      cursor = match.end;
    }
  }

  private resumeTextSegments(item: ResumeContentItem): ResumeTextSegment[] {
    const segments: ResumeTextSegment[] = [];
    const fallbackStyle = this.resumeBodyTextStyle(item);
    let plainText = '';
    let inlineText = '';
    let inInlineCode = false;

    for (let index = 0; index < item.text.length; index++) {
      const char = item.text.charAt(index);
      if (char === '`') {
        if (inInlineCode) {
          this.appendResumeTextSegment(segments, inlineText, this.resumeInlineCodeStyle(inlineText));
          inlineText = '';
          inInlineCode = false;
        } else {
          this.appendResumePlainTextSegments(segments, plainText, fallbackStyle);
          plainText = '';
          inInlineCode = true;
        }
        continue;
      }

      if (inInlineCode) {
        inlineText = `${inlineText}${char}`;
      } else {
        plainText = `${plainText}${char}`;
      }
    }

    if (inInlineCode) {
      this.appendResumePlainTextSegments(segments, `\`${inlineText}`, fallbackStyle);
    } else {
      this.appendResumePlainTextSegments(segments, plainText, fallbackStyle);
    }

    return segments;
  }

  private markdownBlocksCache: Map<string, ResumeMdBlockCacheEntry> = new Map();

  private resumeMarkdownBlocksForItem(item: ResumeContentItem): ResumeMdBlock[] {
    const cached = this.markdownBlocksCache.get(item.id);
    if (cached !== undefined && cached.text === item.text) {
      return cached.blocks;
    }
    const blocks = resolveResumeMarkdownBlocks(item.text);
    this.markdownBlocksCache.set(item.id, { text: item.text, blocks });
    return blocks;
  }

  private resumeMarkdownSegmentColor(segment: ResumeMdInlineSegment, item: ResumeContentItem): Resource {
    if (segment.kind === RESUME_MD_BLOCK_CODE) {
      return TERMINAL_INLINE_CODE_COLOR;
    }
    if (segment.kind === RESUME_MD_BLOCK_LINK) {
      return TERMINAL_LINK_COLOR;
    }
    return this.resumeBodyTextColor(item);
  }

  private resumeMarkdownSegmentWeight(segment: ResumeMdInlineSegment): FontWeight {
    return segment.kind === RESUME_MD_BLOCK_BOLD ? FontWeight.Bold : FontWeight.Regular;
  }

  private resumeMarkdownSegmentStyle(segment: ResumeMdInlineSegment): FontStyle {
    return segment.kind === RESUME_MD_BLOCK_ITALIC ? FontStyle.Italic : FontStyle.Normal;
  }

  private resumeMarkdownSegmentDecoration(segment: ResumeMdInlineSegment): TextDecorationType {
    return segment.kind === RESUME_MD_BLOCK_LINK ? TextDecorationType.Underline : TextDecorationType.None;
  }

  private isResumeMarkdownBody(item: ResumeContentItem): boolean {
    return item.role === 'assistant' && item.kind === 'message';
  }

  private resumeMarkdownHeadingFontSize(block: ResumeMdBlock): number {
    if (block.level === 1) {
      return this.resumeContentSize(19);
    }
    if (block.level === 2) {
      return this.resumeContentSize(17);
    }
    return this.resumeContentSize(15);
  }

  private displayResumeStatus(status: string): string {
    return status === 'completed' || status === 'notLoaded' ? '' : status;
  }

  private displayResumeListStatus(resume: ResumeItem): string {
    if (this.resumeMutatingId === resume.id) {
      return '处理中';
    }

    if (this.openingResumeId === resume.id) {
      return '正在打开';
    }

    return '';
  }

  @Builder
  private PlusIcon(size: number, color: Resource) {
    Text('+')
      .fontSize(size)
      .fontColor(color)
      .fontWeight(FontWeight.Regular)
  }

  @Builder
  private RefreshIcon(size: number, color: Resource) {
    Text('↻')
      .fontSize(size)
      .fontColor(color)
      .fontWeight(FontWeight.Medium)
      .fontFamily(TERMINAL_FONT_FAMILY)
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private DarkModeToggleButton() {
    Button() {
      Text(this.resumeDarkMode ? '浅色' : '深色')
        .fontSize(12)
        .fontFamily(TERMINAL_FONT_FAMILY)
        .fontColor(TERMINAL_BACKGROUND_COLOR)
    }
    .width(52)
    .height(32)
    .borderRadius(8)
    .backgroundColor(TERMINAL_TEXT_COLOR)
    .border({ width: 1, color: TERMINAL_BORDER_COLOR })
    .accessibilityText(this.resumeDarkMode ? '切换为浅色模式' : '切换为深色模式')
    .onClick(() => {
      this.toggleResumeDarkMode();
    })
  }

  @Builder
  private WindowDots(size: number = 8) {
    Row({ space: 6 }) {
      Row()
        .width(size)
        .height(size)
        .borderRadius(size / 2)
        .backgroundColor(TERMINAL_RED_COLOR)
        .opacity(0.8)

      Row()
        .width(size)
        .height(size)
        .borderRadius(size / 2)
        .backgroundColor(TERMINAL_AMBER_COLOR)
        .opacity(0.8)

      Row()
        .width(size)
        .height(size)
        .borderRadius(size / 2)
        .backgroundColor(TERMINAL_GREEN_COLOR)
        .opacity(0.8)
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private ResumeBackButton() {
    Button() {
      Text('‹')
        .fontSize(22)
        .fontFamily(TERMINAL_FONT_FAMILY)
        .fontColor(TERMINAL_TEXT_COLOR)
        .lineHeight(24)
    }
    .width(34)
    .height(32)
    .borderRadius(8)
    .backgroundColor(TERMINAL_TOOLBAR_COLOR)
    .border({ width: 1, color: TERMINAL_BORDER_COLOR })
    .accessibilityText('返回会话列表')
    .onClick(() => {
      this.backToResumeList();
    })
  }

  @Builder
  private ResumeListIcon(size: number) {
    Stack({ alignContent: Alignment.Center }) {
      Row()
        .width(size * 0.52)
        .height(size * 0.34)
        .borderRadius(size * 0.12)
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: TERMINAL_BORDER_COLOR })

      Row()
        .width(size * 0.11)
        .height(size * 0.25)
        .borderRadius(size * 0.055)
        .backgroundColor(TERMINAL_ACCENT_COLOR)
        .opacity(0.8)
        .translate({ x: size * -0.13, y: 0 })

      Row()
        .width(size * 0.21)
        .height(size * 0.11)
        .borderRadius(size * 0.055)
        .backgroundColor(TERMINAL_ACCENT_COLOR)
        .opacity(0.8)
        .translate({ x: size * 0.1, y: size * -0.07 })

      Row()
        .width(size * 0.21)
        .height(size * 0.11)
        .borderRadius(size * 0.055)
        .backgroundColor(TERMINAL_ACCENT_COLOR)
        .opacity(0.8)
        .translate({ x: size * 0.1, y: size * 0.07 })
    }
    .width(size)
    .height(size)
    .translate({ x: -2 })
  }

  @Builder
  private TopBar() {
    Row() {
      Text('AIRouter')
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor(TERMINAL_APP_TITLE_COLOR)

      Blank()
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 22, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private ConnectionList() {
    if (this.connections.length === 0) {
      this.EmptyConnectionList()
    } else {
      this.ConnectionCardList()
    }
  }

  @Builder
  private EmptyConnectionList() {
    Column() {
      Column() {
        this.ConnectionCarouselHeader()
      }
      .width('100%')
      .layoutWeight(4)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      Stack() {
        Column() {
          this.AddConnectionCircleButton()
        }
        .width('100%')
        .height(65)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .align(Alignment.Center)

        if (this.feedback.length > 0) {
          Text(this.feedback)
            .fontSize(13)
            .fontColor(TERMINAL_MUTED_TEXT_COLOR)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ left: 20, right: 20 })
            .translate({ y: 56 })
            .align(Alignment.Center)
        }
      }
      .width('100%')
      .layoutWeight(6)
    }
    .layoutWeight(1)
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20 })
  }

  @Builder
  private ConnectionCardList() {
    Column() {
      Column() {
        this.ConnectionCarouselHeader()
      }
      .width('100%')
      .height('20%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .translate({ y: resolveConnectedTitleOffset(this.connections.length) })

      if (this.feedback.length > 0) {
        Text(this.feedback)
          .fontSize(13)
          .fontColor(TERMINAL_MUTED_TEXT_COLOR)
          .width('100%')
          .textAlign(TextAlign.Center)
      }

      Column({ space: 12 }) {
        this.ConnectionCardStage()
        this.ConnectionPager()
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ bottom: 32 })
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      Column() {
        this.AddConnectionCircleButton()
      }
      .width('100%')
      .height('8%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      Blank()
        .width('100%')
        .height('8%')

      if (!canAddConnection(this.connections)) {
        Text('最多支持 5 个连接，请删除一个连接后再添加。')
          .fontSize(13)
          .fontColor(TERMINAL_MUTED_TEXT_COLOR)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ left: 20, right: 20 })
      }
    }
    .layoutWeight(1)
    .width('100%')
    .padding({
      left: resolveConnectedCardListHorizontalPadding(),
      right: resolveConnectedCardListHorizontalPadding()
    })
    .alignItems(HorizontalAlign.Center)
    .onTouch((event: TouchEvent) => {
      this.handleCardActionOutsideTouch(event);
    })
  }

  @Builder
  private ConnectionCarouselHeader() {
    Row() {
      Text('AIRouter')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(TERMINAL_APP_TITLE_COLOR)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)

      this.DarkModeToggleButton()
    }
    .width('100%')
  }

  @Builder
  private ConnectionCardStage() {
    Swiper(this.connectionSwiperController) {
      ForEach(this.sortedConnections(), (connection: SavedConnection, index: number) => {
        Column() {
          this.ConnectionCarouselCard(connection)
        }
        .width('100%')
        .height('100%')
        .padding({
          left: this.getCardMargin(),
          right: this.getCardMargin()
        })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .translate({ x: this.connectionCardSwitchOffset(index), y: 0 })
        .scale({ x: this.connectionCardScale(index), y: this.connectionCardScale(index) })
      }, (connection: SavedConnection) => connection.id)
    }
    .width('100%')
    .layoutWeight(1)
    .indicator(false)
    .autoPlay(resolveConnectionSwiperAutoPlay())
    .disableSwipe(resolveConnectionSwiperDisableSwipe())
    .loop(this.connections.length > 1)
    .duration(CONNECTION_CARD_SWIPER_DURATION_MS)
    .curve(Curve.EaseOut)
    .itemSpace(resolveConnectionSwiperItemSpace(this.connections.length))
    .index(this.activeConnectionPosition())
    .onChange((index: number) => {
      this.handleConnectionSwiperChange(index);
    })
    .onAnimationStart((index: number, targetIndex: number, _extraInfo: SwiperAnimationEvent) => {
      this.handleConnectionSwiperAnimationStart(index, targetIndex);
    })
    .onContentDidScroll((selectedIndex: number, index: number, position: number, _mainAxisLength: number) => {
      this.handleConnectionSwiperContentScroll(selectedIndex, index, position);
    })
    .onAnimationEnd((_index: number) => {
      this.clearConnectionCardScrollPositions();
    })
  }

  @Builder
  private ConnectionCarouselCard(connection: SavedConnection) {
    Column({ space: 16 }) {
      this.ConnectionCardHeader(connection)

      this.ConnectionResumePreview(connection)

      Button(resolveResumeCardActionLabel(connection.status, this.hasCardAutoConnectFailed(connection)))
        .width('100%')
        .height(48)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TERMINAL_ACCENT_TEXT_COLOR)
        .backgroundColor(TERMINAL_ACCENT_COLOR)
        .borderRadius(14)
        .shadow({ radius: 16, color: TERMINAL_ACCENT_GLOW_COLOR, offsetX: 0, offsetY: 4 })
        .enabled(!this.resumeStarting && this.openingResumeId.length === 0 && !this.isCardAutoConnecting(connection))
        .onClick(() => {
          if (this.consumeSuppressedCardActionClick()) {
            return;
          }

          if (this.closeConnectionActionMenuIfOpen(connection)) {
            return;
          }

          if (this.hasCardAutoConnectFailed(connection)) {
            this.retryCardAutoConnect(connection);
            return;
          }

          this.addResumeFromCard(connection);
        })
    }
    .width('100%')
    .layoutWeight(1)
    .constraintSize({ maxWidth: this.getCardMaxWidth() })
    .padding({ left: 16, right: 16, top: 4, bottom: 20 })
    .backgroundColor(TERMINAL_PANEL_ELEVATED_COLOR)
    .border({ width: 1, color: TERMINAL_BORDER_COLOR })
    .borderRadius(20)
    .shadow({ radius: 24, color: TERMINAL_CARD_SHADOW_COLOR, offsetX: 0, offsetY: 8 })
  }

  @Builder
  private ConnectionCardHeader(connection: SavedConnection) {
    Column({ space: 6 }) {
      Row() {
        this.WindowDots(8)
      }
      .width('100%')
      .height(12)
      .alignItems(VerticalAlign.Center)
      .translate({ x: -2, y: 10 })

      this.ConnectionTitleArea(connection)
    }
    .width('100%')
  }

  @Builder
  private ConnectionTitleArea(connection: SavedConnection) {
    Stack({ alignContent: Alignment.Center }) {
      Row() {
        Column({ space: 0 }) {
          Text(resolveConnectionCardTitle(connection))
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(TERMINAL_TEXT_COLOR)
            .width('100%')
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .height('100%')
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        if (this.resumeRenamingId.length > 0) {
          this.cancelRenameResumeItem();
          return;
        }

        if (this.resumeActionMenuId.length > 0) {
          this.resumeActionMenuId = '';
          return;
        }

        this.openConnectionActionMenu(connection);
      })

      if (this.connectionActionMenuId === connection.id) {
        this.ConnectionTitleOverlayActions(connection)
      }
    }
    .width('100%')
    .height(44)
    .onTouch((event: TouchEvent) => {
      event.stopPropagation();
    })
  }

  @Builder
  private ConnectionResumePreview(connection: SavedConnection) {
    Column({ space: 12 }) {
      Row() {
        Text('会话历史')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(TERMINAL_SECTION_TITLE_COLOR)

        Text(resolveResumeCountText(this.cardResumes(connection).length))
          .fontSize(12)
          .fontColor(TERMINAL_MUTED_TEXT_COLOR)
          .margin({ left: 16 })

        Blank()

        Row() {
          this.RefreshIcon(18, TERMINAL_ACCENT_COLOR)
        }
        .width(32)
        .height(18)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .enabled(!this.isCardAutoConnecting(connection))
        .onClick(() => {
          if (this.consumeSuppressedCardActionClick()) {
            return;
          }

          if (this.closeConnectionActionMenuIfOpen(connection)) {
            return;
          }

          this.retryCardAutoConnect(connection);
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      if (this.resumesConnectionId === connection.id && this.resumesLoading) {
        Row() {
          Text('正在获取会话')
            .fontSize(13)
            .fontColor(TERMINAL_MUTED_TEXT_COLOR)
        }
        .width('100%')
        .height(RESUME_PREVIEW_ROW_HEIGHT)
        .padding({ left: 10, right: 10 })
        .backgroundColor(TERMINAL_ROW_COLOR)
        .borderRadius(10)
        .border({ width: 1, color: TERMINAL_BORDER_COLOR })
        .alignItems(VerticalAlign.Center)
      } else if (this.resumesConnectionId === connection.id && this.resumesFeedback.length > 0 &&
        this.cardResumes(connection).length === 0) {
        Row() {
          Text(this.resumesFeedback)
            .fontSize(13)
            .fontColor(TERMINAL_MUTED_TEXT_COLOR)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .height(RESUME_PREVIEW_ROW_HEIGHT)
        .padding({ left: 10, right: 10 })
        .backgroundColor(TERMINAL_ROW_COLOR)
        .borderRadius(10)
        .border({ width: 1, color: TERMINAL_BORDER_COLOR })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.handleResumeFeedbackClick(connection);
        })
      } else {
        Scroll() {
          Column({ space: RESUME_PREVIEW_ROW_GAP }) {
            ForEach(this.cardResumes(connection), (resume: ResumeItem) => {
              Stack({ alignContent: Alignment.Center }) {
                Row({ space: 2 }) {
                  this.ResumeListIcon(24)

                  Row() {
                    Column({ space: 3 }) {
                  Text(resume.title)
                    .fontSize(13)
                    .fontColor(TERMINAL_RESUME_TITLE_COLOR)
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  Text(resume.subtitle)
                    .fontSize(11)
                    .fontColor(TERMINAL_MUTED_TEXT_COLOR)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)

                    if (this.displayResumeListStatus(resume).length > 0) {
                      Text(this.displayResumeListStatus(resume))
                        .fontSize(11)
                        .fontColor(TERMINAL_GREEN_COLOR)
                    }
                  }
                  .layoutWeight(1)
                  .alignItems(VerticalAlign.Center)
                }
                .width('100%')
                .height('100%')
                .padding({ left: 8, right: 10 })
                .alignItems(VerticalAlign.Center)

                if (this.resumeActionMenuId === resume.id) {
                  this.CardResumeOverlayActions(resume)
                }

                if (this.resumeRenamingId === resume.id) {
                  this.CardResumeRenameOverlay(resume)
                }
              }
              .width('100%')
              .height(RESUME_PREVIEW_ROW_HEIGHT)
              .backgroundColor(TERMINAL_ROW_COLOR)
              .borderRadius(10)
              .border({ width: 1, color: TERMINAL_BORDER_COLOR })
              .enabled(this.openingResumeId.length === 0 && this.resumeMutatingId.length === 0)
              .onClick(() => {
                if (this.consumeSuppressedCardActionClick()) {
                  return;
                }

                if (this.closeConnectionActionMenuIfOpen(connection)) {
                  return;
                }

                if (this.resumeActionMenuId === resume.id) {
                  this.resumeActionMenuId = '';
                  return;
                }

                this.selectedConnectionId = connection.id;
                this.connectionActionMenuId = '';
                this.resumeSelectedThread(resume);
              })
              .gesture(
                LongPressGesture({ duration: 500 })
                  .onAction(() => {
                    if (this.openingResumeId.length === 0 && this.resumeMutatingId.length === 0) {
                      this.selectedConnectionId = connection.id;
                      this.connectionActionMenuId = '';
                      this.clearCardActionClickSuppression();
                      this.resumeActionMenuId = resume.id;
                      this.resumeActionFeedback = '';
                    }
                  })
              )
            }, (resume: ResumeItem) => resume.id)
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .onClick(() => {
      this.closeConnectionActionMenuIfOpen(connection);
    })
  }

  @Builder
  private CardResumeOverlayActions(resume: ResumeItem) {
    Row({ space: 8 }) {
      Button('重命名')
        .layoutWeight(1)
        .height('100%')
        .fontSize(12)
        .fontColor(TERMINAL_RENAME_BUTTON_TEXT_COLOR)
        .backgroundColor(TERMINAL_RENAME_BUTTON_COLOR)
        .borderRadius(8)
        .opacity(0.95)
        .enabled(this.resumeMutatingId.length === 0)
        .onClick(() => {
          this.startRenameResumeItem(resume);
        })

      Button('删除')
        .layoutWeight(1)
        .height('100%')
        .fontSize(12)
        .fontColor(TERMINAL_DANGER_TEXT_COLOR)
        .backgroundColor(TERMINAL_DANGER_SURFACE_COLOR)
        .borderRadius(8)
        .opacity(0.95)
        .enabled(this.resumeMutatingId.length === 0)
        .onClick(() => {
          this.deleteResumeItem(resume);
        })

      Button('返回')
        .layoutWeight(1)
        .height('100%')
        .fontSize(12)
        .fontColor(TERMINAL_TEXT_COLOR)
        .backgroundColor(TERMINAL_BUTTON_SECONDARY_COLOR)
        .borderRadius(8)
        .opacity(0.95)
        .border({ width: 1, color: TERMINAL_BORDER_COLOR })
        .onClick(() => {
          this.resumeActionMenuId = '';
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 8, right: 8, top: 8, bottom: 8 })
    .backgroundColor(TERMINAL_PANEL_ELEVATED_COLOR)
    .onTouch((event: TouchEvent) => {
      event.stopPropagation();
    })
  }

  @Builder
  private CardResumeRenameOverlay(resume: ResumeItem) {
    Row({ space: 6 }) {
      TextInput({ text: this.resumeRenameDraft, placeholder: '会话名称' })
        .layoutWeight(1)
        .height('100%')
        .fontSize(12)
        .fontColor(TERMINAL_TEXT_COLOR)
        .placeholderColor(TERMINAL_MUTED_TEXT_COLOR)
        .backgroundColor(TERMINAL_INPUT_COLOR)
        .border({ width: 1, color: TERMINAL_BORDER_STRONG_COLOR })
        .borderRadius(10)
        .enabled(this.resumeMutatingId.length === 0)
        .autoCapitalizationMode(AutoCapitalizationMode.NONE)
        .onChange((text: string) => {
          this.resumeRenameDraft = text;
          if (this.resumeActionFeedback === '请输入会话名称' ||
            this.resumeActionFeedback === '重命名会话失败') {
            this.resumeActionFeedback = '';
          }
        })

      Button('确定')
        .width(68)
        .height('100%')
        .fontSize(12)
        .fontColor(TERMINAL_ACCENT_TEXT_COLOR)
        .backgroundColor(TERMINAL_ACCENT_COLOR)
        .borderRadius(10)
        .padding({ left: 0, right: 0 })
        .enabled(this.resumeMutatingId.length === 0)
        .onClick(() => {
          this.confirmRenameResumeItem(resume);
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 6, right: 6, top: 8, bottom: 8 })
    .backgroundColor(TERMINAL_PANEL_ELEVATED_COLOR)
    .borderRadius(8)
    .onTouch((event: TouchEvent) => {
      event.stopPropagation();
    })
  }

  @Builder
  private ResumeActionMenu(resume: ResumeItem) {
    Row({ space: 10 }) {
      Button('重命名')
        .layoutWeight(1)
        .height(40)
        .fontSize(13)
        .fontColor(TERMINAL_RENAME_BUTTON_TEXT_COLOR)
        .backgroundColor(TERMINAL_RENAME_BUTTON_COLOR)
        .borderRadius(10)
        .enabled(this.resumeMutatingId.length === 0)
        .onClick(() => {
          this.startRenameResumeItem(resume);
        })

      Button('删除')
        .layoutWeight(1)
        .height(40)
        .fontSize(13)
        .fontColor(TERMINAL_DANGER_TEXT_COLOR)
        .backgroundColor(TERMINAL_DANGER_SURFACE_COLOR)
        .borderRadius(10)
        .enabled(this.resumeMutatingId.length === 0)
        .onClick(() => {
          this.deleteResumeItem(resume);
        })
    }
    .width('100%')
  }

  @Builder
  private ResumeRenameEditor(resume: ResumeItem) {
    Column({ space: 10 }) {
      TextInput({ text: this.resumeRenameDraft, placeholder: '会话名称' })
        .width('100%')
        .height(44)
        .fontSize(14)
        .fontColor(TERMINAL_TEXT_COLOR)
        .placeholderColor(TERMINAL_MUTED_TEXT_COLOR)
        .backgroundColor(TERMINAL_INPUT_COLOR)
        .border({ width: 1, color: TERMINAL_BORDER_COLOR })
        .borderRadius(10)
        .enabled(this.resumeMutatingId.length === 0)
        .autoCapitalizationMode(AutoCapitalizationMode.NONE)
        .onChange((text: string) => {
          this.resumeRenameDraft = text;
          if (this.resumeActionFeedback === '请输入会话名称' ||
            this.resumeActionFeedback === '重命名会话失败') {
            this.resumeActionFeedback = '';
          }
        })

      Row({ space: 10 }) {
        Button('确定')
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor(TERMINAL_ACCENT_TEXT_COLOR)
          .backgroundColor(TERMINAL_ACCENT_COLOR)
          .borderRadius(10)
          .enabled(this.resumeMutatingId.length === 0)
          .onClick(() => {
            this.confirmRenameResumeItem(resume);
          })
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  private ConnectionTitleOverlayActions(connection: SavedConnection) {
    Row({ space: 8 }) {
      Button('编辑')
        .layoutWeight(1)
        .height('100%')
        .fontSize(12)
        .fontColor(TERMINAL_RENAME_BUTTON_TEXT_COLOR)
        .backgroundColor(TERMINAL_RENAME_BUTTON_COLOR)
        .borderRadius(8)
        .opacity(0.95)
        .onClick(() => {
          this.clearCardActionClickSuppression();
          this.openEditDialog(connection);
        })

      Button('删除')
        .layoutWeight(1)
        .height('100%')
        .fontSize(12)
        .fontColor(TERMINAL_DANGER_TEXT_COLOR)
        .backgroundColor(TERMINAL_DANGER_SURFACE_COLOR)
        .borderRadius(8)
        .opacity(0.95)
        .onClick(() => {
          this.clearCardActionClickSuppression();
          this.openDeleteDialog(connection);
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 8, right: 8, top: 6, bottom: 6 })
    .onTouch((event: TouchEvent) => {
      event.stopPropagation();
    })
  }

  @Builder
  private ConnectionPager() {
    Row({ space: 6 }) {
      ForEach(this.sortedConnections(), (connection: SavedConnection, index: number) => {
        Column()
          .width(index === this.activeConnectionPosition() ? 20 : 6)
          .height(6)
          .backgroundColor(index === this.activeConnectionPosition() ? TERMINAL_ACCENT_COLOR : TERMINAL_BUTTON_NEUTRAL_COLOR)
          .borderRadius(3)
      }, (connection: SavedConnection) => connection.id)
    }
    .height(20)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.closeConnectionActionMenu();
    })
  }

  @Builder
  private AddConnectionCircleButton() {
    Button({ type: ButtonType.Circle }) {
      this.PlusIcon(46, canAddConnection(this.connections) ? TERMINAL_ACCENT_TEXT_COLOR : TERMINAL_DIM_TEXT_COLOR)
    }
    .width(60)
    .height(60)
    .borderRadius(30)
    .backgroundColor(canAddConnection(this.connections) ? TERMINAL_ACCENT_COLOR : TERMINAL_PANEL_ELEVATED_COLOR)
    .border({ width: 1, color: canAddConnection(this.connections) ? TERMINAL_ACCENT_COLOR : TERMINAL_BORDER_COLOR })
    .shadow({
      radius: 20,
      color: canAddConnection(this.connections) ? TERMINAL_ACCENT_GLOW_COLOR : TERMINAL_FLOATING_SHADOW_COLOR,
      offsetX: 0,
      offsetY: 6
    })
    .enabled(canAddConnection(this.connections))
    .onClick(() => {
      if (this.consumeSuppressedCardActionClick()) {
        return;
      }

      if (this.connectionActionMenuId.length > 0) {
        this.closeConnectionActionMenu();
        return;
      }

      this.openAddDialog();
    })
  }

  @Builder
  private FieldFeedback(label: string) {
    if (label === '服务器地址' && this.addressFeedback.length > 0) {
      Text(this.addressFeedback)
        .fontSize(12)
        .fontColor(TERMINAL_DANGER_TEXT_COLOR)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    } else if (label === '注册码' && this.passwordFeedback.length > 0) {
      Text(this.passwordFeedback)
        .fontSize(12)
        .fontColor(TERMINAL_DANGER_TEXT_COLOR)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
  }

  @Builder
  private Field(label: string, value: string, placeholder: string) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(label)
          .fontSize(14)
          .fontColor(TERMINAL_LABEL_COLOR)
          .fontWeight(FontWeight.Medium)

        this.FieldFeedback(label)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      TextInput({ text: value, placeholder: placeholder })
        .height(44)
        .fontSize(15)
        .fontColor(TERMINAL_TEXT_COLOR)
        .placeholderColor(TERMINAL_DIM_TEXT_COLOR)
        .backgroundColor(TERMINAL_INPUT_COLOR)
        .borderRadius(10)
        .border({ width: 1, color: TERMINAL_BORDER_COLOR })
        .type(InputType.Normal)
        .autoCapitalizationMode(AutoCapitalizationMode.NONE)
        .onChange((text: string) => {
          if (label === '服务器地址') {
            this.draftAddress = text;
            this.addressFeedback = '';
          } else if (label === '注册码') {
            this.draftPassword = text;
            this.passwordFeedback = '';
          } else {
            this.draftName = text;
          }

          if (this.dialogFeedback.length > 0) {
            this.dialogFeedback = '';
          }
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private DialogFrame(title: string) {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')

      Row() {
        Column({ space: 18 }) {
          Row() {
            Row() {
              this.WindowDots(8)
            }
            .width(64)
            .alignItems(VerticalAlign.Center)

            Text(title)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(TERMINAL_DIALOG_TITLE_COLOR)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            Blank()
              .width(64)
          }
          .width('100%')

          if (this.dialog === ConnectionDialog.EDIT) {
            this.AddDialogContent()
          } else if (this.dialog === ConnectionDialog.RELOGIN) {
            this.ReloginDialogContent()
          } else if (this.dialog === ConnectionDialog.DELETE) {
            this.DeleteDialogContent()
          }
        }
        .width('100%')
        .constraintSize({ minHeight: 112, maxHeight: '92%' })
        .padding(24)
        .backgroundColor(TERMINAL_PANEL_ELEVATED_COLOR)
        .border({ width: 1, color: TERMINAL_BORDER_COLOR })
        .borderRadius(20)
        .shadow({ radius: 32, color: TERMINAL_DIALOG_SHADOW_COLOR, offsetX: 0, offsetY: 12 })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 24, right: 24 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private AddDialogContent() {
    Column({ space: 18 }) {
      Scroll() {
        Column({ space: 10 }) {
            this.Field('服务器地址', this.draftAddress, '例如 8.153.174.88')
            Row({ space: 10 }) {
              Button(this.testingConnection ? '正在测试...' : '测试连接')
                .height(36)
                .fontSize(13)
                .fontColor(TERMINAL_ACCENT_TEXT_COLOR)
                .backgroundColor(this.testingConnection ? TERMINAL_BUTTON_SECONDARY_COLOR : TERMINAL_ACCENT_COLOR)
                .borderRadius(8)
                .enabled(!this.testingConnection && this.draftAddress.trim().length > 0)
                .onClick(() => {
                  this.testConnection();
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.End)

            if (this.connectionTestResult.length > 0) {
              Text(this.connectionTestResult)
                .fontSize(13)
                .fontColor(this.connectionTestPassed ? TERMINAL_SUCCESS_TEXT_COLOR : TERMINAL_DANGER_TEXT_COLOR)
                .width('100%')
                .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                .backgroundColor(this.connectionTestPassed ? TERMINAL_SUCCESS_SURFACE_COLOR : TERMINAL_DANGER_SURFACE_COLOR)
                .borderRadius(10)
            }

            this.Field('注册码', this.draftPassword,
            this.dialog === ConnectionDialog.EDIT ? '留空保留当前凭据' : '请输入注册码')
          this.Field('连接名称', this.draftName, '可选')

          Column({ space: 4 }) {
            Text('注册码由服务器管理员提供，每个设备注册一次。')
              .fontSize(12)
              .fontColor(TERMINAL_MUTED_TEXT_COLOR)
              .width('100%')
            Text('设备密钥由系统自动生成并安全存储在本机，无需手动管理。')
              .fontSize(12)
              .fontColor(TERMINAL_MUTED_TEXT_COLOR)
              .width('100%')
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor(TERMINAL_NOTICE_SURFACE_COLOR)
          .border({ width: 1, color: TERMINAL_NOTICE_BORDER_COLOR })
          .borderRadius(10)

          if (this.dialogFeedback.length > 0) {
            Text(this.dialogFeedback)
              .fontSize(13)
              .fontColor(TERMINAL_DANGER_TEXT_COLOR)
              .width('100%')
              .padding({ left: 12, right: 12, top: 10, bottom: 10 })
              .backgroundColor(TERMINAL_DANGER_SURFACE_COLOR)
              .borderRadius(10)
          }
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 320 })
      .scrollBar(BarState.Off)

      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(TERMINAL_MUTED_TEXT_COLOR)
          .backgroundColor(TERMINAL_BUTTON_SECONDARY_COLOR)
          .borderRadius(10)
          .border({ width: 1, color: TERMINAL_BORDER_COLOR })
          .onClick(() => {
            this.closeDialog();
          })

        Button(this.dialog === ConnectionDialog.EDIT ? '确定' : '连接')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(TERMINAL_ACCENT_TEXT_COLOR)
          .backgroundColor(TERMINAL_ACCENT_COLOR)
          .borderRadius(10)
          .enabled(this.dialog === ConnectionDialog.EDIT || !this.connectionSubmitting)
          .onClick(() => {
            if (this.dialog === ConnectionDialog.EDIT) {
              this.saveEditedConnection();
            } else {
              this.addConnection();
            }
          })
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  private ResumeListContent() {
    Column({ space: 10 }) {
      if (this.resumesLoading) {
        Text('正在获取会话')
          .fontSize(13)
          .fontColor(TERMINAL_MUTED_TEXT_COLOR)
          .width('100%')
          .padding({ left: 14, right: 14, top: 12, bottom: 12 })
          .backgroundColor(TERMINAL_ROW_COLOR)
          .borderRadius(10)
          .border({ width: 1, color: TERMINAL_BORDER_COLOR })
      } else if (this.resumesFeedback.length > 0) {
        Text(this.resumesFeedback)
          .fontSize(13)
          .fontColor(TERMINAL_MUTED_TEXT_COLOR)
          .width('100%')
          .padding({ left: 14, right: 14, top: 12, bottom: 12 })
          .backgroundColor(TERMINAL_ROW_COLOR)
          .borderRadius(10)
          .border({ width: 1, color: TERMINAL_BORDER_COLOR })
      } else {
        Scroll() {
          Column({ space: RESUME_LIST_ROW_GAP }) {
            ForEach(this.resumes, (resume: ResumeItem) => {
              Column({ space: 10 }) {
                Row({ space: 4 }) {
                  this.ResumeListIcon(28)

                  Column({ space: 4 }) {
                    Text(resume.title)
                      .fontSize(14)
                      .fontColor(TERMINAL_RESUME_TITLE_COLOR)
                      .fontWeight(FontWeight.Medium)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })

                    Text(resume.subtitle)
                      .fontSize(12)
                      .fontColor(TERMINAL_MUTED_TEXT_COLOR)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  if (this.displayResumeListStatus(resume).length > 0) {
                    Text(this.displayResumeListStatus(resume))
                      .fontSize(12)
                      .fontColor(TERMINAL_GREEN_COLOR)
                  }
                }
                .alignItems(VerticalAlign.Center)

                if (this.resumeActionMenuId === resume.id) {
                  this.ResumeActionMenu(resume)
                }

                if (this.resumeRenamingId === resume.id) {
                  this.ResumeRenameEditor(resume)
                }
              }
              .width('100%')
              .padding({ left: 12, right: 14, top: 10, bottom: 10 })
              .backgroundColor(TERMINAL_ROW_COLOR)
              .borderRadius(12)
              .border({ width: 1, color: TERMINAL_BORDER_COLOR })
              .enabled(this.openingResumeId.length === 0 && this.resumeMutatingId.length === 0)
              .onClick(() => {
                if (this.resumeActionMenuId === resume.id) {
                  this.resumeActionMenuId = '';
                  return;
                }
                this.resumeSelectedThread(resume);
              })
              .gesture(
                LongPressGesture({ duration: 500 })
                  .onAction(() => {
                    if (this.openingResumeId.length === 0 && this.resumeMutatingId.length === 0) {
                      this.resumeActionMenuId = resume.id;
                      this.resumeActionFeedback = '';
                    }
                  })
              )
            }, (resume: ResumeItem) => resume.id)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private ResumeListPage() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Row() {
          Text('会话历史')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(TERMINAL_SECTION_TITLE_COLOR)
            .layoutWeight(1)
            .textAlign(TextAlign.Start)

          this.DarkModeToggleButton()
        }
        .width('100%')
        .height(56)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
          .padding({ left: 16, right: 16, top: 12, bottom: 8 })

        if (this.resumeActionFeedback.length > 0) {
          Text(this.resumeActionFeedback)
            .fontSize(13)
            .fontColor(TERMINAL_GREEN_COLOR)
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .backgroundColor(TERMINAL_NOTICE_SURFACE_COLOR)
            .border({ width: { bottom: 1 }, color: TERMINAL_NOTICE_BORDER_COLOR })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        Column() {
          this.ResumeListContent()
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, top: 14, bottom: 100 })
      }
      .width('100%')
      .height('100%')

      Column() {
        Button() {
          if (this.resumeStarting) {
            Text('...')
              .fontSize(24)
              .fontColor(TERMINAL_MUTED_TEXT_COLOR)
              .fontWeight(FontWeight.Medium)
          } else {
            this.PlusIcon(46, TERMINAL_ACCENT_COLOR)
          }
        }
        .width(72)
        .height(72)
        .borderRadius(36)
        .backgroundColor(TERMINAL_ACCENT_COLOR)
        .shadow({ radius: 24, color: TERMINAL_ACCENT_GLOW_COLOR, offsetX: 0, offsetY: 8 })
        .onClick(() => {
          this.startNewResume();
        })
      }
      .width('100%')
      .height(80)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .align(Alignment.Bottom)
      .margin({ bottom: 20 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TERMINAL_BACKGROUND_COLOR)
  }

  @Builder
  private ResumeSessionContent() {
    Column() {
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          this.WindowDots()

          this.ResumeBackButton()

          Text(this.activeResumeShortTitle())
            .fontSize(15)
            .fontFamily(TERMINAL_FONT_FAMILY)
            .fontWeight(FontWeight.Medium)
            .fontColor(TERMINAL_TEXT_COLOR)
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          this.DarkModeToggleButton()
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.activeResumeDirectoryText())
          .fontSize(12)
          .fontFamily(TERMINAL_FONT_FAMILY)
          .fontColor(TERMINAL_DIM_TEXT_COLOR)
          .width('100%')
          .textAlign(TextAlign.Start)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 10 })
      .backgroundColor(TERMINAL_TOOLBAR_COLOR)
      .border({ width: { bottom: 1 }, color: TERMINAL_BORDER_COLOR })

      if (this.resumeActionFeedback.length > 0) {
        Text(this.resumeActionFeedback)
          .fontSize(13)
          .fontFamily(TERMINAL_FONT_FAMILY)
          .fontColor(TERMINAL_GREEN_COLOR)
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .backgroundColor(TERMINAL_NOTICE_SURFACE_COLOR)
          .border({ width: { bottom: 1 }, color: TERMINAL_NOTICE_BORDER_COLOR })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Scroll(this.resumeContentScroller) {
        Column({ space: 10 }) {
          if (this.activeResumeTurns().length > 0) {
            ForEach(this.activeResumeTurns(), (turn: ResumeTurn) => {
              this.ResumeTurnBlock(turn)
            }, (turn: ResumeTurn) => turn.id)
          }

          if (this.pendingResumeMessage.length > 0) {
            this.ResumeContentItemView({
              id: 'pending-user-message',
              role: 'user',
              kind: 'text',
              text: this.pendingResumeMessage,
              status: ''
            }, this.pendingResumeMessageTimestamp)
          }

          if (this.resumeIsWaitingForResponse()) {
            this.ResumeWaitingItemView()
          }

          if (this.activeResumeTurns().length === 0 && this.pendingResumeMessage.length === 0 &&
            this.resumeCenterNotice.length > 0) {
            Column() {
              Text(this.resumeCenterNotice)
                .fontSize(this.resumeContentSize(14))
                .fontFamily(TERMINAL_FONT_FAMILY)
                .fontColor(TERMINAL_GREEN_COLOR)
                .textAlign(TextAlign.Center)
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .backgroundColor(TERMINAL_NOTICE_SURFACE_COLOR)
                .border({ width: 1, color: TERMINAL_NOTICE_BORDER_COLOR })
                .borderRadius(10)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          }
        }
        .width('100%')
        .constraintSize({ minHeight: '100%' })
        .padding({ top: 14, bottom: 14 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .onDidScroll((_xOffset: number, _yOffset: number, _scrollState: ScrollState) => {
        this.updateResumeScrollFollowAnchor();
      })
      .onTouch((event: TouchEvent) => {
        event.stopPropagation();
        if (event.type === TouchType.Down) {
          this.handleResumePageTap();
        }
      })
      .parallelGesture(
        PinchGesture({ fingers: 2 })
          .onActionStart((_event: GestureEvent) => {
            this.handleResumeContentPinchStart();
          })
          .onActionUpdate((event: GestureEvent) => {
            this.handleResumeContentPinchUpdate(event);
          })
          .onActionEnd((event: GestureEvent) => {
            this.handleResumeContentPinchEnd(event);
          })
          .onActionCancel((_event: GestureEvent) => {
            this.handleResumeContentPinchCancel();
          })
      )

      if (this.resumeComposerVisible) {
        Text('该内容由AI生成，请注意甄别')
          .width('100%')
          .fontSize(11)
          .fontFamily(TERMINAL_FONT_FAMILY)
          .fontColor(TERMINAL_DIM_TEXT_COLOR)
          .textAlign(TextAlign.Center)
          .padding({ top: 4, bottom: 2 })

        Row({ space: 10 }) {
          Row({ space: 6 }) {
            Text('$')
              .width(14)
              .fontSize(16)
              .fontFamily(TERMINAL_FONT_FAMILY)
              .fontColor(TERMINAL_GREEN_COLOR)
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Center)
              .height(RESUME_COMPOSER_LINE_HEIGHT)
              .margin({ top: 6 })

            Stack({ alignContent: Alignment.Start }) {
              TextArea({ text: this.resumeInputText(), placeholder: '' })
                .width('100%')
                .height(this.resumeComposerInputHeight())
                .fontSize(14)
                .fontFamily(TERMINAL_FONT_FAMILY)
                .fontColor(TERMINAL_TEXT_COLOR)
                .backgroundColor(TERMINAL_TRANSPARENT_COLOR)
                .padding({ left: 4, right: 4, top: 5, bottom: 5 })
                .enabled(!this.resumeMessageSending)
                .autoCapitalizationMode(AutoCapitalizationMode.NONE)
                .onChange((text: string) => {
                  this.resumeMessageDraft = this.normalizeResumeInputText(text);
                  if (this.resumeJustSent) {
                    this.resumeJustSent = false;
                    if (this.resumeTextIsBlank(this.resumeMessageDraft)) {
                      this.resumeMessageDraft = '';
                    }
                  }
                  if (this.resumeActionFeedback === '请输入消息' || this.resumeActionFeedback === '消息发送失败') {
                    this.resumeActionFeedback = '';
                  }
                })
                .onKeyEvent((event: KeyEvent) => {
                  this.handleResumeComposerKeyEvent(event);
                })

              if (this.resumeMessageDraft.length === 0) {
                Text('message')
                  .fontSize(14)
                  .fontFamily(TERMINAL_FONT_FAMILY)
                  .fontColor(TERMINAL_DIM_TEXT_COLOR)
                  .height(this.resumeComposerInputHeight())
                  .padding({ left: 4 })
                  .textAlign(TextAlign.Center)
                  .hitTestBehavior(HitTestMode.None)
              }
            }
            .layoutWeight(1)
            .height(this.resumeComposerInputHeight())
          }
          .layoutWeight(1)
          .height(this.resumeComposerInputHeight())
          .padding({ left: 10, right: 8, top: 2, bottom: 2 })
          .backgroundColor(TERMINAL_INPUT_COLOR)
          .border({ width: 1, color: TERMINAL_BORDER_COLOR })
          .borderRadius(10)
          .alignItems(VerticalAlign.Top)

          if (this.resumeIsWaitingForResponse()) {
            Button('停止')
              .width(72)
              .height(this.resumeComposerInputHeight())
              .fontSize(14)
              .fontFamily(TERMINAL_FONT_FAMILY)
              .fontColor(TERMINAL_DANGER_TEXT_COLOR)
              .backgroundColor(TERMINAL_DANGER_SURFACE_COLOR)
              .borderRadius(10)
              .border({ width: 1, color: TERMINAL_BORDER_COLOR })
              .onClick(() => {
                this.stopResumeGeneration();
              })
          } else {
            Button(this.resumeSendButtonLabel())
              .width(72)
              .height(this.resumeComposerInputHeight())
              .fontSize(14)
              .fontFamily(TERMINAL_FONT_FAMILY)
              .fontColor(this.resumeCanSubmitMessage() ? TERMINAL_ACCENT_TEXT_COLOR : TERMINAL_DIM_TEXT_COLOR)
              .backgroundColor(this.resumeCanSubmitMessage() ? TERMINAL_ACCENT_COLOR : TERMINAL_BUTTON_SECONDARY_COLOR)
              .borderRadius(10)
              .enabled(this.resumeCanSubmitMessage())
              .onClick(() => {
                this.sendResumeMessage();
              })
          }

        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 14 })
        .backgroundColor(TERMINAL_TRANSCRIPT_COLOR)
        .onTouch((event: TouchEvent) => {
          event.stopPropagation();
        })
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: this.getResumePanelMaxWidth() })
    .height('100%')
    .backgroundColor(TERMINAL_TRANSCRIPT_COLOR)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.handleResumePageTap();
      }
    })
  }

  @Builder
  private ResumeTurnBlock(turn: ResumeTurn) {
    Column({ space: 2 }) {
      ForEach(turn.items, (item: ResumeContentItem) => {
        this.ResumeContentItemView(item, this.resumeTurnItemTimestampText(turn, item))
      }, (item: ResumeContentItem) => item.id)
    }
    .width('100%')
  }

  @Builder
  private ResumeWaitingItemView() {
    Column({ space: 4 }) {
      Text('opencode@router:~$')
        .fontSize(this.resumeContentSize(12))
        .fontFamily(TERMINAL_FONT_FAMILY)
        .fontColor(TERMINAL_GREEN_COLOR)
        .fontWeight(FontWeight.Medium)
        .width('100%')

      Text(this.waitingDotsText())
        .fontSize(this.resumeContentSize(13))
        .fontFamily(TERMINAL_FONT_FAMILY)
        .fontColor(TERMINAL_TEXT_COLOR)
        .width('100%')
        .height(this.resumeContentSize(18))
        .textAlign(TextAlign.Start)
        .textOverflow({ overflow: TextOverflow.Clip })
    }
    .width('100%')
    .padding({ left: 24, right: 16, top: 10, bottom: 12 })
    .backgroundColor(TERMINAL_WAITING_MESSAGE_SURFACE_COLOR)
  }

  private resumeMarkdownSingleLinkSegment(block: ResumeMdBlock): ResumeMdInlineSegment | null {
    if (block.inline.length !== 1) {
      return null;
    }

    const segment = block.inline[0];
    if (segment.kind !== RESUME_MD_BLOCK_LINK || segment.href.length === 0) {
      return null;
    }

    return segment;
  }

  @Builder
  private ResumeMarkdownSingleLink(block: ResumeMdBlock, item: ResumeContentItem) {
    Text(this.resumeMarkdownSingleLinkSegment(block)!.text)
      .fontSize(this.resumeContentSize(14))
      .fontFamily(TERMINAL_FONT_FAMILY)
      .fontColor(TERMINAL_LINK_COLOR)
      .decoration({
        type: TextDecorationType.Underline,
        color: TERMINAL_LINK_COLOR
      })
      .onClick(() => {
        this.openResumeMarkdownLink(this.resumeMarkdownSingleLinkSegment(block)!.href);
      })
  }

  @Builder
  private ResumeMarkdownParagraph(block: ResumeMdBlock, item: ResumeContentItem) {
    if (this.resumeMarkdownSingleLinkSegment(block) !== null) {
      this.ResumeMarkdownSingleLink(block, item)
    } else {
      Text() {
        ForEach(block.inline, (segment: ResumeMdInlineSegment) => {
          Span(segment.text)
            .fontColor(this.resumeMarkdownSegmentColor(segment, item))
            .fontWeight(this.resumeMarkdownSegmentWeight(segment))
            .fontStyle(this.resumeMarkdownSegmentStyle(segment))
            .decoration({
              type: this.resumeMarkdownSegmentDecoration(segment),
              color: TERMINAL_LINK_COLOR
            })
            .backgroundColor(segment.kind === RESUME_MD_BLOCK_CODE ? TERMINAL_CODE_BLOCK_BACKGROUND_COLOR : TERMINAL_TRANSPARENT_COLOR)
        }, (segment: ResumeMdInlineSegment) => segment.id)
      }
        .fontSize(this.resumeContentSize(14))
        .fontFamily(TERMINAL_FONT_FAMILY)
        .fontColor(this.resumeBodyTextColor(item))
        .width('100%')
        .wordBreak(WordBreak.BREAK_ALL)
        .textAlign(TextAlign.Start)
        .textOverflow({ overflow: TextOverflow.Clip })
        .copyOption(CopyOptions.LocalDevice)
    }
  }

  @Builder
  private ResumeMarkdownHeading(block: ResumeMdBlock, item: ResumeContentItem) {
    Text(block.text)
      .fontSize(this.resumeMarkdownHeadingFontSize(block))
      .fontFamily(TERMINAL_FONT_FAMILY)
      .fontColor(TERMINAL_HEADING_COLOR)
      .fontWeight(FontWeight.Bold)
      .width('100%')
      .textAlign(TextAlign.Start)
      .wordBreak(WordBreak.BREAK_ALL)
  }

  @Builder
  private ResumeMarkdownList(block: ResumeMdBlock, item: ResumeContentItem) {
    Row({ space: 8 }) {
      Text('•')
        .fontSize(this.resumeContentSize(14))
        .fontFamily(TERMINAL_FONT_FAMILY)
        .fontColor(this.resumeBodyTextColor(item))
        .width(16)
        .textAlign(TextAlign.Center)

      if (this.resumeMarkdownSingleLinkSegment(block) !== null) {
        Text(this.resumeMarkdownSingleLinkSegment(block)!.text)
          .fontSize(this.resumeContentSize(14))
          .fontFamily(TERMINAL_FONT_FAMILY)
          .fontColor(TERMINAL_LINK_COLOR)
          .decoration({
            type: TextDecorationType.Underline,
            color: TERMINAL_LINK_COLOR
          })
          .layoutWeight(1)
          .onClick(() => {
            this.openResumeMarkdownLink(this.resumeMarkdownSingleLinkSegment(block)!.href);
          })
      } else {
        Text() {
          ForEach(block.inline, (segment: ResumeMdInlineSegment) => {
            Span(segment.text)
              .fontColor(this.resumeMarkdownSegmentColor(segment, item))
              .fontWeight(this.resumeMarkdownSegmentWeight(segment))
              .fontStyle(this.resumeMarkdownSegmentStyle(segment))
              .decoration({
                type: this.resumeMarkdownSegmentDecoration(segment),
                color: TERMINAL_LINK_COLOR
              })
              .backgroundColor(segment.kind === RESUME_MD_BLOCK_CODE ? TERMINAL_CODE_BLOCK_BACKGROUND_COLOR : TERMINAL_TRANSPARENT_COLOR)
          }, (segment: ResumeMdInlineSegment) => segment.id)
        }
          .fontSize(this.resumeContentSize(14))
          .fontFamily(TERMINAL_FONT_FAMILY)
          .fontColor(this.resumeBodyTextColor(item))
          .layoutWeight(1)
          .wordBreak(WordBreak.BREAK_ALL)
          .textAlign(TextAlign.Start)
          .textOverflow({ overflow: TextOverflow.Clip })
          .copyOption(CopyOptions.LocalDevice)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  private ResumeMarkdownQuote(block: ResumeMdBlock, item: ResumeContentItem) {
    if (this.resumeMarkdownSingleLinkSegment(block) !== null) {
      Row() {
        this.ResumeMarkdownSingleLink(block, item)
      }
      .width('100%')
      .padding({ left: 12, right: 8, top: 6, bottom: 6 })
      .border({ width: { left: 3 }, color: TERMINAL_QUOTE_BORDER_COLOR })
      .borderRadius(4)
    } else {
      Text() {
        ForEach(block.inline, (segment: ResumeMdInlineSegment) => {
          Span(segment.text)
            .fontColor(this.resumeMarkdownSegmentColor(segment, item))
            .fontWeight(this.resumeMarkdownSegmentWeight(segment))
            .fontStyle(this.resumeMarkdownSegmentStyle(segment))
            .decoration({
              type: this.resumeMarkdownSegmentDecoration(segment),
              color: TERMINAL_LINK_COLOR
            })
            .backgroundColor(segment.kind === RESUME_MD_BLOCK_CODE ? TERMINAL_CODE_BLOCK_BACKGROUND_COLOR : TERMINAL_TRANSPARENT_COLOR)
        }, (segment: ResumeMdInlineSegment) => segment.id)
      }
        .fontSize(this.resumeContentSize(14))
        .fontFamily(TERMINAL_FONT_FAMILY)
        .fontColor(this.resumeBodyTextColor(item))
        .width('100%')
        .padding({ left: 12, right: 8, top: 6, bottom: 6 })
        .border({ width: { left: 3 }, color: TERMINAL_QUOTE_BORDER_COLOR })
        .borderRadius(4)
        .wordBreak(WordBreak.BREAK_ALL)
        .textAlign(TextAlign.Start)
        .textOverflow({ overflow: TextOverflow.Clip })
        .copyOption(CopyOptions.LocalDevice)
    }
  }

  @Builder
  private ResumeMarkdownDivider() {
    Divider()
      .strokeWidth(1)
      .color(TERMINAL_BORDER_COLOR)
      .width('100%')
      .margin({ top: 2, bottom: 2 })
  }

  @Builder
  private ResumeMarkdownCodeBlock(block: ResumeMdBlock, item: ResumeContentItem) {
    Column({ space: 0 }) {
      Row({ space: 8 }) {
        Text(block.language)
          .fontSize(this.resumeContentSize(11))
          .fontFamily(TERMINAL_FONT_FAMILY)
          .fontColor(TERMINAL_MUTED_TEXT_COLOR)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Button('复制')
          .height(24)
          .padding({ left: 10, right: 10 })
          .fontSize(this.resumeContentSize(11))
          .fontFamily(TERMINAL_FONT_FAMILY)
          .fontColor(TERMINAL_ACCENT_TEXT_COLOR)
          .backgroundColor(TERMINAL_ACCENT_COLOR)
          .borderRadius(6)
          .onClick(() => {
            this.copyResumeText(block.text, '已复制代码');
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ bottom: 8 })

      ForEach(block.text.split('\n'), (codeLine: string, lineIndex: number) => {
        Text(codeLine.length > 0 ? codeLine : ' ')
          .fontSize(this.resumeContentSize(13))
          .fontFamily(TERMINAL_FONT_FAMILY)
          .fontColor(TERMINAL_TEXT_COLOR)
          .width('100%')
          .textAlign(TextAlign.Start)
          .wordBreak(WordBreak.BREAK_ALL)
      }, (codeLine: string, lineIndex: number) => `${block.id}-${lineIndex}`)
    }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor(TERMINAL_CODE_BLOCK_BACKGROUND_COLOR)
      .border({ width: 1, color: TERMINAL_CODE_BLOCK_BORDER_COLOR })
      .borderRadius(8)
  }

  @Builder
  private ResumeMarkdownBody(item: ResumeContentItem) {
    Column({ space: 6 }) {
      ForEach(this.resumeMarkdownBlocksForItem(item), (block: ResumeMdBlock) => {
        if (block.kind === RESUME_MD_BLOCK_HEADING) {
          this.ResumeMarkdownHeading(block, item)
        } else if (block.kind === RESUME_MD_BLOCK_CODE) {
          this.ResumeMarkdownCodeBlock(block, item)
        } else if (block.kind === RESUME_MD_BLOCK_LIST) {
          this.ResumeMarkdownList(block, item)
        } else if (block.kind === RESUME_MD_BLOCK_QUOTE) {
          this.ResumeMarkdownQuote(block, item)
        } else if (block.kind === RESUME_MD_BLOCK_DIVIDER) {
          this.ResumeMarkdownDivider()
        } else {
          this.ResumeMarkdownParagraph(block, item)
        }
      }, (block: ResumeMdBlock) => block.id)
    }
      .width('100%')
  }

  @Builder
  private ResumeContentItemView(item: ResumeContentItem, timestampText: string) {
    Column({ space: 6 }) {
      Row({ space: 4 }) {
        if (item.role === 'user') {
          Text('›')
            .width(10)
            .fontSize(this.resumeContentSize(13))
            .fontFamily(TERMINAL_FONT_FAMILY)
            .fontColor(this.resumeItemColor(item))
            .fontWeight(FontWeight.Bold)
            .textAlign(TextAlign.Start)
            .translate({ x: -11 })
            .margin({ right: -11 })
        }

        if (shouldShowAgentOutputDot(item.role)) {
          Column()
            .width(RESUME_AGENT_OUTPUT_DOT_SIZE)
            .height(RESUME_AGENT_OUTPUT_DOT_SIZE)
            .borderRadius(RESUME_AGENT_OUTPUT_DOT_SIZE / 2)
            .backgroundColor(TERMINAL_GREEN_COLOR)
            .translate({ x: RESUME_AGENT_OUTPUT_DOT_OFFSET_X })
            .margin({ right: RESUME_AGENT_OUTPUT_DOT_TRAILING_MARGIN })
        }

        Text(this.resumePromptText(item))
          .fontSize(this.resumeContentSize(12))
          .fontFamily(TERMINAL_FONT_FAMILY)
          .fontColor(this.resumeItemColor(item))
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.displayResumeStatus(item.status).length > 0) {
          Text(this.displayResumeStatus(item.status))
            .fontSize(this.resumeContentSize(11))
            .fontFamily(TERMINAL_FONT_FAMILY)
            .fontColor(TERMINAL_MUTED_TEXT_COLOR)
            .maxLines(1)
        }

        if (timestampText.length > 0) {
          Text(timestampText)
            .fontSize(this.resumeContentSize(11))
            .fontFamily(TERMINAL_FONT_FAMILY)
            .fontColor(TERMINAL_DIM_TEXT_COLOR)
            .maxLines(1)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.isResumeMarkdownBody(item)) {
        this.ResumeMarkdownBody(item)
      } else {
        Text() {
          ForEach(this.resumeTextSegments(item), (segment: ResumeTextSegment) => {
            Span(segment.text)
              .fontColor(this.resumeSegmentTextColor(segment, item))
              .fontWeight(this.resumeSegmentFontWeight(segment))
          }, (segment: ResumeTextSegment) => segment.id)
        }
          .fontSize(this.resumeContentSize(14))
          .fontFamily(TERMINAL_FONT_FAMILY)
          .fontColor(this.resumeBodyTextColor(item))
          .width('100%')
          .maxLines(80)
          .wordBreak(WordBreak.BREAK_ALL)
          .textAlign(TextAlign.Start)
          .textOverflow({ overflow: TextOverflow.Clip })
          .copyOption(CopyOptions.LocalDevice)
      }
    }
    .width('100%')
    .padding({ left: 24, right: 16, top: 10, bottom: 12 })
    .backgroundColor(this.resumeItemSurfaceColor(item))
    .borderRadius({ bottomLeft: 8, bottomRight: 8 })
  }

  @Builder
  private ReloginDialogContent() {
    Column({ space: 12 }) {
      if (this.dialogFeedback.length > 0) {
        Text(this.dialogFeedback)
          .fontSize(13)
          .fontColor(TERMINAL_DANGER_TEXT_COLOR)
          .width('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor(TERMINAL_DANGER_SURFACE_COLOR)
          .borderRadius(10)
      } else {
        Text('正在自动重新认证...')
          .fontSize(14)
          .fontColor(TERMINAL_MUTED_TEXT_COLOR)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
      }

      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(TERMINAL_MUTED_TEXT_COLOR)
          .backgroundColor(TERMINAL_BUTTON_SECONDARY_COLOR)
          .borderRadius(10)
          .border({ width: 1, color: TERMINAL_BORDER_COLOR })
          .onClick(() => {
            this.closeDialog();
          })
      }
      .width('100%')
      .padding({ top: 4 })
    }
    .width('100%')
  }

  @Builder
  private DeleteDialogContent() {
    Column({ space: 16 }) {
      Text('删除后将移除此设备上的连接记录和登录凭据。')
        .fontSize(14)
        .fontColor(TERMINAL_DANGER_TEXT_COLOR)
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .backgroundColor(TERMINAL_DANGER_SURFACE_COLOR)
        .borderRadius(10)

      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(TERMINAL_MUTED_TEXT_COLOR)
          .backgroundColor(TERMINAL_BUTTON_SECONDARY_COLOR)
          .borderRadius(10)
          .border({ width: 1, color: TERMINAL_BORDER_COLOR })
          .onClick(() => {
            this.closeDialog();
          })

        Button('删除')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(TERMINAL_DANGER_TEXT_COLOR)
          .backgroundColor(TERMINAL_DANGER_SURFACE_COLOR)
          .borderRadius(10)
          .border({ width: 1, color: '#FECACA' })
          .onClick(() => {
            this.deleteSelectedConnection();
          })
      }
      .width('100%')
      .padding({ top: 4 })
    }
    .width('100%')
  }

  @Builder
  private ReadonlyLine(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(TERMINAL_MUTED_TEXT_COLOR)
        .width(76)

      Text(value)
        .fontSize(14)
        .fontColor(TERMINAL_TEXT_COLOR)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }

  @Builder
  private AddConnectionPage() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Column({ space: 16 }) {
          Column({ space: 6 }) {
            Row() {
              this.WindowDots(8)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .height(10)
            .translate({ x: -2, y: 10 })

            Stack({ alignContent: Alignment.Center }) {
              Row() {
                Text('新建连接')
                  .fontSize(22)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(TERMINAL_TEXT_COLOR)
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .height('100%')
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .height(44)
          }
          .width('100%')

          Column({ space: 18 }) {
            this.Field('服务器地址', this.draftAddress, '例如 8.153.174.88')
            Row({ space: 10 }) {
              Button(this.testingConnection ? '正在测试...' : '测试连接')
                .height(36)
                .fontSize(13)
                .fontColor(TERMINAL_ACCENT_TEXT_COLOR)
                .backgroundColor(this.testingConnection ? TERMINAL_BUTTON_SECONDARY_COLOR : TERMINAL_ACCENT_COLOR)
                .borderRadius(8)
                .enabled(!this.testingConnection && this.draftAddress.trim().length > 0)
                .onClick(() => {
                  this.testConnection();
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.End)

            if (this.connectionTestResult.length > 0) {
              Text(this.connectionTestResult)
                .fontSize(13)
                .fontColor(this.connectionTestPassed ? TERMINAL_SUCCESS_TEXT_COLOR : TERMINAL_DANGER_TEXT_COLOR)
                .width('100%')
                .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                .backgroundColor(this.connectionTestPassed ? TERMINAL_SUCCESS_SURFACE_COLOR : TERMINAL_DANGER_SURFACE_COLOR)
                .borderRadius(10)
            }

            this.Field('注册码', this.draftPassword, '请输入注册码')
            this.Field('连接名称', this.draftName, '可选')

            Column({ space: 4 }) {
              Text('注册码由服务器管理员提供，每个设备注册一次。')
                .fontSize(12)
                .fontColor(TERMINAL_MUTED_TEXT_COLOR)
                .width('100%')
              Text('设备密钥由系统自动生成并安全存储在本机，无需手动管理。')
                .fontSize(12)
                .fontColor(TERMINAL_MUTED_TEXT_COLOR)
                .width('100%')
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .backgroundColor(TERMINAL_NOTICE_SURFACE_COLOR)
            .border({ width: 1, color: TERMINAL_NOTICE_BORDER_COLOR })
            .borderRadius(10)

            if (this.dialogFeedback.length > 0) {
              Text(this.dialogFeedback)
                .fontSize(13)
                .fontColor(TERMINAL_DANGER_TEXT_COLOR)
                .width('100%')
                .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                .backgroundColor(TERMINAL_DANGER_SURFACE_COLOR)
                .borderRadius(10)
            }
          }
          .width('100%')

          Button('连接')
            .width('100%')
            .height(48)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(TERMINAL_ACCENT_TEXT_COLOR)
            .backgroundColor(TERMINAL_ACCENT_COLOR)
            .borderRadius(12)
            .shadow({ radius: 16, color: TERMINAL_ACCENT_GLOW_COLOR, offsetX: 0, offsetY: 4 })
            .enabled(!this.connectionSubmitting)
            .onClick(() => {
              this.addConnection();
            })
        }
        .width('100%')
        .constraintSize({ maxWidth: this.getCardMaxWidth(), minHeight: this.addConnectionMeasuredCardHeight() })
        .padding({ left: 16, right: 16, top: 4, bottom: 20 })
        .backgroundColor(TERMINAL_PANEL_ELEVATED_COLOR)
        .border({ width: 1, color: TERMINAL_BORDER_COLOR })
        .borderRadius(20)
        .shadow({ radius: 24, color: TERMINAL_CARD_SHADOW_COLOR, offsetX: 0, offsetY: 8 })
        .translate({ y: this.addConnectionCardOffsetY() })
        .onAreaChange((_oldValue: Area, newValue: Area) => {
          const nextHeight = this.areaLengthToNumber(newValue.height);
          if (this.addConnectionCardHeight !== nextHeight) {
            this.addConnectionCardHeight = nextHeight;
          }
          if (nextHeight > this.addConnectionNaturalCardHeight) {
            this.addConnectionNaturalCardHeight = nextHeight;
          }
        })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .clip(false)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TERMINAL_BACKGROUND_COLOR)
    .clip(false)
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        const nextPageHeight = this.areaLengthToNumber(newValue.height);
        if (this.addConnectionPageHeight !== nextPageHeight) {
          this.addConnectionPageHeight = nextPageHeight;
        }
        if (nextPageHeight > this.addConnectionScreenHeight) {
          this.addConnectionScreenHeight = nextPageHeight;
        }
        const nextPageWidth = this.areaLengthToNumber(newValue.width);
        if (this.addConnectionPageWidth !== nextPageWidth) {
          this.addConnectionPageWidth = nextPageWidth;
        }
      })
  }
  build() {
    Column() {
      if (this.selectedTab === AppTab.FILES) {
        this.FileTabContent()
      } else {
        Stack() {
          if (this.hasActiveResumeSession) {
            this.ResumeSessionContent()
          } else if (this.dialog === ConnectionDialog.ADD) {
            this.AddConnectionPage()
          } else if (this.dialog === ConnectionDialog.RESUME_LIST) {
            this.ResumeListPage()
          } else {
            Column() {
              this.ConnectionList()
            }
            .width('100%')
            .height('100%')
            .backgroundColor(TERMINAL_BACKGROUND_COLOR)

            if (this.dialog === ConnectionDialog.EDIT) {
              this.DialogFrame('编辑连接')
            } else if (this.dialog === ConnectionDialog.RELOGIN) {
              this.DialogFrame('重新登录')
            } else if (this.dialog === ConnectionDialog.DELETE) {
              this.DialogFrame('删除连接')
            }
          }

          if (this.shouldShowRightEdgeBackGesture()) {
            Column() {
            }
            .width(28)
            .height('100%')
            .backgroundColor('#00FFFFFF')
            .align(Alignment.End)
            .gesture(
              PanGesture({ direction: PanDirection.Horizontal })
                .onActionEnd((event: GestureEvent) => {
                  this.handlePageLeftSwipe(event.offsetX);
                })
            )
          }
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(TERMINAL_BACKGROUND_COLOR)
      }

      if (!this.hasActiveResumeSession) {
        this.BottomNavBar()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TERMINAL_BACKGROUND_COLOR)
  }

  @Builder
  private BottomNavBar() {
    Row({ space: 8 }) {
      this.NavBarItem('连接', AppTab.CONNECT, '▣')
      this.NavBarItem('文件', AppTab.FILES, '▤')
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor(TERMINAL_ROW_COLOR)
    .border({ width: { top: 1 }, color: TERMINAL_BORDER_COLOR })
  }

  @Builder
  private NavBarItem(label: string, tab: AppTab, icon: string) {
    Column({ space: 2 }) {
      Text(icon)
        .fontSize(16)
        .fontColor(this.selectedTab === tab ? TERMINAL_TEXT_COLOR : TERMINAL_MUTED_TEXT_COLOR)
      Text(label)
        .fontSize(11)
        .fontColor(this.selectedTab === tab ? TERMINAL_TEXT_COLOR : TERMINAL_MUTED_TEXT_COLOR)
    }
    .layoutWeight(1)
    .height(46)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      if (this.selectedTab !== tab) {
        this.selectedTab = tab;
        if (tab === AppTab.FILES) {
          this.filesRefreshTick++;
          this.refreshServerFilesOnTabOpen();
        }
      }
    })
  }

  @Builder
  private FileTabContent() {
    Stack() {
      if (this.resolveConnectionForFiles() === null) {
        Column({ space: 10 }) {
          Text('请先添加并登录一个连接')
            .fontSize(13)
            .fontColor(TERMINAL_MUTED_TEXT_COLOR)
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Column({ space: 12 }) {
          Row({ space: 8 }) {
            Text('文件')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(TERMINAL_TEXT_COLOR)

            Blank()

            Button() {
              Text(this.serverFilesLoading ? '刷新中…' : '刷新')
                .fontSize(12)
                .fontColor(TERMINAL_BACKGROUND_COLOR)
            }
            .width(64)
            .height(32)
            .borderRadius(8)
            .backgroundColor(TERMINAL_TEXT_COLOR)
            .border({ width: 1, color: TERMINAL_BORDER_COLOR })
            .enabled(!this.serverFilesLoading)
            .onClick(() => this.loadServerFiles(this.resolveConnectionForFiles()))
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 4 })

          if (this.serverFilesLoading) {
            Text('正在获取文件…')
              .fontSize(13)
              .fontColor(TERMINAL_MUTED_TEXT_COLOR)
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
              .backgroundColor(TERMINAL_ROW_COLOR)
              .borderRadius(10)
              .border({ width: 1, color: TERMINAL_BORDER_COLOR })
          } else if (this.serverFilesFeedback.length > 0 && this.serverFiles.length === 0) {
            Column({ space: 10 }) {
              Text(this.serverFilesFeedback)
                .fontSize(13)
                .fontColor(TERMINAL_MUTED_TEXT_COLOR)
                .width('100%')
                .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                .backgroundColor(TERMINAL_ROW_COLOR)
                .borderRadius(10)
                .border({ width: 1, color: TERMINAL_BORDER_COLOR })

              if (this.serverFilesFeedback !== '暂无文件') {
                Button('重试')
                  .fontSize(12)
                  .fontColor(TERMINAL_BACKGROUND_COLOR)
                  .backgroundColor(TERMINAL_TEXT_COLOR)
                  .onClick(() => this.loadServerFiles(this.resolveConnectionForFiles()))
              }
            }
            .width('100%')
          } else {
            this.ServerFileList()
          }

          if (this.downloadFeedback.length > 0) {
            Text(this.downloadFeedback)
              .fontSize(12)
              .fontColor(TERMINAL_MUTED_TEXT_COLOR)
              .width('100%')
              .padding({ left: 14, right: 14, top: 10, bottom: 10 })
              .backgroundColor(TERMINAL_ROW_COLOR)
              .borderRadius(10)
              .border({ width: 1, color: TERMINAL_BORDER_COLOR })
          }
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .layoutWeight(1)
    .backgroundColor(TERMINAL_BACKGROUND_COLOR)
  }

  @Builder
  private ServerFileList() {
    Scroll() {
      Column({ space: RESUME_LIST_ROW_GAP }) {
        ForEach(this.serverFiles, (file: ServerFile) => {
          Column({ space: 10 }) {
            Row({ space: 12 }) {
              Column({ space: 4 }) {
                Text(file.name)
                  .fontSize(14)
                  .fontColor(TERMINAL_RESUME_TITLE_COLOR)
                  .fontWeight(FontWeight.Medium)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })

                Text(`${this.formatServerFileSize(file.size)} · ${this.formatServerFileDate(file.modifiedAt)}`)
                  .fontSize(12)
                  .fontColor(TERMINAL_MUTED_TEXT_COLOR)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Row({ space: 6 }) {
              if (this.downloadingFileId === file.name) {
                Button() {
                  Text('下载中…')
                    .fontSize(12)
                    .fontColor(TERMINAL_MUTED_TEXT_COLOR)
                }
                .width(72)
                .height(34)
                .borderRadius(8)
                .backgroundColor(TERMINAL_ROW_COLOR)
                .border({ width: 1, color: TERMINAL_BORDER_COLOR })
              } else if (this.downloadedFileName === file.name && this.openingFileName.length === 0) {
                Button() {
                  Text('打开')
                    .fontSize(12)
                    .fontColor(TERMINAL_BACKGROUND_COLOR)
                }
                .width(72)
                .height(34)
                .borderRadius(8)
                .backgroundColor(TERMINAL_TEXT_COLOR)
                .border({ width: 1, color: TERMINAL_BORDER_COLOR })
                .onClick(() => this.openDownloadedFile(file.name))
              } else {
                Button() {
                  Text('下载')
                    .fontSize(12)
                    .fontColor(TERMINAL_BACKGROUND_COLOR)
                }
                .width(72)
                .height(34)
                .borderRadius(8)
                .backgroundColor(TERMINAL_TEXT_COLOR)
                .border({ width: 1, color: TERMINAL_BORDER_COLOR })
                .enabled(this.downloadingFileId.length === 0 && this.openingFileName.length === 0)
                .onClick(() => this.downloadServerFile(this.resolveConnectionForFiles(), file))
              }
            }
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 12, bottom: 12 })
            .backgroundColor(TERMINAL_ROW_COLOR)
            .borderRadius(10)
            .border({ width: 1, color: TERMINAL_BORDER_COLOR })
          }
        }, (file: ServerFile) => file.name)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4, bottom: 16 })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
  }
}
