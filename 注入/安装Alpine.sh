mkdir -p "$HOME/ST_SH"
cat > "$HOME/ST_SH/安装Alpine.sh" <<'__ST_SH_INJECT_EOF__'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Simple Alpine installer for Termux.
# Goals:
# 1) Default to 64-bit.
# 2) Keep startup behavior close to the historically working script.
# 3) Keep the script easy to read.

ROOT_DIR="$HOME/alpine"
ROOTFS_DIR="$ROOT_DIR/rootfs"
TARBALL="$ROOT_DIR/alpine-rootfs.tar.gz"
LAUNCHER="$HOME/start_alpine.sh"

MIRROR_KEY="tuna"
ALLOW_32=0
NO_INIT=0
KEEP_OLD=0
USE_LATEST=1
ALPINE_SERIES="v3.20"

usage() {
  cat <<'USAGE'
用法:
  /opt/ST_SH/安装Alpine.sh [选项]

选项:
  --mirror <tuna|official|URL>  设置镜像，默认 tuna
  --series <v3.x>               指定 Alpine 大版本分支（例如 v3.20）
  --latest                      使用 latest-stable（默认）
  --allow-32                    允许 32 位设备安装（默认不允许）
  --no-init                     只安装 rootfs，不执行 apk 初始化
  --keep-old                    保留旧 rootfs，不自动备份重命名
  -h, --help                    查看帮助

示例:
  /opt/ST_SH/安装Alpine.sh
  /opt/ST_SH/安装Alpine.sh --latest
  /opt/ST_SH/安装Alpine.sh --series v3.20
  /opt/ST_SH/安装Alpine.sh --mirror official
  /opt/ST_SH/安装Alpine.sh --allow-32
USAGE
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mirror)
        [ "$#" -ge 2 ] || { echo "错误: --mirror 需要参数" >&2; exit 1; }
        MIRROR_KEY="$2"
        shift 2
        ;;
      --series)
        [ "$#" -ge 2 ] || { echo "错误: --series 需要参数" >&2; exit 1; }
        ALPINE_SERIES="$2"
        USE_LATEST=0
        shift 2
        ;;
      --latest)
        USE_LATEST=1
        shift
        ;;
      --allow-32)
        ALLOW_32=1
        shift
        ;;
      --no-init)
        NO_INIT=1
        shift
        ;;
      --keep-old)
        KEEP_OLD=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "错误: 未知参数 $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

require_termux() {
  if [ -z "${PREFIX:-}" ]; then
    echo "错误: 请在 Termux 里执行。" >&2
    exit 1
  fi
}

ensure_resolv_conf() {
  local resolv="$PREFIX/etc/resolv.conf"
  mkdir -p "$PREFIX/etc"

  if [ -s "$resolv" ]; then
    return
  fi

  {
    local key dns
    for key in net.dns1 net.dns2 net.dns3 net.dns4; do
      dns="$(getprop "$key" 2>/dev/null || true)"
      [ -n "$dns" ] && printf 'nameserver %s\n' "$dns"
    done
    # Fallback public DNS
    echo "nameserver 223.5.5.5"
    echo "nameserver 1.1.1.1"
  } | awk 'NF && !seen[$0]++' > "$resolv"
}

resolve_mirror() {
  case "$MIRROR_KEY" in
    tuna)
      MIRROR_BASE="https://mirrors.tuna.tsinghua.edu.cn/alpine"
      ;;
    official)
      MIRROR_BASE="https://dl-cdn.alpinelinux.org/alpine"
      ;;
    http://*|https://*)
      MIRROR_BASE="${MIRROR_KEY%/}"
      ;;
    *)
      echo "错误: 不支持的镜像 '$MIRROR_KEY'" >&2
      echo "可用: tuna / official / 自定义URL" >&2
      exit 1
      ;;
  esac
  if [ "$USE_LATEST" -eq 1 ]; then
    RELEASE_BRANCH="latest-stable"
    APK_BRANCH="latest-stable"
  else
    ALPINE_SERIES="${ALPINE_SERIES#v}"
    case "$ALPINE_SERIES" in
      3.*) ;;
      *)
        echo "错误: --series 只支持形如 v3.20 或 3.20" >&2
        exit 1
        ;;
    esac
    RELEASE_BRANCH="v$ALPINE_SERIES"
    APK_BRANCH="$RELEASE_BRANCH"
  fi

  APK_MAIN="$MIRROR_BASE/$APK_BRANCH/main"
  APK_COMMUNITY="$MIRROR_BASE/$APK_BRANCH/community"
}

