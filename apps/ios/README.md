# Jasmine Bot iOS 客户端（Grok Bot 式随身遥控端）

面向 iPhone / iPad（iOS 18+）的纯原生 SwiftUI 客户端，采用 **「常驻电脑主机干活 + 手机免 VPN 随身派活、安全审批与语音对话」** 架构。

## 核心能力

1. **免 VPN 多通道自动竞速选路（`RouteRacer`）**
   - 扫一次 Mac 桌面端的「iOS 客户端全通道码」（`jasminebot://pair?data=...`），同时保存 **局域网 Wi-Fi + 公网 Cloudflare HTTPS 反向隧道 + Tailscale** 三套地址；
   - 在家自动优先走 `~2ms` 局域网直连；出门切 5G 蜂窝网络时无需手动开 Tailscale VPN，自动秒切公网 HTTPS 隧道，凭证安全存入 iOS `Keychain`。
2. **随身对话与多 Agent 群聊（`Conversations` + `ChatRoomDetail`）**
   - 实时 SSE 事件流（`/api/mobile/events`）同步所有单聊 Bot 与多 Bot 群聊；
   - 原生展示长任务 **中间阶段回复（Phase Replies）**、快捷 `@成员` 栏、相册图片直传、一键紧急停止，以及随时调出 **主机实时终端画面**。
3. **三键安全审批卡（`Approvals`）**
   - 对齐 Grok Bot 移动端审批体验，支持 **「允许一次 / 总是允许 / 拒绝」**，实时联动 Trellis 待审规则与记忆。
4. **原生中文语音派活与播报（`VoiceConsole`）**
   - 基于 iOS 系统级 `SFSpeechRecognizer` + `AVAudioEngine` + `AVSpeechSynthesizer`，绕开 iOS Safari 在局域网 HTTP 下禁用网页麦克风的限制，支持直接说话派活并朗读回复。
5. **主机状态、Magpie 周额度与后台通知（`HostStatus`）**
   - 查看当前命中通道与延迟、Magpie 各渠道周额度进度条、在线执行节点（主 Mac / `liuxu` / Windows），长任务跑完或出现新审批时自动弹系统通知。

## 构建与装机方式（Mac mini 无需安装 30GB Xcode）

### 方式 1：GitHub Actions 云端自动构建 `.ipa`（推荐）
1. 推送代码后在 GitHub Actions 运行 **Build Jasmine Bot iOS IPA**（`.github/workflows/ios-ipa.yml`）；
2. 下载产物 `JasmineBotIOS-unsigned-ipa` 中的 `JasmineBotIOS.ipa`；
3. 用 **AltStore / SideStore / Sideloadly** 或你的 Apple 开发者签名工具直接装入 iPhone。

### 方式 2：在装有 Xcode 16+ 的 Mac 上本地构建
```bash
brew install xcodegen
bash apps/ios/scripts/package-ipa.sh
# 或生成工程后直接在 Xcode 打开插线真机运行：
cd apps/ios && xcodegen generate && open JasmineBotIOS.xcodeproj
```

### 本机核心协议包测试（仅需 Command Line Tools）
```bash
swift test --package-path apps/ios/Packages/JasmineMobileCore
```
