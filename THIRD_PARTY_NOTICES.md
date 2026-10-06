# 第三方组件与素材声明（THIRD_PARTY_NOTICES）

本文件列出「喵阅」使用的第三方**软件库**与**素材**（图片 / 音频 / 字体）及其授权来源。
所有条目均以仓库内实际文件或依赖包的元数据为依据；来源不明的项目会明确标注 **待补**。

> 本文件放在仓库根目录（不是 `docs/`）：`.gitignore` 里排除了 `/docs/`，放那里不会被提交。

- 项目本体许可：**GPL-3.0**，见 [LICENSE](LICENSE)
- 应用内同名页面：我的 → 关于我们 → 开源许可
- 隐私相关的**数据出境**说明（在线语音合成 / AI 说话人识别 / WiFi 传书）见
  `entry/src/main/resources/rawfile/default_agreement.txt` 第 4 节

---

## 1. 代码依赖

授权字段取自各依赖 `oh_modules/**/oh-package.json5` 的 `license` 原文（下表括注即原文）。

| 组件 | 版本 | 用途 | 许可证 | 与 GPL-3.0 兼容 |
|---|---|---|---|---|
| [gedoor/legado](https://github.com/gedoor/legado) | — | **上游项目**（本项目由其衍生） | GPL-3.0 | — （同许可） |
| [yongfengnice/legado-harmony](https://github.com/yongfengnice/legado-harmony) | — | **直接上游**（HarmonyOS 移植基座） | GPL-3.0 | — （同许可） |
| [@ohos/axios](https://gitcode.com/openharmony-sig/ohos_axios) | 2.2.0 | 三方 HTTP 客户端 | MIT（`"license": "MIT"`） | ✅ |
| [dayjs](https://github.com/iamkun/dayjs) | 1.11.7 | 日期时间处理 | MIT（`"license": "MIT"`） | ✅ |
| [@pura/harmony-utils](https://gitee.com/tongyuyan/harmony-utils) | 1.3.2 | HarmonyOS 工具集（PreferencesUtil 等） | **Apache-2.0**（`"license":"Apache-2.0"`） | ✅ |
| [@ohos/hypium](https://gitee.com/openharmony/testfwk_arkxtest) | 1.0.17 | 单元测试框架（**仅测试期**，不进发行包） | Apache-2.0（`"license":"Apache-2.0"`） | ✅ |
| @ohos/hamock | 1.0.0 | 测试 mock（**仅测试期**，不进发行包） | Apache-2.0（LICENSE 文件原文） | ✅ |

**Apache-2.0 的义务**：再分发时须保留许可证与 NOTICE 文本。上表已给出名称/版本/来源/许可，
若上游提供独立 `NOTICE` 文件，应随发行物一并提供。

**HarmonyOS 系统 Kit**（ReaderKit、Core Speech Kit、Core Vision、AVSession、
Share Kit、IAP Kit、NetworkKit 等）：随 HarmonyOS 系统提供，不属于本仓库分发的第三方库，
使用时受华为开发者协议约束，无需在此列许可证。

---

## 2. 图片素材

| 素材 | 位置 | 数量/体积 | 来源 | 授权 |
|---|---|---|---|---|
| 阅读器材质背景 | `entry/src/main/resources/rawfile/texture_001.jpg` … `texture_040.jpg` | 40 张，约 36 MB | **豆包 AI 生成**（项目方声明） | 自生成，无第三方权利 |
| 主题配置预览图 | `entry/src/main/resources/rawfile/bgi/my_theme_config_bg1..7.png` | 7 张 | 项目自制 | 同 GPL-3.0 |
| 默认封面 | `entry/src/main/resources/rawfile/cover_defaults/c1..c9.svg` | 9 张 | 项目自制 | 同 GPL-3.0 |
| 应用内图标 / UI 图形 | `entry/src/main/resources/base/media/*` | — | 项目自制，部分为 HarmonyOS 系统 Symbol | 同 GPL-3.0 |

> **AI 生成内容的说明**：豆包等生成式模型产出的图片，第三方通常不主张权利，因此**不存在侵犯他人著作权的问题**；
> 但相应地，这类纯 AI 生成图在多数法域**也较难获得著作权保护**（中国司法实践对"独创性智力投入"有要求）。
> 对本项目而言这只影响"别人抄你的图你能不能维权"，不影响合规性。
> 若曾对生成图做过人工再创作（裁剪/合成/手绘叠加），建议在此登记具体张数，便于主张权利。

**保留原始生成记录**：建议把生成时的提示词/时间/账号截图留在本地（不必进仓库），
万一将来需要证明素材来源，这是最直接的证据。

---

## 3. 音频素材

| 素材 | 位置 | 体积 | 来源 | 授权 |
|---|---|---|---|---|
| TTS 垫片环境音 | `entry/src/main/resources/rawfile/pad.mp3` | 约 1.34 MB | 项目方声明：**网上下载的开放式长音频（约 1 小时）中截取的一段** | ✅ 项目方确认具备使用权（原始出处已不可考） |

**关于"出处已不可考"的处理**（2026-10-06 经项目方确认）：

- 项目方确认该音频**具备使用权**（来源为开放式授权音频），因此本项目按可使用处理并随发行包分发；
- 但因**原始链接与许可类型已无法回溯**，本文件无法登记出处的具体条目。风险与建议：
  - 该音频在其他法域若被主张权利，本项目缺少"已获授权"的书面证据；
  - 建议**保留当时下载的凭证**（浏览器下载记录、文件名、下载日期截图等），归档在本地，不必进仓库；
  - 若日后能重新定位来源，请补上三项：① 原始链接 ② 许可类型（CC0 / CC-BY / 公有领域）③ 是否剪辑修改；
  - 最稳妥的长期方案：换用可确证为 **CC0 / 公有领域**的音频，或自行录制/合成垫片音。
- 该音频仅在**听书垫片**（朗读句间环境音）处使用；缺失或解码失败会自动降级为粉噪/静音（见 `TtsEngine.ets` 的三级降级注释），因此**替换成本很低**。

---

## 4. 字体

**本项目当前不内置任何第三方字体文件。**

已核查：`entry/src/main/resources/rawfile/` 下无 `.ttf/.otf/.ttc/.woff/.woff2`。

| 曾经的素材 | 处理 |
|---|---|
| `DingTalkJinBuTi.ttf`（钉钉进步体，2.0 MB，版权归钉钉(中国)信息技术有限公司） | **已于 2026-10-06 删除**。原因：字体内部声明为 `All rights reserved.`，且全仓无任何代码引用 |

阅读器使用的字体来自：
- **系统字体**（如 `/system/fonts/HarmonyOS_Sans_SC.ttf`，即"鸿蒙黑体"）—— 随系统提供；
- **用户自行导入**的字体文件 —— 由用户自行确保其授权。

---

## 5. 品牌标识（已处理）

**本项目自身的分享入口只使用系统分享**（`systemShare.ShareController` + 华为分享面板），
不包含微信 / QQ / 朋友圈 / QQ空间 等第三方品牌图标。

| 曾用的素材 | 处理 |
|---|---|
| `wechat.svg`、`QQ_blue.svg`、`QQ_space.svg`、`circle_friends.svg` | **2026-10-06 随自定义分享弹窗一并下线**。原弹窗（`entry/src/main/ets/pages/view/dialog/shareWorksBook.ets`）其实是"生成书单图片 + 未接入任何官方 SDK 的第三方品牌按钮"，已整体删除；这些图标现在全仓**零引用** |
| `legado.svg`、`legado_icon.svg` | 原先仅被上面的弹窗用于分享图生成，现同样**零引用** |

保留的自定义分享入口（书单长按 → 分享、书单编辑页 → 分享）现在与项目内既有先例
（`BookManagePage.manageShare()` 的分组分支）一致：**提示"书单暂不支持分享，请选择书籍"**
—— 因为**书单没有可分享的文件**，而系统分享必须提供 utd + uri 的文件。
真正可分享的是**书籍文件**：`BookInfoDialogs.shareSingle()`（单本）与
`BookManagePage.manageShare()`（多选）均走系统分享面板。

> 上述"零引用"的图标文件仍留在 `resources/base/media/` 中（会增大包体但不影响合规），
> 可按需清理。

---

## 6. 更新方式

新增三方依赖或素材时，请**同时**更新两处，避免不一致：

1. 本文件（`THIRD_PARTY_NOTICES.md`）—— 授权来源与义务；
2. 应用内页面 `entry/src/main/ets/pages/view/myCenter/about/LicensePage.ets` 的 `LICENSES` 数组。
