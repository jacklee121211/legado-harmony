import { PreferencesUtil } from '@pura/harmony-utils'

/**
 * 全局开发者/标定模式开关（2026-10-10 新增）
 *
 * 复用阅读器标定模式的持久化键 `TtsHlCalibV3`（其中 `dev` 字段），
 * 并通过 AppStorage 的 `devMode` 键**全局广播**给所有页签订阅。
 *
 * 谁会订阅 devMode？
 *   · `ReaderPage3.ets` 已经在原开关打开时画标尺（沿用旧逻辑）
 *   · `IndexShelf.ets`（书架）1区叠加：经纬线 + 区域边框
 *   · `MyCenter.ets`（我的）2区叠加：经纬线 + 区域边框
 *   · `PlugboardZone.ets` 叠加：标定模式下红边 + 半透明红底
 *
 * 入口（用户的标定模式开关）：
 *   我的 → 设置 → 听书引擎（进阶）→ 打开标定模式
 *   （设置页调用 `CalibMode.setOn(true)` / `setOn(false)`）
 */
export class CalibMode {
  /** 持久化键（与 ReaderPage3 的 HL_CALIB_KEY 一致） */
  static readonly PREF_KEY: string = 'TtsHlCalibV3'
  /** AppStorage 全局广播键 */
  static readonly STORAGE_KEY: string = 'devMode'

  /** 读取 dev 字段（不改 AppStorage，仅返回当前值） */
  static read(): boolean {
    try {
      const raw = PreferencesUtil.getSync(CalibMode.PREF_KEY, '') as string
      if (typeof raw !== 'string' || raw.length === 0) {
        return false
      }
      const o = JSON.parse(raw) as Record<string, Object>
      const d = o['dev']
      return typeof d === 'number' && (d as number) > 0
    } catch (_e) {
      return false
    }
  }

  /**
   * 写入 dev 字段，并同步广播到 AppStorage。
   * 必须在主线程调用（PreferencesUtil 是同步 API，AppStorage.setOrCreate 也同步）。
   */
  static setOn(v: boolean): void {
    try {
      let o: Record<string, Object> = {}
      const raw = PreferencesUtil.getSync(CalibMode.PREF_KEY, '') as string
      if (typeof raw === 'string' && raw.length > 0) {
        const p = JSON.parse(raw) as Record<string, Object>
        if (p !== null && p !== undefined) {
          o = p
        }
      }
      o['dev'] = v ? 1 : 0
      PreferencesUtil.putSync(CalibMode.PREF_KEY, JSON.stringify(o))
    } catch (_e) {
      // 落盘失败不阻断 UI
    }
    // 同步广播
    AppStorage.setOrCreate(CalibMode.STORAGE_KEY, v)
  }

  /** 应用启动时调用：从 Preferences 读 → 回填到 AppStorage */
  static bootstrap(): void {
    AppStorage.setOrCreate(CalibMode.STORAGE_KEY, CalibMode.read())
  }
}