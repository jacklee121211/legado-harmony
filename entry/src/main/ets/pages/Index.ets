import { bookParser, readerCore, ReadPageComponent } from '@kit.ReaderKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';

const TAG: string = 'ReaderProbe';
const DOMAIN: number = 0x0000;
/** 翻页采样次数（用于反推每页字符数） */
const FLIP_SAMPLES: number = 8;
/** 视口高度递减阶梯（px）：用于判断引擎页边距是固定值还是随视口变化 */
const VIEWPORT_STEPS: number[] = [0, 100, 200, 300];
/** 是否跑视口/字号阶梯（默认关：先做一次干净的满屏渲染，便于截图量墨迹） */
const RUN_SWEEP: boolean = true;

class ProbeHandler extends bookParser.BookParserHandler {
  private text: string = '';

  constructor(text: string) {
    super();
    this.text = text;
  }

  getBookInfo(): bookParser.BookInfo {
    const info: bookParser.BookInfo = {
      bookTitle: 'Probe',
      bookCreator: 'probe',
      bookLanguage: 'zh'
    };
    return info;
  }

  getCatalogList(): bookParser.CatalogItem[] {
    const item: bookParser.CatalogItem = {
      catalogId: 0,
      catalogName: '第1章',
      catalogLevel: 1,
      playOrder: 1,
      idRef: '0',
      href: '0'
    };
    return [item];
  }

  getSpineList(): bookParser.SpineItem[] {
    const s: bookParser.SpineItem = {
      idRef: '0',
      index: 0,
      href: '0',
      properties: ''
    };
    return [s];
  }

  getSpineItemContent(spineIndex: number): Promise<string> {
    const parts: string[] = this.text.split('\n');
    let html: string = '<html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0;background:#FFFFFF;color:#000000;}</style></head><body>';
    for (let i = 0; i < parts.length; i++) {
      const p: string = parts[i].trim();
      if (p.length > 0) {
        html += '<p>' + p + '</p>';
      }
    }
    html += '</body></html>';
    return Promise.resolve(html);
  }

  getResourceContent(spineIndex: number, filePath: string): ArrayBuffer {
    return new ArrayBuffer(0);
  }

  getDomPosByCatalogHref(href: string): string {
    return '0';
  }

  getAbsoluteResourcePath(spineIndex: number): string {
    return '';
  }
}

@Entry
@Component
struct Index {
  private controller: readerCore.ReaderComponentController = new readerCore.ReaderComponentController();
  @State logs: string[] = [];
  @State showPanel: boolean = true;
  private lastWinW: number = 0;
  private lastWinH: number = 0;
  @State showReader: boolean = true;
  private running: boolean = false;

