/**
 * 阅读器「材质背景」—— 动态纹理清单 + 合成管线（2026-09-25 新增，同日二次改造）。
 *
 * ── 需求（用户原话要点）─────────────────────────────────────────────────────
 * 「将会引入大批量材质…只要在 rawfile 目录下名字叫做 **texture_xxx.jpg** 的文件都编译，
 *   只是**前八个**进入设置主页，其他的在「更多材质」里面。改成**三位**，不是 0X，而是 00X，
 *   便于以后更多拓展。」
 * ⇒ 纹理清单**运行时动态枚举**（不再写死 8 个）：`resourceManager.getRawFileListSync('')`
 *   （`@ohos.resourceManager.d.ts:2431`）列出 rawfile 根目录 → 正则过滤
 *   `^texture_\d{3}\.jpg$` → 按编号排序。往目录里丢新文件即自动进列表，零代码改动。
 *   编号即 id（texture_001 ⇒ 1），持久化稳定。
 *
 * ── 两步管线（mix 模式已按用户要求拆除，纯材质一条路）────────────────────────
 * ① `avgOf()`：64×64 快速解码取**平均色** —— 决定字色/nightMode/仿真翻页背面色
 *    （官方文档 `reader-setting-background`：「需要同时设置与背景图片相近的主题颜色，
 *      用于仿真翻页时背面主题色的绘制」）。内存缓存，一张图只算一次。
 * ② `composedPath()`：整图 **居中裁切到屏幕比例（上下顶高、左右按 1:1 自适应）**
 *    → 限长边 → 打包 JPEG 写沙箱缓存 → 返回路径给 `readerSetting.themeBgImg`
 *    （官方支持沙箱路径）。磁盘缓存：同一材质同一屏幕尺寸只合成一次。
 *
 * ── SDK 取证（`@ohos.multimedia.image.d.ts` / `@ohos.resourceManager.d.ts`）────
 * · `createImageSource(rawfile: RawFileDescriptor, options?)`（image.d.ts:4296）+
 *   `getRawFdSync(path)`（resourceManager.d.ts:2025）—— rawfile 直接解码；
 * · `PixelMap.crop(region)`（:5669，@since 8）、`scale(x,y)`（:5233）、
 *   `readPixelsToBuffer(dst)`（:4570）、`writeBufferToPixels(src)`（:4873）；
 * · `image.createImagePacker()`（:4374）+ `packToData(source, {format, quality})`；
 * · `fileIo.mkdirSync(path, recursion)`（`@ohos.file.fs.d.ts:1918`）、
 *   `accessSync`（:336）、`writeSync(fd, buffer)`（:3651）。
 */
import effectKit from '@ohos.effectKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { PreferencesUtil } from '@pura/harmony-utils';
import { RgbTriple, BG_BLUR_TIERS } from './ReaderCustomBg';

/** 一个材质的静态信息（图片在 `resources/rawfile/`，运行时枚举） */
export interface TextureItem {
  /** 稳定 id = 文件名里的三位编号（texture_001 ⇒ 1），持久化在 `ReaderBgRecord.texId` */
  id: number;
  /** rawfile 文件名 */
  file: string;
}

/** 用户导入的自定义背景（2026-09-27）：id 为沙箱文件名主干，path 为源图沙箱路径 */
export interface CustomTex {
  id: string;
  path: string;
}

export interface ComposeResult {
  /** 沙箱缓存路径；'' = 合成失败（调用方回落纯色，绝不黑屏） */
  path: string;
  /** 整图平均色（字色/nightMode/仿真翻页背面用） */
  avg: RgbTriple;
}

export class ReaderTexture {
  /** 合成图的最长边（px）。1200 源图在 1320px 宽的屏上几乎 1:1，再大只是浪费 */
  private static readonly MAX_EDGE: number = 1440;
  /** 动态清单只枚举一次的缓存（null = 还没枚举） */
  private static itemsCache: TextureItem[] | null = null;
  /** 平均色内存缓存（一张图一个会话只算一次） */
  private static avgCache: Map<number, RgbTriple> = new Map();
  /** rawfile Resource 缓存：每次 build 都 new 一个 $r 会让 Image 反复解码（真机表现为格子闪一下） */
  private static resCache: Map<string, Resource> = new Map();

