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

# tty 检测：curl|bash 模式下 stdin 是管道，交互 read 前需重定向到 /dev/tty
TTY_OK=1
if [[ ! -t 0 ]]; then
	if : </dev/tty 2>/dev/null; then
		exec </dev/tty
	else
		TTY_OK=0
		info "无终端（管道/CI 环境）：跳过交互，直达 headless 部署（需 CLOUDFLARE_API_TOKEN）"
	fi
fi

# ===== [1/4] 前置检查 + 平台探测 =====
info "=== [1/4] 前置检查 ==="
command -v curl >/dev/null || err "需要 curl"
command -v tar  >/dev/null || err "需要 tar"

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS/$ARCH" in
	Linux/x86_64)              PLATFORM="linux_amd64" ;;
	Linux/aarch64|Linux/arm64) PLATFORM="linux_arm64" ;;
	Darwin/x86_64)             PLATFORM="darwin_amd64" ;;
	Darwin/arm64)              PLATFORM="darwin_arm64" ;;
	# Git Bash / MSYS2 / Cygwin（安装 x-cmd 即自带 Git Bash）：跑原生 Windows 二进制
	MINGW*/x86_64|MSYS*/x86_64|CYGWIN*/x86_64) PLATFORM="windows_amd64" ;;
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
		read -rp "选择版本（回车用最新 [$LATEST_TAG]）: " TAG
		TAG="${TAG:-$LATEST_TAG}"
	else
		TAG="$LATEST_TAG"
	fi
fi
info "已选版本：$TAG"

TMPDIR_B="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_B"' EXIT

# ===== [3/4] 下载平台自包含包 + 校验 + 解压 + 审查暂停 =====
info "=== [3/4] 下载平台包（$PLATFORM，内含部署器）==="
TARBALL="${TAG}_${PLATFORM}.tar.gz"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${TARBALL}"
curl -fSL "$DOWNLOAD_URL" -o "$TMPDIR_B/$TARBALL" \
	|| err "下载失败：$DOWNLOAD_URL（确认版本号 $TAG 与平台 $PLATFORM 是否存在）"
curl -fSL "$DOWNLOAD_URL.sha256" -o "$TMPDIR_B/$TARBALL.sha256" 2>/dev/null || true
verify_sha "$TMPDIR_B/$TARBALL" "$TMPDIR_B/$TARBALL.sha256"

INSTALL_DIR_ABS="$(cd "$(dirname "$INSTALL_DIR")" && pwd)/$(basename "$INSTALL_DIR")"
if [[ -d "$INSTALL_DIR" ]]; then
	if [[ "$TTY_OK" == "1" ]]; then
		read -rp "$INSTALL_DIR 已存在，覆盖？[y/N] " YN
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
	echo "📦 版本：$TAG（$PLATFORM）"
	echo "📁 安装目录：$INSTALL_DIR_ABS"
	echo
	echo "审查以上信息后按回车继续部署（Ctrl+C 取消）"
	read -rp ""
fi

# ===== [4/4] 启动部署 =====
info "=== [4/4] 启动部署 ==="
cd "$INSTALL_DIR"

echo
echo "========================================"
echo "  cf-hub 部署（后端 + 前端）"
echo "========================================"
exec "./x-hub-deployer$EXE" deploy
