

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


  storageName: string



  constructor(
    showArrow: boolean,
    value: string,
    toggleStatus?: boolean,
    rightText?: string,
    bottomText?: string,
    storageName?: string
  ) {
    this.showArrow = showArrow;
    this.value = value;
    this.toggleStatus = toggleStatus || false; // 如果未传入toggleStatus，则默认为false
    this.rightText = rightText || ''; // 如果未传入rightText，则默认为空字符串
    this.bottomText = bottomText || ''; // 如果未传入bottomText，则默认为空字符串
    this.storageName = storageName || '';
    this.vipMark = false;
    this.disabled = false;
  }

}