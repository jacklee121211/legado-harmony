/**
 * 「字体管理」弹窗（2026-09-26 新增，用户设计）。
 *
 * ── 需求原文（要点）─────────────────────────────────────────────────────────
 * 「直接把字体甚至原有的字号、间距都提取到一个新的弹窗中」「必须要有恢复默认的快捷项」
 * 「必须支持自定义改名」「做好下载：点击后弹窗输入**直链字体下载地址**，下载要有
 *   进度动画和取消按钮，下载后直接入库」「字体列表做好删除按钮以及确认弹窗」
 * 「查询加粗/下划线/斜体/中划线是否支持」。
 *
 * ── 能力边界（取证）─────────────────────────────────────────────────────────
 * · **加粗**：官方支持 —— `ReaderSetting.fontWeight: number`（SDK
 *   `@hms.core.readerservice.readerComponent.d.ets:93-99`），常规 400 / 加粗 700；
 * · **下划线 / 斜体 / 中划线**：官方**不支持** —— `ReaderSetting` 全部 13 个字段里没有
 *   对应属性（同文件 :69-200），引擎内部不可达，不做（UI 上不出现，避免无效开关）。
 *
 * ── 结构与风格 ──────────────────────────────────────────────────────────────
 * 弹窗配方与「更多材质」同款（@CustomDialog + 页面每次新建 controller + 沉浸光感材质 +
 * 弹簧出入场）；列表橙圈沿用背景方案的选中语言；正文字色随 colorMode 日/夜切换。
 * 字体文件登记/导入/下载/删除全部委托 `ReaderFontLib`（本弹窗只管 UI）。
 */
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { picker } from '@kit.CoreFileKit';
import { ReaderFontLib, FontLibItem } from '../../../common/utils/ReaderFontLib';
import { Haptics } from '../../../common/utils/Haptics';

/** 与原面板一致的快捷档位（字号） */
const FONT_PRESETS: number[] = [12, 18, 24, 32, 40, 48];
/** 与原面板一致的快捷档位（行距） */
const LINE_HEIGHT_PRESETS: number[] = [1.2, 1.6, 1.9, 2.4, 3.0];
/** 列表预览样张（用户定名「喵阅阅读」）：中文字形差异一眼可辨 */
const SAMPLE_TEXT: string = '喵阅阅读';

@CustomDialog
export struct ReaderFontDialog {
  controller?: CustomDialogController

  // ── 页面注入：当前值快照（controller 每次新建 ⇒ 打开时即最新）────────────
  @Prop initFontSize: number = 18
  @Prop initLineHeight: number = 1.9
  /** 当前正在用的字体名（橙圈 + 删除保护） */
  @Prop curFontName: string = ReaderFontLib.DEFAULT_NAME

  /** 应用回调：页面侧改 readerSetting + setPageConfig + updateHighlight */
  onFontSize: (v: number) => void = (): void => {}
  onLineHeight: (v: number) => void = (): void => {}
  onFont: (name: string, path: string) => void = (): void => {}

  /**
   * 关闭回调（2026-09-26 弹窗协调）：「完成」由**页面**关本弹窗并恢复父弹窗（设置面板）
   * —— 关闭权在页面（弹窗内 controller?.close() 曾失灵，见页面侧注释）。
   */
  onClose: () => void = (): void => {}

  @StorageLink('readerColorMode') colorMode: number = 1

  // ── 本地编辑态（页面是真源，这里只镜像当前会话的编辑）────────────────────
  @State fontSize: number = 18
  @State lineHeight: number = 1.9
  /** 列表（aboutToAppear 一次性读库；导入/下载/删除后手动刷新） */
  @State fonts: FontLibItem[] = []
  /** 正在改名的字体名（'' = 无）；改名输入框内容 */
  @State renamingName: string = ''
  @State renameText: string = ''
  /** 0 = 无下载；2 = 下载中（2026-09-26 去掉"展开"中间态：输入框常驻，见 build 下载区） */
  @State dlState: number = 0
  @State dlUrl: string = ''
  @State dlPercent: number = 0
  /** 多直链队列进度（3.4：空格/分号/逗号/顿号/中英文符号分隔，串行逐个下载） */
  @State dlIndex: number = 0
  @State dlTotal: number = 0
  @State dlFail: number = 0
  private dlQueue: string[] = []
  private dlReq: http.HttpRequest | null = null

  aboutToAppear(): void {
    this.fontSize = this.initFontSize
    this.lineHeight = this.initLineHeight
    this.refreshList()
  }

