/**
 * 书架听书迷你 dock（2026-10-09）。
 *
 * ── 设计原则（用户拍板）────────────────────────────────────────────────────
 * · **唯一实现是阅读器的听书模式**，本组件只做两件事：
 *   ① 入口/遥控：展开后的 ▶ 起播（无会话时）或暂停/续播；上一章/下一章直接调
 *      同一个 `TtsEngine` 静态单例；
 *   ② 镜像：书名来自 `ListenSession`（由听书状态镜像而来）。
 * · **点圆形只展开，不播放**（用户 2026-10-09：「把播放和暂停都放在展开后」）。
 * · **不做旋转动画**（用户 2026-10-09：「直接删除动画，就完了」）。
 *   旋转那套（`animateTo(iterations:-1)` + 相位 + 闸门 + onAppear 补起转）
 *   带来的问题远多于收益：被打断、越转越快、关闭展开后不转、重建跳变。
 *   现在圆形只表达两态：**播放中显示 ⏸，暂停显示 ▶**。
 *
 * ── 历史坑（别再踩）────────────────────────────────────────────────────────
 * · 圆形上**不能挂 onClick** —— 会吃掉 HDS「点迷你栏自动展开」的事件。
 * · 圆形裁切与（曾经的）旋转必须放在**外层 Column** 上：放在 Image 上时方图
 *   旋转会扫出裁切区，真机表现是"右侧缺一块、像月牙"。
 * · `CIRCLE_SIZE` 必须等于**页签栏高度 56**（官方约束「跟页签栏高度相等」），
 *   否则圆四周空一圈（用户反馈"图标没撑满按钮"）。
 */
import { HdsBarStyle, HdsTabsController } from '@kit.UIDesignKit';
import { Haptics } from '../../common/utils/Haptics';
import { NightMode } from '../../common/utils/NightMode';
import { ListenUnlock } from '../../common/utils/ListenUnlock';
import { ThemeStorageKey } from '../../common/constants/Theme';
import { ThemeItem } from '../../common/model/Theme';
import { TtsEngine, TtsState } from '../../tts/TtsEngine';
import { ListenSession } from '../../tts/ListenSession';

/** 圆形直径（vp）= 页签栏高度 56，保证"撑满按钮" */
const CIRCLE_SIZE: number = 56;

@Component
export struct ListenDock {
  /** HDS 控制器：X 收回圆形用它（`applyMiniBarStyle(COLLAPSE)`） */
  controller: HdsTabsController = new HdsTabsController();
  /** 「开始听书」的动作，由 `Index` 注入。本组件不做任何起播逻辑（那是引擎/阅读器的职责） */
  onStartListen: () => void = (): void => {
  };
  @StorageLink('listenEntryUnlocked') unlocked: boolean = false;
  @StorageLink('listenExpanded') expanded: boolean = false;
  @StorageLink('listenPlaying') playing: boolean = false;
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem;

  aboutToAppear(): void {
    // ★ 判别打点（2026-10-09 排查"切页签圆形闪"）：
    //   切页签时**只要这行出现一次**，就说明迷你栏内容**被销毁重建了**
    //   （= HDS 把 `barFloatingStyle` 当成"配置变了"重新应用）⇒ 闪是"重建"造成的；
    //   如果切页签**完全不出现**，则节点没重建 ⇒ 闪只能是"重绘/配色"造成的。
    //   两者修法完全不同，所以必须先分清。
    console.info('LISTENDOCK', `dock node rebuilt, playing=${this.playing} expanded=${this.expanded}`);
    // 与 `ReaderPage3:3140` 同源：`@StorageLink` 初值 false，必须从 Preferences 拉一次，
    // 否则已解锁用户冷启动后书架上看不到这个入口。
    this.unlocked = ListenUnlock.isUnlocked();
  }