  private addLog(msg: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', msg);
    this.logs = this.logs.concat([msg]);
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  aboutToAppear(): void {
    setTimeout(() => {
      this.runProbe();
    }, 1500);
    // ★ 2026-11-01：窗口尺寸变化（折叠屏切 单屏/双屏/三屏、2in1 拖窗）自动重测。
    //   一次启动即可采到多种形态的数据（云真机按分钟计费，省时间）。
    this.watchWindowSize();
  }

  /** 轮询屏幕尺寸；变化即重跑探针（标签会写 RESIZE） */
  private watchWindowSize(): void {
    try {
      const d0: display.Display = display.getDefaultDisplaySync();
      this.lastWinW = d0.width;
      this.lastWinH = d0.height;
    } catch (e) {
    }
    setInterval(() => {
      try {
        const d: display.Display = display.getDefaultDisplaySync();
        if (d.width !== this.lastWinW || d.height !== this.lastWinH) {
          this.lastWinW = d.width;
          this.lastWinH = d.height;
          this.addLog(`RESIZE ${d.width}x${d.height} density=${d.densityPixels} -> re-measure`);
          this.runProbe();
        }
      } catch (e) {
      }
    }, 1200);
  }

  private async loadProbeText(): Promise<string> {
    const ctx = getContext(this) as common.UIAbilityContext;
    const buf: Uint8Array = await ctx.resourceManager.getRawFileContent('probe.txt');
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(buf);
  }

  /** 窗口 / 避让区参数 */
  private async logWindow(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(ctx);
      const rect = win.getWindowProperties().windowRect;
      this.addLog(`windowRect=${rect.width}x${rect.height} left=${rect.left} top=${rect.top}`);
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const gesture = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM_GESTURE);
      const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.addLog(`avoid system.top=${sys.topRect.height} gesture.bottom=${gesture.bottomRect.height} nav.bottom=${nav.bottomRect.height}`);
    } catch (e) {
      this.addLog(`window info failed: ${JSON.stringify(e)}`);
    }
  }

  /** 逐页翻页采样：记录 pageOffset，用于反推每页字符数 */
  private async sampleFlip(tagText: string): Promise<void> {
    for (let i = 0; i < FLIP_SAMPLES; i++) {
      this.controller.flipPage(true);
      await this.sleep(220);
    }
    this.addLog(`${tagText}: flipped ${FLIP_SAMPLES} pages`);
    this.controller.flipPage(false);
  }

  private async runProbe(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    this.logs = [];

    this.addLog(`canIUse BookParser=${canIUse('SystemCapability.Reader.ReaderService.BookParser')}`);
    this.addLog(`canIUse ReaderCore=${canIUse('SystemCapability.Reader.ReaderService.ReaderCore')}`);
    this.addLog(`deviceType=${deviceInfo.deviceType} model=${deviceInfo.productModel}`);

    let d: display.Display | null = null;
    try {
      d = display.getDefaultDisplaySync();
      this.addLog(`display=${d.width}x${d.height} density=${d.densityPixels} dpi=${d.densityDPI}`);
      this.addLog(`vp=${px2vp(d.width).toFixed(2)}x${px2vp(d.height).toFixed(2)}`);
    } catch (e) {
      this.addLog(`display failed: ${JSON.stringify(e)}`);
    }

    await this.logWindow();

    // ── ENVPROBE：分档 / 折叠 / 全屏 / 渲染口径（2026-11-01 补全，云真机分档用）──
    try {
      const d0: display.Display = display.getDefaultDisplaySync();
      let wbp: string = 'n/a';
      let hbp: string = 'n/a';
      try { wbp = String(this.getUIContext().getWindowWidthBreakpoint()); } catch (e) { }
      try { hbp = String(this.getUIContext().getWindowHeightBreakpoint()); } catch (e) { }
      let foldable: boolean = false;
      let foldStatus: string = 'n/a';
      let foldMode: string = 'n/a';
      try { foldable = display.isFoldable(); } catch (e) { }
      try { foldStatus = String(display.getFoldStatus()); } catch (e) { }
      try { foldMode = String(display.getFoldDisplayMode()); } catch (e) { }
      this.addLog(`ENVPROBE wbp=${wbp} hbp=${hbp} foldable=${foldable} foldStatus=${foldStatus} foldMode=${foldMode}`);
      let sd: string = 'n/a';
      try { sd = String(d0.scaledDensity); } catch (e) { }
      this.addLog(`ENVPROBE density=${d0.densityPixels} scaledDensity=${sd} dpi=${d0.densityDPI} engineFont=systemDefault fontSize=30 lineHeight=1.6 flipMode=0`);
      const win2: window.Window = await window.getLastWindow(getContext(this) as common.UIAbilityContext);
      const wr: window.Rect = win2.getWindowProperties().windowRect;
      const full: string = (wr.width >= d0.width - 1 && wr.height >= d0.height - 1) ? 'Y' : 'N';
      this.addLog(`ENVPROBE window=${wr.width}x${wr.height} display=${d0.width}x${d0.height} fullscreen=${full} winVp=${(wr.width / d0.densityPixels).toFixed(2)}x${(wr.height / d0.densityPixels).toFixed(2)}`);
    } catch (e) {
      this.addLog(`ENVPROBE failed: ${JSON.stringify(e)}`);
    }

    let text: string = '';
    try {
      text = await this.loadProbeText();
      this.addLog(`rawfile chars=${text.length}`);
    } catch (e) {
      this.addLog(`read rawfile failed: ${JSON.stringify(e)}`);
      this.running = false;
      return;
    }

    const ctx = getContext(this) as common.UIAbilityContext;
    try {
      await this.controller.init(ctx);
      this.addLog('init OK');
    } catch (e) {
      this.addLog(`init FAILED: ${JSON.stringify(e)}`);
      this.running = false;
      return;
    }

    // 页码回调：pageShow 里的 pageOffset 是"当前页到全书起点的偏移"
    try {
      this.controller.on('pageShow', (info: readerCore.PageDataInfo) => {
        this.addLog(`pageShow offset=${info.pageOffset} header='${info.pageHeaderContent}' footer='${info.pageFooterContent}'`);
      });
      this.addLog('pageShow subscribed');
    } catch (e) {
      this.addLog(`pageShow subscribe FAILED: ${JSON.stringify(e)}`);
    }

    try {
      this.controller.registerBookParser(new ProbeHandler(text));
      this.addLog('registerBookParser OK');
    } catch (e) {
      this.addLog(`registerBookParser FAILED: ${JSON.stringify(e)}`);
    }

    const width: number = d !== null ? d.width : 1080;
    const height: number = d !== null ? d.height : 1920;
    const density: number = d !== null ? d.densityPixels : 3;

    // ① 全屏视口：基准测量
    try {
      this.controller.setPageConfig(this.mkSetting(width, height, density, 30));
      this.addLog(`setPageConfig viewPort=${width}x${height} fontSize=30 OK`);
      await this.controller.startPlay(0, '0');
      this.addLog('startPlay OK');
    } catch (e) {
      this.addLog(`startPlay FAILED: ${JSON.stringify(e)}`);
    }

    // ② 翻页采样（等引擎首帧稳定）
    await this.sleep(1500);
    if (RUN_SWEEP) {
      await this.sampleFlip('baseline(vp=full,fs=30)');
    }

    // ③ 视口阶梯：判断页边距是固定值还是随视口变化
    if (RUN_SWEEP) {
      for (let i = 0; i < VIEWPORT_STEPS.length; i++) {
        const dh: number = VIEWPORT_STEPS[i];
        if (dh === 0) {
          continue;
        }
        try {
          this.controller.setPageConfig(this.mkSetting(width, height - dh, density, 30));
          await this.controller.startPlay(0, '0');
          await this.sleep(400);
          this.addLog(`viewport=${height - dh} (dh=${dh}) startPlay OK`);
        } catch (e) {
          this.addLog(`viewport=${height - dh} FAILED: ${JSON.stringify(e)}`);
        }
      }
    }

    // ④ 字号阶梯：判断页边距是否随字号变化
    if (RUN_SWEEP) {
      const fonts: number[] = [16, 20];
      for (let i = 0; i < fonts.length; i++) {
        try {
          this.controller.setPageConfig(this.mkSetting(width, height, density, fonts[i]));
          await this.controller.startPlay(0, '0');
          await this.sleep(400);
          this.addLog(`fontSize=${fonts[i]} startPlay OK`);
        } catch (e) {
          this.addLog(`fontSize=${fonts[i]} FAILED: ${JSON.stringify(e)}`);
        }
      }
    }

    // ⑤ 复原为基准配置，并隐藏面板，让外部截图能扫到纯正文
    try {
      this.controller.setPageConfig(this.mkSetting(width, height, density, 30));
      await this.controller.startPlay(0, '0');
      await this.sleep(500);
      this.addLog('restored baseline config');
    } catch (e) {
      this.addLog(`restore FAILED: ${JSON.stringify(e)}`);
    }

    // ⑤' 先收起面板（纯正文），再自截图量首行/末行/行距
    this.showPanel = false;
    this.addLog('panel hidden, measuring...');
    await this.sleep(1000);
    await this.measureAndLog('baseline');

    this.addLog('PROBE DONE');
    this.running = false;
  }

  /**
   * 自截图 + 像素分析：量出引擎正文的首行/末行/行距。
   * 结果全部打到 hilog（tag ReaderProbe），不依赖取文件。
   */
  private async measureAndLog(tagText: string): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(ctx);
      const pm: image.PixelMap = await win.snapshot();
      const info: image.ImageInfo = await pm.getImageInfo();
      const w: number = info.size.width;
      const h: number = info.size.height;
      const buf: ArrayBuffer = new ArrayBuffer(w * h * 4);
      await pm.readPixelsToBuffer(buf);
      const px: Uint8Array = new Uint8Array(buf);
      pm.release();

      const x0: number = Math.floor(w * 0.03);
      const x1: number = Math.floor(w * 0.80);
      const inkCount: number[] = [];
      const inkRows: number[] = [];
      const yStart: number = Math.floor(h * 0.045);
      const yEnd: number = Math.floor(h * 0.97);
      for (let y = yStart; y < yEnd; y++) {
        let c: number = 0;
        const rowBase: number = y * w * 4;
        for (let x = x0; x < x1; x += 4) {
          const i: number = rowBase + x * 4;
          // 底部手势条（底部 10% 的中间 40%）不算墨迹
          if (y > h * 0.90 && x > w * 0.30 && x < w * 0.70) {
            continue;
          }
          const lum: number = 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2];
          if (lum < 100) {
            c++;
          }
        }
        inkCount.push(c);
        if (c >= 3) {
          inkRows.push(y);
        }
      }

      if (inkRows.length === 0) {
        this.addLog(`MEASURE(${tagText}) size=${w}x${h} NO_INK`);
        return;
      }

      const first: number = inkRows[0];
      const last: number = inkRows[inkRows.length - 1];

      // 行距：找连续墨迹段起点，取相邻起点差值的中位数
      const starts: number[] = [];
      let prevInk: boolean = false;
      let gap: number = 0;
      for (let y = 0; y < h; y++) {
        const ink: boolean = inkCount[y] >= 3;
        if (ink && !prevInk && (starts.length === 0 || gap >= 6)) {
          starts.push(y);
        }
        gap = ink ? 0 : gap + 1;
        prevInk = ink;
      }
      const diffs: number[] = [];
      for (let i = 1; i < starts.length; i++) {
        diffs.push(starts[i] - starts[i - 1]);
      }
      diffs.sort((a: number, b: number) => a - b);
      const pitch: number = diffs.length > 0 ? diffs[Math.floor(diffs.length / 2)] : -1;

      this.addLog(`MEASURE(${tagText}) size=${w}x${h} first=${first} last=${last} `
        + `lineStarts=${starts.length} pitch=${pitch} topMarginPx=${first} bottomMarginPx=${h - last}`);
    } catch (e) {
      this.addLog(`MEASURE(${tagText}) FAILED: ${JSON.stringify(e)}`);
    }
  }

  private mkSetting(width: number, height: number, density: number, fontSize: number): readerCore.ReaderSetting {
    const s: readerCore.ReaderSetting = {
      fontName: '鸿蒙黑体',
      fontSize: fontSize,
      fontWeight: 400,
      fontColor: '#000000',
      fontPath: '',
      lineHeight: 1.9,
      nightMode: false,
      themeColor: '#FFFFFF',
      themeBgImg: '',
      flipMode: '0',
      scaledDensity: density,
      viewPortWidth: width,
      viewPortHeight: height
    };
    return s;
  }

  build() {
    Stack() {
      if (this.showReader) {
        ReadPageComponent({
          controller: this.controller,
          readerCallback: (err: Error, data: readerCore.ReaderComponentController) => {
            if (data !== undefined && data !== null) {
              this.controller = data;
              hilog.info(DOMAIN, TAG, 'readerCallback OK');
            } else {
              hilog.error(DOMAIN, TAG, 'readerCallback err=%{public}s', JSON.stringify(err));
            }
          }
        })
          .width('100%')
          .height('100%')
      }

      if (this.showPanel) {
        Column({ space: 6 }) {
          Text('ReaderKit 探针').fontSize(18).fontWeight(700)
          Row({ space: 8 }) {
            Button('重跑').onClick(() => {
              this.runProbe();
            })
            Button('清空').onClick(() => {
              this.logs = [];
            })
            Button('收起').onClick(() => {
              this.showPanel = false;
            })
          }
          Scroll() {
            Column({ space: 2 }) {
              ForEach(this.logs, (line: string) => {
                Text(line).fontSize(11).width('100%')
              }, (line: string, idx: number) => `${idx}-${line}`)
            }.width('100%').alignItems(HorizontalAlign.Start)
          }
          .layoutWeight(1)
          .width('100%')
          .backgroundColor('#F2F2F2')
        }
        .width('92%')
        .height('78%')
        .padding(12)
        .backgroundColor('#FFFFFFEE')
        .borderRadius(12)
      } else {
        // 面板收起后留一个很小的入口，不挡正文
        Text('日志')
          .fontSize(10)
          .fontColor('#808080')
          .padding(4)
          .backgroundColor('#FFFFFFAA')
          .borderRadius(6)
          .position({ x: '84%', y: '95%' })
          .onClick(() => {
            this.showPanel = true;
          })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }
}
