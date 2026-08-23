# 私有插件仓库发布模板

每个插件可以放在独立的 GitHub private repository。私有性保护源代码；它不是 TimeTrace 的信任依据。桌面端只接受：Marketplace 根密钥签名的目录/发布者密钥响应、目录中固定的包 SHA-256，以及该发布者 Ed25519 公钥验证通过的 TTX。

## 在一个私有插件仓库启用

复制本目录的 `build_ttx.py`、`publish_ttx.py` 到该仓库的 `tools/`，复制 `private-plugin-release.yml.example` 为 `.github/workflows/release.yml`，并复制 `requirements-release.txt` 为 `.github/requirements-release.txt`。仓库根目录提供 `manifest.json` 与可选 `resources/`。`build_ttx.py build` 会把 source JSON 规范化为 Worker/host 要求的 canonical bytes，生成 `dist/<version>.ttx` 和 `dist/release-attestation.json`，再由 `verify` 在上传前验签。

GitHub Environment `marketplace-production` 必须配置 required reviewers。每仓库的 variables：`MARKETPLACE_BASE_URL`、`TTX_PUBLISHER_ID`、`TTX_PLUGIN_ID`、`TTX_PUBLISHER_KEY_ID`。每仓库的 secrets：

- `TTX_SIGNING_PRIVATE_KEY_B64`：Ed25519 PEM 私钥的单行 base64；仅在 Actions runner 临时写入，绝不提交或打印。
- `MARKETPLACE_PUBLISHER_TOKEN`：该 publisher owner 的短期 API JWT，只能创建、上传、完成其 own release；不能审核或发布。

在首次发布前，管理员需在 Marketplace 后台/D1 中注册并启用 `(publisher_id, key_id, public_key JWK)`，并将 publisher 状态设为 `approved`。在隔离机器上以 `python tools/build_ttx.py publisher-jwk --signing-key .\\private-key.pem` 导出 JWK；不要将私钥放入主仓库、Worker 环境或 D1。密钥轮换时先注册新 key id、更新 private repo variable/secret，再撤销旧 key。

工作流只把 release 推到 `pending_review`，不会调用管理员审核 API。管理员在后台查看 release id、attestation（package SHA-256、manifest SHA-256、key id、signature、source revision）并决定 approve/publish、reject、suspend 或 revoke。这样 private repository 不需要赋予主仓库或 Worker GitHub 读取权限。

## 本地自检

安装 `cryptography==41.0.5` 后：

```powershell
python tools/build_ttx.py build --manifest manifest.json --payload-dir resources --signing-key .\private-key.pem --key-id publisher-key-2026 --out .\dist\1.2.3.ttx
python tools/build_ttx.py public-key --signing-key .\private-key.pem --out .\public-key.pem
python tools/build_ttx.py verify --archive .\dist\1.2.3.ttx --public-key .\public-key.pem --key-id publisher-key-2026
```

`release-attestation.json` is an audit receipt, while the authoritative archive signature covers the canonical `(manifest, payload_index)` pair. The Marketplace independently recomputes package SHA-256 and independently verifies the same Ed25519 signature before accepting the release.
