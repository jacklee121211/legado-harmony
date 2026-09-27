# 喵阅

一款专注本地阅读的 HarmonyOS 阅读器。

> **纯本地工具**：不内置、不提供、不检索任何网络书源或在线内容。
> 所有阅读内容均来自你自行导入的本地文件，导入什么是你的权利，也由你负责。

## 功能

- **本地导入阅读**：支持 `txt / epub / mobi / azw / azw3`，与 ReaderKit 官方支持列表一致；支持自定义字符集
- **优质排版**：基于华为 [ReaderKit（阅读服务）](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/reader-kit-introduction)排版引擎，翻页覆盖 / 仿真 / 滑动 / 滚动等多种模式
- **听书**：本地 TTS 与在线 TTS 引擎（仅合成语音，不涉及内容分发），支持朗读定时
- **个性化**：沉浸光感材质、自定义背景与纹理混合、主题编辑器（自定义主题创建/管理）
- **书架管理**：分组、置顶、批量管理、书单导入（本地 JSON）、书架本地搜索
- **阅读辅助**：书签、阅读进度、阅读统计（读过 / 读完）、简繁转换等排版选项
- **效率**：桌面快捷方式（快速听书 / 快速阅读）、精细的震动反馈

## 构建

1. 安装 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（HarmonyOS SDK）
2. 克隆本仓库后用 DevEco Studio 打开
3. `Build > Build Hap(s)/APP(s)` 或命令行：

```bash
hvigorw assembleHap --mode module -p product=default -p buildMode=release
```

## 声明

- 本应用为本地文件阅读工具，与任何内容提供方无关联；应用内不包含任何书籍内容
- 在线 TTS 仅为语音合成能力，不抓取、不分发任何文本内容

## 开源协议与致谢

- 本项目基于 [gedoor/legado](https://github.com/gedoor/legado)（**GPL-3.0**）的 HarmonyOS 社区移植版本 [yongfengnice/legado-harmony](https://github.com/yongfengnice/legado-harmony) 修改而来，感谢两位上游作者的工作
- 相对移植版本的主要修改：**移除书源 / 订阅 / RSS 等全部联网内容获取体系**，仅保留本地阅读能力，并重构了 UI
- 本项目依 **GPL-3.0** 协议继续开源，完整许可证见 [LICENSE](LICENSE)
