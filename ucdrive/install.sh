#!/usr/bin/env bash
# ucdrive skill installer — sets up the CLI on macOS.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v node >/dev/null 2>&1 || { echo "❌ 需要 Node.js >= 20（未检测到 node）。先安装：https://nodejs.org"; exit 1; }
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
[ "$NODE_MAJOR" -ge 20 ] || { echo "❌ Node.js 版本过低（$(node -v)），需要 >= 20（内置 WebSocket）"; exit 1; }

mkdir -p "$HOME/bin"
# Launcher resolves the skill folder dynamically so the repo can live anywhere.
cat > "$HOME/bin/ucdrive" <<LAUNCH
#!/bin/bash
exec node "$DIR/cli.mjs" "\$@"
LAUNCH
chmod +x "$HOME/bin/ucdrive"

case ":$PATH:" in
  *":$HOME/bin:"*) ;;
  *) echo "⚠️  $HOME/bin 不在 PATH 里。请把下面这行加进 ~/.zshrc 或 ~/.bashrc 后重开终端："
     echo "   export PATH=\"\$HOME/bin:\$PATH\""
     ;;
esac

echo "✅ ucdrive 安装完成：$HOME/bin/ucdrive"
echo "下一步：打开 UC 浏览器的网盘页面（能看到文件列表），然后运行:"
echo "  ucdrive login"
echo "验证:"
echo "  ucdrive whoami && ucdrive list /"
