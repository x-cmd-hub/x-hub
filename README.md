# x-hub 私有化部署

x-hub 是 [x-cmd](https://x-cmd.com) 的云同步与分享服务（文件 / 数据 / AI 技能）。本仓库提供**私有化部署包**：把 x-hub 后端 + 前端一键部署到你自己的 Cloudflare 账号，数据完全在你的 CF 账号内（D1 / R2 / KV）。

> 本仓库只发布部署包（Release tarball）与部署脚本，**不含服务源码**。

---

## 一、前置条件

| 条件 | 说明 |
|------|------|
| **Cloudflare 账号** | 免费版即可；资源部署在你自己账号下 |
| **R2 已激活** | 首次使用请到 [CF 控制台](https://dash.cloudflare.com) → R2 Object Storage 点击激活（免费） |

支持平台：Linux / macOS / **Windows x64**（Windows 需在 [Git Bash](https://git-scm.com) 中运行——安装 x-cmd 即自带；或用 WSL2）。

不需要 Node.js / pnpm / 前端构建工具 / GitHub SSH key：部署由 **x-hub-deployer**（Go 静态二进制，内嵌在平台包里，bootstrap 自动下载对应平台的那一个包）完成，依赖缺失时自动补装（node 缺失时经 x-cmd，wrangler 经 npm）。

## 二、快速开始

**方式 A：一行命令**

```bash
curl -fsSL https://raw.githubusercontent.com/x-cmd-hub/x-hub/main/bootstrap.sh | bash
```

**方式 B：手动下载 Release**

到 [Releases](../../releases) 页面**只下载你这一个平台的包**（`vX.Y.Z_<os>_<arch>.tar.gz`，自包含、无需其他下载；Windows 为 `windows_amd64`），然后：

```bash
shasum -a 256 -c vX.Y.Z_darwin_arm64.tar.gz.sha256   # 校验（可选；Linux 用 sha256sum -c）
tar -xzf vX.Y.Z_<os>_<arch>.tar.gz && cd vX.Y.Z_<os>_<arch>
bash deploy.sh                                        # 或直接 ./x-hub-deployer deploy
```

Windows 手动方式（PowerShell，Win10+ 自带 tar）：解压后在包目录运行 `.\x-hub-deployer.exe deploy`；推荐还是用 Git Bash 跑 `bash deploy.sh`，交互体验一致。

bootstrap 支持的环境变量：`INSTALL_DIR=./cf-hub-deploy`（安装目录）、`TAG=`（指定版本，默认最新）、`REPO=`（默认本仓库）。

### 在容器 / 虚拟机 / 无浏览器环境部署（headless）

`wrangler login` 需要打开浏览器授权，headless 环境无法使用。改用 **API Token** 认证：

1. 在**有浏览器的机器**上登录 [dash.cloudflare.com](https://dash.cloudflare.com) → 左侧边栏 → **Manage Account（管理帐户）** → **Account API Tokens（帐户 API 令牌）** → **Create Token（创建令牌）**
2. 选择 **Edit Cloudflare Workers** 模板（已含 Workers Scripts / KV Storage / R2 Storage / Workers Routes 等），再在 Additional permissions 里补两项（模板均不含）：
   - `Account` → `D1` → **Edit**（建库、建表需要）
   - `Account` → `Cloudflare Pages` → **Edit**（前端部署需要）
3. Account Resources 选要部署的账号；使用自定义域名时，Zone Resources 需包含该域名
4. 创建后复制 Token（只显示一次），在容器 / 虚拟机里：

```bash
export CLOUDFLARE_API_TOKEN=<你的token>
curl -fsSL https://raw.githubusercontent.com/x-cmd-hub/x-hub/main/bootstrap.sh | bash
# 或已解压好包：./x-hub-deployer --non-interactive --yes deploy
```

CI 一行直通（bootstrap 在无终端时零交互、自动选最新版本）。部署器缺答案时一次性聚合列出全部缺失项（flag 名 + 等价环境变量），退出码 2；完整 flag 表见包内 `deploy/docs/README.md`。

Token 泄漏等同于账号权限泄漏，用完可随时在控制台 Roll 或 Delete。

## 三、部署后验证

```bash
# 后端健康检查（地址在部署完成时打印）
curl https://<worker-url>/ping
# 应返回 {"ping":"pong"}

# 前端：浏览器打开部署完成时打印的 Pages 地址
```

## 四、自定义配置

部署前可编辑包内的 `deploy.conf`（改完再跑 `./x-hub-deployer deploy` 生效）：

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `WORKER_NAME` | `hub` | 后端 Worker 服务名（小写字母/数字/连字符） |
| `SHARE_DOMAIN` | 空 | 托管在 CF 的根域；留空 = 部署时询问 |
| `PAGES_PROJECT` | 空 | 前端 Pages 项目名；留空 = 部署时询问（默认 `x-hub-web`） |
| `TRAFFIC_LIMIT_BYTES` | `1073741824` | 每用户月流量上限（1GB） |
| `R2_BUCKET` | `x-hub-files` | R2 桶名（同名自动复用已有桶） |
| `D1_NAME` | `x-hub-db` | D1 数据库名（同名自动复用已有库） |

### 关于域名（SHARE_DOMAIN）

**为什么要配置域名**：唯一影响的功能是**子域名分享**——配置后每个用户拥有 `用户名.你的域名` 形式的专属分享主页（如 `alice.example.com`）。这需要给 Worker 绑定 `*.域名` 的通配路由，只有托管在 Cloudflare 的自有域名才能做到，`workers.dev` 不支持。此外自有域名地址更干净（`api.域名` / `hub.域名`），且不依赖 `workers.dev` / `pages.dev` 这类公共域名（部分网络环境下访问受限）。

**没有域名会怎么样**：完全可用。后端跑在 `<worker>.workers.dev`，前端跑在 `<项目名>.pages.dev`，同步、文件、路径分享 `/s/:id` 等核心功能全部正常，仅子域名分享不可用。以后买了域名，托管到 Cloudflare 后改 `SHARE_DOMAIN` 重跑 `./x-hub-deployer deploy` 即可启用。

**有域名**：先把域名托管到 Cloudflare（控制台 Add a Site，按提示把注册商的 nameserver 改成 CF 分配的地址），再在 `SHARE_DOMAIN` 填根域，部署脚本会自动配置通配路由和子域地址。

## 五、升级

从 [Releases](../../releases) 下载新版 tarball，解压后进入新目录重跑：

```bash
tar -xzf vX.Y.Z_private.tar.gz
cd vX.Y.Z_private
./x-hub-deployer deploy   # 或 bash deploy.sh；检测到已部署 Worker 后选「更新代码」即可，数据全保留
```

新目录没有旧配置没关系：脚本会自动找到你账号里的已有部署并复用全部资源。

## 六、常见问题

**CORS 跨域报错**
检查部署目录 `wrangler.toml` 的 `ALLOWED_ORIGINS` 是否包含前端域名，缺了就补上后重跑 `./x-hub-deployer deploy`。

**邮件验证链接 404**
检查 `grep FRONT_END_URL wrangler.toml`，应为 `https://<pages-project>.pages.dev`（前端地址，不是 API 地址）；不对则改正后重跑 `./x-hub-deployer deploy`。

**R2 报 10042 / enable R2**
你的 CF 账号还没激活 R2：控制台 → R2 Object Storage → 激活后重跑 `./x-hub-deployer deploy`。

**想自己重新构建前端（高级）**
包内 `website/` 是前端源码，`public/` 是预构建产物。日常部署只用 `public/`，想改前端可以：

```bash
cd website
pnpm install
pnpm build:private   # 需要自行编辑 .env.private
# 产出 .output/public，替换 public/ 后重跑 ./x-hub-deployer deploy
```

---

## 支持与反馈

- 问题反馈：[Issues](../../issues)
- 更多文档见部署包内 `deploy/docs/` 与 `docs/`
