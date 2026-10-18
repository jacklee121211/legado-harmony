/**
 * @author 2008
 * @datetime 2024/5/27 16:09
 * @className: coverInfoImageShow
 * 分组封面弹窗的预览列（封面样式弹窗 coverInfoDialog 的子部件）。
 *
 * 2026-10-01 变更（用户："布局溢出"、"自定义和全图样式功能重叠就删一个"）：
 *   · 删除 coverCount===3「全图样式」列 —— 它与「自定义」共用同一个选图器，渲染上唯一
 *     差异是 BookOverlay 的 `coverType !== 2` 才画的底部装饰叠层（BookOverlay.ets:37、
 *     BookFolder.ets:232），0(默认)与1(自定义)渲染完全一样 ⇒ 三选二重，删全图。
 *     存量 coverType=2 的分组照常渲染（BookOverlay 的判断保留，老数据不受影响）。
 *   · 「默认样式」列的 9 张缩略图行**移交宿主**（coverInfoDialog 全宽网格，原来挤在
 *     ~1/3 宽的列里必然溢出 —— 9×26vp+间距 ≈ 282vp）。
 */
import CommonConstants from '../../common/constants/CommonConstants'
import { coverCorners } from '../../common/utils/CoverSource'
import { Haptics } from '../../common/utils/Haptics'
import { ThemeStorageKey } from '../../common/constants/Theme'
import { ThemeItem } from '../../common/model/Theme'
import BookOverlay from '../../componets/bookDetail/BookOverlay'

@Component
export default struct coverInfoImageShow {
  @Prop coverCount:number
  @Prop image:Resource|string
  @Prop imageString:string
  @Prop selectImage:number = 0
  /** v3.21：默认样式网格选中项（0-based；-1=未选）；宿主维护 */
  @Prop pickDefault:number = -1
  onSelectImageNumber:Function = (_selectImage:number)=>{}
  /** v3.21：默认封面网格点选回调（宿主写 coverUrl=default://…） */
  onPickDefault:Function = (_index:number)=>{}
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  build() {
    if (this.coverCount === 1){
      this.coverImageOne(typeof this.image === 'string' ? this.image : '')
    } else if (this.coverCount === 2){
      this.coverImageTwo()
    }
  }

  @Builder coverImageOne(bookImage:string){
    Column(){
      BookOverlay({
        // v3.21：默认样式 = 内置 9 封面（网格选中项优先于原封面）。
        // 2026-10-01：bookImage 为空（分组从未设置/存的是自定义图）时落内置默认 c1，
        // 保证"默认样式"预览永远是内置封面的真实对照（用户："如果用户没在此处修改过，
        // 则分组显示默认封面"）。
        bookImage: this.pickDefault >= 0
          ? ('default://cover_defaults/c' + (this.pickDefault + 1) + '.svg')
          : (bookImage !== '' ? bookImage : 'default://cover_defaults/c1.svg'),
        // 2026-10-05（用户："预览图有三层 + 底部白色矩形，太复杂了"）：
        // 预览**永远**只显示一张封面（不再画"书页叠层"），与真实封面同尺寸同圆角。
        showStack: false
      })
      // 2026-10-05：删除原来的白色底条（`Row().width(86).height(20).backgroundColor(Color.White)`）
      // —— 它就是用户看到的"底部白色矩形"，纯装饰、与预览无关。
      Row({
        space:12
      }){
        Text('默认样式')
          .fontWeight(400)
          .fontSize(14)
          .fontColor($r('app.string.color_black_45'))
          .lineHeight(22)
        Radio({value:JSON.stringify('0'),group:'radioGroup'})
          .checked(this.selectImage === 0)
          .radioStyle({
            checkedBackgroundColor: this.theme.mainColor
          })
          .border({width:2,color:'rgba(255, 255, 255, 0.10)'})
          .width(20).height(20)
          .onChange((val)=>{
            val? this.onSelectImageNumber(0):''
          })
      }
      .padding({top:8})
    }
  }