  /** 未播放色：与底部页签未选中态同源（深浅档各自取色） */
  private idleColor(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.90)' : '#000000';
  }

  private seekChapter(delta: number): void {
    Haptics.tap();
    if (TtsEngine.getState() === 'stopped') {
      return;
    }
    const target = Math.max(0, TtsEngine.currentChapter() + delta);
    TtsEngine.seekToChapter(target);
  }

  /** 播放/暂停：会话不存在或引擎已停 ⇒ 交回「开始听书」 */
  private onPlayPauseTap(): void {
    Haptics.tap();
    const st: TtsState = TtsEngine.getState();
    if (!ListenSession.isActive() || st === 'stopped') {
      this.onStartListen();
      return;
    }
    if (st === 'playing') {
      TtsEngine.pause();
    } else {
      TtsEngine.resume();
    }
  }

  /**
   * X：**只收回 UI，不停播**。
   * `applyMiniBarStyle(COLLAPSE)` 的几何动画由 HDS 负责；折叠完成后
   * `onBarStyleChange` 会把 `listenExpanded` 置 false。
   */
  private collapse(): void {
    Haptics.tap();
    ListenSession.setExpanded(false);
    this.controller.applyMiniBarStyle(HdsBarStyle.COLLAPSE);
  }

  /** 折叠态：app 图标圆形裁切 + 居中 播放/暂停 symbol（**无旋转动画**） */
  @Builder
  circle() {
    Stack() {
      Column() {
        Image($r('app.media.app_icon'))
          .width(CIRCLE_SIZE)
          .height(CIRCLE_SIZE)
          .objectFit(ImageFit.Cover)
          // ★★ 2026-10-09「切页签圆形区域闪一下」的**正解** ★★
          //   真机打点实证：切页签时 `currentTabIndex` 变 → Index 重渲染 →
          //   `hdsFloatingStyle()` 重跑 → 迷你栏 builder 重跑 →
          //   **本组件被销毁重建**（`dock node rebuilt` 与 `tab` 同拍出现）。
          //   这是 `@Builder` 的架构决定，**防不住**（父组件每次重渲染，builder 里的
          //   自定义组件就会重建）⇒ 只能让"重建那一帧就已经有内容"。
          //   而 `Image` 默认**异步**加载：重建首帧图还没上屏、占位图也不画
          //   ⇒ 露出底下的材质/主题色 ⇒ 用户看到"圆形瞬间变橙色"。
          //
          //   `.syncLoad(true)` 的官方原文（SDK `component/image.d.ts:1136`，@since 8）：
          //     「Whether to load the image synchronously. By default, the image is loaded
          //       asynchronously. **During synchronous loading, the UI thread is blocked and
          //       the placeholder image is not displayed.**」
          //   ⇒ **占位图不显示** = 不会出现"空一帧"。
          //   代价：同步加载会阻塞 UI 线程 —— 本图是**本地资源、192×192**，开销可忽略
          //   （官方警告的 AppFreeze 是主线程阻塞 >6s，这里差着好几个数量级）。
          .syncLoad(true)
          .draggable(false)
      }
      .width(CIRCLE_SIZE)
      .height(CIRCLE_SIZE)
      .borderRadius(CIRCLE_SIZE / 2)
      .clip(true)
      // ★★ 2026-10-09「切页签圆形区域闪一下」修复：**这里不能有 backgroundColor** ★★
      //   圆上原本有一层 `backgroundColor(this.theme.mainColor)` 兜底（防"图标填不满"）。
      //   但切页签时 `Index.onAnimationStart` 会调 `NightMode.setMainTab()` + `sync()`
      //   —— **书架=深色档、主题/设置/我的=浅色档，主题色每次都变**
      //   ⇒ 这个背景属性每切一次页签就要重绘一帧，图像还没重新合成完
      //   ⇒ 肉眼正好看到圆形那一块闪一下（dock 其它部分不依赖主题色，所以不闪）。
      //   现在 `CIRCLE_SIZE = 56 = 页签栏高度`，图标本来就铺满整圆，
      //   兜底底色已无必要 ⇒ 去掉后圆的任何属性都不再随主题变，闪的根因消失。
      SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
        .fontSize(19)
        .fontColor([Color.White])
        .shadow({ radius: 6, color: 'rgba(0,0,0,0.55)', offsetX: 0, offsetY: 1 })
    }
    .width(CIRCLE_SIZE)
    .height(CIRCLE_SIZE)
    // ⚠️ 这里**不挂 onClick**：会让 HDS「点迷你栏自动展开」收不到事件。
  }

  /** 展开态：上一章 / 播放暂停 / 下一章 / X；书名条向上溢出画在条的上方 */
  @Builder
  controls() {
    // 迷你栏本体只有页签栏那么高（官方约束「跟页签栏高度相等」），所以书名条用
    // `offset()` **画**到上方；`enableMiniBarClip: false` 已开，不会被裁掉。
    // ⚠️ 为什么不用 `Index` 里包一层 Stack 来叠：`#main` 是一镜到底的测量基准
    //    （`common/utils/LongTakeBook.ets:81-82` 取 `getRectangleById('main')`），
    //    包一层会挪动基准，真机表现是"打开/回落动画位置全变"。结构不许再包。
    Stack() {
      Row() {
        SymbolGlyph($r('sys.symbol.backward_end_fill'))
          .fontSize(22)
          .fontColor([this.idleColor()])
          .padding(10)
          .onClick(() => {
            this.seekChapter(-1);
          })

        SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
          .fontSize(26)
          .fontColor([this.theme.mainColor])
          .padding(10)
          .onClick(() => {
            this.onPlayPauseTap();
          })

        SymbolGlyph($r('sys.symbol.forward_end_fill'))
          .fontSize(22)
          .fontColor([this.idleColor()])
          .padding(10)
          .onClick(() => {
            this.seekChapter(1);
          })

        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([this.idleColor()])
          .padding(10)
          .onClick(() => {
            this.collapse();
          })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.SpaceEvenly)
      .alignItems(VerticalAlign.Center)

      Column() {
        ListenTitleBar()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .offset({ y: -46 })
    }
    .width('100%')
    .height('100%')
  }

  build() {
    // ⚠️ 不能用 `ListenSession.isActive()` 做条件：那是普通静态读，**不驱动重绘**
    //    （`expanded` / `playing` 才是本组件的响应式源）。
    //    未解锁时 `.miniBar` 根本不会被挂上（见 `Index.hdsFloatingStyle()`）。
    if (this.unlocked) {
      if (this.expanded) {
        this.controls()
      } else {
        this.circle()
      }
    }
  }
}

/**
 * dock 上方的**书名信息条**（用户："在这个 dock 上面，居中对齐出现一个信息条，是书名"）。
 *
 * 为什么单独一个组件、由迷你栏 builder 用 `offset` 叠放：
 * MiniBar 官方约束是「跟页签栏高度相等且水平对齐」⇒ builder 的高度就是页签栏那 56vp，
 * 装不下它**上方**这条，只能在同一个 builder 里向上溢出绘制。
 */
@Component
export struct ListenTitleBar {
  @StorageLink('listenTitle') title: string = '';
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem;

  build() {
    Row() {
      SymbolGlyph($r('sys.symbol.music_note_list'))
        .fontSize(14)
        .fontColor([this.theme.mainColor])
        .margin({ right: 6 })
      Text(this.title)
        .fontSize(13)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.95)' : '#000000')
    }
    .constraintSize({ maxWidth: '80%' })
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor(NightMode.isDarkSurface() ? 'rgba(31,31,31,0.92)' : 'rgba(255,255,255,0.92)')
    .borderRadius(18)
    .shadow({ radius: 12, color: 'rgba(0,0,0,0.18)', offsetX: 0, offsetY: 2 })
  }
}