  /** 读库 + 预注册（导入/下载字体的预览与测量通道都要注册，串行幂等） */
  private refreshList(): void {
    const items: FontLibItem[] = ReaderFontLib.list()
    for (const f of items) {
      if (f.src !== 'system') {
        ReaderFontLib.ensureRegistered(this.getUIContext(), f.name, f.path)
      }
    }
    this.fonts = items
  }

  private toast(m: string): void {
    this.getUIContext().getPromptAction().showToast({ message: m, duration: 1500 })
  }

  private pick(item: FontLibItem): void {
    Haptics.tap();
    ReaderFontLib.ensureRegistered(this.getUIContext(), item.name, item.path)
    this.curFontName = item.name
    this.onFont(item.name, item.path)
  }

  // ── 导入（文件选择器 → 拷沙箱 → 登记；支持一次多选，逐个入库）──────────────
  private importFont(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
    const docPicker = new picker.DocumentViewPicker()
    const opts = new picker.DocumentSelectOptions()
    // 不限一个：用户要求"爱多少就多少个"（上限给 100 防失控，字库另有总量保险丝）
    opts.maxSelectNumber = 100
    docPicker.select(opts).then((uris: string[]) => {
      if (uris.length === 0) {
        return
      }
      let ok: number = 0
      let fail: number = 0
      const next = (i: number): void => {
        if (i >= uris.length) {
          this.refreshList()
          if (fail === 0) {
            this.toast(`已导入 ${ok} 个字体`)
          } else {
            this.toast(`导入 ${ok} 个，失败 ${fail} 个（仅支持 .ttf/.otf/.woff2）`)
          }
          return
        }
        ReaderFontLib.importFromUri(ctx, uris[i]).then((item: FontLibItem | null) => {
          if (item === null) {
            fail++
          } else {
            ok++
          }
          next(i + 1)
        })
      }
      next(0)
    }).catch((): void => {
      // 用户取消选择，不提示
    })
  }

  // ── 下载（直链 → 进度 + 取消 → 入库；支持一次粘贴多条串行下载）──────────────
  private startDownload(): void {
    // 分隔符全覆盖：空白 / 半角; / 全角； / 半角, / 全角， / 顿号、（3.4 用户要求）
    const parts: string[] = this.dlUrl.split(new RegExp('[\\s;,，、；]+'))
    const urls: string[] = []
    for (const p of parts) {
      const u: string = p.trim()
      if (u.length === 0) {
        continue
      }
      if (!ReaderFontLib.isFontFile(u.split('?')[0])) {
        this.toast('存在非字体直链：' + u)
        return
      }
      urls.push(u)
    }
    if (urls.length === 0) {
      this.toast('请先粘贴字体直链')
      return
    }
    this.dlQueue = urls
    this.dlTotal = urls.length
    this.dlIndex = 0
    this.dlFail = 0
    this.dlState = 2
    this.dlPercent = 0
    this.downloadNext()
  }

