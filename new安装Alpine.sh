#!/data/data/com.termux/files/usr/bin/bash
# 脚本：在Termux中手动安装Alpine Linux并通过PRoot运行SillyTavern
set -e

echo "
辰林的酒馆自动安装app
本软件是基于Termux制作
但是GPLv3是可以商用的
如果要用请购买密钥后使用
用盗版的别跳脸
出了问题别找我即可
"

echo ">>> 软件会安装64位的Alpine并通过PRoot运行SillyTavern"
echo ">>> 这个安装版本是不需要梯子的！！！"
echo ">>> 别开梯子！！！开了反而会出问题！！！"
read -p "确保没有开了梯子后按回车继续"


# --- Termux 环境准备 ---
echo ">>> [Termux] 正在更新软件包列表..."
yes | pkg update

echo ">>> [Termux] 正在升级已安装的软件包..."
yes | pkg upgrade

echo ">>> [Termux] 安装必要的依赖..."
NECESSARY_PACKAGES="proot git curl tar wget fakeroot coreutils sed gawk findutils xz-utils gzip"
pkg install ${NECESSARY_PACKAGES} -y
if [ $? -ne 0 ]; then
    echo ">>> 错误: Termux基础依赖安装失败。"
    exit 1
fi
echo ">>> [Termux] Termux基础依赖安装完成。"

command -v curl >/dev/null 2>&1 || { echo ">>> 错误: curl 命令未找到。"; exit 1; }
command -v wget >/dev/null 2>&1 || { echo ">>> 错误: wget 命令未找到。"; exit 1; }
command -v proot >/dev/null 2>&1 || { echo ">>> 错误: proot 命令未找到。"; exit 1; }
echo ">>> [Termux] 基础命令检查通过。"

# 确保 resolv.conf 存在
if [ ! -f "$PREFIX/etc/resolv.conf" ]; then
    echo ">>> [Termux] 创建 resolv.conf..."
    mkdir -p "$PREFIX/etc"
    echo "nameserver 8.8.8.8" > "$PREFIX/etc/resolv.conf"
    echo "nameserver 8.8.4.4" >> "$PREFIX/etc/resolv.conf"
fi

# --- Alpine Linux 手动安装 ---
ALPINE_FS_DIR="$HOME/alpine_manual_fs"
ALPINE_ROOTFS_TARBALL_PATH="$HOME/alpine_latest_rootfs.tar.gz"

# 动态获取最新的Alpine Mini RootFS aarch64链接从清华源
echo ">>> [Termux] 正在从清华源获取最新的Alpine Linux aarch64 Mini RootFS信息..."
LATEST_RELEASES_URL="https://mirrors.tuna.tsinghua.edu.cn/alpine/latest-stable/releases/aarch64/latest-releases.yaml"
YAML_FILE_TMP="$HOME/latest-releases.yaml.tmp"

echo ">>> [Termux] 尝试下载版本信息..."
curl -LfS --connect-timeout 15 "${LATEST_RELEASES_URL}" -o "${YAML_FILE_TMP}" 2>/dev/null
CURL_EXIT_CODE=$?

ALPINE_ROOTFS_DOWNLOAD_URL=""

if [ $CURL_EXIT_CODE -eq 0 ] && [ -s "${YAML_FILE_TMP}" ]; then
    MINIROOTFS_FILENAME=$(grep -o 'alpine-minirootfs-[0-9][^"]*-aarch64\.tar\.gz' "${YAML_FILE_TMP}" | head -n1)
    if [ -n "$MINIROOTFS_FILENAME" ]; then
        ALPINE_ROOTFS_DOWNLOAD_URL="https://mirrors.tuna.tsinghua.edu.cn/alpine/latest-stable/releases/aarch64/${MINIROOTFS_FILENAME}"
        echo ">>> [Termux] 解析到最新版本: ${MINIROOTFS_FILENAME}"
    fi
fi
rm -f "${YAML_FILE_TMP}"

if [ -z "$ALPINE_ROOTFS_DOWNLOAD_URL" ]; then
    echo ">>> 警告: 无法自动获取最新版本，使用预设版本 Alpine v3.20.3。"
    ALPINE_ROOTFS_DOWNLOAD_URL="https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.20/releases/aarch64/alpine-minirootfs-3.20.3-aarch64.tar.gz"