detect_arch() {
  local raw abilist
  raw="$(uname -m 2>/dev/null || true)"
  abilist="$(getprop ro.product.cpu.abilist 2>/dev/null || true)"

  case "$raw" in
    aarch64|arm64)
      ALPINE_ARCH="aarch64"
      ;;
    x86_64|amd64)
      ALPINE_ARCH="x86_64"
      ;;
    armv7l|armv8l|armhf|arm)
      if [ "$ALLOW_32" -ne 1 ]; then
        echo "错误: 检测到32位ARM设备，默认策略不安装32位。" >&2
        echo "如需继续，请加 --allow-32" >&2
        exit 1
      fi
      ALPINE_ARCH="armv7"
      ;;
    i686|i386|x86)
      if [ "$ALLOW_32" -ne 1 ]; then
        echo "错误: 检测到32位x86设备，默认策略不安装32位。" >&2
        echo "如需继续，请加 --allow-32" >&2
        exit 1
      fi
      ALPINE_ARCH="x86"
      ;;
    *)
      # Fallback: use Android ABI string
      if printf '%s' "$abilist" | grep -qi 'arm64-v8a'; then
        ALPINE_ARCH="aarch64"
      elif printf '%s' "$abilist" | grep -qi 'x86_64'; then
        ALPINE_ARCH="x86_64"
      elif printf '%s' "$abilist" | grep -qi 'armeabi'; then
        [ "$ALLOW_32" -eq 1 ] || {
          echo "错误: 仅检测到32位ABI，默认策略不安装32位。" >&2
          echo "如需继续，请加 --allow-32" >&2
          exit 1
        }
        ALPINE_ARCH="armv7"
      elif printf '%s' "$abilist" | grep -qiE '(^|,)x86($|,)'; then
        [ "$ALLOW_32" -eq 1 ] || {
          echo "错误: 仅检测到32位ABI，默认策略不安装32位。" >&2
          echo "如需继续，请加 --allow-32" >&2
          exit 1
        }
        ALPINE_ARCH="x86"
      else
        echo "错误: 无法识别设备架构。" >&2
        echo "uname -m=$raw" >&2
        echo "abilist=$abilist" >&2
        exit 1
      fi
      ;;
  esac
}

install_deps() {
  TERMUX_PKG_NO_MIRROR_SELECT=1 pkg update -y
  TERMUX_PKG_NO_MIRROR_SELECT=1 pkg install -y proot tar curl wget fakeroot
}

prepare_dirs() {
  mkdir -p "$ROOT_DIR"
  if [ -d "$ROOTFS_DIR" ] && [ "$(ls -A "$ROOTFS_DIR" 2>/dev/null || true)" ]; then
    if [ "$KEEP_OLD" -eq 1 ]; then
      echo "错误: 检测到已有 rootfs，且你使用了 --keep-old。" >&2
      echo "为避免新旧文件混合，本次已停止。" >&2
      echo "你可以去掉 --keep-old，或手动指定新目录后再执行。" >&2
      exit 1
    fi
    local bak="$ROOT_DIR/rootfs.bak.$(date +%s)"
    mv "$ROOTFS_DIR" "$bak"
    echo "已备份旧 rootfs: $bak"
  fi
  mkdir -p "$ROOTFS_DIR"
}

