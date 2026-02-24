#!/data/data/com.termux/files/usr/bin/bash
#
# 辰林的酒馆自动安装脚本
# Termux + PRoot + Alpine Linux + SillyTavern
# 知识产权归辰林所有
#

set -e

# ========== 全局变量 ==========
ALPINE_FS_DIR="$HOME/alpine_manual_fs"
ALPINE_ROOTFS_TARBALL="$HOME/alpine_latest_rootfs.tar.gz"
START_SCRIPT="$HOME/start_alpine.sh"
RESOLV_CONF="$PREFIX/etc/resolv.conf"
AUTO_START_FILE="$PREFIX/etc/profile.d/auto_custom_alpine.sh"
SYMLINK_PATH="$HOME/alpine_root_access"
TUNA_ALPINE="https://mirrors.tuna.tsinghua.edu.cn/alpine"
FALLBACK_VERSION="3.20.3"

# ========== 日志函数 ==========
log_info()  { echo ">>> [INFO]  $*"; }
log_warn()  { echo ">>> [WARN]  $*"; }
log_error() { echo ">>> [ERROR] $*"; exit 1; }

# ========== 显示欢迎 ==========
show_banner() {
    cat << 'BANNER'

  辰林的酒馆自动安装脚本
  基于 Termux + PRoot + Alpine Linux
  GPLv3 许可，可商用
  如需使用请购买密钥
  盗版出了问题别找我

BANNER
    echo ">>> 本脚本会安装 64 位 Alpine Linux 并通过 PRoot 运行 SillyTavern"
    echo ">>> 不需要梯子！开了梯子反而会出问题！"
    echo ""
    read -rp "确认没有开梯子后按回车继续..."
}

# ========== Termux 环境准备 ==========
setup_termux() {
    log_info "更新 Termux 软件包..."
    yes | pkg update
    yes | pkg upgrade

    log_info "安装 Termux 依赖..."
    pkg install -y proot git curl tar wget fakeroot coreutils sed gawk findutils xz-utils gzip \
        || log_error "Termux 依赖安装失败"

    for cmd in curl wget proot tar git fakeroot; do
        command -v "$cmd" >/dev/null 2>&1 || log_error "命令 $cmd 未找到"
    done
    log_info "命令检查通过。"
}

# ========== 确保 DNS 配置 ==========
ensure_resolv_conf() {
    if [ ! -f "$RESOLV_CONF" ]; then
        log_info "创建 resolv.conf..."
        mkdir -p "$(dirname "$RESOLV_CONF")"
        printf "nameserver 8.8.8.8\nnameserver 8.8.4.4\n" > "$RESOLV_CONF"
    fi
}

# ========== 获取 Alpine 下载链接 ==========
resolve_alpine_url() {
    log_info "从清华源获取最新 Alpine aarch64 Mini RootFS..."

    local yaml_tmp="$HOME/.alpine_releases.yaml.tmp"
    ALPINE_ROOTFS_URL=""

    if curl -LfS --connect-timeout 15 \
        "${TUNA_ALPINE}/latest-stable/releases/aarch64/latest-releases.yaml" \
        -o "$yaml_tmp" 2>/dev/null && [ -s "$yaml_tmp" ]; then

        local filename
        filename=$(grep -o 'alpine-minirootfs-[0-9.]*-aarch64\.tar\.gz' "$yaml_tmp" | head -n1)
        if [ -n "$filename" ]; then
            ALPINE_ROOTFS_URL="${TUNA_ALPINE}/latest-stable/releases/aarch64/${filename}"
            log_info "解析到: $filename"
        fi
    fi
    rm -f "$yaml_tmp"

    if [ -z "$ALPINE_ROOTFS_URL" ]; then
        log_warn "无法自动获取最新版本，使用预设 v${FALLBACK_VERSION}"
        ALPINE_ROOTFS_URL="${TUNA_ALPINE}/v${FALLBACK_VERSION%.*}/releases/aarch64/alpine-minirootfs-${FALLBACK_VERSION}-aarch64.tar.gz"
    fi
    log_info "下载地址: $ALPINE_ROOTFS_URL"
}