  /**
   * 枚举 rawfile 里的全部纹理（texture_三位数字.jpg），按编号升序。
   * `getRawFileListSync('')` 失败（部分机型对空路径严格）时回落到**顺序探测**：
   * getRawFdSync 从 001 试到第一个断号为止（上限 300，防极端坏数据卡死）。
   */
  static items(ctx: common.UIAbilityContext): TextureItem[] {
    if (ReaderTexture.itemsCache !== null) {
      return ReaderTexture.itemsCache;
    }
    const out: TextureItem[] = [];
    try {
      const names: Array<string> = ctx.resourceManager.getRawFileListSync('');
      for (const n of names) {
        const m = /^texture_(\d{3})\.jpg$/.exec(n);
        if (m !== null) {
          out.push({ id: parseInt(m[1], 10), file: n });
        }
      }
    } catch (e) {
      // 回落：顺序探测（001 起连续编号；用户按约定命名时与枚举等价）
      for (let i = 1; i <= 300; i++) {
        const name = 'texture_' + (i < 10 ? '00' : (i < 100 ? '0' : '')) + i + '.jpg';
        try {
          ctx.resourceManager.getRawFdSync(name);
          out.push({ id: i, file: name });
        } catch (e2) {
          break;
        }
      }
    }
    out.sort((a: TextureItem, b: TextureItem) => a.id - b.id);
    ReaderTexture.itemsCache = out;
    return out;
  }

  static byId(ctx: common.UIAbilityContext, id: number): TextureItem | null {
    for (const t of ReaderTexture.items(ctx)) {
      if (t.id === id) {
        return t;
      }
    }
    return null;
  }

  /** 格子预览用的 rawfile Resource（**缓存同一实例**，避免重建导致 Image 闪烁） */
  static res(file: string): Resource {
    let r = ReaderTexture.resCache.get(file);
    if (r === undefined) {
      r = $rawfile(file);
      ReaderTexture.resCache.set(file, r);
    }
    return r;
  }

