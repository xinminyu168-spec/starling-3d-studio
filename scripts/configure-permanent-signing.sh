#!/usr/bin/env bash
# One-time owner-authorized setup. Never generate a replacement signing key.
set +x
set -euo pipefail
umask 077
repo=xinminyu168-spec/starling-3d-studio
expected=065d80ddf51e5a7cbc881900351ee355cdd8aa2447fee0a959d0391ecc02c7ba
for cmd in gh openssl sha256sum base64 unzip tr python; do command -v "$cmd" >/dev/null || { echo "缺少工具 $cmd"; exit 1; }; done
gh auth status --hostname github.com >/dev/null 2>&1 || { echo '请先使用 gh auth login 登录仓库所有者账号。'; exit 1; }
# Resolve the latest requested successful build instead of embedding a version number.
run=$(gh api "repos/$repo/contents/updates/permanent-release-request.json" --jq .content | base64 -d | python -c 'import json,sys; print(int(json.load(sys.stdin)["runId"]))')
[[ $(gh api "repos/$repo/actions/runs/$run" --jq '.conclusion') == success ]]
[[ $(gh api "repos/$repo/actions/runs/$run" --jq '.head_branch') == main ]]
[[ $(gh api "repos/$repo/actions/runs/$run" --jq '.path') == .github/workflows/starling-native.yml ]]
secret_names=$(gh secret list --repo "$repo" --json name --jq '.[].name')
if grep -qx STARLING_MIGRATION_KEY_PK8_B64 <<<"$secret_names" && grep -qx STARLING_MIGRATION_CERT_DER_B64 <<<"$secret_names"; then
  echo '两个签名 Secrets 已存在，先交由云端验证；不会覆盖现有密钥。'
  gh workflow run permanent-release.yml --repo "$repo" --ref main -f run_id="$run"
  exit 0
fi
root="$HOME/storage/downloads"
key="$HOME/.starling-signing/migration-key.encrypted.pem"
cert="$HOME/.starling-signing/migration-cert.der"
work=$(mktemp -d)
trap 'unset pass; rm -rf "$work"' EXIT
if [[ ! -f "$key" || ! -f "$cert" ]]; then
  backup="$root/Starling-signing-backup.zip"
  if [[ $# -gt 0 ]]; then backup="$1"; fi
  if [[ -f "$backup" ]]; then
    for n in migration-key.encrypted.pem migration-cert.der SHA256SUMS.txt; do
      unzip -p "$backup" "Starling-signing-backup/$n" > "$work/$n"
    done
    key="$work/migration-key.encrypted.pem"
    cert="$work/migration-cert.der"
  else
    key="$root/Starling-signing-backup/migration-key.encrypted.pem"
    cert="$root/Starling-signing-backup/migration-cert.der"
  fi
fi
[[ -s "$key" && -s "$cert" ]] || { echo '缺少原加密私钥或证书。'; exit 1; }
[[ $(sha256sum "$cert" | cut -d' ' -f1) == "$expected" ]] || { echo '证书不匹配，拒绝继续。'; exit 1; }
read -rsp '原签名备份密码（不回显，仅本机）：' pass; echo
kp=$(openssl pkey -in "$key" -passin fd:3 -pubout -outform DER 3<<<"$pass" | sha256sum | cut -d' ' -f1)
cpub=$(openssl x509 -in "$cert" -inform DER -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1)
[[ "$kp" == "$cpub" ]] || { echo '私钥与原证书不匹配。'; exit 1; }
read -rp '授权将原密钥保存到本仓库加密 Actions Secrets 并发布？输入 YES：' answer
[[ "$answer" == YES ]] || exit 0
# Stream key bytes without printing or persisting the decrypted key.
openssl pkcs8 -topk8 -nocrypt -in "$key" -passin fd:3 -outform DER 3<<<"$pass" | base64 | tr -d '\n' | gh secret set STARLING_MIGRATION_KEY_PK8_B64 --repo "$repo"
unset pass
base64 < "$cert" | tr -d '\n' | gh secret set STARLING_MIGRATION_CERT_DER_B64 --repo "$repo"
gh workflow run permanent-release.yml --repo "$repo" --ref main -f run_id="$run"
echo "发布任务已提交。最终结果：https://github.com/$repo/actions/workflows/permanent-release.yml"
