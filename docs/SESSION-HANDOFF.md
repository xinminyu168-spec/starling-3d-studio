# 星灵项目跨会话交接与发布约定

## 每次新对话先恢复项目状态
1. 读取本文件、app-update-v2.json、最新 main 提交和 GitHub Actions 构建结果，区分源码版本、构建版本和正式发布版本。
2. 永久证书 SHA-256: 065d80ddf51e5a7cbc881900351ee355cdd8aa2447fee0a959d0391ecc02c7ba. 包名 com.xs.character.viewer。禁止擅自换证书、卸载应用、覆盖原始资产或提交私钥。
3. 如果缺少临时签名环境，优先检索用户私有历史对话及文件库，寻找 Starling-signing-backup.zip、migration-key.encrypted.pem、migration-cert.der 和该备份对应的历史解锁信息。不要仅凭当前会话上下文认定密码丢失，不要重复要求用户提供已经存在的信息。2026-11-28 已实际恢复并验证匹配原证书的私钥。任何密码或私钥均不得写入公开仓库、构建日志、交接文档。
4. 优先使用 .github/workflows/permanent-release.yml 和仓库 Secrets；未配置时允许按已验证的离线签名方案使用 updates/publish-v2.json 和 .github/workflows/publish-shell-v2.yml。离线签名仅提交针对指定 APK 的公开签名块和哈希，不提交私钥。
5. 必须等待云端实际签名校验、版本校验、发布任务及 app-update-v2.json 生效后，才可宣称热更新完成。

## 长期目标
使用 scripts/configure-permanent-signing.sh 由仓库所有者授权一次，将原密钥安全配置为 STARLING_MIGRATION_KEY_PK8_B64 和 STARLING_MIGRATION_CERT_DER_B64 两个 Actions Secrets；之后云端签名不依赖 ChatGPT 临时会话。未获得该权限前，采用上述可恢复离线发布路线，不声称完全自动化。

## 当前交接点
V7.9 build 81: native build 46127704070 and publication 46129157738 completed successfully; manifest versionCode 81 SHA256 5da03d6d21a2a7023eff0e09f13547fa26bb7a38f9d4afa0f2f7c6b67948ae19. Device visual acceptance remains pending.
V8.0 build 82: native source commit 2824f7b922fa71a04f987d9a94b5e9ff262ebd64, run 46129762509. Verify live results; not signed/published when recorded. Adds opt-in local ZIP asset package import with permanent certificate signature verification, semantic8 GLB profile, fixed source hash, immutable ID >=5, bounded size, streaming hash validation and separate model storage. scripts/build-signed-asset.py generates package using original encrypted private key and verifies certificate; script not yet end-to-end tested. No private models or key material uploaded. Local asset import only, not automatic remote delivery. Next: confirm compile, sign/publish using existing certificate, generate and test signed asset package, validate on-device PBR A/B and invalid-package rejection.
