# 首次启用与需要用户处理的事项

[返回 README](../README.md) · [计划与验收边界](plan.md)

用户指定的文件名为 `nees_user_read.md`，本项目保持此名。这里说明需要的操作，不代表小哈已替用户修改设置或完成部署。

## 1. 项目形态已经明确

按 2026-11-02 用户澄清，本项目使用 Shell + GitHub Actions + 静态 Pages，不做管理平台、Go 后端、数据库或认证系统。因此不需要为本项目安装 Go，也不运行 Go 服务模板初始化。

## 2. 首次启用之前

- **生产签名密钥**：由用户创建、保管与备份专用 OpenPGP 签名身份，准备完整指纹。不要复用本地测试密钥，不要把私钥/口令发到聊天或提交 Git。
- **软件再分发条件**：核对每个软件的许可、对应源码和版权保留义务。RustDesk 的源代码许可及包内内容需要分别核对，不能把“公开下载”当无限制再分发。清单保留官方项目与具体版本来源，首次公开分发前由维护者确认合规。
- **GitHub Pages**：本次只读 API 检查返回 `has_pages: false`。用户需要在仓库 Settings → Pages 中选择 GitHub Actions，并按 GitHub 提示批准部署环境。小哈不自动修改仓库设置。
- **发布身份**：Actions 的提交作者和提交者必须是用户身份，通过仓库变量显式提供，不使用机器人或 agent 协作者。

在仓库 Settings → Secrets and variables → Actions 中，由用户配置：

| 类型 | 名称 | 内容 |
|---|---|---|
| Secret | `APT_HUB_GPG_PRIVATE_KEY` | 专用生产签名私钥的 ASCII armored 导出内容 |
| Secret | `APT_HUB_GPG_FINGERPRINT` | 对应密钥的完整指纹 |
| Secret | `APT_HUB_GPG_PASSPHRASE` | 私钥口令；不要使用或上传测试密钥 |
| Variable | `APT_HUB_GIT_NAME` | 用户提交名称，本次核对为 `yerikokay` |
| Variable | `APT_HUB_GIT_EMAIL` | 用户提交地址，本次核对为 `129245892+yerikokay@users.noreply.github.com` |

用户已授权本次以该账号核对并提交；小哈已通过 GitHub 用户 API 获取 ID，并通过当前 SSH 认证返回的账号交叉核对，未读取私人邮箱、未改 Git 配置。Actions 配置值仍由用户设置。

工作流名为 `ubuntu-publish`，每日定时与手动触发；普通代码 push/PR 仅执行无生产密钥的测试，不自动部署。配置齐备后在 Actions 页面手动运行首次同步，必须看构建/依赖解析、Pages 部署和 README 回写三个阶段的实际结果。未配置前工作流明确拒绝发布，不回退成无签名源。

## 3. 本地提交身份

首次检查时，仓库 `git var GIT_AUTHOR_IDENT` 返回“作者身份未知”。随后用户明确要求使用 `yerikokay` 的精确信息；已核对 GitHub API 用户 ID `129245892`、GitHub 官方 ID 型 noreply 格式及当前 SSH 认证账号。

本次提交采用 `yerikokay <129245892+yerikokay@users.noreply.github.com>`，仅通过单次命令的 author/committer 参数指定，不修改 `.git/config`、全局 Git/SSH 或 shell 配置。所有新 commit 不包含 `Co-authored-by`、agent 名称或会话标记；初始历史保持原样。

## 4. APT 客户端配置

只有生产 Pages 部署成功、公钥可获取且完整指纹经可信途径核对后，才添加源。使用专用 `Signed-By` keyring，不使用 `apt-key`、`trusted=yes` 或全局关闭验签。

当前没有部署成功证据，不给一条带假密钥或占位地址、看似能直接安装的命令。软件源按实际 Ubuntu 代号和架构选择，不把当前最新 Ubuntu 当作所有机器的代号。

测试中的隔离 APT 目录与测试密钥仅验证流程；本地不会写 `/etc/apt` 或安装目标软件。真实 GUI、无人值守和 DGX Spark 硬件行为需要在目标设备环境另行验证。

## 5. 官方支持与维护边界

- Ubuntu 当前标准支持期按权威 `distro-info-data` 日期字段筛选，并与 Ubuntu 官方 release-cycle 对齐。Ubuntu Pro、ESM、Legacy 与普通标准支持分开；不根据升级元数据中的单个 `Supported: 1` 字段混算。
- 每个声明发布组合使用其版本和架构的 Ubuntu 官方签名仓库验证依赖；不能解析或上游明确不支持时拒绝本批，保留旧发布，而不是悄悄宣称兼容。
- 网络获取失败与依赖不兼容分开报告，不修改路由器排障。Fake-IP 地址本身不是故障证据。
- Pages 官方站点大小上限为 1 GB，普通 Git 保存还有单文件 100MiB 限制，另有带宽与部署时长限制。工作流在保存前分别检查并明确拒绝超限。本项目不自动清除仍被旧客户端引用的包；接近容量上限时由维护者规划保留与静态承载迁移，不引入管理平台。
- `git_tag.sh` 管理仓库脚本标签，不对 RustDesk 等软件升版本，也不自动 push/tag 重写。用户明确要求脚本发版时才使用。

## 6. 当前未代办的外部操作

未开启 Pages、未配置生产密钥、未写入 Actions secrets/vars、未添加客户端源、未安装目标包、未发布脚本标签。这些不能被本地测试绿灯代替。
