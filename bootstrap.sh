#!/bin/bash
# cf-hub 私有化部署 Bootstrap
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
# 流程：检查环境 → 选版本 → 下载 release + sha256 校验 → 解压 → 审查暂停 → 调 deploy.sh（含后端+前端）
set -euo pipefail

# curl|bash 模式下 stdin 接的是管道（curl 的输出），read 会读到乱码。
# 重定向到 tty 让交互式 read 能正常工作。
[[ -t 0 ]] || exec </dev/tty

REPO="${REPO:-x-cmd-hub/x-hub}"
INSTALL_DIR="${INSTALL_DIR:-./cf-hub-deploy}"

info() { echo "[bootstrap] $*"; }
err()  { echo "[bootstrap] 错误：$*" >&2; exit 1; }

# ===== [1/5] 前置检查 =====
info "=== [1/5] 前置检查 ==="
command -v curl >/dev/null || err "需要 curl"
command -v tar  >/dev/null || err "需要 tar"
# node：缺失或版本过低时通过 x-cmd env use 自动安装（x-cmd 缺失则先装 x-cmd）
node_usable() {
	command -v node >/dev/null 2>&1 || return 1
	[[ "$(node -p 'process.versions.node.split(".")[0]')" -ge 18 ]]
}
if ! node_usable; then
	info "未检测到 Node.js 18+，通过 x-cmd 自动安装 ..."
	if ! command -v x-cmd >/dev/null 2>&1; then
		info "  安装 x-cmd ..."
		eval "$(curl -fsSL https://get.x-cmd.com 2>/dev/null)" >/dev/null 2>&1 || true
	fi
	X_PKG_EXEC_BIN="$HOME/.x-cmd.root/local/data/pkg/exec"
	x-cmd env use node >/dev/null 2>&1 || true
	[[ -d "$X_PKG_EXEC_BIN" ]] && export PATH="$X_PKG_EXEC_BIN:$PATH"
	node_usable || err "Node.js 自动安装失败。请手动安装 Node.js 18+ 后重跑（https://nodejs.org）"
fi
info "Node.js: $(node -v)"

# ===== [2/5] 选版本 =====
info "=== [2/5] 选版本 ==="
if [[ -n "${TAG:-}" ]]; then
	info "使用环境变量指定的版本：$TAG"
else
	info "查询最新版本 ..."
	LATEST_TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
		| grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
		| head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
	if [[ -z "$LATEST_TAG" ]]; then
		err "未能查询最新版本（GitHub API 速率限制或网络问题）。请用 TAG=v1.0.0 bash bootstrap.sh 指定版本。"
	fi
	info "最新版本：$LATEST_TAG"
	read -rp "选择版本（回车用最新 [$LATEST_TAG]）: " TAG
	TAG="${TAG:-$LATEST_TAG}"
fi
info "已选版本：$TAG"

# ===== [3/5] 下载 + 校验 =====
info "=== [3/5] 下载 Release ==="
TARBALL="${TAG}.tar.gz"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${TARBALL}"
SHA256_URL="${DOWNLOAD_URL}.sha256"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

info "下载 $TARBALL ..."
curl -fSL "$DOWNLOAD_URL" -o "$TMPDIR/$TARBALL" || err "下载失败：${DOWNLOAD_URL}（确认版本号 $TAG 是否存在）"

info "下载 sha256 校验文件 ..."
if curl -fSL "$SHA256_URL" -o "$TMPDIR/$TARBALL.sha256" 2>/dev/null; then
	EXPECTED_SHA="$(awk '{print $1}' "$TMPDIR/$TARBALL.sha256")"
	# sha256sum（Linux）→ shasum（macOS）→ x-cmd hash（内部自动回退 cosmo 工具）
	if command -v sha256sum >/dev/null 2>&1; then
		ACTUAL_SHA="$(sha256sum "$TMPDIR/$TARBALL" | awk '{print $1}')"
	elif command -v shasum >/dev/null 2>&1; then
		ACTUAL_SHA="$(shasum -a 256 "$TMPDIR/$TARBALL" | awk '{print $1}')"
	elif command -v x-cmd >/dev/null 2>&1; then
		ACTUAL_SHA="$(x-cmd hash sha256 "$TMPDIR/$TARBALL")"
	else
		ACTUAL_SHA=""
	fi
	if [[ -z "$ACTUAL_SHA" ]]; then
		info "⚠ 环境缺少 sha256 工具（sha256sum / shasum / x-cmd），跳过校验"
	elif [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
		err "sha256 校验失败（文件可能被篡改）。期望 ${EXPECTED_SHA}，实际 $ACTUAL_SHA"
	else
		info "sha256 校验通过：$ACTUAL_SHA"
	fi
else
	info "⚠ 未找到 sha256 文件，跳过校验（建议联系 x-cmd 确认包完整性）"
fi

# ===== [4/5] 解压 + 审查暂停 =====
info "=== [4/5] 解压到 $INSTALL_DIR ==="
INSTALL_DIR_ABS="$(cd "$(dirname "$INSTALL_DIR")" && pwd)/$(basename "$INSTALL_DIR")"
if [[ -d "$INSTALL_DIR" ]]; then
	read -rp "$INSTALL_DIR 已存在，覆盖？[y/N] " YN
	[[ "$YN" =~ ^[Yy]$ ]] || err "用户取消"
	rm -rf "$INSTALL_DIR"
fi
mkdir -p "$INSTALL_DIR"
# tarball 内顶层目录是 {TAG}/，用 --strip-components=1 去掉
tar -xzf "$TMPDIR/$TARBALL" -C "$INSTALL_DIR" --strip-components=1
info "已解压到 $INSTALL_DIR_ABS"

# 打印内容清单 + 暂停供审查
echo
echo "----- 目录结构（顶层）-----"
ls -la "$INSTALL_DIR"
echo "---------------------------"
echo
echo "📦 版本：$TAG"
echo "📁 安装目录：$INSTALL_DIR_ABS"
echo "🔐 sha256：${ACTUAL_SHA:-未校验}"
echo
echo "审查以上信息后按回车继续部署（Ctrl+C 取消）"
read -rp ""

# ===== [5/5] 串联部署 =====
info "=== [5/5] 启动部署 ==="
cd "$INSTALL_DIR"

# deploy.sh 一个脚本搞定：后端 Worker → 前端 Pages（交互询问是否部署前端）
echo
echo "========================================"
echo "  cf-hub 部署（后端 + 前端）"
echo "========================================"
bash deploy/scripts/deploy.sh

# 从 wrangler.toml 读 API 地址（打印用）
WORKER_API=""
if [[ -f wrangler.toml ]]; then
	WORKER_API="$(grep -E '^API_ENDPOINT' wrangler.toml | sed -E 's/.*= *"([^"]+)".*/\1/' || true)"
fi

echo
echo "========== 全部完成 =========="
[[ -n "$WORKER_API" ]] && echo "后端 API：$WORKER_API"
echo "安装目录：$INSTALL_DIR_ABS"
echo "文档：$INSTALL_DIR_ABS/deploy/docs/README.md"
