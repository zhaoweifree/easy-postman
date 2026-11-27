#!/bin/bash
#
# 把 .deb 内 control/data 成员的压缩方式统一为 dpkg 普遍支持的格式。
#
# 背景：Ubuntu 24.04+（dpkg >= 1.21.18）的 dpkg-deb 默认使用 zstd，
# jpackage --type deb 会继承该默认值；而 Debian 11 / Ubuntu 20.04 / openEuler /
# 麒麟 等较老系统的 dpkg 不认识 zstd，安装时报：
#   dpkg-deb: 错误: 归档 xxx.deb 对成员 control.tar.zst 使用了未知的压缩，放弃操作
#
# 默认统一为 xz（dpkg >= 1.17，2013 年起就支持）；极老环境可传 gzip。
# tar 负载是解压后按原始字节重新压缩，所以文件权限、时间戳、md5sums 都不会变。
#
# 用法: repack-deb-to-xz.sh <package.deb> [xz|gzip]

set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 <package.deb> [xz|gzip]" >&2
    exit 1
fi

DEB_PATH="$1"
COMPRESSION="${2:-xz}"

case "$COMPRESSION" in
    xz|gzip) ;;
    *)
        echo "Unsupported compression: $COMPRESSION (expected xz or gzip)" >&2
        exit 1
        ;;
esac

if [ ! -f "$DEB_PATH" ]; then
    echo "DEB file not found: $DEB_PATH" >&2
    exit 1
fi

for cmd in ar tar gzip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required command: $cmd" >&2
        exit 1
    fi
done

if [ "$COMPRESSION" = "xz" ] && ! command -v xz >/dev/null 2>&1; then
    echo "Missing required command: xz (apt-get install xz-utils)" >&2
    exit 1
fi

DEB_PATH=$(cd "$(dirname "$DEB_PATH")" && pwd)/$(basename "$DEB_PATH")

TMP_DIR=$(mktemp -d)
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cp "$DEB_PATH" "$TMP_DIR/input.deb"
cd "$TMP_DIR"
ar x input.deb

CONTROL_MEMBER=$(find . -maxdepth 1 -type f -name 'control.tar.*' | head -n 1)
DATA_MEMBER=$(find . -maxdepth 1 -type f -name 'data.tar.*' | head -n 1)

if [ ! -f "./debian-binary" ] || [ -z "$CONTROL_MEMBER" ] || [ -z "$DATA_MEMBER" ]; then
    echo "Unexpected DEB structure in $DEB_PATH" >&2
    exit 1
fi

decompress_member() {
    local input_path="$1"
    local base_name
    base_name=$(basename "$input_path")
    case "$base_name" in
        *.tar.xz) xz -d -c "$input_path" ;;
        *.tar.gz) gzip -d -c "$input_path" ;;
        *.tar.zst)
            if ! command -v zstd >/dev/null 2>&1; then
                echo "Input uses zstd but the zstd command is missing (apt-get install zstd)" >&2
                exit 1
            fi
            zstd -d -q -c "$input_path"
            ;;
        *.tar) cat "$input_path" ;;
        *)
            echo "Unsupported tar member format: $base_name" >&2
            exit 1
            ;;
    esac
}

recompress_member() {
    local input_path="$1"
    local base_name
    base_name=$(basename "$input_path")
    local stem="${base_name%%.tar.*}"
    local output_path

    if [ "$COMPRESSION" = "xz" ]; then
        output_path="rebuilt/${stem}.tar.xz"
        decompress_member "$input_path" | xz -T0 -6 -c > "$output_path"
    else
        output_path="rebuilt/${stem}.tar.gz"
        decompress_member "$input_path" | gzip -9 -n -c > "$output_path"
    fi

    # 自检：重新压缩后的负载必须能被完整读回
    tar -tf "$output_path" > /dev/null
    basename "$output_path"
}

mkdir -p rebuilt
NEW_CONTROL=$(recompress_member "$CONTROL_MEMBER")
NEW_DATA=$(recompress_member "$DATA_MEMBER")
cp debian-binary rebuilt/

# ar 成员顺序必须是 debian-binary、control.tar.*、data.tar.*
(
    cd rebuilt
    rm -f ../output.deb
    ar cr ../output.deb debian-binary "$NEW_CONTROL" "$NEW_DATA"
)

# 自检：不允许再出现 dpkg 不认识的压缩成员
MEMBERS=$(ar t output.deb)
echo "Members of $(basename "$DEB_PATH"):"
echo "$MEMBERS" | sed 's/^/  /'
if echo "$MEMBERS" | grep -q '\.zst$'; then
    echo "Refusing to produce a package that still contains a zstd member" >&2
    exit 1
fi

cp output.deb "$DEB_PATH"
echo "Repacked with $COMPRESSION: $DEB_PATH"
