import { KeyboardAvoidMode } from '@kit.ArkUI';
import { ConnectionHome } from '../components/ConnectionHome';

const SPLASH_KLEIN_BLUE: string = '#002FA7';

@Entry
@Component
struct Index {
  @State private backRequestToken: number = 0;
  @State private splashVisible: boolean = true;
  @State private splashLight: boolean = false;
  private splashTimer: number = -1;
  private splashHideTimer: number = -1;

  aboutToAppear(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.splashTimer = setTimeout(() => {
      this.splashLight = true;
    }, 220);
    this.splashHideTimer = setTimeout(() => {
      this.splashVisible = false;
    }, 1050);
  }

  aboutToDisappear(): void {
    if (this.splashTimer >= 0) {
      clearTimeout(this.splashTimer);
      this.splashTimer = -1;
    }
    if (this.splashHideTimer >= 0) {
      clearTimeout(this.splashHideTimer);
      this.splashHideTimer = -1;
    }
  }

  onBackPress(): boolean {
    this.backRequestToken++;
    return true;
  }

  build() {
    Stack() {
      ConnectionHome({ backRequestToken: $backRequestToken })

      if (this.splashVisible) {
        Column({ space: 12 }) {
          Text('AI')
            .fontSize(48)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.splashLight ? '#000000' : '#FFFFFF')
            .letterSpacing(0)

          Row()
            .width(56)
            .height(4)
            .borderRadius(2)
            .backgroundColor(SPLASH_KLEIN_BLUE)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.splashLight ? '#FFFFFF' : '#000000')
        .animation({ duration: 650, curve: Curve.EaseInOut })
      }
    }
    .width('100%')
    .height('100%')
  }
}
