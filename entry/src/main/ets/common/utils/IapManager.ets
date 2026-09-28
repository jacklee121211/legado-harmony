import { iap } from '@kit.IAPKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { VipManager } from './VipManager';

/**
 * IAP 接入层（2026-09-28 阶段2）。
 *
 * ── 契约（官方文档 + SDK 声明取证）──────────────────────────────────────
 * · 商品：`miaoyue_vip_permanent`（AGC 非消耗型商品，9.9 元永久）。
 *   —— `@hms.core.iap.d.ts`：ProductType.NONCONSUMABLE / PurchaseQueryType.CURRENT_ENTITLEMENT
 * · VIP 事实源 = `queryPurchases(CURRENT_ENTITLEMENT)`（已购非消耗型商品清单，
 *   按设备上的华为账号记账），本地 Preferences 仅缓存（VipManager）。
 * · 购买 = `createPurchase` 拉收银台；返回 PRODUCT_OWNED（1001860051）表示已拥有。
 * · 发货确认 = `finishPurchase`（非消耗型在 finishStatus ≠ 1 时补确认；
 *   官方《确保权益发放》：应用启动/PRODUCT_OWNED/SYSTEM_ERROR 时检查已购未发货）。
 *
 * ── 沙盒测试 ────────────────────────────────────────────────────────────
 * debug 签名包 + 沙盒测试账号（AGC→运营→沙盒测试）即可走通购买，不产生真实订单
 * （官方《沙盒测试》：商品草稿/待提交状态下即可调测）。
 */

/** PurchaseData（JSON 字符串）——只取用到的字段（SDK：CreatePurchaseResult.purchaseData） */
interface PurchaseDataLite {
  jwsPurchaseOrder?: string;
}

/** PurchaseOrderPayload（JWS payload 解码后）——只取用到的字段 */
interface OrderPayloadLite {
  productId?: string;
  purchaseToken?: string;
  purchaseOrderId?: string;
  /** 0 = 未确认发货，1 = 已发货（官方 FinishStatus.FINISHED = 1） */
  finishStatus?: number;
}

export class IapManager {
  /**
   * 刷新 VIP 状态：查华为服务器已购记录。
   * ⚠️ **只升不降**（2026-09-28）：查询到已购才置 true，查不到**绝不**清除本地位——
   * 沙盒环境 queryPurchases 查不到已发货订单（官方 faqs-iap-5），网络/账号态偶发
   * 异常同理，都不能把已有 VIP 冲掉（否则购买后杀进程重开就掉会员）。
   */
  static async refreshVip(context: common.UIAbilityContext): Promise<void> {
    try {
      const param: iap.QueryPurchasesParameter = {
        productType: iap.ProductType.NONCONSUMABLE,
        queryType: iap.PurchaseQueryType.CURRENT_ENTITLEMENT
      };
      const res: iap.QueryPurchaseResult = await iap.queryPurchases(context, param);
      if (IapManager.listHasProduct(res.purchaseDataList)) {
        VipManager.setVip(true);
      }
    } catch (e) {
      // 查询失败（未登录华为账号/网络异常）保持本地缓存位不变。
    }
  }

  /** 立即开通：拉起 IAP 收银台。返回给 UI 的提示文案；'' = 用户取消，不提示 */
  static async buy(context: common.UIAbilityContext): Promise<string> {
    try {
      const param: iap.PurchaseParameter = {
        productId: VipManager.PRODUCT_ID,
        productType: iap.ProductType.NONCONSUMABLE
      };
      const result: iap.CreatePurchaseResult = await iap.createPurchase(context, param);
      await IapManager.finishIfPending(context, result.purchaseData);
      VipManager.setVip(true);
      return '开通成功！全部会员特权已解锁';
    } catch (err) {
      const be = err as BusinessError;
      if (be.code === 1001860000) {
        // 用户取消收银台 —— 静默
        return '';
      }
      if (be.code === iap.IAPErrorCode.PRODUCT_OWNED) {
        // 已拥有（可能存在已购未确认发货）→ 补发货检查后视为会员
        await IapManager.restorePending(context);
        VipManager.setVip(true);
        return '你已是永久会员';
      }
      if (be.code === iap.IAPErrorCode.APP_NOT_AUTHORIZED) {
        // 1001860002（官方 faqs-iap-11）：IAP 服务开关未开，或当前打包证书的
        // 公钥指纹未配置到 AGC。给用户（开发者自己）可操作的提示。
        return '应用未授权支付：请检查 AGC 的 IAP 服务开关，以及当前签名证书的公钥指纹是否已配置';
      }
      return '开通失败：' + (be.message ?? `错误码 ${be.code}`);
    }
  }