  /** 串行逐个下载（不并发抢带宽；单个失败计数后继续其余；取消即中止整个队列） */
  private downloadNext(): void {
    if (this.dlState !== 2) {
      return // 已取消
    }
    if (this.dlIndex >= this.dlQueue.length) {
      this.dlState = 0
      this.dlReq = null
      this.refreshList()
      if (this.dlFail === 0) {
        this.toast('全部下载完成')
      } else {
        this.toast(`完成 ${this.dlTotal - this.dlFail} 个，失败 ${this.dlFail} 个`)
      }
      return
    }
    const url: string = this.dlQueue[this.dlIndex]
    this.dlPercent = 0
    const req = http.createHttp()
    this.dlReq = req
    req.on('dataReceiveProgress', (data: http.DataReceiveProgressInfo) => {
      if (data.totalSize > 0) {
        this.dlPercent = Math.min(100, Math.round(data.receiveSize * 100 / data.totalSize))
      }
    })
    req.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 15000,
      readTimeout: 60000
    }).then((resp: http.HttpResponse) => {
      if (this.dlState !== 2) {
        // 下载途中被取消：丢弃结果
        req.destroy()
        this.dlReq = null
        return
      }
      const buf: ArrayBuffer = resp.result as ArrayBuffer
      const fileName: string = url.split('?')[0].substring(url.lastIndexOf('/') + 1)
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
      const item = ReaderFontLib.saveDownloaded(ctx, fileName, buf)
      req.destroy()
      this.dlReq = null
      if (item === null) {
        this.dlFail++
      } else {
        this.toast('已入库：' + item.name)
      }
      this.dlIndex++
      this.downloadNext()
    }).catch((): void => {
      this.dlReq = null
      if (this.dlState !== 2) {
        return
      }
      this.dlFail++
      this.dlIndex++
      this.downloadNext()
    })
  }

  private cancelDownload(): void {
    Haptics.tap();
    this.dlState = 0
    this.dlReq?.destroy()
    this.dlReq = null
    this.toast('已取消')
  }

  private askDelete(item: FontLibItem): void {
    this.getUIContext().showAlertDialog({
      message: '删除字体「' + item.name + '」？文件与登记将一并移除。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E5310A',
        action: (): void => {
          Haptics.tap();
          const inUse: boolean = item.name === this.curFontName
          if (ReaderFontLib.remove(item.name, inUse)) {
            this.refreshList()
            this.toast('已删除')
          } else {
            this.toast(inUse ? '正在使用中，请先换成其他字体' : '删除失败')
          }
        }
      }
    })
  }

  private confirmRename(): void {
    const item: FontLibItem | undefined = this.fonts.find((f: FontLibItem) => f.name === this.renamingName)
    this.renamingName = ''
    if (item === undefined) {
      return
    }
    const renamed = ReaderFontLib.rename(item.name, this.renameText)
    if (renamed === null) {
      this.toast('改名失败：名字为空或已被占用')
      return
    }
    // 正在用的字体改了名 ⇒ readerSetting.fontName 同步走一遍（测量通道按名注册）
    if (this.curFontName === item.name) {
      this.curFontName = renamed.name
      this.onFont(renamed.name, renamed.path)
    }
    this.refreshList()
    this.toast('已改名：' + renamed.name)
  }

  build() {
    Column({ space: 12 }) {
      // 顶栏：标题 + 完成（与「更多材质」同款）
      Row() {
        Text('字体管理')
          .fontSize(16)
          .fontWeight(600)
          .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
        Blank()
        Text('完成')
          .fontSize(15)
          .fontColor('#007DFF')
          .onClick(() => {
            Haptics.tap();
            this.onClose()
          })
      }
      .width('100%')

      // ── 字号 / 行距（从阅读器-设置迁入，含快捷档位）────────────────────────
      Row({ space: 12 }) {
        Text('字号')
          .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
        Slider({ value: this.fontSize, max: 48, min: 12, step: 1, style: SliderStyle.InSet })
          .selectedColor('#007DFF')
          .blockSize({ width: 30, height: 30 })
          .borderRadius(20)
          .padding({ left: 8, right: 8 })
          .layoutWeight(1)
          .onChange((value: number) => {
            Haptics.tick();
            this.fontSize = Math.round(value)
            this.onFontSize(this.fontSize)
          })
        Text(`${this.fontSize}`)
          .fontSize(13).fontColor('#007DFF').width(34).textAlign(TextAlign.End)
      }
      .width('100%')

      Row({ space: 6 }) {
        Text('档位')
          .fontSize(12)
          .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 0.6)' : 'rgba(19, 19, 19, 0.6)')
          .width(28)
        ForEach(FONT_PRESETS, (v: number) => {
          Text(`${v}`)
            .fontSize(13)
            .fontColor(this.fontSize === v ? '#007DFF'
              : (this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(12)
            .backgroundColor(this.fontSize === v ? 'rgba(0,125,255,0.15)' : Color.Transparent)
            .onClick(() => {
              Haptics.tap();
              this.fontSize = v
              this.onFontSize(v)
            })
        }, (v: number) => `fs-${v}`)
      }
      .width('100%')

      Row({ space: 12 }) {
        Text('行距')
          .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
        Slider({ value: this.lineHeight, max: 3, min: 1, step: 0.1, style: SliderStyle.InSet })
          .selectedColor('#007DFF')
          .blockSize({ width: 30, height: 30 })
          .borderRadius(20)
          .padding({ left: 8, right: 8 })
          .layoutWeight(1)
          .onChange((value: number) => {
            Haptics.tick();
            this.lineHeight = Math.round(value * 10) / 10
            this.onLineHeight(this.lineHeight)
          })
        Text(`${this.lineHeight.toFixed(1)}`)
          .fontSize(13).fontColor('#007DFF').width(34).textAlign(TextAlign.End)
      }
      .width('100%')

      Row({ space: 6 }) {
        Text('档位')
          .fontSize(12)
          .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 0.6)' : 'rgba(19, 19, 19, 0.6)')
          .width(28)
        ForEach(LINE_HEIGHT_PRESETS, (v: number) => {
          Text(v.toFixed(1))
            .fontSize(13)
            .fontColor(this.lineHeight === v ? '#007DFF'
              : (this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(12)
            .backgroundColor(this.lineHeight === v ? 'rgba(0,125,255,0.15)' : Color.Transparent)
            .onClick(() => {
              Haptics.tap();
              this.lineHeight = v
              this.onLineHeight(v)
            })
        }, (v: number) => `lh-${v}`)
      }
      .width('100%')

      // ── 字体列表（橙圈 = 当前使用；导入/下载项带 改名/删除）────────────────
      Scroll() {
        Column({ space: 6 }) {
          ForEach(this.fonts, (item: FontLibItem) => {
            if (this.renamingName === item.name) {
              // ── 改名行：输入框 + 确定/取消 ─────────────────────────────────
              Row({ space: 8 }) {
                TextInput({ text: item.name })
                  .onChange((v: string) => {
                    this.renameText = v
                  })
                  .fontSize(14)
                  .layoutWeight(1)
                  .height(36)
                Text('确定')
                  .fontSize(14).fontColor('#007DFF')
                  .onClick(() => {
                    Haptics.tap();
                    this.confirmRename()
                  })
                Text('取消')
                  .fontSize(14)
                  .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 0.6)' : 'rgba(19, 19, 19, 0.6)')
                  .onClick(() => {
                    Haptics.tap();
                    this.renamingName = ''
                  })
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(10)
              .backgroundColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 0.10)' : 'rgba(19, 19, 19, 0.05)')
            } else {
              Row({ space: 8 }) {
                Text(SAMPLE_TEXT)
                  .fontSize(18)
                  .fontFamily(item.name)
                  .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
                  .maxLines(1)
                Column({ space: 2 }) {
                  Text(item.name + (item.name === ReaderFontLib.DEFAULT_NAME ? '（默认）' : ''))
                    .fontSize(12)
                    .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 0.6)' : 'rgba(19, 19, 19, 0.6)')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                if (item.src !== 'system') {
                  Text('改名')
                    .fontSize(13).fontColor('#007DFF')
                    .padding(6)
                    .onClick(() => {
                      Haptics.tap();
                      this.renamingName = item.name
                      this.renameText = item.name
                    })
                  Text('删除')
                    .fontSize(13)
                    .fontColor(item.name === this.curFontName
                      ? (this.colorMode == 0 ? 'rgba(248, 249, 250, 0.35)' : 'rgba(19, 19, 19, 0.35)')
                      : '#E5310A')
                    .padding(6)
                    .onClick(() => {
                      Haptics.tap();
                      this.askDelete(item)
                    })
                }
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .borderRadius(10)
              .borderWidth(item.name === this.curFontName ? 1.5 : 0)
              .borderColor('#ff6600')
              .backgroundColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 0.06)' : 'rgba(19, 19, 19, 0.03)')
              .onClick(() => {
                this.pick(item)
              })
            }
          }, (item: FontLibItem) => item.name + '|' + item.path)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)

      // ── 下载区（3.3：去掉"展开"按钮，输入框常驻；3.4：占位文案 + 多直链）────
      if (this.dlState === 2) {
        Row({ space: 10 }) {
          Progress({ value: this.dlPercent, total: 100, type: ProgressType.Linear })
            .color('#007DFF')
            .layoutWeight(1)
          Text(`(${this.dlIndex + 1}/${this.dlTotal}) ${this.dlPercent}%`)
            .fontSize(12)
            .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 0.6)' : 'rgba(19, 19, 19, 0.6)')
          Text('取消')
            .fontSize(14).fontColor('#E5310A')
            .onClick(() => {
              this.cancelDownload()
            })
        }
        .width('100%')
      } else {
        TextInput({ text: this.dlUrl, placeholder: '粘贴字体直链，空格或；以输入多个' })
          .onChange((v: string) => {
            this.dlUrl = v
          })
          .fontSize(13)
          .width('100%')
          .height(36)

        Row({ space: 12 }) {
          Button('导入字体文件')
            .fontSize(13)
            .fontColor(Color.White)
            .backgroundColor('#007DFF')
            .borderRadius(18)
            .height(34)
            .padding({ left: 14, right: 14 })
            .onClick(() => {
              this.importFont()
            })
          Button('开始下载字体')
            .fontSize(13)
            .fontColor(Color.White)
            .backgroundColor('#007DFF')
            .borderRadius(18)
            .height(34)
            .padding({ left: 14, right: 14 })
            .onClick(() => {
              Haptics.tap();
              this.startDownload()
            })
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
      }
    }
    .padding(16)
    .width('100%')
    .height('78%')
  }
}