pick_rootfs_url() {
  local base_url
  if [ "$RELEASE_BRANCH" = "latest-stable" ]; then
    local yaml_url
    yaml_url="$MIRROR_BASE/latest-stable/releases/$ALPINE_ARCH/latest-releases.yaml"
    ROOTFS_FILE="$(
      curl -fsSL "$yaml_url" \
        | grep -oE "alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-$ALPINE_ARCH\.tar\.gz" \
        | sort -V \
        | tail -n1
    )"
    [ -n "$ROOTFS_FILE" ] || {
      echo "错误: 无法从 $yaml_url 解析 rootfs 文件名。" >&2
      exit 1
    }
    ROOTFS_URL="$MIRROR_BASE/latest-stable/releases/$ALPINE_ARCH/$ROOTFS_FILE"
    return
  fi

  base_url="$MIRROR_BASE/$RELEASE_BRANCH/releases/$ALPINE_ARCH"
  ROOTFS_FILE="$(
    curl -fsSL "$base_url/" \
      | grep -oE "alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-$ALPINE_ARCH\.tar\.gz" \
      | sort -V \
      | tail -n1
  )"

  [ -n "$ROOTFS_FILE" ] || {
    echo "错误: 无法从 $base_url 解析 rootfs 文件名。" >&2
    exit 1
  }

  ROOTFS_URL="$base_url/$ROOTFS_FILE"
}

download_and_extract() {
  echo "下载: $ROOTFS_URL"
  wget -O "$TARBALL" "$ROOTFS_URL"

  echo "解压: $TARBALL -> $ROOTFS_DIR"
  if tar -xzf "$TARBALL" -C "$ROOTFS_DIR"; then
    :
  elif command -v fakeroot >/dev/null 2>&1; then
    echo "警告: 普通 tar 解压失败，尝试 fakeroot 解压..."
    fakeroot tar -xzf "$TARBALL" -C "$ROOTFS_DIR"
  else
    echo "错误: 解压失败且 fakeroot 不可用。" >&2
    exit 1
  fi
  rm -f "$TARBALL"
}

proot_base() {
  local use_link="${1:-1}"
  shift

  mkdir -p "$HOME/.proot-tmp"
  unset LD_PRELOAD
  export PROOT_NO_SECCOMP=1
  export PROOT_TMP_DIR="$HOME/.proot-tmp"

  if [ "$use_link" -eq 1 ]; then
    proot --link2symlink "$@"
  else
    proot "$@"
  fi
}