fi
echo ">>> [Termux] 下载URL: ${ALPINE_ROOTFS_DOWNLOAD_URL}"

# 清理旧的安装
echo ">>> [Termux] 清理可能存在的旧文件..."
rm -rf "${ALPINE_FS_DIR}"
rm -f "${ALPINE_ROOTFS_TARBALL_PATH}"

echo ">>> [Termux] 创建新的Alpine文件系统目录: ${ALPINE_FS_DIR}"
mkdir -p "${ALPINE_FS_DIR}"

echo ">>> [Termux] 正在下载 Alpine Linux Mini RootFS..."
wget --tries=3 --timeout=60 "${ALPINE_ROOTFS_DOWNLOAD_URL}" -O "${ALPINE_ROOTFS_TARBALL_PATH}"
if [ $? -ne 0 ]; then
    echo ">>> 错误: 下载 Alpine RootFS 失败，请检查网络连接。"
    exit 1
fi
echo ">>> [Termux] 下载完成。"

echo ">>> [Termux] 正在解压 Alpine RootFS (使用 fakeroot)..."
fakeroot tar -xzf "${ALPINE_ROOTFS_TARBALL_PATH}" -C "${ALPINE_FS_DIR}"
if [ $? -ne 0 ]; then
    echo ">>> 错误: 解压失败，下载的文件可能已损坏。"
    exit 1
fi
echo ">>> [Termux] 解压完成。"

BUSYBOX_PATH="${ALPINE_FS_DIR}/bin/busybox"
if [ ! -x "${BUSYBOX_PATH}" ]; then
    echo ">>> 错误: 未找到 busybox，解压可能不完整。"
    ls -lA "${ALPINE_FS_DIR}/" 2>/dev/null || true
    exit 1
fi
echo ">>> [Termux] busybox 检查通过。"

# --- 创建启动脚本 ---
CUSTOM_START_SCRIPT_PATH="$HOME/start_alpine.sh"
echo ">>> [Termux] 创建 Alpine 启动脚本 ${CUSTOM_START_SCRIPT_PATH}..."
cat > "${CUSTOM_START_SCRIPT_PATH}" << EOF_ALPINE_LOGIN
#!/data/data/com.termux/files/usr/bin/bash
echo "正在启动 Alpine Linux (手动PRoot)..."
unset LD_PRELOAD
exec proot \
    -0 \
    --link2symlink \
    -r "${ALPINE_FS_DIR}" \
    -w /root \
    -b /dev \
    -b /proc \
    -b /sys \
    -b /data \
    -b "\$HOME/storage/shared:/mnt/sdcard" \
    -b "${ALPINE_FS_DIR}/root:/root" \
    -b "$PREFIX/etc/resolv.conf:/etc/resolv.conf" \
    /usr/bin/env -i \
    HOME=/root \
    TERM="\$TERM" \
    LANG=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/ash --login
EOF_ALPINE_LOGIN
chmod +x "${CUSTOM_START_SCRIPT_PATH}"
echo ">>> [Termux] 启动脚本已创建。"

# --- Alpine 内部首次配置 ---
echo ">>> [Termux] 开始首次进入Alpine进行内部配置..."