  /**
   * @deprecated 2026-10-18 起**不再被使用**：分组封面弹窗的「自定义」预览已内联到
   * `coverInfoDialog.customColumn()`。原因（真机日志 `docs/日志.md`）：
   *   `E AceStateMgmt: View coverInfoImageShow is already in process of destruction,
   *    will not execute observeComponentCreation2`
   * —— 选图返回的瞬间本组件正在销毁，`@Prop imageString` 的新值被丢弃，
   * 预览位停在旧值上并露出深色衬底（用户看到的"灰色蒙版"）。
   * 保留此分支只为兼容（当前仅 `coverCount === 1` 的「默认样式」列在用本组件）。
   */
  @Builder coverImageTwo(){
    Column(){
      Stack(){
        Flex({
          alignItems: ItemAlign.End,
        }){
          if (this.imageString) {
            // 2026-10-04：预览图与真实封面同尺寸同曲率（书脊式圆角，同内置封面 SVG），
            // 此前无尺寸无圆角，选图预览是一张直角大图，与实际显示效果不一致。
            Image(this.imageString).draggable(false)
              .borderRadius(coverCorners(CommonConstants.NOVEL_IMG_WIDTH))
              .width(CommonConstants.NOVEL_IMG_WIDTH)
              .height(CommonConstants.NOVEL_IMG_HEIGHT)
          } else {
            // ── 未选图占位（2026-10-13 重做）────────────────────────────────
            // 用户原话（真机截图）：「自定义预览图默认很难看，像是一个**灰色的矩形
            // 然后套着一个框**，然后内部还是**黑色的字体**」。
            // 旧实现三件套正是这三样：外层 `backgroundColor(color_black_65)`（黑 65% =
            // 深灰块）+ 虚线框（黑 20%，在深底上几乎不可见）+ `Text('点击选择')`
            // 用 `color_black_45`（黑字压深底 ⇒ 读不出来）。
            // 现在：**浅色底 + 可见虚线框 + picture 图标 + 可读提示字**，
            // 与单本封面弹窗（`CoverStyleDialog`）的选图入口视觉语言对齐。
            Column({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.picture'))
                .fontSize(20)
                .fontColor([$r('app.string.color_black_45')])
              Text('点击选择')
                .fontColor($r('app.string.color_black_45'))
                .fontWeight(400)
                .fontSize(12)
                .lineHeight(16)
            }
            .justifyContent(FlexAlign.Center)
            .width(CommonConstants.NOVEL_IMG_WIDTH)
            .height(CommonConstants.NOVEL_IMG_HEIGHT)
            .borderRadius(5)
            .backgroundColor('rgba(0, 0, 0, 0.03)')
            .border({ width: 1, color: 'rgba(0, 0, 0, 0.18)', style: BorderStyle.Dashed, radius: 5 })
          }
        }
        .borderRadius(5)
        // 2026-10-13：深色衬底只在**有图**时当"画框"用；空态必须透明，
        // 否则又会退化成用户看到的"灰块 + 框 + 黑字"。
        .backgroundColor(this.imageString ? $r('app.string.color_black_65') : Color.Transparent)
        .align(Alignment.Start)
        .width(CommonConstants.NOVEL_IMG_WIDTH).height(CommonConstants.NOVEL_IMG_HEIGHT)
        .zIndex(2)

        // 2026-10-05（用户："有三层 + 底部白色矩形，太复杂了"）：与"默认样式"列同样处理 ——
        // 删掉两层"书页叠层"（occlusion1/2），预览只留一张封面。
      }
      .align(Alignment.BottomStart)
      // 2026-10-05：同样删除"自定义"列下方的白色底条（原来是 Row().width(86).height(20) 白块）
      Row({
        space:12
      }){
        Text('自定义')
          .fontWeight(400).fontSize(14).fontColor($r('app.string.color_black_45')).lineHeight(22)
        Radio({value:JSON.stringify('1'),group:'radioGroup'})
          .checked(this.selectImage === 1)
          .radioStyle({
            checkedBackgroundColor: this.theme.mainColor
          })
          .border({width:2,color:'rgba(255, 255, 255, 0.10)'})
          .width(20).height(20)
          .onChange((val)=>{
            val? this.onSelectImageNumber(1):''
          })
      }
      .padding({top:8})
    }
  }
}
