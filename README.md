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

## 新增软件

官方已有 GitHub `.deb` 时，用 `scripts/add_package.sh` 写入 `config/packages.json`。脚本校验 Debian 包名、清单去重、Ubuntu apt/snap 同名冲突，并默认核对上游 `/releases/latest` 资产正则。命令、字段和手工模板见[维护说明](docs/maintenance.md#新增软件)。

上游只有归档、没有官方 `.deb` 时，在 `scripts/` 实现构包并接入 `gen_debs.sh`，不要复制发布流程，也不要在客户端安装时联网下载主程序。

## 维护

首次部署只要一个签名私钥 Secret 和 Pages，见[使用与部署](docs/nees_user_read.md#部署自己的源)。

日常更新在有 `origin` 推送权限的 Linux 机器上运行 `scripts/auto_check.sh`：巡检全部已支持软件，本地预验通过后调用 `git_tag.sh` 打 tag；GitHub Actions 仅在 `push: tags` 上走 `Release → Build → PublishPages → RemoveOldRelease`。无更新时 exit 0，不打 tag。换钥等手动重签用 Actions `workflow_dispatch` 的 `rotate_from`，不会在 Actions 里升版。

```bash
bash scripts/auto_check.sh --dry-run
bash git_tag.sh
```

systemd 分两套，命令可直接复制，见[维护说明：systemd 定时巡检](docs/maintenance.md#systemd-定时巡检)：

- 系统级：`templates/systemd/apt-hub-auto-check.service`（`sudo` 安装，服务仍以维护者账户运行）
- 普通用户级：`templates/systemd/apt-hub-auto-check.user.service`（安装为 `~/.config/systemd/user/apt-hub-auto-check.service`；注销后仍要跑时执行 `loginctl enable-linger`）
- 两套共用 `templates/systemd/apt-hub-auto-check.timer`（默认每天北京时间 12:17）
- 每次运行覆盖同一文件 `tmp/auto_check.last.log`（`cat tmp/auto_check.last.log` 查看），不向 journald 堆积历史

### 脚本一览

| 脚本 | 职责 |
| --- | --- |
| `scripts/add_source.sh` | 使用者加源，发布时原样放到 Pages |
| `scripts/add_package.sh` | 按模板把官方 GitHub `.deb` 写入 `config/packages.json` |
| `scripts/auto_check.sh` | 巡检上游；`--dry-run` 只探测和预验；有更新则预验后调用 `git_tag.sh` |
| `git_tag.sh` | 唯一升版、打 tag、推送入口 |
| `build.sh` | 构包入口；`--arch` 只预验本机架构；`build.sh test` 跑全量测试 |
| `scripts/sync.sh` | 生成签名 APT 索引；`--check-catalog-only` 只验清单 |
| `scripts/render.sh` | 渲染 README 列表和 Pages 首页 |
| `scripts/release_assets.sh` | 为当前 tag 决定构包、复用或跳过，并核验 Release 资产 |
| `scripts/reindex_apt_repo.sh` | 在 Actions 中重索引、签名并发布 `apt-hub-pages` |
| `scripts/update_sources.sh` | 本地/CI 生成签源候选，不上传、不推送 |

更细的职责边界见 [AGENTS.md](AGENTS.md) 与 [CLAUDE.md](CLAUDE.md)。

## 文档

- [维护说明](docs/maintenance.md)：新增软件、巡检发版、systemd（系统级与普通用户级）和单日志。
- [使用与部署](docs/nees_user_read.md)：加源、Pages、签名密钥与恢复。
- [项目规范](docs/PROJECT_STANDARDS.md)：路径、SSH、版本号与发版授权。
- [AGENTS.md](AGENTS.md) · [CLAUDE.md](CLAUDE.md)：协作约束与脚本职责。
- [验证记录](docs/verification.md) · [需求与边界](docs/plan.md)：历史记录，不是现行操作说明。
