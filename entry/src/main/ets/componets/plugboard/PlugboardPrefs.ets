import { PreferencesUtil } from '@pura/harmony-utils'
import { PlugboardConfig, PlugboardConfigDefault, PlugZone, PlugType, PlugNode, BoxRatio, WHALE_PRESET_SOURCE } from './PlugboardTypes'

export class PlugboardPrefs {
  private static PREFIX = 'plugboard_'

  static get(zone: PlugZone): PlugboardConfig {
    const key = PlugboardPrefs.PREFIX + zone
    const raw: string = PreferencesUtil.getSync(key, '') as string
    if (!raw) {
      return {
        type: PlugboardConfigDefault.type,
        source: PlugboardConfigDefault.source,
        fit: PlugboardConfigDefault.fit,
        opacity: PlugboardConfigDefault.opacity,
        boxRatio: PlugboardConfigDefault.boxRatio,
        crop: {
          croppedPath: PlugboardConfigDefault.crop.croppedPath ?? '',
          offsetX: PlugboardConfigDefault.crop.offsetX ?? 0,
          offsetY: PlugboardConfigDefault.crop.offsetY ?? 0,
          scale: PlugboardConfigDefault.crop.scale ?? 1,
          rotation: PlugboardConfigDefault.crop.rotation ?? 0,
        },
        positionOffset: { x: 0, y: 0 },
      }
    }
    try {
      const o = JSON.parse(raw) as Record<string, Object>
      const dc = o['crop'] as Record<string, Object> | undefined
      const po = o['positionOffset'] as Record<string, Object> | undefined
      return {
        type: (o['type'] as PlugType) ?? PlugboardConfigDefault.type,
        source: (o['source'] as string) ?? PlugboardConfigDefault.source,
        fit: ((o['fit'] as string) ?? PlugboardConfigDefault.fit) as 'fit' | 'fill' | 'cover',
        opacity: (o['opacity'] as number) ?? PlugboardConfigDefault.opacity,
        boxRatio: ((o['boxRatio'] as string) ?? PlugboardConfigDefault.boxRatio) as BoxRatio,
        crop: {
          croppedPath: (dc?.['croppedPath'] as string) ?? '',
          offsetX: (dc?.['offsetX'] as number) ?? 0,
          offsetY: (dc?.['offsetY'] as number) ?? 0,
          scale: (dc?.['scale'] as number) ?? 1,
          rotation: (dc?.['rotation'] as number) ?? 0,
        },
        positionOffset: {
          x: (po?.['x'] as number) ?? 0,
          y: (po?.['y'] as number) ?? 0,
        },
      }
    } catch (_e) {
      return {
        type: PlugboardConfigDefault.type,
        source: PlugboardConfigDefault.source,
        fit: PlugboardConfigDefault.fit,
        opacity: PlugboardConfigDefault.opacity,
        boxRatio: PlugboardConfigDefault.boxRatio,
        crop: {
          croppedPath: '',
          offsetX: 0,
          offsetY: 0,
          scale: 1,
          rotation: 0,
        },
        positionOffset: { x: 0, y: 0 },
      }
    }
  }

  static set(zone: PlugZone, cfg: PlugboardConfig): void {
    const key = PlugboardPrefs.PREFIX + zone
    PreferencesUtil.putSync(key, JSON.stringify(cfg))
  }

  static reset(zone: PlugZone): void {
    const key = PlugboardPrefs.PREFIX + zone
    PreferencesUtil.putSync(key, JSON.stringify(PlugboardConfigDefault))
  }

  static hasContent(zone: PlugZone): boolean {
    const cfg = PlugboardPrefs.get(zone)
    return cfg.source.length > 0
  }

  static getWithZone(zone: PlugZone): PlugboardConfig {
    const cfg = PlugboardPrefs.get(zone)
    if (zone === PlugZone.SHELF_TOP) {
      cfg.boxRatio = '16:1'
    }
    return cfg
  }

  static setRatio(zone: PlugZone, r: BoxRatio): void {
    const cfg = PlugboardPrefs.getWithZone(zone)
    cfg.boxRatio = r
    PlugboardPrefs.set(zone, cfg)
  }
}

export interface PlugPreset {
  label: string
  thumb: string
  config: PlugboardConfig
}

function pl(cfg: Partial<PlugboardConfig>): PlugboardConfig {
  return {
    type: cfg.type ?? PlugboardConfigDefault.type,
    source: cfg.source ?? PlugboardConfigDefault.source,
    fit: cfg.fit ?? PlugboardConfigDefault.fit,
    opacity: cfg.opacity ?? PlugboardConfigDefault.opacity,
    boxRatio: cfg.boxRatio ?? PlugboardConfigDefault.boxRatio,
    crop: cfg.crop ?? PlugboardConfigDefault.crop,
    positionOffset: cfg.positionOffset ?? PlugboardConfigDefault.positionOffset,
  }
}

export const PlugPresets: PlugPreset[] = [
  {
    label: '🐋 像素鲸鱼',
    thumb: '',
    config: pl({
      type: PlugType.JSON,
      source: WHALE_PRESET_SOURCE,
      opacity: 1,
    }),
  },
  {
    label: '✧ 星光点点',
    thumb: '',
    config: pl({
      type: PlugType.JSON,
      source: JSON.stringify([
        { type: 'Row', gap: 4, justifyContent: 'center', alignItems: 'center', children: [
          { type: 'Text', text: '✦', color: '#FFD700', fontSize: 14 },
          { type: 'Text', text: '✧', color: '#FFA500', fontSize: 14 },
          { type: 'Text', text: '✦', color: '#FFD700', fontSize: 14 },
        ]}
      ] as PlugNode[]),
      opacity: 0.8,
    }),
  },
  {
    label: '📖 阅读时光',
    thumb: '',
    config: pl({
      type: PlugType.JSON,
      source: JSON.stringify([
        { type: 'Row', gap: 6, justifyContent: 'center', alignItems: 'center', children: [
          { type: 'Text', text: '📖', fontSize: 16 },
          { type: 'Text', text: '阅读', color: '#666', fontSize: 12, fontWeight: 500 },
          { type: 'Text', text: '📖', fontSize: 16 },
        ]}
      ] as PlugNode[]),
      opacity: 0.7,
    }),
  },
  {
    label: '💬 欢迎语',
    thumb: '',
    config: pl({
      type: PlugType.JSON,
      source: JSON.stringify([
        { type: 'Column', gap: 2, justifyContent: 'center', alignItems: 'center', children: [
          { type: 'Text', text: '欢迎回来', color: '#333', fontSize: 13, fontWeight: 600 },
          { type: 'Text', text: '今天读点什么？', color: '#999', fontSize: 10 },
        ]}
      ] as PlugNode[]),
      opacity: 0.85,
    }),
  },
]