# apt-hub

为没有官方 Ubuntu APT 源的软件提供签名索引，使用标准 APT 安装与升级。官方 `.deb` 直接从上游下载；Go 官方归档转换为 Debian 包后由本仓 Releases 分发。Git 和 Pages 不存安装包。

## 使用

下方一键命令一次添加本站对当前 Ubuntu、架构支持的全部软件源，不安装软件。以后新增软件，重新执行同一条命令即可纳入；已有源保持幂等。加源脚本成功自删，失败保留。

加源后按需安装、正常升级：

```bash
sudo apt update && sudo apt install <软件包名>
sudo apt update && sudo apt upgrade
```

Go 安装后直接使用 `go`、`gofmt`。环境要求、手动配置与换钥见[使用与部署](docs/nees_user_read.md)。

## 一键加源与软件列表


<!-- APT-HUB:PACKAGES:BEGIN -->
<a id="apt-hub-add-source"></a>

```bash
curl -fsSL --proto '=https' --proto-redir '=https' -o add_source.sh 'https://apt-hub.m-b-crazy.com/add_source.sh' && chmod a+x ./add_source.sh && sudo ./add_source.sh --site-url 'https://apt-hub.m-b-crazy.com'
```

已支持：

- [x] golang
- [x] rustdesk

| 软件 | 版本 | 支持环境 | 说明 |
| --- | --- | --- | --- |
| [golang](https://github.com/0xdevelop/apt-hub/releases/tag/v0.0.16) | 2:1.27.4-2 | jammy, noble, resolute, stonking · amd64, arm64 | Go 官方 Linux 归档构建的工具链 |
| [rustdesk](https://github.com/rustdesk/rustdesk/releases/tag/1.5.3) | 1.5.3 | jammy, noble, resolute, stonking · amd64, arm64 | 开源远程桌面 |
<!-- APT-HUB:PACKAGES:END -->

## 新增软件流程规范

接入入口是 `config/packages.json`，不为每个软件另建目录或复制同步脚本。官方已有 GitHub `.deb` 时，优先用 `scripts/add_package.sh` 填写 `id`、`repository`、`package`、说明、源地址、许可证和各架构资产正则；脚本会校验 Debian 包名、清单去重、Ubuntu apt/snap 同名冲突，并默认核对上游 `/releases/latest`。也可以按 `templates/package_github_deb.json` 手工追加条目。清单生效后，下一次 `auto_check.sh` 或手动发版会纳入新软件；已加源的使用者重跑同一条加源命令即可。版本、大小和摘要由官方发布与包元数据取得，不手填。更细的字段说明见[维护说明](docs/maintenance.md#新增软件)。

新增软件的 `package` 必须等于 `.deb` 的 `Package` 字段，并遵守 Debian/APT 包名约定：以小写字母或数字开头，其后只使用小写字母、数字、`-`、`+`、`.`。选名时必须与 Ubuntu 自带的 apt 包和 snap 包名错开，避免同名冲突。

上游只有归档、没有官方 `.deb` 时，在 `scripts/` 实现具体构包并接入 `gen_debs.sh`，不复制发布流程，也不在客户端安装阶段联网下载主程序。

## 维护

首次部署只需一个签名私钥 Secret 和 Pages，步骤见[部署与密钥](docs/nees_user_read.md#部署自己的源)。日常联动更新在有 `origin` 推送权限的 Linux 机器上启用 systemd 定时器，由 `scripts/auto_check.sh` 巡检全部已支持软件；发现更新并通过本地预验后调用 `git_tag.sh` 打 tag，GitHub Actions 再按母版链路发版。也可先预览：

```bash
bash scripts/auto_check.sh --dry-run
```

手动发版在干净仓库执行：

```bash
bash git_tag.sh
```

默认自动升版。`push: tags` 工作流完成 `Release → Build → PublishPages → RemoveOldRelease`：构造包或复用包上传到本仓 `vX.Y.Z` assets，签名站点保存到 `apt-hub-pages` 并发布，成功后回写列表。`Release` 与 `Build`（含 Pages 部署及列表回写）全部成功后，自动调用既有两代清理；不足两代或有效索引仍引用的资产不删除。换钥等手动重签使用 Actions `workflow_dispatch` 的 `rotate_from`，不会在 Actions 里升版。

核心脚本的职责边界见 [AGENTS.md](AGENTS.md) 与 [CLAUDE.md](CLAUDE.md)。

系统级（sudo 安装，服务仍以仓库维护者账户运行）和普通用户级（`systemd --user`）的完整启用、手动触发、查看日志与卸载步骤见[维护说明：systemd 定时巡检](docs/maintenance.md#systemd-定时巡检)。模板在 `templates/systemd/`。每次运行覆盖同一文件 `tmp/auto_check.last.log`，不向 journald 堆积历史。默认每天北京时间 12:17 运行；无更新时脚本 exit 0 且不打 tag。

## 文档

- [项目规范](docs/PROJECT_STANDARDS.md)：本地工作流、版本管理与发布授权。
- [使用与部署](docs/nees_user_read.md)：加源、Pages、签名密钥与恢复。
- [维护说明](docs/maintenance.md)：新增软件、版本职责、本地验证，以及 systemd 定时巡检（系统级与普通用户级）。
- [AGENTS.md](AGENTS.md) · [CLAUDE.md](CLAUDE.md)：核心脚本职责与发版边界。
- [验证记录](docs/verification.md) · [需求与边界](docs/plan.md)。