# ========== 下载并解压 Alpine ==========
download_and_extract() {
    log_info "清理旧文件..."
    rm -rf "$ALPINE_FS_DIR"
    rm -f "$ALPINE_ROOTFS_TARBALL"
    mkdir -p "$ALPINE_FS_DIR"

    log_info "下载 Alpine RootFS..."
    if ! wget --progress=bar:force --tries=3 --timeout=60 "$ALPINE_ROOTFS_URL" -O "$ALPINE_ROOTFS_TARBALL"; then
        log_error "下载失败，请检查网络"
    fi

    log_info "解压 Alpine RootFS..."
    if ! fakeroot tar -xzf "$ALPINE_ROOTFS_TARBALL" -C "$ALPINE_FS_DIR"; then
        log_error "解压失败，文件可能损坏"
    fi

    if [ ! -x "$ALPINE_FS_DIR/bin/busybox" ]; then
        log_error "未找到 busybox，解压不完整"
    fi
    log_info "解压验证通过。"
}

# ========== 创建启动脚本 ==========
create_start_script() {
    log_info "创建启动脚本: $START_SCRIPT"

    cat > "$START_SCRIPT" << EOF_START
#!/data/data/com.termux/files/usr/bin/bash
echo "正在启动 Alpine Linux..."
unset LD_PRELOAD

BIND_SHARED=""
if [ -d "\$HOME/storage/shared" ]; then
    BIND_SHARED="-b \$HOME/storage/shared:/mnt/sdcard"
fi

exec proot \\
    -0 \\
    --link2symlink \\
    -r "${ALPINE_FS_DIR}" \\
    -w /root \\
    -b /dev \\
    -b /proc \\
    -b /sys \\
    -b /data \\
    \${BIND_SHARED} \\
    -b "${ALPINE_FS_DIR}/root:/root" \\
    -b "${RESOLV_CONF}:/etc/resolv.conf" \\
    /usr/bin/env -i \\
    HOME=/root \\
    TERM="\$TERM" \\
    LANG=C.UTF-8 \\
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \\
    /bin/ash --login
EOF_START

    chmod +x "$START_SCRIPT"
    log_info "启动脚本已创建。"
}

