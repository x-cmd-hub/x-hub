# x-hub 私有化部署

x-hub 是 [x-cmd](https://x-cmd.com) 的云同步与分享服务（文件 / 数据 / AI 技能）。本仓库提供**私有化部署包**：把 x-hub 后端 + 前端一键部署到你自己的 Cloudflare 账号，数据完全在你的 CF 账号内（D1 / R2 / KV）。

> 本仓库只发布部署包（Release tarball）与部署脚本，**不含服务源码**。

---

## 一、前置条件

| 条件 | 说明 |
|------|------|
| **Node.js 18+** | 推荐 24+ |
| **Cloudflare 账号** | 免费版即可；资源部署在你自己账号下 |
| **R2 已激活** | 首次使用请到 [CF 控制台](https://dash.cloudflare.com) → R2 Object Storage 点击激活（免费） |

不需要 pnpm / 前端构建工具 / GitHub SSH key，部署依赖会自动安装。

## 二、快速开始

**方式 A：一行命令**

```bash
curl -fsSL https://raw.githubusercontent.com/x-cmd-hub/x-hub/main/bootstrap.sh | bash
```

**方式 B：手动下载 Release**

到 [Releases](../../releases) 页面下载 `vX.Y.Z_private.tar.gz`（及 `.sha256` 校验文件），然后：

```bash
shasum -a 256 -c vX.Y.Z_private.tar.gz.sha256   # 校验（可选）
tar -xzf vX.Y.Z_private.tar.gz
cd vX.Y.Z_private
bash deploy.sh
```

bootstrap 支持的环境变量：`INSTALL_DIR=./cf-hub-deploy`（安装目录）、`TAG=`（指定版本，默认最新）、`REPO=`（默认本仓库）。

### 在容器 / 虚拟机 / 无浏览器环境部署

`wrangler login` 需要打开浏览器授权，headless 环境无法使用。改用 **API Token** 认证：

1. 在**有浏览器的机器**上登录 [dash.cloudflare.com](https://dash.cloudflare.com) → 右上角头像 → **My Profile** → **API Tokens** → **Create Token**
2. 选择 **Edit Cloudflare Workers** 模板，在 Additional permissions 里补充：
   - `Account` → `Cloudflare Pages` → **Edit**（前端部署需要）
   - `Zone` → `Workers Routes` → **Edit**（仅使用自定义域名时需要）
3. 创建后复制 Token（只显示一次），在容器 / 虚拟机里：

```bash
export CLOUDFLARE_API_TOKEN=<你的token>
bash bootstrap.sh        # 或 bash deploy.sh
```

Token 泄漏等同于账号权限泄漏，用完可随时在控制台 Roll 或 Delete。

## 三、部署时会问你什么

部署脚本全自动运行（资源创建、部署、密钥、建表都不需要你操作），只有这几个问题需要你回答：

| 问题 | 怎么答 |
|------|--------|
| 确认部署到此 Cloudflare 账号？ | 核对显示的账号邮箱，回车确认 |
| 是否有托管在 Cloudflare 的域名？ | 有则输入根域（如 `example.com`），没有则直接回车 |
| Pages 项目名 | 回车用默认 `x-hub-web`（撞名会自动换名，无需处理） |
| 其余 Y/N（是否部署前端 / 初始化模板等） | 按需选择，回车即默认值 |

### 关于域名

- **没有域名**：直接回车。服务跑在 `<worker>.workers.dev`（后端）+ `<项目名>.pages.dev`（前端），只有「子域名分享」不可用，路径分享 `/s/:id` 正常。
- **有域名**：先把域名托管到 Cloudflare（控制台 Add a Site，按提示改 nameserver），部署时输入根域即可，路由和地址会自动配置。

## 四、部署后验证

```bash
# 后端健康检查（地址在部署完成时打印）
curl https://<worker-url>/ping
# 应返回 {"ping":"pong"}

# 前端：浏览器打开部署完成时打印的 Pages 地址
```

## 五、自定义配置

部署前可编辑包内的 `deploy.conf`（改完再跑 `bash deploy.sh` 生效）：

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `WORKER_NAME` | `hub` | 后端 Worker 服务名（小写字母/数字/连字符） |
| `SHARE_DOMAIN` | 空 | 托管在 CF 的根域；留空 = 部署时询问 |
| `PAGES_PROJECT` | 空 | 前端 Pages 项目名；留空 = 部署时询问（默认 `x-hub-web`） |
| `TRAFFIC_LIMIT_BYTES` | `1073741824` | 每用户月流量上限（1GB） |
| `R2_BUCKET` | `x-hub-files` | R2 桶名（同名自动复用已有桶） |
| `D1_NAME` | `x-hub-db` | D1 数据库名（同名自动复用已有库） |

## 六、升级

从 [Releases](../../releases) 下载新版 tarball，解压后进入新目录重跑：

```bash
tar -xzf vX.Y.Z_private.tar.gz
cd vX.Y.Z_private
bash deploy.sh    # 检测到已部署的 Worker 后选「更新代码」即可，数据全保留
```

新目录没有旧配置没关系：脚本会自动找到你账号里的已有部署并复用全部资源。

## 七、常见问题

**CORS 跨域报错**
检查部署目录 `wrangler.toml` 的 `ALLOWED_ORIGINS` 是否包含前端域名，缺了就补上后重跑 `bash deploy.sh`。

**邮件验证链接 404**
检查 `grep FRONT_END_URL wrangler.toml`，应为 `https://<pages-project>.pages.dev`（前端地址，不是 API 地址）；不对则改正后重跑 `bash deploy.sh`。

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