ALPINE_FIRST_SETUP_COMMANDS=$(cat <<'EOF_ALPINE_FIRST_SETUP'
set +e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo ">>> [Alpine Init] 配置APK源为清华大学镜像..."
if [ -f /etc/apk/repositories ]; then
    cp /etc/apk/repositories /etc/apk/repositories.bak
fi
echo "https://mirrors.tuna.tsinghua.edu.cn/alpine/latest-stable/main" > /etc/apk/repositories
echo "https://mirrors.tuna.tsinghua.edu.cn/alpine/latest-stable/community" >> /etc/apk/repositories
echo ">>> [Alpine Init] APK源已配置。"

echo ">>> [Alpine Init] 更新APK索引..."
apk update || echo ">>> 警告: apk update 报错，但继续..."

echo ">>> [Alpine Init] 安装基础依赖..."
apk add bash sudo nano ca-certificates git curl nodejs npm --no-cache || echo ">>> 警告: 部分包安装失败，继续..."

echo ">>> [Alpine Init] 检查安装结果..."
git --version 2>/dev/null && echo "git OK" || echo "警告: git 没装上"
node -v 2>/dev/null && echo "node OK" || echo "警告: node 没装上"
npm -v 2>/dev/null && echo "npm OK" || echo "警告: npm 没装上"

echo ">>> [Alpine Init] 配置 npm 淘宝镜像源..."
npm config set registry https://registry.npmmirror.com 2>/dev/null || true

echo ">>> [Alpine Init] 配置登录脚本..."
PROFILE_MARKER="# ALPINE_LOGIN_SETUP_DONE"
if ! grep -q "$PROFILE_MARKER" /root/.profile 2>/dev/null; then
    echo '' >> /root/.profile
    echo '# --- Alpine Login Setup ---' >> /root/.profile
    echo 'echo ">>> [Alpine] 欢迎使用辰林的酒馆环境！"' >> /root/.profile
    echo 'if [ ! -d "/root/SillyTavern" ]; then echo ">>> 克隆SillyTavern..."; cd /root && git clone https://gitee.com/mirrors/sillytavern.git SillyTavern && echo "克隆完成."; else echo ">>> SillyTavern已存在."; fi' >> /root/.profile
    echo 'if [ -d "/root/SillyTavern" ]; then echo ">>> 启动酒馆: cd ~/SillyTavern && node server.js"; fi' >> /root/.profile
    echo "$PROFILE_MARKER" >> /root/.profile
    echo ">>> [Alpine Init] 登录脚本已配置。"
else
    echo ">>> [Alpine Init] 登录脚本已存在，跳过。"
fi

echo ">>> [Alpine Init] 首次配置完成。"
EOF_ALPINE_FIRST_SETUP
)

# 用 proot -S 执行，简单粗暴
unset LD_PRELOAD
proot -S "${ALPINE_FS_DIR}" -b "$PREFIX/etc/resolv.conf:/etc/resolv.conf" /bin/ash -c "$ALPINE_FIRST_SETUP_COMMANDS"
if [ $? -ne 0 ]; then
    echo ">>> 警告: Alpine 首次配置可能部分失败，但继续..."
fi
echo ">>> [Termux] Alpine 内部首次配置完成。"

# --- 配置Termux自动启动 ---
AUTO_START_SCRIPT_DIR="$PREFIX/etc/profile.d"
AUTO_START_SCRIPT_FILE="$AUTO_START_SCRIPT_DIR/auto_custom_alpine.sh"
echo ">>> [Termux] 配置自动启动脚本..."
mkdir -p "$AUTO_START_SCRIPT_DIR"
cat > "$AUTO_START_SCRIPT_FILE" << EOF_AUTO_START_ALPINE
#!/data/data/com.termux/files/usr/bin/bash
if [ -f "$HOME/start_alpine.sh" ] && [ ! -f "$HOME/.no-auto-alpine" ]; then
    echo "正在自动启动 Alpine..."
    "$HOME/start_alpine.sh"
fi
EOF_AUTO_START_ALPINE
chmod +x "$AUTO_START_SCRIPT_FILE"
echo ">>> [Termux] 自动启动已配置。"

# 清理
echo ">>> [Termux] 清理压缩包..."
rm -f "${ALPINE_ROOTFS_TARBALL_PATH}"

# 软链接
ALPINE_INTERNAL_ROOT="${ALPINE_FS_DIR}/root"
SYMLINK_PATH="$HOME/alpine_root_access"
if [ -d "${ALPINE_INTERNAL_ROOT}" ]; then
    rm -rf "${SYMLINK_PATH}" 2>/dev/null || true
    ln -s "${ALPINE_INTERNAL_ROOT}" "${SYMLINK_PATH}"
    echo ">>> [Termux] 软链接已创建: ${SYMLINK_PATH}"
fi

echo ""
echo "---------------------------------------------------------------------"
echo ">>> 安装完成！"
echo ">>> 手动启动: $HOME/start_alpine.sh"
echo ">>> 下次启动Termux自动进入Alpine"
echo ">>> 禁用自动启动: touch $HOME/.no-auto-alpine"
echo ">>> 进入Alpine后启动酒馆: cd ~/SillyTavern && node server.js"
echo ">>> 请重启Termux使自动启动生效"
echo ">>> 该脚本由辰林制作，知识产权归辰林所有"
echo "---------------------------------------------------------------------"

exit 0
