#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  /opt/ST_SH/换源.sh [源名|URL] [--update|--upgrade]
  /opt/ST_SH/换源.sh --list

预置源:
  cf          -> Cloudflare CDN (官方加速)
  official    -> 官方源 packages.termux.dev
  iscas       -> 中科院软件所
  aliyun      -> 阿里云
  tuna        -> 清华 TUNA
  ustc        -> 中科大 USTC
  bfsu        -> 北外开源镜像站
  nju         -> 南京大学镜像站
  sjtu        -> 上海交大 SJTUG
  asia        -> 亚洲源 (TWDS, 台湾)
  us          -> 美国源 (FCIX, California)

示例:
  /opt/ST_SH/换源.sh aliyun
  /opt/ST_SH/换源.sh aliyun --update
  /opt/ST_SH/换源.sh aliyun --upgrade
USAGE
}

list_mirrors() {
  cat <<'LIST'
cf=https://packages-cf.termux.dev/apt
official=https://packages.termux.dev/apt
iscas=https://mirror.iscas.ac.cn/termux/apt
aliyun=https://mirrors.aliyun.com/termux
tuna=https://mirrors.tuna.tsinghua.edu.cn/termux/apt
ustc=https://mirrors.ustc.edu.cn/termux
bfsu=https://mirrors.bfsu.edu.cn/termux
nju=https://mirrors.nju.edu.cn/termux
sjtu=https://mirrors.sjtug.sjtu.edu.cn/termux
asia=https://mirror.twds.com.tw/termux
us=https://mirror.fcix.net/termux
LIST
}

resolve_mirror() {
  case "$1" in
    cf|cloudflare) echo "https://packages-cf.termux.dev/apt" ;;
    official|main) echo "https://packages.termux.dev/apt" ;;
    iscas) echo "https://mirror.iscas.ac.cn/termux/apt" ;;
    aliyun|ali) echo "https://mirrors.aliyun.com/termux" ;;
    tuna|tsinghua|thu) echo "https://mirrors.tuna.tsinghua.edu.cn/termux/apt" ;;
    ustc|zkd) echo "https://mirrors.ustc.edu.cn/termux" ;;
    bfsu) echo "https://mirrors.bfsu.edu.cn/termux" ;;
    nju) echo "https://mirrors.nju.edu.cn/termux" ;;
    sjtu) echo "https://mirrors.sjtug.sjtu.edu.cn/termux" ;;
    asia) echo "https://mirror.twds.com.tw/termux" ;;
    us|usa) echo "https://mirror.fcix.net/termux" ;;
    http://*|https://*) echo "${1%/}" ;;
    *)
      echo "未知源: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
}

if [ -z "${PREFIX:-}" ]; then
  echo "错误: 不是 Termux 环境（PREFIX 为空）" >&2
  exit 1
fi

MIRROR_KEY="cf"
DO_UPDATE=0
DO_UPGRADE=0

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --list)
      list_mirrors
      exit 0
      ;;
    --update)
      DO_UPDATE=1
      ;;
    --upgrade)
      DO_UPGRADE=1
      ;;
    *)
      MIRROR_KEY="$arg"
      ;;
  esac
done

MIRROR_BASE="$(resolve_mirror "$MIRROR_KEY")"
APT_DIR="$PREFIX/etc/apt"
mkdir -p "$APT_DIR/sources.list.d"

MAIN_URI="$MIRROR_BASE/termux-main"
ROOT_URI="$MIRROR_BASE/termux-root"
X11_URI="$MIRROR_BASE/termux-x11"

if [ -f "$APT_DIR/sources.list.d/main.sources" ]; then
  sed -i -E "s|^[[:space:]]*URIs:[[:space:]]*.*$|URIs: $MAIN_URI|" "$APT_DIR/sources.list.d/main.sources"
else
  printf 'deb %s stable main\n' "$MAIN_URI" > "$APT_DIR/sources.list"
fi

if [ -f "$APT_DIR/sources.list.d/root.sources" ]; then
  sed -i -E "s|^[[:space:]]*URIs:[[:space:]]*.*$|URIs: $ROOT_URI|" "$APT_DIR/sources.list.d/root.sources"
elif [ -f "$APT_DIR/sources.list.d/root.list" ]; then
  printf 'deb %s root stable\n' "$ROOT_URI" > "$APT_DIR/sources.list.d/root.list"
fi

if [ -f "$APT_DIR/sources.list.d/x11.sources" ]; then
  sed -i -E "s|^[[:space:]]*URIs:[[:space:]]*.*$|URIs: $X11_URI|" "$APT_DIR/sources.list.d/x11.sources"
elif [ -f "$APT_DIR/sources.list.d/x11.list" ]; then
  printf 'deb %s x11 main\n' "$X11_URI" > "$APT_DIR/sources.list.d/x11.list"
fi

# Lock mirror for pkg to avoid random mirror probing/rotation.
TERMUX_CFG="$PREFIX/etc/termux"
mkdir -p "$TERMUX_CFG"
cat > "$TERMUX_CFG/chosen_mirrors" <<EOF
MAIN=$MAIN_URI
ROOT=$ROOT_URI
X11=$X11_URI
WEIGHT=100
EOF

echo "已切换到: $MIRROR_BASE"
echo "当前 main 源:"
if [ -f "$APT_DIR/sources.list.d/main.sources" ]; then
  grep -m1 -E '^[[:space:]]*URIs:[[:space:]]+' "$APT_DIR/sources.list.d/main.sources" || true
elif [ -f "$APT_DIR/sources.list" ]; then
  cat "$APT_DIR/sources.list"
fi

if [ "$DO_UPDATE" -eq 1 ] && [ "$DO_UPGRADE" -eq 1 ]; then
  echo "错误: --update 和 --upgrade 不能同时使用。" >&2
  echo "请先运行: /opt/ST_SH/换源.sh <源> --update" >&2
  echo "再运行: /opt/ST_SH/换源.sh <源> --upgrade" >&2
  exit 1
fi

if [ "$DO_UPDATE" -eq 1 ]; then
  TERMUX_PKG_NO_MIRROR_SELECT=1 pkg update -y
elif [ "$DO_UPGRADE" -eq 1 ]; then
  TERMUX_PKG_NO_MIRROR_SELECT=1 pkg upgrade -y
else
  echo "已完成切源。"
  echo "下一步请单独执行："
  echo "  ~/ST_SH/换源.sh $MIRROR_KEY --update"
  echo "  ~/ST_SH/换源.sh $MIRROR_KEY --upgrade"
fi