run_in_alpine_mode() {
  local mode="$1"
  local cmd="$2"
  local shell_bin="/bin/ash"
  local bind_shared=()
  [ -x "$ROOTFS_DIR/bin/ash" ] || shell_bin="/bin/sh"
  if [ -d "$HOME/storage/shared" ]; then
    bind_shared=(-b "$HOME/storage/shared:/mnt/sdcard")
  fi

  case "$mode" in
    legacy)
      unset LD_PRELOAD
      unset PROOT_NO_SECCOMP PROOT_TMP_DIR PROOT_L2S_DIR
      proot \
        -0 \
        --link2symlink \
        -r "$ROOTFS_DIR" \
        -w /root \
        -b /dev \
        -b /proc \
        -b /sys \
        -b /data \
        "${bind_shared[@]}" \
        -b "$ROOTFS_DIR/root:/root" \
        -b "$PREFIX/etc/resolv.conf:/etc/resolv.conf" \
        /usr/bin/env -i \
        HOME=/root \
        USER=root \
        TERM="${TERM:-xterm-256color}" \
        LANG=C.UTF-8 \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        "$shell_bin" -lc "$cmd"
      ;;
    pd-nolink)
      proot_base 0 \
        -0 \
        -L \
        --sysvipc \
        --kill-on-exit \
        --kernel-release="6.17.0-PRoot-Distro" \
        --rootfs="$ROOTFS_DIR" \
        --cwd=/ \
        --bind=/dev \
        --bind=/proc \
        --bind=/sys \
        --bind=/dev/urandom:/dev/random \
        --bind=/data \
        --bind="$PREFIX/etc/resolv.conf:/etc/resolv.conf" \
        /usr/bin/env -i \
        HOME=/root \
        USER=root \
        TERM="${TERM:-xterm-256color}" \
        LANG=C.UTF-8 \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        "$shell_bin" -lc "$cmd"
      ;;
    pd-link)
      proot_base 1 \
        -0 \
        -L \
        --sysvipc \
        --kill-on-exit \
        --kernel-release="6.17.0-PRoot-Distro" \
        --rootfs="$ROOTFS_DIR" \
        --cwd=/ \
        --bind=/dev \
        --bind=/proc \
        --bind=/sys \
        --bind=/dev/urandom:/dev/random \
        --bind=/data \
        --bind="$PREFIX/etc/resolv.conf:/etc/resolv.conf" \
        /usr/bin/env -i \
        HOME=/root \
        USER=root \
        TERM="${TERM:-xterm-256color}" \
        LANG=C.UTF-8 \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        "$shell_bin" -lc "$cmd"
      ;;
    simple-nolink)
      proot_base 0 -0 -S "$ROOTFS_DIR" \
        -w / \
        -b "$PREFIX/etc/resolv.conf:/etc/resolv.conf" \
        "$shell_bin" -lc "$cmd"
      ;;
    simple-link)
      proot_base 1 -0 -S "$ROOTFS_DIR" \
        -w / \
        -b "$PREFIX/etc/resolv.conf:/etc/resolv.conf" \
        "$shell_bin" -lc "$cmd"
      ;;
    full-nolink)
      proot_base 0 -0 -r "$ROOTFS_DIR" \
        -w / \
        -b /dev -b /proc -b /sys \
        -b /data \
        -b "$PREFIX/etc/resolv.conf:/etc/resolv.conf" \
        "$shell_bin" -lc "$cmd"
      ;;
    full-link)
      proot_base 1 -0 -r "$ROOTFS_DIR" \
        -w / \
        -b /dev -b /proc -b /sys \
        -b /data \
        -b "$PREFIX/etc/resolv.conf:/etc/resolv.conf" \
        "$shell_bin" -lc "$cmd"
      ;;
    *)
      echo "错误: 未知 proot 模式: $mode" >&2
      return 1
      ;;
  esac
}

select_proot_mode() {
  if [ -n "${PROOT_MODE_SELECTED:-}" ]; then
    return
  fi

  local probe_cmd="pwd >/dev/null 2>&1 && cd / >/dev/null 2>&1 && cd .. >/dev/null 2>&1 && test -d /etc"
  local basic_probe_cmd="test -d /etc"
  for mode in legacy full-nolink simple-nolink full-link simple-link pd-nolink pd-link; do
    if run_in_alpine_mode "$mode" "$probe_cmd" >/dev/null 2>&1; then
      PROOT_MODE_SELECTED="$mode"
      echo "proot 模式: $PROOT_MODE_SELECTED"
      return
    fi
  done

  for mode in legacy full-nolink simple-nolink full-link simple-link pd-nolink pd-link; do
    if run_in_alpine_mode "$mode" "$basic_probe_cmd" >/dev/null 2>&1; then
      PROOT_MODE_SELECTED="$mode"
      echo "警告: proot 严格预检失败，降级使用模式: $PROOT_MODE_SELECTED"
      return
    fi
  done

  PROOT_MODE_SELECTED="legacy"
  echo "警告: proot 预检全部失败，强制兜底模式: $PROOT_MODE_SELECTED" >&2
}

run_in_alpine() {
  local cmd="$1"
  select_proot_mode
  run_in_alpine_mode "$PROOT_MODE_SELECTED" "$cmd"
}

