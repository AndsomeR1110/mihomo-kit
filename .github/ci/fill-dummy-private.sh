#!/bin/bash
# CI 专用：用假数据生成 config/private/ 下的两个私有文件，让 mihomo -t 能跑通。
# 地址用文档保留网段（RFC 5737），节点不可能连得上；绝不要拿来当真实配置。
set -eu
cd "$(dirname "$0")/../.."
priv=config/private
key="$(printf 'A%.0s' $(seq 43))"           # 43 个 A = 32 字节全零的 base64url，格式合法
fp="$(printf 'AB%.0s' $(seq 32))"           # 64 位十六进制
for n in nodes infra-direct; do
    sed -e 's/__HK_IP__/192.0.2.10/g; s/__US_IP__/192.0.2.20/g' \
        -e 's/__HK_UUID__/00000000-0000-4000-8000-000000000001/g; s/__US_UUID__/00000000-0000-4000-8000-000000000002/g' \
        -e "s/__HK_REALITY_PUBLIC_KEY__/$key/g; s/__US_REALITY_PUBLIC_KEY__/$key/g" \
        -e 's/__HK_REALITY_SHORT_ID__/0123abcd/g; s/__US_REALITY_SHORT_ID__/0123abcd/g' \
        -e 's/__HK_HY2_PASSWORD__/dummy-password/g; s/__US_HY2_PASSWORD__/dummy-password/g' \
        -e "s/__HK_HY2_CERT_SHA256__/$fp/g; s/__US_HY2_CERT_SHA256__/$fp/g" \
        -e 's/__OWN_ROOT_DOMAIN__/example.com/g' \
        "$priv/$n.example.yaml" > "$priv/$n.yaml"
done
# 示例文件的注释里也提到占位符名，一并抹掉，免得被当成“没填完”
sed -i.bak 's/__[A-Z0-9_]*__/filled/g' "$priv/nodes.yaml" "$priv/infra-direct.yaml" && rm -f "$priv"/*.bak
echo "dummy private files written"
