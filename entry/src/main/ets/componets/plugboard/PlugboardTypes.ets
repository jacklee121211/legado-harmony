/**
 * 个性化插件屏 —— 类型定义（2026-10-10 新增）
 */

export enum PlugType {
  IMAGE = 'image',
  GIF = 'gif',
  JSON = 'json',
}

export type BoxRatio = '1:1' | '2:1' | '16:1'

/** JSON模板中的单个节点。支持逐帧动画（keyframes[] + msPerFrame） */
export interface PlugNode {
  type: 'Text' | 'Image' | 'Row' | 'Column'
  text?: string
  src?: string
  children?: PlugNode[]
  color?: string
  fontSize?: number
  fontWeight?: number
  width?: number
  height?: number
  gap?: number
  justifyContent?: 'start' | 'center' | 'end' | 'spaceBetween'
  alignItems?: 'start' | 'center' | 'end'
  /**
   * 多帧动画（2026-10-10 新增）：
   * 如果存在，节点被解释为"逐帧源"，每一帧替换本节点的 text/children 渲染
   * 帧索引循环：0→len-1→0
   */
  keyframes?: string[]
  /** 逐帧的帧间时长（ms，默认 200） */
  msPerFrame?: number
}

export interface PlugCrop {
  croppedPath?: string
  offsetX?: number
  offsetY?: number
  scale?: number
  rotation?: number
}

export const PlugCropDefault: PlugCrop = {
  croppedPath: '',
  offsetX: 0,
  offsetY: 0,
  scale: 1,
  rotation: 0,
}

/**
 * 位置偏移（2026-10-10 新增，用于标定模式下用户拖动 1/2 区）
 */
export interface PositionOffset {
  x: number
  y: number
}

export const PositionOffsetDefault: PositionOffset = { x: 0, y: 0 }

/**
 * 单个区域的插件配置
 */
export interface PlugboardConfig {
  type: PlugType
  source: string
  fit: 'fit' | 'fill' | 'cover'
  opacity: number
  boxRatio: BoxRatio
  crop: PlugCrop
  /** 区域位置偏移（标定模式下可拖动，持久化到这里） */
  positionOffset: PositionOffset
}

export const PlugboardConfigDefault: PlugboardConfig = {
  type: PlugType.IMAGE,
  source: '',
  fit: 'fit',
  opacity: 1,
  boxRatio: '1:1',
  crop: {
    croppedPath: '',
    offsetX: 0,
    offsetY: 0,
    scale: 1,
    rotation: 0,
  },
  positionOffset: { x: 0, y: 0 },
}

export enum PlugZone {
  SHELF_TOP = 'shelf_top',
  MY_BLOCK = 'my_block',
}

export const ZONE_RATIO: Record<PlugZone, BoxRatio> = {
  [PlugZone.SHELF_TOP]: '16:1',
  [PlugZone.MY_BLOCK]: '1:1',
}

export function ratioToHeightRatio(r: BoxRatio): number {
  if (r === '1:1') {
    return 1
  }
  if (r === '2:1') {
    return 0.5
  }
  return 1 / 16
}

// ── 像素鲸鱼 4 帧（2026-10-10）────────────────────────────────────────
// 12×8 网格，灰阶：'0'=透明, '1'=浅灰 #e0e0e0, '2'=中灰 #888, '3'=深色 #333
// 帧0: 尾巴平; 帧1: 尾巴下摆; 帧2: 尾巴上摆; 帧3: 尾巴平（带前位移）
const WHALE_FRAMES: string[] = [
  // 帧0
  '001100000000' +
  '012210000110' +
  '012221012211' +
  '011221122221' +
  '001121222211' +
  '000112222211' +
  '000001111100' +
  '000000011000',
  // 帧1（尾下摆）
  '001100000000' +
  '012210000110' +
  '012221012211' +
  '011221122221' +
  '001121222211' +
  '000112222211' +
  '000001111100' +
  '000000011001',
  // 帧2（尾上摆）
  '001100000000' +
  '012210000110' +
  '012221012211' +
  '011221122221' +
  '001121222211' +
  '000112222211' +
  '000001111100' +
  '000000001010',
  // 帧3（尾平，略微前移）
  '011000000000' +
  '122100001100' +
  '222210122110' +
  '112211222210' +
  '011212222110' +
  '001122222110' +
  '000011111000' +
  '000000110000',
]

function frameToNodes(frame: string): PlugNode[] {
  const COLS = 12
  const palette: Record<string, string> = {
    '0': 'transparent',
    '1': '#e0e0e0',
    '2': '#888',
    '3': '#333',
    '4': '#000',
  }
  const rows: PlugNode[] = []
  for (let r = 0; r < 8; r++) {
    const rowChildren: PlugNode[] = []
    for (let c = 0; c < COLS; c++) {
      const ch = frame[r * COLS + c] ?? '0'
      rowChildren.push({
        type: 'Text',
        text: '█',
        color: palette[ch] ?? 'transparent',
        fontSize: 5,
        fontWeight: 400,
      })
    }
    rows.push({
      type: 'Row',
      gap: 0,
      children: rowChildren,
    })
  }
  return rows
}

const whaleNodes: PlugNode = {
  type: 'Column',
  gap: 0,
  children: frameToNodes(WHALE_FRAMES[0]),
  keyframes: WHALE_FRAMES.map(f => JSON.stringify(frameToNodes(f))),
  msPerFrame: 240,
}

/** 像素鲸鱼预置模板（JSON DSL） */
export const WHALE_PRESET_SOURCE: string = JSON.stringify([whaleNodes])