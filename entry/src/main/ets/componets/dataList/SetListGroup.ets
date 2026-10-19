

export class SetGroupList {

  groupValue: string


  setList: SetList[]

  constructor(groupValue: string, setList: SetList[]) {
    this.groupValue = groupValue;
    this.setList = setList;
  }
}

@Observed
export class SetList{

  /**
   * 是否显示箭头
   */
  showArrow: boolean

  /**
   *
   */
  value: string

  /**
   * 右边按钮状态
   */
  toggleStatus?: boolean

  /**
   * 右边文字
   */
  rightText?: string

  /**
   * 下面文字
   */
  bottomText?: string

  /**
   * 是否在开关左侧挂「VIP」金标（2026-10-08：防窥两层开关为会员特权，
   * 用户要求与阅读页"未开通才显示"的做法不同 —— 这里**常驻**标识特权属性）
   */
  vipMark?: boolean

  /**
   * 整行置灰不可用（2026-10-08：如「智控键翻页」在本机探测为不支持时）。
   * 渲染侧：整行降透明度 + Toggle 不可点；点击侧由页面在 itemOnclick 里自行拦。
   */
  disabled?: boolean

  /**
   * 子项缩进（2026-10-19 新增）：true = 整行左内边距 +20vp（视觉上"开头空两格"）。
   * 用途：设置页「显示阅读器信息窗」主开关下面的元素子项（时间/电量/书签/防窥/定时）。
   * 渲染侧见 `SetListView`。
   */
  indent?: boolean

  /**
   * 不渲染右侧控件（2026-10-19 新增）：true = 既不画箭头也不画 Toggle，只留 `rightText`。
   * 用途：多档"值行"（如「时间显示」的 关 / 时:分 / 时:分:秒）—— 它既不是布尔开关，
   * 也不是跳转行；点击由页面在 `itemOnclick` 里按当前值循环。
   * ⚠️ 未设该字段时行为与改动前完全一致（`showArrow` 决定箭头/Toggle）。
   */
  hideControl?: boolean


  storageName: string



  constructor(
    showArrow: boolean,
    value: string,
    toggleStatus?: boolean,
    rightText?: string,
    bottomText?: string,
    storageName?: string,
    indent?: boolean,
    hideControl?: boolean
  ) {
    this.showArrow = showArrow;
    this.value = value;
    this.toggleStatus = toggleStatus || false; // 如果未传入toggleStatus，则默认为false
    this.rightText = rightText || ''; // 如果未传入rightText，则默认为空字符串
    this.bottomText = bottomText || ''; // 如果未传入bottomText，则默认为空字符串
    this.storageName = storageName || '';
    this.vipMark = false;
    this.disabled = false;
    this.indent = indent === true;
    this.hideControl = hideControl === true;
  }

}