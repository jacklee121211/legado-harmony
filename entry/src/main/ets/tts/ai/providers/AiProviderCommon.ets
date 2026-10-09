/**
 * AI TTS 服务商共享工具（自研）。
 *
 * 这里只放**跨厂商复用**的纯函数：鉴权头、URL 兜底、参数换算、请求 ID。
 * 厂商特有的协议（URL / 请求体 / 响应解析）一律留在各自的 provider 文件里，
 * 便于单家改动不影响其他家（审查要点：改 A 不碰 B）。
 */
import { util } from '@kit.ArkTS';
import { AiProviderMeta, AiTtsConfig } from '../AiTtsTypes';

/** Bearer 鉴权（DashScope / MiniMax 用） */
export function bearerHeaders(cfg: AiTtsConfig): Record<string, string> {
  const h: Record<string, string> = {};
  h['Content-Type'] = 'application/json';
  const k: string = cfg.apiKey.trim();
  if (k.length > 0) {
    h['Authorization'] = 'Bearer ' + k;
  }
  return h;
}

/** 自定义鉴权头（小米 MiMo 用 `api-key`） */
export function apiKeyHeader(cfg: AiTtsConfig, headerName: string): Record<string, string> {
  const h: Record<string, string> = {};
  h['Content-Type'] = 'application/json';
  const k: string = cfg.apiKey.trim();
  if (k.length > 0) {
    h[headerName] = k;
  }
  return h;
}

/** 用户填的 baseUrl 优先，否则回落厂商默认地址 */
export function baseUrlOf(cfg: AiTtsConfig, meta: AiProviderMeta): string {
  const b: string = cfg.baseUrl.trim();
  return b.length > 0 ? b : meta.defaultBaseUrl;
}

export function clampNum(v: number, lo: number, hi: number): number {
  if (!Number.isFinite(v)) {
    return lo;
  }
  return Math.max(lo, Math.min(hi, v));
}

/**
 * `.../v1` 风格地址拼接（MiniMax / 小米这类以 `/v1` 为根的厂商）。
 * 容错：用户只填 `https://api.minimaxi.com` 时自动补 `/v1`
 *（真机反馈里"地址少写一段"是最常见的输入错误之一）。
 */
export function v1Join(base: string, tail: string): string {
  let b: string = base.trim();
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  if (!/\/v\d+$/.test(b)) {
    b = b + '/v1';
  }
  return b + (tail.startsWith('/') ? tail : '/' + tail);
}

/** 请求 ID（火山要求 `X-Api-Request-Id`） */
export function uuidLike(): string {
  try {
    return util.generateRandomUUID(false);
  } catch (e) {
    return 'ai' + Date.now() + '-' + Math.floor(Math.random() * 1e9);
  }
}