# ========== Alpine 内部首次配置 ==========
configure_alpine() {
    log_info "开始 Alpine 内部首次配置..."

    local setup_commands
    setup_commands=$(cat <<'EOF_SETUP'
set +e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo ">>> [Alpine] 配置 APK 镜像源..."
mkdir -p /etc/apk
cat > /etc/apk/repositories << 'REPO'
https://mirrors.tuna.tsinghua.edu.cn/alpine/latest-stable/main
https://mirrors.tuna.tsinghua.edu.cn/alpine/latest-stable/community
REPO

echo ">>> [Alpine] 更新 APK 索引..."
mkdir -p /var/cache/apk /lib/apk/db /var/lib/apk
apk update || echo ">>> apk update 有警告，继续..."

echo ">>> [Alpine] 安装软件包..."
apk add --no-cache bash sudo nano ca-certificates git curl nodejs npm \
    || echo ">>> 部分包可能安装失败，继续..."

echo ">>> [Alpine] 安装检查:"
for cmd in git node npm; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "  OK: $cmd ($($cmd --version 2>/dev/null || $cmd -v 2>/dev/null))"
    else
        echo "  FAIL: $cmd 未安装"
    fi
done

echo ">>> [Alpine] 配置 npm 镜像源..."
npm config set registry https://registry.npmmirror.com 2>/dev/null || true

MARKER="# CHENLIN_TAVERN_SETUP"
if ! grep -q "$MARKER" /root/.profile 2>/dev/null; then
    cat >> /root/.profile << 'PROFILE'

# --- 辰林酒馆登录脚本 ---

# ========== 自定义进度条函数 ==========
show_progress() {
    local label="$1"
    local target_dir="$2"
    local est_size_mb="$3"
    local bg_pid="$4"
    local bar_width=40
    local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local spin_len=${#spin_chars}
    local spin_idx=0
    local start_time=$(date +%s)

    while kill -0 "$bg_pid" 2>/dev/null; do
        local current_kb=0
        if [ -d "$target_dir" ]; then
            current_kb=$(du -sk "$target_dir" 2>/dev/null | cut -f1)
        fi
        local current_mb=$((current_kb / 1024))

        local pct=0
        if [ "$est_size_mb" -gt 0 ]; then
            pct=$((current_mb * 100 / est_size_mb))
        fi
        if [ "$pct" -gt 99 ]; then
            pct=99
        fi

        local now=$(date +%s)
        local elapsed=$((now - start_time))
        local mins=$((elapsed / 60))
        local secs=$((elapsed % 60))
        local time_str=$(printf "%02d:%02d" "$mins" "$secs")

        local filled=$((pct * bar_width / 100))
        local empty=$((bar_width - filled))
        local bar=""
        local i=0
        while [ "$i" -lt "$filled" ]; do
            bar="${bar}█"
            i=$((i + 1))
        done
        i=0
        while [ "$i" -lt "$empty" ]; do
            bar="${bar}░"
            i=$((i + 1))
        done

        local spin_char=$(echo "$spin_chars" | cut -c$((spin_idx + 1)))
        spin_idx=$(( (spin_idx + 1) % spin_len ))

        printf "\r  %s %s │%s│ %3d%% %dMB/%dMB %s " \
            "$spin_char" "$label" "$bar" "$pct" "$current_mb" "$est_size_mb" "$time_str"

        sleep 0.5
    done

    wait "$bg_pid"
    local exit_code=$?

    local final_kb=0
    if [ -d "$target_dir" ]; then
        final_kb=$(du -sk "$target_dir" 2>/dev/null | cut -f1)
    fi
    local final_mb=$((final_kb / 1024))
    local now=$(date +%s)
    local elapsed=$((now - start_time))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))
    local time_str=$(printf "%02d:%02d" "$mins" "$secs")

    if [ "$exit_code" -eq 0 ]; then
        local full_bar=""
        local i=0
        while [ "$i" -lt "$bar_width" ]; do
            full_bar="${full_bar}█"
            i=$((i + 1))
        done
        printf "\r  ✓ %s │%s│ 100%% %dMB %s    \n" \
            "$label" "$full_bar" "$final_mb" "$time_str"
    else
        printf "\r  ✗ %s 失败 (退出码: %d) %s    \n" \
            "$label" "$exit_code" "$time_str"
    fi

    return $exit_code
}

cat << 'WELCOME'

=====================================================================
  辰林的酒馆环境
  首次进入会自动克隆 SillyTavern 并安装依赖
=====================================================================

WELCOME

# 克隆 SillyTavern（如果不存在）
if [ ! -d "/root/SillyTavern" ]; then
    echo ">>> 正在克隆 SillyTavern 仓库..."
    echo ""

    cd /root
    git clone --quiet https://gitee.com/mirrors/sillytavern.git SillyTavern > /tmp/git_clone.log 2>&1 &
    CLONE_PID=$!

    if ! show_progress "克隆仓库" "/root/SillyTavern" 200 "$CLONE_PID"; then
        echo ""
        echo ">>> Gitee 克隆失败，尝试 GitHub..."
        rm -rf /root/SillyTavern 2>/dev/null
        echo ""

        git clone --quiet https://github.com/SillyTavern/SillyTavern.git SillyTavern > /tmp/git_clone.log 2>&1 &
        CLONE_PID=$!

        if ! show_progress "克隆仓库(GitHub)" "/root/SillyTavern" 200 "$CLONE_PID"; then
            echo ""
            cat << 'CLONE_FAIL'
=====================================================================
  克隆失败！请手动执行以下命令:

  git clone https://gitee.com/mirrors/sillytavern.git SillyTavern
=====================================================================
CLONE_FAIL
        fi
    fi
fi

# 安装依赖（如果没装过）
if [ -d "/root/SillyTavern" ] && [ ! -d "/root/SillyTavern/node_modules" ]; then
    echo ""
    echo ">>> 正在安装 SillyTavern 依赖..."
    echo ""

    cd /root/SillyTavern
    npm install --no-audit --no-fund --loglevel=silent > /tmp/npm_install.log 2>&1 &
    NPM_PID=$!

    if ! show_progress "安装依赖" "/root/SillyTavern/node_modules" 150 "$NPM_PID"; then
        echo ""
        echo ">>> npm install 失败，最后 20 行日志:"
        tail -20 /tmp/npm_install.log 2>/dev/null
        echo ""
        cat << 'NPM_FAIL'
=====================================================================
  依赖安装失败！请手动执行以下命令:

  cd ~/SillyTavern && npm install
=====================================================================
NPM_FAIL
    fi
fi

# 提示启动命令
if [ -d "/root/SillyTavern" ]; then
    cat << 'READY'

=====================================================================
  SillyTavern 已就绪！

  启动酒馆:   cd ~/SillyTavern && node server.js
  浏览器打开:  http://localhost:8000

  酒馆更新在设置启动按钮后在主页更新
  由于使用镜像源，更新可能有延迟

  该脚本由辰林制作，知识产权归辰林所有
=====================================================================

READY
else
    cat << 'NOT_FOUND'

=====================================================================
  SillyTavern 未找到，请手动安装:

  git clone https://gitee.com/mirrors/sillytavern.git SillyTavern
  cd SillyTavern && npm install && npm start

  该脚本由辰林制作，知识产权归辰林所有
=====================================================================

NOT_FOUND
fi
PROFILE
    echo "$MARKER" >> /root/.profile
fi

echo ">>> [Alpine] 首次配置完成！"
EOF_SETUP
)

    unset LD_PRELOAD
    proot \
        -0 \
        --link2symlink \
        -r "$ALPINE_FS_DIR" \
        -w /root \
        -b /dev \
        -b /proc \
        -b /sys \
        -b "$RESOLV_CONF:/etc/resolv.conf" \
        /usr/bin/env -i \
        HOME=/root \
        TERM="$TERM" \
        LANG=C.UTF-8 \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        /bin/ash -c "$setup_commands"

    log_info "Alpine 内部配置已执行。"
}

