# apt-hub 协作者约定

仓库路径：`/home/certa/workspace/apt-hub`。远程必须使用 SSH：`git@github.com:0xdevelop/apt-hub.git`。版本号只由 `git_tag.sh` 管理，禁止手写 `VERSION` 或重打已有 `vX.Y.Z`。未经用户明确授权，禁止 `git push`、打 tag 或发版。

## 核心脚本

- `build.sh`：本地/CI 构包入口。`release` 按 `config/packages.json` 调用 `gen_debs.sh` 写入输出目录（默认 `build/upload_tmp_dir`）。可选 `--arch amd64|arm64` 只构造本机架构，供 `auto_check.sh` 预验；默认仍构造配置中的全部架构。`build.sh test` 校验已有上传目录后跑完全量测试。
- `git_tag.sh`：唯一发版入口。自动进位 `VERSION`，生成 `changelog/vX.Y.Z.md`，提交 `Release:--: vX.Y.Z_...`，原子推送当前分支、版本 tag 与 `latest`。若存在 `tmp/auto_check_reasons.txt`（或 `AUTO_CHECK_REASONS_FILE`），把 `auto-update:` / `auto-renew:` 行写入 changelog，不改变提交说明格式。
- `scripts/auto_check.sh`：在有推送权限的机器上巡检全部已支持软件。同步 `origin/main` 与 `origin/apt-hub-pages` 的 `state.json`，工作区不干净则拒绝。构包类比对上游稳定版和 `build_inputs_sha256`，外链 `.deb` 比对 GitHub `/releases/latest`，签名默认按 7 天阈值检查（`--renew-days`，仓库 `Valid-Until` 为 14 天）。无更新则打印状态并 exit 0。`--dry-run` 仍做探测和本地预验，但不调用 `git_tag.sh`。预验通过且非 dry-run 时写下固定范式原因并触发 `git_tag.sh`。
- `scripts/add_package.sh`：按 `templates/package_github_deb.json` 向 `config/packages.json` 追加官方 GitHub `.deb`。校验 Debian 包名、清单去重、Ubuntu apt/snap 同名冲突，并默认请求 `/releases/latest` 确认各架构正则唯一匹配；`--skip-remote-check` 供离线测试。写入后再跑 `scripts/sync.sh --check-catalog-only`。
- `scripts/reindex_apt_repo.sh`：在 `PublishPages` job 中生成 APT 索引、签名并推送到 `apt-hub-pages`，轮询 Pages 部署完成后回写 README。不负责上传 `.deb`。
- `scripts/release_assets.sh`：为当前本仓 tag 制定构包、复用或跳过计划，并准备/核验 Release 资产。只关心 `go_official_archive` 的构包决策。
- `scripts/sync.sh`：根据 catalog 与上游元数据生成签名索引和 `state.json`。`--check-catalog-only` 只校验清单。
- `scripts/render.sh`：用已发布状态渲染 README 列表和 Pages 首页。
- `scripts/add_source.sh`：用户侧加源脚本，发布时原样放到 Pages。

## 发布链路

日常更新由机器上的 `scripts/auto_check.sh`（或手动 `bash git_tag.sh`）打出 `v*` tag。GitHub Actions `Release_Build` 仅在 `push: tags` 时走母版四段：`Release` → `Build`（`george012/upload_github_release_assets_action@latest` 上传 `./build/upload_tmp_dir/*`）→ `PublishPages` → `RemoveOldRelease`。`workflow_dispatch` 仅用于换钥等手动重索引（`rotate_from`），不在 Actions 里调用 `git_tag.sh`，也不在 `main` 引用上上传资产。

## systemd 定时

模板在 `templates/systemd/`：`apt-hub-auto-check.service`（系统级）、`apt-hub-auto-check.user.service`（用户级，安装时复制为同名 `apt-hub-auto-check.service`），共用 `apt-hub-auto-check.timer`。每次运行覆盖 `@REPO@/tmp/auto_check.last.log`，不向 journald 堆积历史。系统级与普通用户级的启用、手动触发和卸载见 `docs/maintenance.md`。默认每天北京时间 12:17 跑一次 `auto_check.sh`；无更新则不发版。
