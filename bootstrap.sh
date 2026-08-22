#!/bin/bash
# cf-hub 私有化部署 Bootstrap（install 瘦壳：下载平台自包含包 → exec 部署器）
#
# 一行启动（信任来源时）：
#   curl -fsSL https://raw.githubusercontent.com/x-cmd-hub/x-hub/main/bootstrap.sh | bash
#
# 推荐先下载审查（更安全）：
#   curl -fsSL https://raw.githubusercontent.com/x-cmd-hub/x-hub/main/bootstrap.sh -o bootstrap.sh
#   less bootstrap.sh
#   bash bootstrap.sh
#
# 可用环境变量：
#   INSTALL_DIR=./cf-hub-deploy   安装目录
#   TAG=                           指定版本（默认查询最新）
#   REPO=x-cmd-hub/x-hub          GitHub 仓库
#
# 流程：探测平台 → 下载对应平台自包含包（含 x-hub-deployer 二进制，sha256 校验）
#       → 解压 → 审查暂停（仅 tty）→ exec ./x-hub-deployer deploy
#       （无 tty 时 install 层零交互直通 headless；node/wrangler 前置检查在部署器 precheck 内完成）
set -euo pipefail

REPO="${REPO:-x-cmd-hub/x-hub}"
INSTALL_DIR="${INSTALL_DIR:-./cf-hub-deploy}"

info() { echo "[bootstrap] $*"; }
err()  { echo "[bootstrap] 错误：$*" >&2; exit 1; }

# tty 检测：curl|bash 模式下 stdin 是管道，交互改从 /dev/tty 读。
# 注意不能 exec </dev/tty 替换 fd0 —— bash 还要从管道读脚本剩余部分，
# 替换后解析器会转而从终端读"脚本"，导致整个脚本静默挂死（零输出卡住）。
TTY_OK=1
if [[ ! -t 0 ]]; then
	if : </dev/tty 2>/dev/null; then
		: # 有终端：各交互点单独 </dev/tty 重定向（见下方 read）
	else
		TTY_OK=0
		info "无终端（管道/CI 环境）：跳过交互，直达 headless 部署（需 CLOUDFLARE_API_TOKEN）"
	fi
fi

# ===== [1/4] 前置检查 + 平台探测 =====
info "=== [1/4] 前置检查 ==="
command -v curl >/dev/null || err "需要 curl"
command -v tar  >/dev/null || err "需要 tar"

# 平台探测用 x-cmd os（输出已规范化：darwin/linux/windows + arm64/amd64）。
# 脚本是非交互 shell，rc 不会自动加载 x-cmd，这里手动加载。
if ! command -v x-cmd >/dev/null 2>&1; then
	___X_CMD_CLAUDECODE_READY=1
	# shellcheck disable=SC1091
	[ -f "$HOME/.x-cmd.root/X" ] && . "$HOME/.x-cmd.root/X" >/dev/null 2>&1
fi
command -v x-cmd >/dev/null 2>&1 \
	|| err "需要 x-cmd（未检测到）。安装：eval \"\$(curl https://get.x-cmd.com)\"，安装后重开终端重跑"

OS="$(x-cmd os name)"
ARCH="$(x-cmd os arch)"
# 兼容 x86_64/x64、aarch64 等同义写法；Windows（含 Git Bash）用原生 exe
case "$OS/$ARCH" in
	linux/amd64|linux/x86_64|linux/x64)    PLATFORM="linux_amd64" ;;
	linux/arm64|linux/aarch64)             PLATFORM="linux_arm64" ;;
	darwin/amd64|darwin/x86_64|darwin/x64) PLATFORM="darwin_amd64" ;;
	darwin/arm64|darwin/aarch64)           PLATFORM="darwin_arm64" ;;
	windows/amd64|windows/x86_64|windows/x64) PLATFORM="windows_amd64" ;;
	*) err "不支持的平台：$OS/$ARCH" ;;
esac
EXE=""
case "$PLATFORM" in windows_*) EXE=".exe" ;; esac
info "平台：$PLATFORM"

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	elif command -v x-cmd >/dev/null 2>&1; then
		x-cmd hash sha256 "$1"
	else
		echo ""
	fi
}