init_alpine() {
  local marker="/etc/.st_alpine_init_done"
  if [ "$NO_INIT" -eq 1 ]; then
    echo "跳过初始化 (--no-init)"
    return
  fi

  if run_in_alpine "[ -f $marker ]"; then
    echo "已初始化过，跳过 apk 初始化。"
    return
  fi

  local init_cmd
  init_cmd="$(cat <<EOF
set -e
echo "$APK_MAIN" > /etc/apk/repositories
echo "$APK_COMMUNITY" >> /etc/apk/repositories
apk update
apk add --no-cache bash ca-certificates curl wget git
touch $marker
EOF
)"
  if run_in_alpine "$init_cmd"; then
    return
  fi

  # Some devices fail with one proot mode during post-install scripts.
  # Retry with alternative modes before giving up.
  for mode in legacy full-nolink simple-nolink full-link simple-link pd-nolink pd-link; do
    if [ "${PROOT_MODE_SELECTED:-}" = "$mode" ]; then
      continue
    fi
    echo "警告: 初始化失败，切换 proot 模式重试: $mode"
    PROOT_MODE_SELECTED="$mode"
    if run_in_alpine "$init_cmd"; then
      return
    fi
  done

  local init_cmd_no_scripts
  init_cmd_no_scripts="$(cat <<EOF
set -e
echo "$APK_MAIN" > /etc/apk/repositories
echo "$APK_COMMUNITY" >> /etc/apk/repositories
apk update
apk add --no-cache --no-scripts bash ca-certificates curl wget git
touch $marker
EOF
)"

  echo "警告: 常规初始化失败，尝试 --no-scripts 兼容模式..."
  for mode in legacy full-nolink simple-nolink full-link simple-link pd-nolink pd-link; do
    echo "警告: --no-scripts 模式尝试: $mode"
    PROOT_MODE_SELECTED="$mode"
    if run_in_alpine "$init_cmd_no_scripts"; then
      echo "警告: 已使用 --no-scripts 完成初始化。"
      return
    fi
  done

  return 1
}

