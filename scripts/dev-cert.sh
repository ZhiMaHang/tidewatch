#!/bin/zsh
# 创建/复用本机 dev 代码签名身份「Tidewatch Dev」,消除 dev 构建的钥匙串重复授权弹框。
#
# 背景:build-app.sh 默认 ad-hoc 签名(--sign -),其 designated requirement 是当次
# 二进制的 cdhash,每次重构建都变,macOS 把新构建当"新应用"对钥匙串条目重新索权。
# 换成稳定的自签名身份后,requirement 锚定证书本身,重构建不再触发重新授权。
#
# 幂等:已有可用身份直接退出;证书存在但不可用时只打修复指引,不重复导入。
# 预期的一次性弹框(各只弹一次,之后重构建/重运行不再弹):
#   1. 本脚本设置证书信任时,系统可能弹密码框(确认修改信任设置);
#   2. 首次用该身份跑 build-app.sh,弹「codesign 想访问密钥」→ 点「始终允许」;
#   3. 换新身份后首次运行 App,每个钥匙串条目各弹一次 → 点「始终允许」。
set -euo pipefail

IDENTITY="Tidewatch Dev"
KEYCHAIN="$(security login-keychain -d user 2>/dev/null | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//' || true)"
[ -n "$KEYCHAIN" ] || KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# 已有可用身份 → 幂等退出
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$IDENTITY\""; then
  echo "✅ 签名身份「$IDENTITY」已存在且可用,无需重复创建。"
  exit 0
fi

# 证书在钥匙串里但不是可用身份(通常是信任设置没成)→ 只给手动指引,避免重复导入出歧义
if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  cat <<'EOF'
⚠️ 钥匙串里已有「Tidewatch Dev」证书,但还不是可用的签名身份(多半是信任未设置成功)。
   手动补一步(只需一次):
   1. 打开「钥匙串访问」→ 左侧「登录」→ 分类「证书」,找到 Tidewatch Dev;
   2. 双击 → 展开「信任」→「代码签名」选「始终信任」→ 关窗口时输一次登录密码。
   完成后重跑本脚本确认(应显示"已存在且可用")。
   若补信任后仍不可用(如私钥缺失),删掉旧证书重来:
     security delete-certificate -c "Tidewatch Dev"
EOF
  exit 1
fi

echo "▸ 生成自签名代码签名证书「$IDENTITY」(有效期 10 年)…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<'CONF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Tidewatch Dev
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:FALSE
subjectKeyIdentifier = hash
CONF

# 固定用系统 LibreSSL,避免 Homebrew OpenSSL 的行为差异
/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$IDENTITY" -passout pass:tidewatch-dev -out "$TMP/dev.p12"

echo "▸ 导入 login 钥匙串(私钥授权给 codesign)…"
security import "$TMP/dev.p12" -k "$KEYCHAIN" -f pkcs12 -P tidewatch-dev \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "▸ 设置证书信任(仅代码签名用途;如弹出密码框请输入登录密码确认)…"
security add-trusted-cert -p basic -p codeSign -r trustRoot -k "$KEYCHAIN" "$TMP/cert.pem" || true

if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$IDENTITY\""; then
  echo "✅ 已创建可用签名身份「$IDENTITY」。之后 ./scripts/build-app.sh 会自动用它签名;"
  echo "   首次构建/首次运行还会各弹一次授权(点「始终允许」),此后重构建不再弹。"
else
  cat <<'EOF'
⚠️ 证书已导入,但信任设置未生效(此步在部分系统上必须 GUI 确认)。手动补一步(只需一次):
   1. 打开「钥匙串访问」→ 左侧「登录」→ 分类「证书」,找到 Tidewatch Dev;
   2. 双击 → 展开「信任」→「代码签名」选「始终信任」→ 关窗口时输一次登录密码。
   完成后重跑本脚本确认(应显示"已存在且可用")。
EOF
  exit 1
fi