  /** purchaseData 列表里是否包含本商品（逐条解 JWS payload 比对商品 ID） */
  private static listHasProduct(list: string[]): boolean {
    for (const data of list) {
      try {
        const pd = JSON.parse(data) as PurchaseDataLite;
        if (pd.jwsPurchaseOrder && IapManager.decodePayload(pd.jwsPurchaseOrder).indexOf(VipManager.PRODUCT_ID) >= 0) {
          return true;
        }
      } catch (e) {
        // 单条解析失败不影响其余条目
      }
    }
    return false;
  }

  /** 购买成功后补发货确认：finishStatus ≠ 1 时调 finishPurchase（官方《确保权益发放》） */
  private static async finishIfPending(context: common.UIAbilityContext, purchaseData: string): Promise<void> {
    try {
      const pd = JSON.parse(purchaseData) as PurchaseDataLite;
      if (!pd.jwsPurchaseOrder) {
        return;
      }
      const payload = IapManager.parsePayload(pd.jwsPurchaseOrder);
      if (payload !== null && payload.finishStatus !== 1 && payload.purchaseToken && payload.purchaseOrderId) {
        const fp: iap.FinishPurchaseParameter = {
          productType: iap.ProductType.NONCONSUMABLE,
          purchaseToken: payload.purchaseToken,
          purchaseOrderId: payload.purchaseOrderId
        };
        await iap.finishPurchase(context, fp);
      }
    } catch (e) {
      // 补发货失败不阻塞开通（下次启动 refreshVip / PRODUCT_OWNED 路径兜底）
    }
  }

  /** PRODUCT_OWNED 路径：查已购未发货并补 finishPurchase */
  private static async restorePending(context: common.UIAbilityContext): Promise<void> {
    try {
      const param: iap.QueryPurchasesParameter = {
        productType: iap.ProductType.NONCONSUMABLE,
        queryType: iap.PurchaseQueryType.UNFINISHED
      };
      const res: iap.QueryPurchaseResult = await iap.queryPurchases(context, param);
      for (const data of res.purchaseDataList) {
        try {
          const pd = JSON.parse(data) as PurchaseDataLite;
          if (!pd.jwsPurchaseOrder) {
            continue;
          }
          const payload = IapManager.parsePayload(pd.jwsPurchaseOrder);
          if (payload !== null && payload.purchaseToken && payload.purchaseOrderId) {
            const fp: iap.FinishPurchaseParameter = {
              productType: iap.ProductType.NONCONSUMABLE,
              purchaseToken: payload.purchaseToken,
              purchaseOrderId: payload.purchaseOrderId
            };
            await iap.finishPurchase(context, fp);
          }
        } catch (e) {
          // 忽略单条失败
        }
      }
    } catch (e) {
      // 查询失败静默（VIP 位已置 true，不影响权益）
    }
  }

  /** 解 JWS payload → 字符串（base64url；SDK：util.Base64Helper.decodeSync） */
  private static decodePayload(jws: string): string {
    const parts = jws.split('.');
    if (parts.length < 2) {
      return '';
    }
    const b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const buf = new util.Base64Helper().decodeSync(b64);
    return util.TextDecoder.create('utf-8').decodeToString(buf);
  }

  /** 解 JWS payload → 结构化对象（解不出 = null） */
  private static parsePayload(jws: string): OrderPayloadLite | null {
    const s = IapManager.decodePayload(jws);
    if (s.length === 0) {
      return null;
    }
    return JSON.parse(s) as OrderPayloadLite;
  }
}
