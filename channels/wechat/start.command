#!/bin/zsh
# Start an explicitly selected chat in the current user's graphical session.
set -eu
umask 077
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
runner="$repo_root/.venv/bin/context-hub-wechat"
helper="$repo_root/channels/wechat/ocr/.build/release/wechat-ocr"
if [[ ! -x "$runner" || ! -x "$helper" ]]; then
  echo "请先按 channels/wechat/README.md 的安装步骤构建采集工具。"
  exit 1
fi
read -r 'chat_title?请输入微信中完整、可区分的会话标题（含可见的群人数）> '
[[ -n "$chat_title" ]] || exit 1
read -r 'account_alias?当前账号的本地别名 [personal]> '
read -r 'chat_id?会话标识（有 WeFlow 历史时填 session.accountId，否则回车使用标题）> '
account_alias=${account_alias:-personal}
chat_id=${chat_id:-$chat_title}
hub_dir=${HUB_DATA_DIR:-"$HOME/Library/Application Support/Context Hub"}
capture_dir=$(mktemp -d -t wechat-calibration)
trap 'rm -f "$capture_dir/layout.json"; rmdir "$capture_dir"' EXIT
permission=$("$helper" request-permission)
if [[ "$permission" != *'"status":"ok"'* ]]; then
  echo "请在系统设置中允许屏幕录制，按系统提示重开终端，再启动此工具。"
  exit 1
fi
echo "现在切到目标微信会话。听提示依次将鼠标停在标题左上、右下，再停在消息区域左上、右下。"
echo "避开侧栏、输入框和草稿。同名会话请先设置唯一可见名称。"
"$helper" calibrate > "$capture_dir/layout.json"
if ! "$repo_root/.venv/bin/python" -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["status"] != "ok")' "$capture_dir/layout.json"; then
  echo "未完成校准。请保持目标窗口在前台，再次运行。"
  exit 1
fi
echo "已开始。每 15 秒采样，每 5 分钟将本会话导出到 $hub_dir/WeChat Exports。回到终端按 Ctrl-C 停止。"
"$runner" watch --data-dir "$hub_dir" --account "$account_alias" --conversation "$chat_id" --title "$chat_title" \
  --helper "$helper" --calibration "$capture_dir/layout.json" --export-dir "$hub_dir/WeChat Exports"
