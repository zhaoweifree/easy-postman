#!/bin/bash
#
# Debian / Ubuntu / 麒麟 / openEuler 等 DEB 系统打包脚本。
#
# 产物架构跟随当前打包机器（amd64 / arm64），文件名统一为：
#   dist/EasyPostman-${VERSION}-linux-${ARCH}.deb
#
# 兼容性约定（重要）：
#   jpackage 生成 DEB 时调用系统 dpkg-deb，而 dpkg >= 1.21.18（Ubuntu 24.04+）
#   默认使用 zstd 压缩，老系统的 dpkg 会直接拒绝安装：
#     dpkg-deb: 错误: 归档 xxx.deb 对成员 control.tar.zst 使用了未知的压缩，放弃操作
#   所以这里打包完成后强制把 control/data 成员重压为 xz（dpkg >= 1.17 均支持），
#   并在脚本末尾做结构自检；可用 DEB_COMPRESSION=gzip 进一步兼容极老环境。
#
# 用法：
#   bash build/linux-deb.sh                  # 默认 xz
#   DEB_COMPRESSION=gzip bash build/linux-deb.sh
#   SKIP_BUILD=1 bash build/linux-deb.sh     # 复用已有 target/ 产物，跳过 mvn

set -euo pipefail

# 检查 java 是否可用
if ! command -v java &> /dev/null; then
    echo "❌ 未检测到 java，请先安装 JDK 17+ 并配置环境变量。"
    exit 1
fi
# 检查 jlink / jpackage / objcopy
for bin in jlink jpackage; do
    if ! command -v "$bin" &> /dev/null; then
        echo "❌ 未检测到 $bin，请确认 JDK 17+ 已正确安装。"
        exit 1
    fi
done
if ! command -v objcopy &> /dev/null; then
    echo "❌ 未检测到 objcopy，请先安装 binutils：sudo apt-get install binutils"
    exit 1
fi
# 重压缩所需的工具
for bin in ar tar xz gzip; do
    if ! command -v "$bin" &> /dev/null; then
        echo "❌ 未检测到 $bin，请先安装：sudo apt-get install binutils xz-utils"
        exit 1
    fi
done

PROJECT_ROOT=$(cd "$(dirname "$0")/.."; pwd)
cd "$PROJECT_ROOT" || exit 1

VERSION=$(grep -m 1 '<revision>' pom.xml | sed 's/.*<revision>\(.*\)<\/revision>.*/\1/')
DEB_COMPRESSION="${DEB_COMPRESSION:-xz}"
SKIP_BUILD="${SKIP_BUILD:-0}"

APP_NAME="EasyPostman"
JAR_NAME_WITH_VERSION="easy-postman-$VERSION.jar"
JAR_NAME="easy-postman.jar"  # 固定名称，不带版本号
MAIN_CLASS="com.laker.postman.App"
OUTPUT_DIR="dist"
APP_TARGET_DIR="easy-postman-app/target"

# 目标架构：以 dpkg 为准，保证 control 里的 Architecture 与文件名一致
ARCH=$(dpkg --print-architecture 2>/dev/null || true)
if [ -z "$ARCH" ]; then
    case "$(uname -m)" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) ARCH="$(uname -m)" ;;
    esac
fi

echo "🔧 开始打包 EasyPostman DEB 包，版本: $VERSION，架构: $ARCH，压缩: $DEB_COMPRESSION"

# 检查 JDK 版本是否 >= 17
JAVA_MAJOR=$(java -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -n 1)
if [ -n "$JAVA_MAJOR" ] && [ "$JAVA_MAJOR" -lt 17 ]; then
    echo "❌ 需要 JDK 17 或更高版本。当前版本: $JAVA_MAJOR"
    exit 1
fi

# Step 1: 清理 & 构建项目
if [ "$SKIP_BUILD" != "1" ]; then
    echo "🚀 开始构建项目..."
    mvn clean package -DskipTests=false
fi

if [ ! -f "${APP_TARGET_DIR}/$JAR_NAME_WITH_VERSION" ]; then
    echo "❌ 构建未生成 jar 包: ${APP_TARGET_DIR}/$JAR_NAME_WITH_VERSION"
    exit 1
fi

# 重命名 JAR 为固定名称（方便 jpackage 配置和后续更新）
echo "📝 重命名 JAR: $JAR_NAME_WITH_VERSION -> $JAR_NAME"
cp "${APP_TARGET_DIR}/$JAR_NAME_WITH_VERSION" "${APP_TARGET_DIR}/$JAR_NAME"

