import confirmDialogExample from '../../../../../componets/common/confirmDialog'
import { showMessage } from '../../../../../componets/common/promptShow'
import { BookGroups } from '../../../../../database/entities/BookGroups'
import BookFolderGridManage from './BookFolderGridManage'
import BookFolderInfoManage from './BookFolderInfoManage'
import { NightMode, ShelfColors } from '../../../../../common/utils/NightMode'

@Component
export default struct BookFolderManages {
  @Prop bookGroups:BookGroups[] = []
  @Link checkGroup:Record<number, boolean>
  @Prop EXHIBIT:string
  @State delCache:boolean = false
  @Prop isManage:boolean = true
  /** App 级深浅色：订阅只为深浅切换时触发重绘 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  onSelect:Function = () => {}
  bookInfoDel: CustomDialogController | null = new CustomDialogController({
    builder: confirmDialogExample({
      cancel: ()=> { this.onCancel() },
      confirm: ()=> { this.onAccept() },
      delCache:this.delCache
    }),
    cancel: this.exitApp,
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
  })

  onCancel() {
    // this.isClear = false
  }

  onAccept() {
    this.deleteFolder()
  }

  exitApp() {
    // this.isClear = false
  }

  deleteFolder() {
    showMessage('删除成功')
  }

 build() {
   if (this.bookGroups === null || this.bookGroups.length === 0) {
     Column() {
       Image($r('app.media.no_record')).width(200).height(200)
       Text('暂无浏览记录').fontSize(12).fontColor(ShelfColors.textSub()).fontWeight(500).padding(5)
     }
     .margin({ top: 120 })
   } else {
     Column(){
       if (this.EXHIBIT === '列表') {
         ForEach(this.bookGroups, (item: BookGroups) => {
           if (item.show && !item.isSystem) {
             BookFolderInfoManage({
               group:item,
               checkGroup:this.checkGroup,
               isManage:this.isManage,
               onSelect:()=>{
                 this.onSelect()
               }
             })
           }
         }, (item: BookGroups): string => groupCardKey(item))
       } else {
         GridRow({
           columns:3
         }){
           ForEach(this.bookGroups, (item: BookGroups) => {
             if (item.show && !item.isSystem) {
               GridCol(){
                 BookFolderGridManage({
                   group:item,
                   checkGroup:this.checkGroup,
                   isManage:this.isManage,
                   onSelect:()=>{
                     this.onSelect()
                   }
                 })
               }
             }
           }, (item: BookGroups): string => groupCardKey(item))
         }
       }
     }.layoutWeight(1)
   }
 }
}

/**
 * 分组卡片键值（2026-10-06）：**必须并入所有影响显示的字段**。
 *
 * 官方《ForEach：循环渲染》非首次渲染原文：「它会检查新生成的键值是否在上次渲染中已经存在。
 * 如果键值不存在，则会创建一个新的组件；**如果键值存在，则不会创建新的组件，而是直接渲染
 * 该键值所对应的组件**。」⇒ 只写 `'g'+groupId` 时，换封面 / 改名 / 置顶 / "共N本"变化
 * 都不会重建卡片（本项目规范 `docs/标准-弹窗与按钮统一规范.md:201,212` 同款要求）。
 */
function groupCardKey(item: BookGroups): string {
  return (item.groupId !== undefined ? 'g' + item.groupId : item.groupName)
    + '|' + (item.groupName ?? '')
    + '|' + (item.isTop ? 'T' : 'F')
    + '|' + (item.show ? '1' : '0')
    + '|' + (item.coverUrl ?? '')
    + '|' + item.coverType
    + '|' + (item.bookIds?.length ?? 0)
}