  /**
   * 64×64 快速取整图平均色（内存缓存）。
   * 用途：字色自动对比 / nightMode / 仿真翻页背面色 —— 官方要求背景图要配"相近的主题颜色"。
   */
  static async avgOf(ctx: common.UIAbilityContext, id: number): Promise<RgbTriple> {
    const hit = ReaderTexture.avgCache.get(id);
    if (hit !== undefined) {
      return hit;
    }
    let src: image.ImageSource | null = null;
    let pm: image.PixelMap | null = null;
    try {
      const tex = ReaderTexture.byId(ctx, id);
      if (tex === null) {
        return { r: 255, g: 255, b: 255 };
      }
      const rawfd = ctx.resourceManager.getRawFdSync(tex.file);
      src = image.createImageSource({ fd: rawfd.fd, offset: rawfd.offset, length: rawfd.length });
      if (src === null) {
        return { r: 255, g: 255, b: 255 };
      }
      pm = await src.createPixelMap({
        desiredSize: { width: 64, height: 64 },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      const buf = new ArrayBuffer(64 * 64 * 4);
      await pm.readPixelsToBuffer(buf);
      const px = new Uint8Array(buf);
      let r = 0;
      let g = 0;
      let b = 0;
      const n = px.length / 4;
      for (let i = 0; i < px.length; i += 4) {
        r += px[i];
        g += px[i + 1];
        b += px[i + 2];
      }
      const avg: RgbTriple = { r: Math.round(r / n), g: Math.round(g / n), b: Math.round(b / n) };
      ReaderTexture.avgCache.set(id, avg);
      return avg;
    } catch (e) {
      return { r: 255, g: 255, b: 255 };
    } finally {
      try {
        if (pm !== null) {
          await pm.release();
        }
        if (src !== null) {
          await src.release();
        }
      } catch (e) {
        // 释放失败不影响结果
      }
    }
  }

  /**
   * 确保"该材质"的合成图存在并返回 { 路径, 平均色 }（磁盘缓存命中直接回）。
   *
   * 合成步骤 = 用户定的标准：**以图片中轴线为主，上下顶满屏幕高，左右按 1:1 自适应、居中**
   * （等价于"按屏幕比例居中裁切"）→ 超长边缩到 `MAX_EDGE` → 打包 JPEG 写缓存。
   *
   * @returns path='' 表示合成失败（调用方回落纯色，绝不黑屏）
   */
  static async composedPath(ctx: common.UIAbilityContext, texId: number,
    outW: number, outH: number): Promise<ComposeResult> {
    const tex = ReaderTexture.byId(ctx, texId);
    if (tex === null || outW <= 0 || outH <= 0) {
      return { path: '', avg: { r: 255, g: 255, b: 255 } };
    }
    const dir: string = ctx.cacheDir + '/readerbg';
    const path: string = dir + '/t' + texId + '_' + outW + 'x' + outH + '.jpg';
    try {
      if (fs.accessSync(path)) {
        return { path: path, avg: await ReaderTexture.avgOf(ctx, texId) };
      }
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
      // 访问/建目录失败继续走合成，最后写文件时若仍失败则返回 ''
    }

    let src: image.ImageSource | null = null;
    let pm: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      const rawfd = ctx.resourceManager.getRawFdSync(tex.file);
      src = image.createImageSource({ fd: rawfd.fd, offset: rawfd.offset, length: rawfd.length });
      if (src === null) {
        return { path: '', avg: { r: 255, g: 255, b: 255 } };
      }
      pm = await src.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
      const info = await pm.getImageInfo();
      const w = info.size.width;
      const h = info.size.height;
      // ── 居中裁切到屏幕比例（上下顶高、左右按比例居中）────────────────────
      const srcAspect = w / h;
      const dstAspect = outW / outH;
      let cropW = w;
      let cropH = h;
      if (srcAspect > dstAspect) {
        cropW = Math.round(h * dstAspect);
      } else {
        cropH = Math.round(w / dstAspect);
      }
      if (cropW !== w || cropH !== h) {
        await pm.crop({
          x: Math.round((w - cropW) / 2),
          y: Math.round((h - cropH) / 2),
          size: { width: cropW, height: cropH }
        });
      }
      // ── 限边长（避免把大图原样塞给引擎）──────────────────────────────────
      if (cropW > ReaderTexture.MAX_EDGE || cropH > ReaderTexture.MAX_EDGE) {
        const k = ReaderTexture.MAX_EDGE / Math.max(cropW, cropH);
        await pm.scale(k, k);
      }
      // ── 打包 JPEG 写入缓存 ────────────────────────────────────────────────
      packer = image.createImagePacker();
      const data = await packer.packToData(pm, { format: 'image/jpeg', quality: 90 });
      const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, data);
      } finally {
        fs.closeSync(f);
      }
      return { path: path, avg: await ReaderTexture.avgOf(ctx, texId) };
    } catch (e) {
      // 合成失败：宁可回落纯色也不能让阅读页黑屏/挂死
      return { path: '', avg: await ReaderTexture.avgOf(ctx, texId) };
    } finally {
      try {
        if (pm !== null) {
          await pm.release();
        }
        if (packer !== null) {
          await packer.release();
        }
        if (src !== null) {
          await src.release();
        }
      } catch (e) {
        // 释放失败不影响结果
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 背景模糊分档预生成（2026-09-26 新增，用户拍板「五个档，每档 20%」）。
  //
  // ── 为什么模糊"洗进图里" ──────────────────────────────────────────────────
  // 背景图由 ReaderKit 引擎内部渲染（按需经 resourceRequest 来要字节），ArkUI 插不进
  // "引擎的背景与文字之间"；真机实测引擎画布不透底（透明主题色 = 黑屏，见
  // `ReaderPage3.ets` bgBlurOn 注释）⇒ 在**给图之前**先把图模糊好，引擎照旧铺图排字。
  //
  // ── SDK 取证 ──────────────────────────────────────────────────────────────
  // · `effectKit.createEffect(source: image.PixelMap): Filter`
  //   （`@ohos.effectKit.d.ts:404`）；
  // · `Filter.blur(radius: number): Filter`（同文件 :79，@since 9）——
  //   官方原文：常用场景即 "background blurring … frosted glass background effect"，
  //   且明示 "provides the blur effect for **static images**"（正是本用法）；
  // · `Filter.getEffectPixelMap(): Promise<image.PixelMap>`（:196，默认 CPU 渲染）；
  // · `image.createImageSource(fd: number)`（`@ohos.multimedia.image.d.ts:4220`）。
  //
  // ── 效率 ──────────────────────────────────────────────────────────────────
  // 强度只有 `BG_BLUR_TIERS` 5 档：每档一张磁盘缓存 JPEG（文件名含档位半径），
  // **生成一次永久命中**；拖动/切档 = 换一个已缓存文件路径 + 一次引擎重排。
  // 源图（合成图）PixelMap 做**单槽内存缓存**：5 档生成共只解码一次（约几 MB）。
  // ══════════════════════════════════════════════════════════════════════════

  /** 模糊源图内存缓存（单槽：key=合成图路径；换图时释放旧图，常驻至多一张） */
  private static blurSrcCacheKey: string = '';
  private static blurSrcCachePm: image.PixelMap | null = null;

  /** 某材质某档位的模糊图缓存路径：`readerbg/blur/t7_1320x2848_r24.jpg` */
  private static blurredCachePath(ctx: common.UIAbilityContext, srcPath: string,
    radius: number): string {
    const base: string = srcPath.substring(srcPath.lastIndexOf('/') + 1);
    return ctx.cacheDir + '/readerbg/blur/' + base.replace('.jpg', '_r' + radius + '.jpg');
  }

  /** 取（或生成）一张"合成图按 radius 高斯模糊"后的缓存图路径；'' = 失败（调用方回落原图） */
  static async blurredPath(ctx: common.UIAbilityContext,
    srcPath: string, radius: number): Promise<string> {
    let srcExists: boolean = false;
    try {
      srcExists = srcPath.length > 0 && fs.accessSync(srcPath);
    } catch (e) {
      srcExists = false;
    }
    if (!srcExists) {
      return '';
    }
    const out: string = ReaderTexture.blurredCachePath(ctx, srcPath, radius);
    try {
      if (fs.accessSync(out)) {
        return out;
      }
      const dir: string = ctx.cacheDir + '/readerbg/blur';
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
      // 访问/建目录失败继续走生成，写文件失败时返回 ''
    }

    let pm: image.PixelMap | null = null;
    let packed: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    let file: fs.File | null = null;
    try {
      // ── 源图：内存单槽缓存命中，未命中才解码（5 档共一次解码）──────────────
      if (ReaderTexture.blurSrcCacheKey === srcPath && ReaderTexture.blurSrcCachePm !== null) {
        pm = ReaderTexture.blurSrcCachePm;
      } else {
        const f = fs.openSync(srcPath, fs.OpenMode.READ_ONLY);
        let src: image.ImageSource | null = null;
        try {
          src = image.createImageSource(f.fd);
          if (src === null) {
            return '';
          }
          const decoded = await src.createPixelMap({
            desiredPixelFormat: image.PixelMapFormat.RGBA_8888
          });
          if (ReaderTexture.blurSrcCachePm !== null) {
            try {
              await ReaderTexture.blurSrcCachePm.release();
            } catch (e2) {
              // 旧图释放失败不影响新图
            }
          }
          ReaderTexture.blurSrcCacheKey = srcPath;
          ReaderTexture.blurSrcCachePm = decoded;
          pm = decoded;
        } finally {
          try {
            if (src !== null) {
              await src.release();
            }
          } catch (e2) {
            // 释放失败不影响结果
          }
          fs.closeSync(f);
        }
      }
      // ── 高斯模糊（effectKit 链式 Filter）→ 打包 JPEG 落盘 ────────────────────
      const filter: effectKit.Filter = effectKit.createEffect(pm).blur(radius);
      packed = await filter.getEffectPixelMap();
      packer = image.createImagePacker();
      const data = await packer.packToData(packed, { format: 'image/jpeg', quality: 90 });
      file = fs.openSync(out, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, data);
      return out;
    } catch (e) {
      // 模糊失败：宁可回落原图也不能让阅读页黑屏/挂死
      return '';
    } finally {
      try {
        if (file !== null) {
          fs.closeSync(file);
        }
        if (packer !== null) {
          await packer.release();
        }
        // pm 可能是缓存的源图（不能释放）；packed 是模糊结果（用完即释）
        if (packed !== null) {
          await packed.release();
        }
      } catch (e) {
        // 释放失败不影响结果
      }
    }
  }

  /**
   * 后台**预生成**全部 5 档的模糊缓存（含当前档 —— 磁盘命中零成本）。
   * 预生成完，用户拖动条无论停在哪档都是**磁盘命中零等待**。
   * 逐档串行（一次只有一张图在模糊/编码），失败静默 —— 预生成只是提前量，
   * 用户真拖到那档时 `blurredPath` 会再兜底生成。
   */
  static preGenerateTiers(ctx: common.UIAbilityContext, srcPath: string): void {
    ReaderTexture.preGenerateLoop(ctx, srcPath);
  }

  private static async preGenerateLoop(ctx: common.UIAbilityContext,
    srcPath: string): Promise<void> {
    for (let i = 0; i < BG_BLUR_TIERS.length; i++) {
      const radius: number = BG_BLUR_TIERS[i];
      try {
        await ReaderTexture.blurredPath(ctx, srcPath, radius);
      } catch (e) {
        // 单档失败不阻断后续档（真拖到时还会再生成）
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 自定义背景（2026-09-27 新增，用户设计）：用户从图库导入的图片当材质用。
  // 与内置材质**同一套计算**：居中裁切→限边→JPEG 缓存→均色配色→（背景模糊），
  // 唯一差别 = 图片来源是**沙箱文件**（图库 PhotoViewPicker 拷入）而非 rawfile。
  // 注册表：Preferences JSON `[{id, path}]`；源图文件存 `filesDir/readerbg/custom/`。
  // ══════════════════════════════════════════════════════════════════════════

  /** 自定义背景登记表键（Preferences JSON `[{id, path}]`） */
  static readonly KEY_CUSTOM_LIST: string = 'ReaderCustomTexList';
  /** 单次导入上限（用户拍板 15 张）；登记总量保险丝 */
  static readonly MAX_CUSTOM_ONCE: number = 15;
  static readonly MAX_CUSTOM_TOTAL: number = 60;
  /** 源图均色内存缓存（key=源路径） */
  private static customAvgCache: Map<string, RgbTriple> = new Map();

  static customDir(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/readerbg/custom';
  }

  static customItems(ctx: common.UIAbilityContext): CustomTex[] {
    let raw: string = '';
    try {
      raw = PreferencesUtil.getSync(ReaderTexture.KEY_CUSTOM_LIST, '') as string;
    } catch (e) {
      return [];
    }
    if (typeof raw !== 'string' || raw.length === 0) {
      return [];
    }
    try {
      const arr = JSON.parse(raw) as CustomTex[];
      if (!Array.isArray(arr)) {
        return [];
      }
      const out: CustomTex[] = [];
      for (const t of arr) {
        if (t !== null && t !== undefined && typeof t.id === 'string' && typeof t.path === 'string'
          && t.id.length > 0 && t.path.length > 0) {
          out.push({ id: t.id, path: t.path });
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  static customById(ctx: common.UIAbilityContext, id: string): CustomTex | null {
    for (const t of ReaderTexture.customItems(ctx)) {
      if (t.id === id) {
        return t;
      }
    }
    return null;
  }

  /**
   * 从图库 uri 导入一张自定义背景：按魔数识别格式（JPEG/PNG）拷入 custom 目录并登记。
   * 失败返回 null（调用方计数）。
   */
  static addCustomTex(ctx: common.UIAbilityContext, uri: string): Promise<CustomTex | null> {
    return new Promise<CustomTex | null>((resolve: (v: CustomTex | null) => void) => {
      let src: fs.File | null = null;
      let dst: fs.File | null = null;
      try {
        src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
        const st = fs.statSync(src.fd);
        if (st.size <= 0 || st.size > 32 * 1024 * 1024) {
          resolve(null);
          return;
        }
        const buf = new ArrayBuffer(st.size);
        fs.readSync(src.fd, buf);
        // 魔数识别格式（图库 uri 不带可靠扩展名）：JPEG=FF D8 FF，PNG=89 50 4E 47
        const b = new Uint8Array(buf, 0, 4);
        let ext: string = '';
        if (b[0] === 0xFF && b[1] === 0xD8 && b[2] === 0xFF) {
          ext = '.jpg';
        } else if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4E && b[3] === 0x47) {
          ext = '.png';
        } else {
          resolve(null);
          return;
        }
        const list: CustomTex[] = ReaderTexture.customItems(ctx);
        if (list.length >= ReaderTexture.MAX_CUSTOM_TOTAL) {
          resolve(null);
          return;
        }
        const dir: string = ReaderTexture.customDir(ctx);
        if (!fs.accessSync(dir)) {
          fs.mkdirSync(dir, true);
        }
        const id: string = 'u' + Date.now();
        const dstPath: string = dir + '/' + id + ext;
        dst = fs.openSync(dstPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(dst.fd, buf);
        const item: CustomTex = { id: id, path: dstPath };
        list.push(item);
        try {
          PreferencesUtil.putSync(ReaderTexture.KEY_CUSTOM_LIST, JSON.stringify(list));
        } catch (e) {
          // 登记失败不影响文件
        }
        resolve(item);
      } catch (e) {
        resolve(null);
      } finally {
        try {
          if (src !== null) {
            fs.closeSync(src);
          }
          if (dst !== null) {
            fs.closeSync(dst);
          }
        } catch (e) {
          // 关闭失败不影响结果
        }
      }
    });
  }

  /** 删除一张自定义背景（登记表 + 源图文件）。幂等；合成/模糊缓存按 key 自然失效 */
  static removeCustomTex(ctx: common.UIAbilityContext, id: string): void {
    const list: CustomTex[] = ReaderTexture.customItems(ctx);
    const kept: CustomTex[] = list.filter((t: CustomTex) => t.id !== id);
    if (kept.length === list.length) {
      return;
    }
    try {
      PreferencesUtil.putSync(ReaderTexture.KEY_CUSTOM_LIST, JSON.stringify(kept));
    } catch (e) {
      // 登记写失败也继续删文件
    }
    const gone: CustomTex | undefined = list.find((t: CustomTex) => t.id === id);
    if (gone === undefined) {
      return;
    }
    try {
      if (fs.accessSync(gone.path)) {
        fs.unlinkSync(gone.path);
      }
    } catch (e) {
      // 文件删不掉不影响登记表
    }
  }

  /** 自定义源图的 64×64 均色（内存缓存 key=源路径；模糊不改变均色，与材质同口径） */
  static async avgOfSrc(ctx: common.UIAbilityContext, srcPath: string): Promise<RgbTriple> {
    const hit = ReaderTexture.customAvgCache.get(srcPath);
    if (hit !== undefined) {
      return hit;
    }
    const fb: RgbTriple = { r: 255, g: 255, b: 255 };
    let src: image.ImageSource | null = null;
    let pm: image.PixelMap | null = null;
    let f: fs.File | null = null;
    try {
      f = fs.openSync(srcPath, fs.OpenMode.READ_ONLY);
      src = image.createImageSource(f.fd);
      if (src === null) {
        return fb;
      }
      pm = await src.createPixelMap({
        desiredSize: { width: 64, height: 64 },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      const buf = new ArrayBuffer(64 * 64 * 4);
      await pm.readPixelsToBuffer(buf);
      const px = new Uint8Array(buf);
      let r = 0;
      let g = 0;
      let b = 0;
      const n: number = px.length / 4;
      for (let i = 0; i < px.length; i += 4) {
        r += px[i];
        g += px[i + 1];
        b += px[i + 2];
      }
      const avg: RgbTriple = { r: Math.round(r / n), g: Math.round(g / n), b: Math.round(b / n) };
      ReaderTexture.customAvgCache.set(srcPath, avg);
      return avg;
    } catch (e) {
      return fb;
    } finally {
      try {
        if (pm !== null) {
          await pm.release();
        }
        if (src !== null) {
          await src.release();
        }
        if (f !== null) {
          fs.closeSync(f);
        }
      } catch (e) {
        // 释放失败不影响结果
      }
    }
  }

  /**
   * 自定义背景合成（与 `composedPath` 同算法，图片来源=沙箱路径）：
   * 居中裁切到屏幕比例 → 限长边 → 打包 JPEG 写缓存 → { 路径, 均色 }。
   * `cacheKey` = 'c<id>'；缓存命中直接回。path='' = 失败（调用方回落纯色）。
   */
  static async composedPathSrc(ctx: common.UIAbilityContext, srcPath: string,
    cacheKey: string, outW: number, outH: number): Promise<ComposeResult> {
    const fb: ComposeResult = { path: '', avg: { r: 255, g: 255, b: 255 } };
    if (srcPath.length === 0 || outW <= 0 || outH <= 0) {
      return fb;
    }
    const dir: string = ctx.cacheDir + '/readerbg/custom';
    const path: string = dir + '/' + cacheKey + '_' + outW + 'x' + outH + '.jpg';
    try {
      if (fs.accessSync(path)) {
        return { path: path, avg: await ReaderTexture.avgOfSrc(ctx, srcPath) };
      }
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
      // 访问/建目录失败继续走合成
    }
    let src: image.ImageSource | null = null;
    let pm: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    let file: fs.File | null = null;
    let srcFile: fs.File | null = null;
    try {
      srcFile = fs.openSync(srcPath, fs.OpenMode.READ_ONLY);
      src = image.createImageSource(srcFile.fd);
      if (src === null) {
        return fb;
      }
      pm = await src.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
      const info = await pm.getImageInfo();
      const w = info.size.width;
      const h = info.size.height;
      const srcAspect = w / h;
      const dstAspect = outW / outH;
      let cropW = w;
      let cropH = h;
      if (srcAspect > dstAspect) {
        cropW = Math.round(h * dstAspect);
      } else {
        cropH = Math.round(w / dstAspect);
      }
      if (cropW !== w || cropH !== h) {
        await pm.crop({
          x: Math.round((w - cropW) / 2),
          y: Math.round((h - cropH) / 2),
          size: { width: cropW, height: cropH }
        });
      }
      if (cropW > ReaderTexture.MAX_EDGE || cropH > ReaderTexture.MAX_EDGE) {
        const k = ReaderTexture.MAX_EDGE / Math.max(cropW, cropH);
        await pm.scale(k, k);
      }
      packer = image.createImagePacker();
      const data = await packer.packToData(pm, { format: 'image/jpeg', quality: 90 });
      file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, data);
      return { path: path, avg: await ReaderTexture.avgOfSrc(ctx, srcPath) };
    } catch (e) {
      return fb; // 合成失败回落纯色，绝不黑屏
    } finally {
      try {
        if (file !== null) {
          fs.closeSync(file);
        }
        if (packer !== null) {
          await packer.release();
        }
        if (pm !== null) {
          await pm.release();
        }
        if (src !== null) {
          await src.release();
        }
        if (srcFile !== null) {
          fs.closeSync(srcFile);
        }
      } catch (e) {
        // 释放失败不影响结果
      }
    }
  }
}
