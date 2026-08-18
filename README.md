# x-hub 私有化部署

x-hub 是 [x-cmd](https://x-cmd.com) 的云同步与分享服务（文件 / 数据 / AI 技能）。本仓库提供**私有化部署包**：把 x-hub 后端 + 前端一键部署到你自己的 Cloudflare 账号，数据完全在你的 CF 账号内（D1 / R2 / KV）。

> 本仓库只发布部署包（Release tarball）与部署脚本，**不含服务源码**。

---

## 一、前置条件

| 条件 | 说明 |
|------|------|
| **Node.js 18+** | 后端 wrangler 需要（推荐 24+） |
| **npm** | 部署脚本会自动安装 `wrangler@^4`（包内不带 node_modules） |
| **Cloudflare 账号** | 免费版即可；部署到你自己账号下，资源归你所有 |
| **R2 已启用** | 首次使用请到 [CF 控制台](https://dash.cloudflare.com) → R2 Object Storage 点击激活（免费，无需付费） |

不需要 pnpm / 前端构建工具：前端已预构建，部署时自动注入配置。
不需要 GitHub SSH key。

## 二、快速开始

**方式 A：一行命令（信任来源时）**

```bash
curl -fsSL https://raw.githubusercontent.com/x-cmd-hub/x-hub/main/bootstrap.sh | bash
```

**方式 B：先下载审查（推荐）**

```bash
# 1. 下载 bootstrap 脚本并审查
curl -fsSL https://raw.githubusercontent.com/x-cmd-hub/x-hub/main/bootstrap.sh -o bootstrap.sh
less bootstrap.sh

# 2. 运行：自动下载最新 Release + sha256 校验 + 解压 + 启动部署
bash bootstrap.sh
```

**方式 C：手动下载 Release**

到 [Releases](../../releases) 页面下载 `vX.Y.Z_private.tar.gz`（及 `.sha256` 校验文件），然后：

```bash
shasum -a 256 -c vX.Y.Z_private.tar.gz.sha256   # 校验（可选）
tar -xzf vX.Y.Z_private.tar.gz
cd vX.Y.Z_private
bash deploy.sh
```

bootstrap 支持的环境变量：`INSTALL_DIR=./cf-hub-deploy`（安装目录）、`TAG=`（指定版本，默认最新）、`REPO=`（默认本仓库）。

### 在容器 / 虚拟机 / 无浏览器环境部署

`wrangler login` 需要打开浏览器授权，在容器、虚拟机、SSH 远程等 headless 环境无法使用。改用 **API Token** 认证：

1. 在**有浏览器的机器**上登录 [dash.cloudflare.com](https://dash.cloudflare.com) → 右上角头像 → **My Profile** → **API Tokens** → **Create Token**
2. 选择 **Edit Cloudflare Workers** 模板，在 Additional permissions 里补充：
   - `Account` → `Cloudflare Pages` → **Edit**（前端部署需要）
   - `Zone` → `Workers Routes` → **Edit**（仅使用自定义域名时需要）
3. 创建后复制 Token（只显示一次），在容器 / 虚拟机里：

```bash
export CLOUDFLARE_API_TOKEN=<你的token>
bash bootstrap.sh        # 或 bash deploy.sh
```

脚本会自动识别 API Token，全程无需浏览器。Token 泄漏等同于账号权限泄漏，用完可随时在控制台 Roll 或 Delete。

## 三、部署过程

`deploy.sh` 会引导你完成全部流程，全程只问少量问题（域名、Pages 项目名、几个 Y/N）：

```
[1/8] 前置检查 —— Node / curl / openssl / wrangler（未装自动 npm install）
      检查 wrangler 登录（未登录自动弹浏览器授权），显示账号并请你确认
[2/8] 模式判断 —— 已部署过则问：更新代码 or 完整重跑
[3/8] 配置     —— 读 deploy.conf，只问一个问题：有没有托管在 Cloudflare 的域名
[4/8] 创建资源 —— KV / R2 / D1（同名已存在则自动复用）
[5/8] 回填 ID  —— 资源 id 写回 wrangler.toml
[6/8] 部署后端 —— 无自定义域名时自动回填 workers.dev 真实地址
[7/8] 注入密钥 —— JWT_SECRET_KEY 自动生成；CLIENT_HMAC_KEY 已内置
[8/8] 初始化   —— D1 建表 + Skill 模板（可选）

阶段 2：前端 Pages 部署 —— 问项目名（默认 x-hub-web，撞名自动加后缀），
      上传预构建产物，自动更新后端 CORS / FRONT_END_URL 并重新部署
阶段 3：x-bash/hub CLI 配置（可选）
```

### 关于域名

- **没有域名**：直接回车，服务跑在 `<worker>.<你的子域>.workers.dev`（后端）+ `<项目名>.pages.dev`（前端），全部功能中只有「子域名分享」不可用，路径分享 `/s/:id` 正常。
- **有域名**：先把域名托管到 Cloudflare（控制台 Add a Site，按提示改 nameserver），部署时输入根域（如 `example.com`），脚本会验证 zone 并配置路由。

## 四、部署后验证

```bash
# 后端健康检查（地址在部署完成时打印）
curl https://<worker-url>/ping
# 应返回 {"ping":"pong"}

# 前端：浏览器打开部署完成时打印的 Pages 地址
```

## 五、配置参考

### deploy.conf（部署前可编辑）

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `WORKER_NAME` | `hub` | 后端 Worker 服务名（小写字母/数字/连字符） |
| `SHARE_DOMAIN` | 空 | 托管在 CF 的根域；留空 = 部署时询问 |
| `PAGES_PROJECT` | 空 | 前端 Pages 项目名；留空 = 部署时询问（默认 `x-hub-web`） |
| `TRAFFIC_LIMIT_BYTES` | `1073741824` | 每用户月流量上限（1GB） |
| `R2_BUCKET` | `x-hub-files` | R2 桶名（同名自动复用） |
| `D1_NAME` | `x-hub-db` | D1 数据库名（同名自动复用） |

`FRONT_END_URL` / `API_ENDPOINT` / `ALLOWED_ORIGINS` 留空自动推导，无需填写。

### wrangler.toml（部署后生成，改后需重跑 deploy.sh）

| 变量 | 说明 |
|------|------|
| `FRONT_END_URL` | 前端地址（前端部署后自动更新为 Pages 地址） |
| `API_ENDPOINT` | 本服务 API 根地址 |
| `ALLOWED_ORIGINS` | CORS 白名单（自动追加 Pages 域名） |
| `TRAFFIC_LIMIT_BYTES` | 每用户月流量上限（字节） |

### Secrets（自动管理，无需手动操作）

| Secret | 用途 |
|--------|------|
| `JWT_SECRET_KEY` | 用户会话签名，部署时自动生成（重新生成会使登录失效，已存在则跳过） |
| `CLIENT_HMAC_KEY` | 与 x-cmd 网关共享的 HMAC，部署包已内置 |

## 六、升级

从 [Releases](../../releases) 下载新版 tarball，解压后进入新目录重跑：

```bash
tar -xzf vX.Y.Z_private.tar.gz
cd vX.Y.Z_private
bash deploy.sh    # 检测到已部署的 Worker 后选「更新代码」即可，数据/密钥全保留
```

新目录没有旧配置没关系：脚本会按 `deploy.conf` 里的 Worker 名查询你的 CF 账号，找到已有部署就自动复用全部资源（KV / R2 / D1 / Secrets）。

## 七、常见问题

**CORS 跨域报错**
前端部署后脚本会自动把 Pages 域名加入 `ALLOWED_ORIGINS` 并重新部署后端。仍报错时检查 `wrangler.toml` 的 `ALLOWED_ORIGINS` 是否包含前端域名，改后重跑 `bash deploy.sh`。

**邮件验证链接 404**
`FRONT_END_URL` 必须指向**前端**地址（不是 API 地址）。检查 `grep FRONT_END_URL wrangler.toml`，应为 `https://<pages-project>.pages.dev`。

**R2 报 10042 / enable R2**
你的 CF 账号还没激活 R2：控制台 → R2 Object Storage → 激活后重跑部署脚本。

**想自己重新构建前端（高级）**
包内 `website/` 是前端源码，`public/` 是预构建产物。日常部署只用 `public/`，想改前端可以：

```bash
cd website
pnpm install
pnpm build:private   # 需要自行编辑 .env.private
# 产出 .output/public，替换 public/ 后重跑 bash deploy.sh
```

---

## 支持与反馈

- 问题反馈：[Issues](../../issues)
- 更多文档见部署包内 `deploy/docs/` 与 `docs/`
