// 阅读器**模块级常量**（2026-11-04 P3 批 A-1：从 `ReaderPage3.ets` 搬出，值逐字未改）。
//
// 为什么要独立成模块：这些是「排版标定 / 进度滑条 / 字体族名」的**唯一真源**，
//   原先散在 1.2 万行的 ReaderPage3 顶部，外部还有 4 处重复定义（ReaderPager / CalibMode /
//   MySetPage / ReaderCustomBg）。搬到这里之后，外部一律改为 import，杜绝"两处各留一份"。
//
// ⚠️ 改这里等于改排版标定与滑条行为：`HL_CALIB_KEY` 是线上存量键名（改了老用户的标定值就读不到），
//   `RS_SETTING_VER` 是 readerSetting 迁移版本号（改默认值必须 +1 并补迁移，见原注释）。
//
// 回退：把这批常量搬回 ReaderPage3.ets 顶部并把本文件删掉（git revert 对应提交即可）。

export const HL_DEV_DEFAULT: boolean = false;

/** 每行位数 = 文本宽 / (字号px × 该系数)。实测字宽 = 1em ⇒ **1.0** */
export const HL_ADVANCE_RATIO: number = 1.0;
/** 段首 text-indent 占几个字位：实测 121.5px = 2em ⇒ **2** */
export const HL_INDENT_SLOTS: number = 2;

/**
 * 整书进度滑条的**内部单位**：1 单位 = 0.1%，所以 0..100% 就是 `0..1000` 的整数。
 *
 * ⚠️⚠️ 2026-10-25 真机定案（"能点、拖不动"）：**绝对不要用浮点 step**。
 *   第一版写的是 `Slider({ min: 0, max: 100, step: 0.1 })`，真机表现是
 *   「点轨道能跳、拖动完全没反应」。根因有两条，都是浮点 step 引起的：
 *     ① `100 / 0.1` 在二进制里不是整数（≈999.9999999999999）⇒ Slider 内部按
 *        `(max-min)/step` 算吸附格数时算错，拖动被丢弃；
 *     ② 拖动中回写 `value` 时，回写的值一旦与内部值差 1e-15，Slider 会认为
 *        "外部改了值" ⇒ 重建拖动状态 ⇒ 手势被取消 ⇒ 松手收不到 `End` ⇒ 不跳转。
 *   ⇒ 现在改成**整数步进**（`min:0 / max:1000 / step:1`），浮点问题从根上消失；
 *     百分比只在外层做一次 `/10`。
 */
export const PROGRESS_UNIT_PER_PCT: number = 10;

/** 滑条上限（= 100% 对应的单位数） */
export const PROGRESS_UNIT_MAX: number = 100 * PROGRESS_UNIT_PER_PCT;

/**
 * 进度气泡宽度（vp）：够放"12.3%" + 一行"312/765 · 章节名"。
 *
 * 关于精度：**0.1%**，显示一位小数。为什么不是 0.01%——滑条轨道实测约 210vp
 * （390vp 屏扣掉左右内边距 + 两个"上一章/下一章"文本 + 两处间距），1 vp ≈ 0.48%、
 * 1 个物理像素 ≈ 0.16% ⇒ 手指横拖的物理极限就在 0.1%~0.5% 之间。写 0.01% 只是
 * "数字好看、手感骗人"（用户 2026-10-25 明确：「精度低一点也没关系，只是为了方便用户使用」）。
 */
export const PROGRESS_TIP_W: number = 176;

/** 进度气泡自动隐藏延时（ms） */
export const PROGRESS_TIP_MS: number = 1200;

/**
 * "拖动锁"静默兜底时长（ms）。
 *
 * 为什么需要：手指落在轨道上（不是 thumb 上）按下时，ArkUI 先报 `Click`，
 * 之后手指继续拖会报 `Moving`，但**抬起时不一定再报 `End`**（因为这次交互的
 * 起点被判成了点击）。没有兜底的话锁就永远开着 ⇒ 引擎回写永久失效 ⇒ thumb 再不跟随。
 * 700ms ≈ 两次事件间隔的 10 倍以上，正常拖动不会被误解锁。
 */
export const PROGRESS_HOLD_MS: number = 700;

// —— 可微调项默认值 ——
export const HL_DEF_TOP_PX: number = 230;          // 文本区首行顶部 y（px）
export const HL_DEF_WIDTH_RATIO: number = 0.861;   // 文本区宽度 / 视口宽度（1137px）
export const HL_DEF_LINE_MUL: number = 1.258;      // 行高系数默认（会被"实测容量自动校准"覆盖）
/** 自动校准采纳区间：超出即视为页高异常（实测页高会随系统避让区变化），弃用并回退手调/默认值 */
export const HL_LINE_MUL_MIN: number = 1.05;
export const HL_LINE_MUL_MAX: number = 1.60;
export const HL_BOTTOM_RESERVED_PX: number = 0;    // 文本区下方预留（px）

// 排版档位（FONT_PRESETS / LINE_HEIGHT_PRESETS）2026-09-26 随「字号/行距」滑条
// 一并迁入「字体管理」弹窗（ReaderFontDialog.ets），此处不再需要。
export const HL_CALIB_KEY: string = 'TtsHlCalibV3';

/**
 * `readerSetting` 迁移版本号。
 *
 * ⚠️ 今后任何「修改 readerSetting 默认值」都必须两步走：
 *   ① 把 RS_SETTING_VER +1；
 *   ② 在 `migrateReaderSetting()` 里补一段 `if (ver < N) { … }` 迁移。
 * 否则对「已读过」的书不生效 —— `readerSetting` 是按书持久化的，存量值会覆盖新默认值。
 * 依据：`ReaderPage3.ets` 原按书读写 `ReaderSetting_<书名>`；HANDOFF §4 坑 6 真机实测。
 * 另：`readerCore.ReaderSetting`（SDK `@hms.core.readerservice.readerComponent.d.ets:69-200`）
 * 的 13 个字段里**没有任何版本字段**，只能在对象外旁路存版本号。
 */
export const RS_SETTING_VER: number = 2;

/**
 * **系统中文黑体的族名**（不带 `fontPath` 时引擎自己按族名解析系统字体）。
 * ⚠️ 这是个**真实族名**，不是占位字面量：
 *   `getFontByName('HarmonyOS Sans SC')` 实测返回 `family = 鸿蒙黑体`
 *   （见本文件 `readerSetting` 初值处注释与真机日志 `fontinfo HarmonyOS Sans SC: {...}`）。
 * 取自 `readerSetting` 默认值，供迁移与 v2 纠正复用。
 */
export const SYSTEM_CJK_FONT_NAME: string = '鸿蒙黑体';