# Step 2: 创建最小运行时 jlink
echo "⚙️ 使用 jlink 创建最小化运行时..."
rm -rf target/runtime
jlink \
    --add-modules java.base,java.desktop,java.logging,jdk.unsupported,java.naming,java.net.http,jdk.httpserver,java.prefs,java.sql,java.security.sasl,java.security.jgss,jdk.crypto.ec,java.management,java.management.rmi,jdk.crypto.cryptoki \
    --strip-debug \
    --no-header-files \
    --no-man-pages \
    --compress=2 \
    --output target/runtime

# Step 3: 准备输出目录
mkdir -p ${OUTPUT_DIR}

# Step 4: 创建仅包含主 jar 的临时目录
DIST_INPUT_DIR="target/dist-input"
rm -rf ${DIST_INPUT_DIR}
mkdir -p ${DIST_INPUT_DIR}
cp "${APP_TARGET_DIR}/${JAR_NAME}" ${DIST_INPUT_DIR}/

# Step 5: 使用 jpackage 打包 DEB
echo "📦 使用 jpackage 打包 DEB 包..."
JPACKAGE_DEB_DIR="target/deb-raw"
rm -rf "$JPACKAGE_DEB_DIR"
mkdir -p "$JPACKAGE_DEB_DIR"

jpackage \
    --input ${DIST_INPUT_DIR} \
    --main-jar ${JAR_NAME} \
    --main-class ${MAIN_CLASS} \
    --add-launcher EasyPostmanMCP=build/easy-postman-mcp-launcher.properties \
    --runtime-image target/runtime \
    --type deb \
    --name "${APP_NAME}" \
    --app-version "${VERSION}" \
    --dest "${JPACKAGE_DEB_DIR}" \
    --vendor "Laker" \
    --copyright "© 2025 Laker" \
    --description "A modern API testing tool similar to Postman" \
    --linux-shortcut \
    --linux-menu-group "Development" \
    --linux-app-category "Development" \
    --java-options "-Xms256m" \
    --java-options "-Xmx1g" \
    --java-options "-XX:MaxMetaspaceSize=256m" \
    --java-options "-XX:MetaspaceSize=128m" \
    --java-options "-XX:MaxDirectMemorySize=256m" \
    --java-options "-XX:+UseG1GC" \
    --java-options "-XX:MaxGCPauseMillis=200" \
    --java-options "-XX:InitiatingHeapOccupancyPercent=45" \
    --java-options "-XX:+UseStringDeduplication" \
    --java-options "-XX:+HeapDumpOnOutOfMemoryError" \
    --java-options "-XX:HeapDumpPath=./dumps" \
    --java-options "-Dfile.encoding=UTF-8" \
    --java-options "-Dawt.useSystemAAFontSettings=on" \
    --java-options "-Dswing.aatext=true" \
    --java-options "-Dhttp.keepAlive=true" \
    --java-options "--add-opens=java.desktop/sun.awt.X11=ALL-UNNAMED"

RAW_DEB=$(find "${JPACKAGE_DEB_DIR}" -maxdepth 1 -type f -name "*.deb" | sort | tail -n 1)
if [ -z "$RAW_DEB" ]; then
    echo "❌ jpackage 未产出 DEB 文件"
    exit 1
fi

# Step 6: 统一压缩格式 + 统一命名
DEB_FILE="${OUTPUT_DIR}/EasyPostman-${VERSION}-linux-${ARCH}.deb"
rm -f "$DEB_FILE"
cp "$RAW_DEB" "$DEB_FILE"

echo "🧩 统一 DEB 成员压缩为 ${DEB_COMPRESSION}（避免老系统 dpkg 不认识 zstd）..."
bash build/repack-deb-to-xz.sh "$DEB_FILE" "$DEB_COMPRESSION"

# Step 7: 结构自检
echo "🔍 校验 DEB 结构..."
MEMBERS=$(ar t "$DEB_FILE")
if echo "$MEMBERS" | grep -q '\.zst$'; then
    echo "❌ 校验失败：产物仍包含 zstd 成员"
    exit 1
fi
if ! echo "$MEMBERS" | grep -q "^control\.tar\.\(xz\|gz\)$"; then
    echo "❌ 校验失败：control.tar 格式异常"
    exit 1
fi
if command -v dpkg-deb &> /dev/null; then
    dpkg-deb -I "$DEB_FILE" > /dev/null
    echo "   dpkg-deb 可正常解析 ✔"
fi

echo "🎉 DEB 包打包完成！输出路径：$(pwd)/${DEB_FILE}"
echo "   架构: ${ARCH}"
echo "   大小: $(du -h "$DEB_FILE" | cut -f1)"
command -v sha256sum &> /dev/null && echo "   SHA256: $(sha256sum "$DEB_FILE" | cut -d' ' -f1)"
echo "📝 安装命令: sudo dpkg -i ${DEB_FILE}"
echo "📝 或使用: sudo apt install ./${DEB_FILE}"
echo "📝 卸载命令: sudo dpkg -r easypostman"
