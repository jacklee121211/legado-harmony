/**
 * 新格式（PDF / DOCX / DOC）支持开关 —— **唯一的开关入口**。
 *
 * 设计约束（项目 AGENTS.md §3）：不可本地验证的路径默认保留旧实现、必须能一键回退。
 * 本文件就是那个"一键"：任何一个常量改回 `false` / 空数组，行为立刻回到只支持 txt/epub/mobi/azw/azw3。
 *
 * 回退验证点（改完后必须确认）：
 *  1. 书架导入选择器只剩 5 种后缀；
 *  2. 分享/打开方式面板里不再出现喵阅接收 pdf/doc/docx；
 *  3. 打开一本已存在的 pdf 书 → 显示"该格式需要开启支持"而不是崩溃/黑屏。
 */

/** 总开关：false ⇒ 所有新格式相关路径全部不参与（导入白名单/接收/转换/门禁） */
export const FMT_MASTER_ENABLED: boolean = true;

/** PDF：页图 → epub（真机 POC 已通过，见 docs/PDF支持方案决策-2026-10-19.md §11） */
export const FMT_PDF_ENABLED: boolean = true;

/** DOCX：解压 + 解析 OOXML → 含图含表的 epub（纯自研，无第三方库） */
export const FMT_DOCX_ENABLED: boolean = true;

/** DOC（Word 97-2003 二进制）：只做系统预览（PreviewKit），阅读器里禁用其它功能 */
export const FMT_DOC_PREVIEW_ONLY: boolean = true;

/** 每章放多少页（目录条数 = ceil(页数/该值)）；10 与上游 legado 的 PAGE_SIZE 一致 */
export const FMT_PDF_PAGES_PER_CHAPTER: number = 10;

/**
 * 页图渲染目标宽度（px）。
 * 实测：本机屏幕 1320×2848、内容区约 1216px；PDF 原始点尺寸只有 612×792（72dpi）
 * ⇒ 必须按目标像素重渲染（`getAreaPixelMapWithOptions`），否则上屏发糊。
 * 取 1400 略大于内容宽，给"整页适配/轻微放大"留一点余量；再大则体积涨得快
 * （实测 1224×1584 JPEG85 ≈ 109KB/页）。
 */
export const FMT_PDF_RENDER_WIDTH_PX: number = 1320;

/** 页图 JPEG 质量 */
export const FMT_PDF_JPEG_QUALITY: number = 85;

/** 点页面 → 全屏放大查看（Z1 缩放） */
export const FMT_ZOOM_ENABLED: boolean = true;

/**
 * PDF「满宽」基准倍率（2026-10-19 真机实测推得）：
 * ReaderKit 的页面左右各有内边距，1320px 宽的页图实际只画到约 **1076px**
 * （实测方法：源图 `p0002.jpg` 里一条黑色通栏条位于 x=116..1203、宽 1088；
 *  该条在 100% 截图上落在 x=193..1084、宽 892 ⇒ 缩放 0.815，
 *  即页图显示宽 ≈ 1320×0.815 ≈ 1076px，两侧各留 ~122px）。
 * ⇒ 1320 / 1076 ≈ 1.227。乘上它，PDF 页的左右边正好贴住屏幕左右边（用户要的"撑满"）。
 */
export const FMT_PDF_FIT_SCALE: number = 1.23;

/**
 * PDF 用哪条渲染路径（2026-10-19 实测后定案）：
 *  false（默认）⇒ PDF 也走「页图 → epub → ReaderPage3」，与 txt/epub 完全同一套体验（推荐）；
 *  true        ⇒ 走自研图片阅读页 pages/view/Reader/PdfReaderPage（页面尺寸/手势完全可控，且自带 pinch 缩放）。
 * 两条路都已真机跑通（screenshots/fmt/30、31）。
 */
  export const FMT_PDF_USE_SELF_VIEWER: boolean = false;

/** 接收层（分享面板 / 用其他应用打开）是否接收新格式 */
export const FMT_SHARE_INTAKE_ENABLED: boolean = true;

/** 转换产物根目录（在 filesDir 下；删掉即彻底清理） */
export const FMT_CACHE_DIR: string = 'fmt_cache';

/**
 * 转换算法版本 —— 参与缓存目录名。
 * 改 EpubBuilder / 渲染参数 / 章节切分等**会影响产物内容**的逻辑时，把它 +1，
 * 老缓存自动失效（与 `BookNormalizer.FORMAT_VERSION` 同一套思路，见其注释）。
 * v2：页图章节加内联样式；v3：页图 JFIF 密度规范成 96dpi + 封面不再混进正文页。
 */
export const FMT_CACHE_VER: string = 'v11';

/** 参与"转换后阅读"的格式（小写、带点） */
export const FMT_CONVERTIBLE_EXT: string[] = ['.pdf', '.docx'];

/** 只做预览的格式（小写、带点） */
export const FMT_PREVIEW_ONLY_EXT: string[] = ['.doc'];

/** 取小写后缀（含点）：`/a/b/C.PDF` → `.pdf`；无后缀 → '' */
export function extOf(path: string): string {
  if (!path) {
    return '';
  }
  const i: number = path.lastIndexOf('.');
  if (i < 0) {
    return '';
  }
  return path.substring(i).toLowerCase();
}

export function isConvertibleExt(path: string): boolean {
  const e: string = extOf(path);
  return FMT_CONVERTIBLE_EXT.indexOf(e) >= 0;
}

export function isPreviewOnlyExt(path: string): boolean {
  const e: string = extOf(path);
  return FMT_PREVIEW_ONLY_EXT.indexOf(e) >= 0;
}

export function isPdfPath(path: string): boolean {
  return extOf(path) === '.pdf';
}

export function isDocxPath(path: string): boolean {
  return extOf(path) === '.docx';
}

/** 导入选择器要展示的后缀（受总开关控制） */
export function importableExts(): string[] {
  const base: string[] = ['.txt', '.epub', '.mobi', '.azw', '.azw3'];
  if (!FMT_MASTER_ENABLED) {
    return base;
  }
  if (FMT_PDF_ENABLED) {
    base.push('.pdf');
  }
  if (FMT_DOCX_ENABLED) {
    base.push('.docx');
  }
  if (FMT_DOC_PREVIEW_ONLY) {
    base.push('.doc');
  }
  return base;
}
