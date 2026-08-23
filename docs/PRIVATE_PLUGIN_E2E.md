# 独立私有插件仓库：端到端上架操作

本仓库的可复用发布模板在 `tools/private-plugin-release/`。每个插件源码仓库可以是 GitHub private；Marketplace 与客户端均不需要读取 GitHub。它们只消费审核过的 TTX 字节和公钥链。

## 为现有两个第一方插件建仓

1. 创建 private repositories `timetrace-plugin-private-flight` 和 `timetrace-plugin-ai-recap`，各自复制 `tools/private-plugin-release/` 到仓库内的 `tools/` 与 `.github/`。
2. `private-flight` 根目录的 `manifest.json` 以 `contracts/fixtures/ttx-marketplace-first-party-bundled-v1/manifest.json` 为基线；`ai-recap` 以同目录的 `ai-recap.manifest.json` 为基线。P2 first-party-bundled profile 必须保持空 payload：不要创建 `resources/`。
3. 为每仓离线生成独立 Ed25519 keypair。存 `base64(private PEM)` 到其 GitHub Environment secret `TTX_SIGNING_PRIVATE_KEY_B64`；绝不把 key、base64 或 Actions log 复制到此仓库。
4. 由离线机执行 `python tools/build_ttx.py publisher-jwk --signing-key private-flight.pem` / `ai-recap.pem`。管理员将输出的 JWK 分别登记为 `wellorbetter/<key-id>` 的 active publisher key。每插件使用不同 key id；密钥范围不可跨插件复用。
5. 在两个 private repo 的 `marketplace-production` Environment 建 variables：`MARKETPLACE_BASE_URL`、`TTX_PUBLISHER_ID=wellorbetter`、`TTX_PLUGIN_ID=private-flight` 或 `ai-recap`、`TTX_PUBLISHER_KEY_ID=<独立 key id>`；设置 required reviewers。写入相应 owner 的 `MARKETPLACE_PUBLISHER_TOKEN` secret。
6. 以 `vX.Y.Z` tag 触发工作流。它会生成 TTX、`release-attestation.json`，用刚导出的 public PEM 回验 archive signature，并将两个文件上传为 GitHub artifact。它只调用 publisher create/upload/complete API，因此最终状态只能是 `pending_review`。
7. 管理员在 Marketplace 后台审核 artifact 的 `package_sha256`、`manifest_sha256`、key id、source revision 和 GitHub run；再调用既有 review API 选择 publish。Worker 会再次计算包 SHA-256 和验证 TTX 签名，发布后客户端拉取根签名 catalog、下载包、复验 digest + publisher key signature，再激活内置 renderer entitlement。

## 真实端到端前置条件与当前阻断

发布 API、R2 immutable promotion、D1 review audit、桌面端 catalog/digest/archive signature 验证均已实现。要真正完成一次“发现 → 下载 → 使用”，尚需管理员完成以下外部配置：登记两个公钥与 approved publisher、生成 publisher-owner JWT、以及启动可见的桌面应用窗口。最后一项是当前主任务正在修复的 Windows 首帧/顶层窗口问题；它不影响私库签名和 Marketplace 发布链路，但阻止人工点击验证最终下载与启用。

管理员 UI 目前尚未覆盖 publisher key registration 与 review action；可先使用受控 D1/管理 API 执行，随后应把这两个操作放进正式后台，且保留现有 audit event/review decision 记录。
