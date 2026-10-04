import CommonConstants from '../../common/constants/CommonConstants'
import { COVER_DEFAULT_FILES, defaultCoverIndex, coverCorners } from '../../common/utils/CoverSource'

@Component
export default struct BookOverlay {
  @Prop bookImage: Resource|string = ''
  @Prop isTop:boolean
  @Prop isShow:boolean = false
  @Prop coverType:number = 0

  /**
   * 封面源解析（2026-10-01 重写，修两处真机事故，日志见 2.md）：
   * ① 闪退：BookFolder.ets:302（group.coverUrl）/ WorksBookListInfo.ets:34（worksCoverUrl）
   *    对未设置封面的分组/书单传 undefined ⇒ 原表达式 `this.bookImage.toString()` 直接抛
   *    "Cannot read property toString of undefined"（16:59:04 点击分组闪退、17:09:43
   *    点击书单闪退，两次 Kill Reason: Js Error，进程被杀）。
   * ② 分组封面预览/卡片永不更新：原 `substring(10)` 只剥掉 'default://'（10 字符），把
   *    'default://cover_defaults/c3.svg' 拼成
   *    $rawfile('cover_defaults/' + 'cover_defaults/c3.svg') ⇒ 路径翻倍、文件永远找不到，
   *    用户实测"点击默认款式其他款，上面的预览没有实时更新"（17:05 分组封面测试）。
   *    存储协议以 `CoverSource.DEFAULT_COVER_PREFIX`（25 字符）为准，与单本弹窗
   *    （CoverStyleDialog）/书架渲染（BookInfos→resolveCoverSource）保持同一契约。
   */
  private coverSrc(): ResourceStr {
    const raw: string = this.bookImage === undefined || this.bookImage === null
      ? '' : this.bookImage.toString()
    if (raw.startsWith('default://cover_defaults/')) {
      // 2026-10-01：改走字面量表（$rawfile 传变量），顺带根除原拼接写法的资源检查误报
      const idx: number = defaultCoverIndex(raw)
      return idx > 0 ? $rawfile(COVER_DEFAULT_FILES[idx - 1]) : ''
    }
    if (raw === '') {
      // 2026-10-01 用户需求："如果用户没在此处修改过，则分组显示默认封面" ——
      // 分组/书单卡片未设置封面时显示内置默认封面 c1（真实对照，不再露空白 alt 图）。
      return $rawfile('cover_defaults/c1.svg')
    }
    return this.bookImage
  }

  build() {

    Stack(){
      if (this.isShow){
        Column(){

        }
        .zIndex(3)
        .backgroundColor('rgba(0,0,0,0.45)')
        .width(CommonConstants.NOVEL_IMG_WIDTH).height(CommonConstants.NOVEL_IMG_HEIGHT)
      }

      Stack(){
        if (this.isTop){
          Text('置顶').fontColor(Color.White).fontWeight(300).fontSize(8).padding(3).borderRadius(5)
            .backgroundColor('rgba(0, 0, 0, 0.45)').zIndex(1)
        }
        Image(this.coverSrc())
          .draggable(false)
          .alt($r('app.media.icon_book_default_cover_one'))
          // 2026-10-04：补书脊式圆角（同内置封面 SVG，90 宽画布左 4 / 右 8 等比）。
          .borderRadius(coverCorners(CommonConstants.NOVEL_IMG_WIDTH))
          .width(CommonConstants.NOVEL_IMG_WIDTH)
          .height(CommonConstants.NOVEL_IMG_HEIGHT)
      }
      .zIndex(2)
      .alignContent(Alignment.BottomStart)
      if (this.coverType !== 2){
        Row(){
          Image($r('app.media.occlusion1')).draggable(false)
        }
        .zIndex(1)
        .width(CommonConstants.NOVEL_IMG_WIDTH + 5).height(CommonConstants.NOVEL_IMG_HEIGHT - 5)

        Row(){
          Image($r('app.media.occlusion2')).draggable(false)
        }.zIndex(0)
        .width(CommonConstants.NOVEL_IMG_WIDTH + 10).height(CommonConstants.NOVEL_IMG_HEIGHT - 10)
      }
    }
    .align(Alignment.BottomStart)
  }
}
