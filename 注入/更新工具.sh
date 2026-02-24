mkdir -p "$HOME/ST_SH"
cat > "$HOME/ST_SH/更新工具.sh" <<'__ST_SH_INJECT_EOF__'
pkg update -y
pkg upgrade -y

pkg install -y git proot tar wget curl

pkg install -y nodejs-lts
__ST_SH_INJECT_EOF__
chmod +x "$HOME/ST_SH/更新工具.sh"
echo '已写入: $HOME/ST_SH/更新工具.sh'
