---
name: ucdrive
description: 操作本机 UC 网盘（UC Browser 云盘）：列目录/搜索/新建/重命名/移动/删除/上传/下载/回收站/配额。当用户提到 UC 网盘、UC 云盘、网盘文件整理、云盘上传下载，或要求对 uc.cn 云端文件做任何操作时使用。通过 ucdrive CLI 执行，无需打开 UC 浏览器。
---

# UC 网盘 CLI (ucdrive)

对 UC 网盘的一切操作都通过 Bash 调用 `ucdrive` 命令完成。输出是 JSON；错误在 stderr，形如 `{"error":{"code","message","hint"}}`。

## 第一步：检查 CLI 是否已安装（每次会话首次使用前必做）

```bash
command -v ucdrive || ls ~/.claude/skills/ucdrive/cli.mjs 2>/dev/null
```

- **两个都没有** → 全新安装，走下面的「安装引导」。
- **`cli.mjs` 存在但命令不存在** → 本地已下载 skill 但没装 launcher，直接执行安装引导第 2 步。
- **`ucdrive` 命令可用** → 继续跑 `ucdrive whoami` 检查凭证：
  - `"cached": true` → 凭证就绪，直接执行用户要的操作。
  - `"cached": false` → 走下面的「首次登录引导」。

## 安装引导（未安装时，按顺序带用户做）

1. **告知用户**：「需要安装 UC 网盘命令行工具（一个本地脚本，不需要管理员权限）。」然后执行：
   ```bash
   bash ~/.claude/skills/ucdrive/install.sh
   ```
   脚本会检查 Node.js ≥20、创建 `~/bin/ucdrive` launcher，并提示 PATH 问题。
2. 若提示 PATH 未包含 `~/bin`：把 `export PATH="$HOME/bin:$PATH"` 追加进用户的 shell 配置（`~/.zshrc`），并告知用户重开终端后生效；当前会话内可以直接用全路径 `~/.claude/skills/ucdrive/cli.mjs` 调用（用法相同，把 `ucdrive` 换成 `node ~/.claude/skills/ucdrive/cli.mjs`）。
3. **前置条件检查**（告诉用户）：
   - macOS + UC 浏览器已安装，且**有 UC 网盘账号**（能在手机或浏览器里打开网盘）。
   - Node.js ≥20。
4. 装完进入「首次登录引导」。

## 首次登录引导（cached: false 时，按顺序带用户做）

1. **告知用户**：「UC 网盘工具还没初始化，需要从你的 UC 浏览器抓取一次登录凭证，之后就可以不开 UC 直接用了。」
2. **让用户配合**：请用户打开 UC 浏览器并进入**网盘页面**（能看到文件列表即可，保持页面开着）。
   - 若用户平时用正常模式开 UC 也没关系，`ucdrive login` 会自动尝试带调试端口重启 UC（标签页会丢，登录态保留）。
3. **执行抓取**：
   ```bash
   ucdrive login
   ```
   - 成功：返回 `{"ok": true, ...}`，告诉用户「好了，以后不开 UC 也能用」，然后继续执行用户原本要的操作。
   - 失败 `WSG_HEADERS_TIMEOUT` / `NO_CLOUD_DRIVE_PAGE`：说明网盘页面没开或没加载完，请用户刷新网盘页面后重试 login。
   - 失败含 `ECONNREFUSED`：UC 没起来，让用户手动打开 UC 并进入网盘页面，再重试。
4. **验证**：`ucdrive list /` 能列出目录即完成，之后正常执行用户的任务。

## 核心规则

1. **路径**以 `/` 开头，根目录是 `/`；也可以直接传 32 位十六进制 fid。
2. **模糊搜索陷阱**：`search` 是模糊匹配，批量删除/移动前必须用 `list` 核对确切名称，逐个精确匹配执行，禁止把搜索结果直接灌给 delete。
3. **删除默认进回收站**（可恢复）；`--purge` 彻底删除不可恢复，仅在用户明确要求时使用。
4. 上传大小不限：<8MB 走单请求直传（纯外部模式）；≥8MB 自动分片（4MB/片，需 UC 网盘页面开着做一次初始化，数据传输仍走外部模式）。上传进度打到 stderr。

## 常用命令

```bash
ucdrive list /                          # 根目录（-j page=N size=N sort=file_name:asc）
ucdrive tree /整理                      # 递归树（-j depth=3 max=300）
ucdrive search <关键词>                 # 按名搜索（模糊）
ucdrive mkdir /整理/2026/报告           # 多级建目录，幂等
ucdrive rename <path> <new_name>
ucdrive move <path1,path2> <dest_dir>
ucdrive delete <path> [--purge]         # 默认回收站
ucdrive upload <local_path> <dest_dir>  # 大小不限；>=8MB 分片（初始化需 UC 页面开着）
ucdrive download <path> <local_path>    # 需 UC 网盘页面开着（页面模式）
ucdrive recycle                         # 回收站列表（条目含 record_id）
ucdrive restore <record_id,...>         # 恢复（落到 /文件恢复/<日期>/）
ucdrive purge <record_id,...>           # 彻底删除（不可逆）
ucdrive quota                           # 配额
ucdrive info <path>                     # 单条目详情
```

## 凭证过期（运行中报 STALE_CREDS 时）

已初始化但某天突然报 `STALE_CREDS`：向用户说明「凭证过期了，需要重新抓一次」，然后走「首次登录引导」的第 2–4 步（开销很小，一次 login 即可）。CLI 收到 401 时也会自动尝试静默重抓，只有 UC 不可达才会报错到这一层。

## 需要页面模式的场景

`download` 和 ≥8MB 上传的初始化需要 UC 以调试端口运行且网盘页面已打开。若失败，提示用户打开 UC 网盘页面后重试。

## 技术背景（仅在用户问起时提及）

外部模式使用从 UC 网络层抓取的 WSG 凭证集（ut + __uus + x-u-kps-wg/sign-wg/vcode）直连 `pc-api.uc.cn`；`file/sort`、`file/download` 等端点响应加密，故列表走 `general_search` 明文替代、下载与分片初始化走页面。凭证缓存在 `~/Library/Application Support/uc-drive-mcp/credentials.json`（0600，只含 token 不含密码）。