# ========== 配置自动启动 ==========
setup_autostart() {
    log_info "配置自动启动..."
    mkdir -p "$(dirname "$AUTO_START_FILE")"

    cat > "$AUTO_START_FILE" << 'EOF_AUTO'
#!/data/data/com.termux/files/usr/bin/bash
if [ -f "$HOME/start_alpine.sh" ] && [ ! -f "$HOME/.no-auto-alpine" ]; then
    echo "自动启动 Alpine... (创建 ~/.no-auto-alpine 可禁用)"
    "$HOME/start_alpine.sh"
fi
EOF_AUTO

    chmod +x "$AUTO_START_FILE"
    log_info "自动启动已配置。"
}

# ========== 收尾清理 ==========
cleanup_and_finish() {
    log_info "清理下载文件..."
    rm -f "$ALPINE_ROOTFS_TARBALL"

    if [ -d "$ALPINE_FS_DIR/root" ]; then
        rm -rf "$SYMLINK_PATH" 2>/dev/null || true
        ln -s "$ALPINE_FS_DIR/root" "$SYMLINK_PATH"
        log_info "软链接: $SYMLINK_PATH → Alpine /root"
    fi

    cat << DONE

=====================================================================
  安装完成！

  手动启动 Alpine:  $START_SCRIPT
  首次进入 Alpine 会自动克隆 SillyTavern 并安装依赖
  启动酒馆 (进入Alpine后):  cd ~/SillyTavern && node server.js
  浏览器访问:  http://localhost:8000

  下次打开 Termux 会自动进入 Alpine
  禁用自动启动:  touch ~/.no-auto-alpine
  重新启用:      rm ~/.no-auto-alpine

  请重启 Termux 使自动启动生效

  酒馆更新在设置启动按钮后在主页更新
  由于使用镜像源，更新可能有延迟

  该脚本由辰林制作，知识产权归辰林所有
=====================================================================
DONE
}

# ========== 主流程 ==========
main() {
    show_banner
    setup_termux
    ensure_resolv_conf
    resolve_alpine_url
    download_and_extract
    create_start_script
    configure_alpine
    setup_autostart
    cleanup_and_finish
}

main
exit 0
