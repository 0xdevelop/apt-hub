# apt-hub

本仓库为缺少官方 APT 源的软件提供签名索引。官方 `.deb` 从上游直链下载；Go 官方归档由本仓构包后经 GitHub Release 分发。不要把安装包提交进 Git 或 Pages。

路径、SSH 远程、版本号与发版授权见 `AGENTS.md` 和 `docs/PROJECT_STANDARDS.md`。未经用户明确授权，不要 push、不要运行 `git_tag.sh`、不要打 tag。

## 脚本职责

| 脚本 | 职责 |
| --- | --- |
| `build.sh` | 构包入口。默认全架构；`--arch` 只预验当前架构，不影响 CI 默认行为。`build.sh test` 跑全量测试。 |
| `git_tag.sh` | 唯一升版/打 tag 入口。提交必须是 `Release:--: vX.Y.Z_...`。可把 `auto_check.sh` 的原因写入 changelog。 |
| `scripts/auto_check.sh` | 本地/systemd 巡检全部已支持软件，预验后调用 `git_tag.sh`。`--dry-run` 只探测和预验。无更新 exit 0。 |
| `scripts/add_package.sh` | 按模板新增官方 GitHub `.deb`：包名、去重、apt/snap 冲突、资产正则校验后写入 `config/packages.json`。 |
| `scripts/reindex_apt_repo.sh` | Actions 中更新 `apt-hub-pages` 索引并确认 Pages 部署。 |
| `scripts/release_assets.sh` | 判断本仓 tag 是构包、复用还是跳过，并核验 Release 资产。 |
| `scripts/sync.sh` | 生成签名 APT 索引。`--check-catalog-only` 只验清单。 |
| `scripts/render.sh` | 渲染 README 与 Pages 列表。 |
| `scripts/add_source.sh` | 终端用户加源脚本。 |
| `scripts/update_sources.sh` | 本地/CI 生成签源候选，不上传、不推送。 |

## 工作流

不要依赖已删除的 Actions `schedule`。在有推送权限的机器上用 systemd 跑 `scripts/auto_check.sh`，由它调用 `git_tag.sh`，再触发 `push: tags` 母版链路：`Release` → `Build` → `PublishPages` → `RemoveOldRelease`。上传必须使用 `george012/upload_github_release_assets_action@latest` 与 `./build/upload_tmp_dir/*`。`workflow_dispatch` 只用于换钥等手动重签。

systemd 模板：`templates/systemd/apt-hub-auto-check.service`（系统级）、`apt-hub-auto-check.user.service`（用户级，安装时改名为 `apt-hub-auto-check.service`）、共用 `apt-hub-auto-check.timer`。每次运行覆盖 `tmp/auto_check.last.log`。用户级注销后仍要跑时需 `loginctl enable-linger`。安装命令见 `docs/maintenance.md`。
