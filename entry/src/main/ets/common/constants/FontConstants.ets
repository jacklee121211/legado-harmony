/**
 * @author 2008
 * @datetime 2024/6/28 22:29
 * @className: FontConstants
 * 通用字体大小样式
 */
export default class FontConstants{
  //字体大小
  static readonly FONT_SIZE_12: number = 12;
  static readonly FONT_SIZE_14: number = 14;
  static readonly FONT_SIZE_16: number = 16;
  static readonly FONT_SIZE_18: number = 18;
  static readonly FONT_SIZE_20: number = 20;
  static readonly FONT_SIZE_22: number = 22;
  static readonly FONT_SIZE_24: number = 24;
  //字体粗细
  static readonly FONT_WEIGHT_400: number = 400;
  static readonly FONT_WEIGHT_500: number = 500;
  static readonly FONT_WEIGHT_600: number = 600;
  static readonly FONT_WEIGHT_700: number = 700;
  static readonly FONT_WEIGHT_800: number = 800;

  // ══════════════════════════════════════════════════════════════════════════
  // 语义阶梯（2026-10-06 新增 —— 用户要求「大字小字标题的字号都要有标准」）
  //
  // 上面的 `FONT_SIZE_*` 是**裸尺寸**：谁都能随手挑一个 ⇒ 历史代码里同一种"设置项标题"
  // 有的 14 有的 16。真机案例（设置页）：`componets/myset/SetListView.ets` 把**行标题**的
  // 字号跟"这一行有没有副说明"绑在一起（有 ⇒ 14 / 没有 ⇒ 16），于是说明为空串的那一行
  // 比邻居大一号；同一页自绘的「震动强度 / 震感模式」又写成 16。
  //
  // 下面这层是**角色 → 尺寸**的唯一映射，新代码与改到的代码一律取这里：
  //   TITLE   16 / W_TITLE   页面标题（TabHeader）、弹窗标题
  //   ITEM    14 / W_BODY    设置项名、表单行标签、列表行主文案（**不因有无副说明而变号**）
  //   VALUE   13             滑块当前值、档位 chip（品牌色）
  //   CAPTION 12             副说明、右侧值、分组小标题、提示
  //
  // ⚠️ 强调用**字重**（`W_TITLE`），不要用更大的字号顶替"条目"级 —— 那会立刻破坏阶梯。
  // 完整口径（三条硬规则 + 真机案例 + 自检项）：`docs/标准-弹窗与按钮统一规范.md` 第 6 节。
  // ══════════════════════════════════════════════════════════════════════════
  /** 标题级：页面标题 / 弹窗标题（16） */
  static readonly TITLE: number = FontConstants.FONT_SIZE_16;
  /** 条目标题级：设置项名、表单行标签、列表行主文案（14） */
  static readonly ITEM: number = FontConstants.FONT_SIZE_14;
  /** 辅助值级：滑块当前值、档位 chip、次要按钮文案（13；裸尺寸表里没有这一档，故写字面量） */
  static readonly VALUE: number = 13;
  /** 说明级：副说明、右侧值、分组小标题、提示（12） */
  static readonly CAPTION: number = FontConstants.FONT_SIZE_12;
  /** 字重：标题 / 强调（入口按钮等） */
  static readonly W_TITLE: number = FontConstants.FONT_WEIGHT_600;
  /** 字重：正文 */
  static readonly W_BODY: number = FontConstants.FONT_WEIGHT_400;
}