write_launcher() {
  cat > "$LAUNCHER" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

ROOT="$HOME/alpine/rootfs"
if [ ! -d "$ROOT" ]; then
  echo "错误: 未找到 $ROOT" >&2
  exit 1
fi

TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
RESOLV="$TERMUX_PREFIX/etc/resolv.conf"
if [ ! -s "$RESOLV" ]; then
  mkdir -p "$TERMUX_PREFIX/etc"
  printf 'nameserver 223.5.5.5\nnameserver 1.1.1.1\n' > "$RESOLV"
fi

SHELL_INNER="/bin/ash"
[ -x "$ROOT/bin/ash" ] || SHELL_INNER="/bin/sh"

mkdir -p "$HOME/.proot-tmp"
unset LD_PRELOAD
export PROOT_NO_SECCOMP=1
export PROOT_TMP_DIR="$HOME/.proot-tmp"

BIND_SHARED=()
if [ -d "$HOME/storage/shared" ]; then
  BIND_SHARED=(-b "$HOME/storage/shared:/mnt/sdcard")
fi

run_launcher_legacy() {
  local use_link="$1"
  local link_args=()
  if [ "$use_link" = "1" ]; then
    link_args=(--link2symlink)
  fi

  unset LD_PRELOAD
  unset PROOT_NO_SECCOMP PROOT_TMP_DIR PROOT_L2S_DIR

  proot \
    -0 \
    "${link_args[@]}" \
    -r "$ROOT" \
    -w /root \
    -b /dev \
    -b /proc \
    -b /sys \
    -b /data \
    "${BIND_SHARED[@]}" \
    -b "$ROOT/root:/root" \
    -b "$RESOLV:/etc/resolv.conf" \
    /usr/bin/env -i \
    HOME=/root \
    USER=root \
    TERM="${TERM:-xterm-256color}" \
    LANG=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    "$SHELL_INNER" --login
}

run_launcher_full() {
  local use_link="$1"
  local link_args=()
  if [ "$use_link" = "1" ]; then
    link_args=(--link2symlink)
  fi

  proot \
    -0 \
    "${link_args[@]}" \
    -r "$ROOT" \
    -w / \
    -b /dev \
    -b /proc \
    -b /sys \
    -b /data \
    "${BIND_SHARED[@]}" \
    -b "$RESOLV:/etc/resolv.conf" \
    /usr/bin/env -i \
    HOME=/root \
    TERM="${TERM:-xterm-256color}" \
    LANG=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    "$SHELL_INNER" --login
}

run_launcher_pd() {
  local use_link="$1"
  local link_args=()
  if [ "$use_link" = "1" ]; then
    link_args=(--link2symlink)
  fi

  proot \
    -0 \
    -L \
    --sysvipc \
    --kill-on-exit \
    --kernel-release="6.17.0-PRoot-Distro" \
    "${link_args[@]}" \
    --rootfs="$ROOT" \
    --cwd=/ \
    --bind=/dev \
    --bind=/proc \
    --bind=/sys \
    --bind=/dev/urandom:/dev/random \
    --bind=/data \
    "${BIND_SHARED[@]}" \
    --bind="$RESOLV:/etc/resolv.conf" \
    /usr/bin/env -i \
    HOME=/root \
    USER=root \
    TERM="${TERM:-xterm-256color}" \
    LANG=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    "$SHELL_INNER" --login
}

run_launcher_simple() {
  local use_link="$1"
  local link_args=()
  if [ "$use_link" = "1" ]; then
    link_args=(--link2symlink)
  fi

  proot \
    -0 \
    "${link_args[@]}" \
    -S "$ROOT" \
    -w / \
    -b "$RESOLV:/etc/resolv.conf" \
    /usr/bin/env -i \
    HOME=/root \
    TERM="${TERM:-xterm-256color}" \
    LANG=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    "$SHELL_INNER" --login
}

if [ "${ALPINE_PROOT_FORCE_SIMPLE:-0}" = "1" ]; then
  run_launcher_simple 0
  exit $?
fi

if [ "${ALPINE_PROOT_FORCE_LEGACY:-0}" = "1" ]; then
  run_launcher_legacy 1
  exit $?
fi

if [ "${ALPINE_PROOT_FORCE_PD:-0}" = "1" ]; then
  echo "警告: PD 模式在部分机型会导致 cwd 异常（localhost:#）。"
  echo "警告: 若出现 cd Function not implemented，请改用 ALPINE_PROOT_FORCE_LEGACY=1。"
  run_launcher_pd 0 || run_launcher_legacy 1
  exit $?
fi

if run_launcher_legacy 1; then
  exit 0
fi

if run_launcher_legacy 0; then
  exit 0
fi

if run_launcher_full 0; then
  exit 0
fi

echo "警告: 标准启动失败，切换到最小 proot(-S) 模式重试..."
if run_launcher_simple 0; then
  exit 0
fi

if run_launcher_pd 0; then
  exit 0
fi

if [ "${ALPINE_PROOT_USE_LINK2SYMLINK:-0}" = "1" ]; then
  echo "警告: 尝试启用 --link2symlink 进行最后重试..."
  run_launcher_legacy 1 || run_launcher_pd 1 || run_launcher_full 1 || run_launcher_simple 1
  exit $?
fi

exit 1
EOF
  chmod +x "$LAUNCHER"
}

main() {
  require_termux
  parse_args "$@"
  resolve_mirror
  detect_arch

  echo "架构: $ALPINE_ARCH"
  echo "镜像: $MIRROR_BASE"
  echo "Alpine 分支: $RELEASE_BRANCH"

  ensure_resolv_conf
  install_deps
  prepare_dirs
  pick_rootfs_url
  download_and_extract
  write_launcher
  if ! init_alpine; then
    echo "警告: Alpine 初始化失败，可稍后手动执行:"
    echo "  ~/start_alpine.sh"
    echo "  apk update"
    echo "  apk add --no-cache bash ca-certificates curl wget git"
  fi

  echo "安装完成。"
  echo "启动 Alpine: $LAUNCHER"
}

main "$@"
__ST_SH_INJECT_EOF__
chmod +x "$HOME/ST_SH/安装Alpine.sh"
echo '已写入: $HOME/ST_SH/安装Alpine.sh'