# verify_sha <file> <file.sha256 路径>；缺工具/缺文件时跳过
verify_sha() {
	local f="$1" sha_src="$2" expected actual
	if [[ ! -s "$sha_src" ]]; then
		info "⚠ 未找到 sha256 文件，跳过校验（建议联系 x-cmd 确认包完整性）"
		return 0
	fi
	expected="$(awk '{print $1}' "$sha_src")"
	actual="$(sha256_of "$f")"
	if [[ -z "$actual" ]]; then
		info "⚠ 环境缺少 sha256 工具（sha256sum / shasum / x-cmd），跳过校验"
	elif [[ "$expected" != "$actual" ]]; then
		err "sha256 校验失败（文件可能被篡改）。期望 ${expected}，实际 ${actual}"
	else
		info "sha256 校验通过：$actual"
	fi
}

# ===== [2/4] 选版本 =====
info "=== [2/4] 选版本 ==="
if [[ -n "${TAG:-}" ]]; then
	info "使用环境变量指定的版本：$TAG"
else
	LATEST_TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
		| grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
		| head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
	[[ -n "$LATEST_TAG" ]] || err "未能查询最新版本（GitHub API 速率限制或网络问题）。请用 TAG=v1.0.0 bash bootstrap.sh 指定版本。"
	if [[ "$TTY_OK" == "1" ]]; then
		read -rp "选择版本（回车用最新 [$LATEST_TAG]）: " TAG </dev/tty
		TAG="${TAG:-$LATEST_TAG}"
	else
		TAG="$LATEST_TAG"
	fi
fi
info "已选版本：$TAG"

TMPDIR_B="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_B"' EXIT

# ===== [3/4] 下载平台自包含包 + 校验 + 解压 + 审查暂停 =====
info "=== [3/4] 下载平台包（${PLATFORM}，内含部署器）==="
TARBALL="${TAG}_${PLATFORM}.tar.gz"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${TARBALL}"
curl -fSL "$DOWNLOAD_URL" -o "$TMPDIR_B/$TARBALL" \
	|| err "下载失败：${DOWNLOAD_URL}（确认版本号 $TAG 与平台 $PLATFORM 是否存在）"
curl -fSL "$DOWNLOAD_URL.sha256" -o "$TMPDIR_B/$TARBALL.sha256" 2>/dev/null || true
verify_sha "$TMPDIR_B/$TARBALL" "$TMPDIR_B/$TARBALL.sha256"

INSTALL_DIR_ABS="$(cd "$(dirname "$INSTALL_DIR")" && pwd)/$(basename "$INSTALL_DIR")"
if [[ -d "$INSTALL_DIR" ]]; then
	if [[ "$TTY_OK" == "1" ]]; then
		read -rp "$INSTALL_DIR 已存在，覆盖？[y/N] " YN </dev/tty
		[[ "$YN" =~ ^[Yy]$ ]] || err "用户取消"
	fi
	rm -rf "$INSTALL_DIR"
fi
mkdir -p "$INSTALL_DIR"
# tarball 内顶层目录是 {TAG}_{PLATFORM}/，用 --strip-components=1 去掉
tar -xzf "$TMPDIR_B/$TARBALL" -C "$INSTALL_DIR" --strip-components=1
chmod +x "$INSTALL_DIR/x-hub-deployer$EXE"
info "已解压到 $INSTALL_DIR_ABS"

# 打印内容清单 + 暂停供审查（仅 tty）
if [[ "$TTY_OK" == "1" ]]; then
	echo
	echo "----- 目录结构（顶层）-----"
	ls -la "$INSTALL_DIR"
	echo "---------------------------"
	echo
	echo "📦 版本：${TAG}（${PLATFORM}）"
	echo "📁 安装目录：$INSTALL_DIR_ABS"
	echo
	echo "审查以上信息后按回车继续部署（Ctrl+C 取消）"
	read -rp "" </dev/tty
fi

# ===== [4/4] 启动部署 =====
info "=== [4/4] 启动部署 ==="
cd "$INSTALL_DIR"

echo
echo "========================================"
echo "  cf-hub 部署（后端 + 前端）"
echo "========================================"
if [[ "$TTY_OK" == "1" ]]; then
	exec "./x-hub-deployer$EXE" deploy </dev/tty
fi
exec "./x-hub-deployer$EXE" deploy
