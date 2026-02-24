mkdir -p "$HOME/ST_SH"
cat > "$HOME/ST_SH/权限获取.sh" <<'__ST_SH_INJECT_EOF__'
termux-setup-storage

cd ~/storage/shared

mkdir bakdata_of_chengming_termux

__ST_SH_INJECT_EOF__
chmod +x "$HOME/ST_SH/权限获取.sh"
echo '已写入: $HOME/ST_SH/权限获取.sh'
