/**
 * ezlt —— @hmanimations/ezcustomtransition v1.3.0 的**受控 fork**（2026-10-02 vendor 进工程）。
 *
 * ── 为什么要 fork ────────────────────────────────────────────────────────────
 * 官方库契约层（打断闸/手势返回/session 状态机/Navigation 注册）成熟健壮，原样保留；
 * 但其动画编排硬编码 250ms 等比缩放，无法承载本工程的视觉需求
 *（封面飞行 620/720ms + 绕左缘 3D 掀开 + 梯形 clip 展开）。
 * ⇒ vendor 源码进工程，只改编排段（session + Delegate），契约层跟随上游。
 * ⛔ 版本锁死：LOCKED @ v1.3.0（2026-10-02）。ohpm 包已卸载，上游更新不会覆盖本目录；升级 = 手动 diff 移植（fork 面积仅动画编排段，契约层保持官方原样刻意不合并）。
 *
 * 本文件 = 原库根 Index.ets 的桶出口（原 `'../../../../Index'` 深引用改指此处）。
 */
export { WindowUtils } from './utils/WindowUtils';

export { CustomTransition, AnimateCallback } from './utils/CustomNavigationUtils';

export { LongTakeSession } from './sessions/LongTakeSession';

export { LongTakeTransitionDelegate } from './CustomTransition/LongTakeTransitionDelegate';

export { RectInfo_px } from './utils/ComponentAttrUtils';

export { SnapShotImage } from './utils/SnapShotImage';

export { ezCustomTransition } from './ezCustomTransition';

export { LongTakeTransitionParam } from './utils/LongTakeTransitionParam';

export * from './Constants/ezCustomTransitionConstants';
