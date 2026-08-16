import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';

const DOMAIN = 0x0000;
const DARK_MODE_PREFERENCES_NAME: string = 'codex_router_dark_mode';
const DARK_MODE_PREFERENCES_KEY: string = 'dark_mode';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;
  private keyboardHeightChangeCallback: ((height: number) => void) | null = null;
  private avoidAreaChangeCallback: ((options: window.AvoidAreaOptions) => void) | null = null;
  private keyboardDidShowCallback: ((info: window.KeyboardInfo) => void) | null = null;
  private keyboardDidHideCallback: ((info: window.KeyboardInfo) => void) | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.applySavedColorMode();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  private applySavedColorMode(): void {
    let saved: preferences.ValueType = '';
    try {
      const store = preferences.getPreferencesSync(this.context, { name: DARK_MODE_PREFERENCES_NAME });
      saved = store.getSync(DARK_MODE_PREFERENCES_KEY, '');
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to read color mode preference. Cause: %{public}s', JSON.stringify(err));
    }

    try {
      if (saved === 'dark') {
        this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else if (saved === 'light') {
        this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else {
        this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    try {
      this.mainWindow = windowStage.getMainWindowSync();
      this.applyImmersiveWindow(this.mainWindow);
      this.watchKeyboardHeight(this.mainWindow);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to apply immersive window. Cause: %{public}s', JSON.stringify(err));
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    this.unwatchKeyboardHeight();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    if (this.mainWindow !== null) {
      this.applyImmersiveWindow(this.mainWindow);
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  private async applyImmersiveWindow(mainWindow: window.Window): Promise<void> {
    try {
      await mainWindow.setWindowLayoutFullScreen(true);
      await mainWindow.setWindowSystemBarEnable([]);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to hide system bars. Cause: %{public}s', JSON.stringify(err));
    }
  }

  private watchKeyboardHeight(mainWindow: window.Window): void {
    AppStorage.setOrCreate<number>('aiRouterKeyboardHeightPx', 0);
    this.keyboardHeightChangeCallback = (height: number): void => {
      this.updateKeyboardHeight(Math.max(0, height), 'height');
    };
    this.avoidAreaChangeCallback = (options: window.AvoidAreaOptions): void => {
      if (options.type !== window.AvoidAreaType.TYPE_KEYBOARD) {
        return;
      }

      this.updateKeyboardHeight(this.resolveKeyboardAvoidAreaHeight(options.area), 'avoidArea');
    };
    this.keyboardDidShowCallback = (info: window.KeyboardInfo): void => {
      this.updateKeyboardHeight(Math.max(0, info.endRect.height), 'didShow');
    };
    this.keyboardDidHideCallback = (_info: window.KeyboardInfo): void => {
      this.updateKeyboardHeight(0, 'didHide');
    };

    mainWindow.on('keyboardHeightChange', this.keyboardHeightChangeCallback);
    mainWindow.on('avoidAreaChange', this.avoidAreaChangeCallback);
    try {
      mainWindow.on('keyboardDidShow', this.keyboardDidShowCallback);
      mainWindow.on('keyboardDidHide', this.keyboardDidHideCallback);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to watch keyboard animation. Cause: %{public}s', JSON.stringify(err));
    }
    try {
      this.updateKeyboardHeight(this.resolveKeyboardAvoidAreaHeight(
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD)), 'initialAvoidArea');
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to read keyboard avoid area. Cause: %{public}s', JSON.stringify(err));
    }
  }

  private unwatchKeyboardHeight(): void {
    if (this.mainWindow !== null && this.keyboardHeightChangeCallback !== null) {
      try {
        this.mainWindow.off('keyboardHeightChange', this.keyboardHeightChangeCallback);
      } catch (err) {
        hilog.error(DOMAIN, 'testTag', 'Failed to unwatch keyboard height. Cause: %{public}s', JSON.stringify(err));
      }
    }
    if (this.mainWindow !== null && this.avoidAreaChangeCallback !== null) {
      try {
        this.mainWindow.off('avoidAreaChange', this.avoidAreaChangeCallback);
      } catch (err) {
        hilog.error(DOMAIN, 'testTag', 'Failed to unwatch keyboard avoid area. Cause: %{public}s',
          JSON.stringify(err));
      }
    }
    if (this.mainWindow !== null && this.keyboardDidShowCallback !== null) {
      try {
        this.mainWindow.off('keyboardDidShow', this.keyboardDidShowCallback);
      } catch (err) {
        hilog.error(DOMAIN, 'testTag', 'Failed to unwatch keyboard show. Cause: %{public}s', JSON.stringify(err));
      }
    }
    if (this.mainWindow !== null && this.keyboardDidHideCallback !== null) {
      try {
        this.mainWindow.off('keyboardDidHide', this.keyboardDidHideCallback);
      } catch (err) {
        hilog.error(DOMAIN, 'testTag', 'Failed to unwatch keyboard hide. Cause: %{public}s', JSON.stringify(err));
      }
    }

    this.keyboardHeightChangeCallback = null;
    this.avoidAreaChangeCallback = null;
    this.keyboardDidShowCallback = null;
    this.keyboardDidHideCallback = null;
    AppStorage.setOrCreate<number>('aiRouterKeyboardHeightPx', 0);
    AppStorage.set<number>('aiRouterKeyboardHeightPx', 0);
  }

  private resolveKeyboardAvoidAreaHeight(area: window.AvoidArea): number {
    if (!area.visible) {
      return 0;
    }

    return Math.max(0, area.bottomRect.height);
  }

  private updateKeyboardHeight(height: number, source: string): void {
    const nextHeight = Math.max(0, height);
    AppStorage.setOrCreate<number>('aiRouterKeyboardHeightPx', nextHeight);
    AppStorage.set<number>('aiRouterKeyboardHeightPx', nextHeight);
    hilog.info(DOMAIN, 'testTag', 'Keyboard height changed by %{public}s: %{public}d', source, nextHeight);
  }
}
