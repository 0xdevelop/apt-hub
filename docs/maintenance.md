# 维护说明

[返回 README](../README.md) · [首次启用](nees_user_read.md)

## 新增软件

接入入口是 `config/packages.json`，不为每个软件另建目录或复制同步脚本。官方已有 GitHub `.deb` 时，在仓库根目录执行：

```bash
bash scripts/add_package.sh --id example-app --repository official-owner/example-app \
  --package example-app --description '软件用途的简短说明' \
  --source-url https://github.com/official-owner/example-app --license MIT \
  --arch 'amd64=^example-app_[0-9.]+_amd64\.deb$' \
  --arch 'arm64=^example-app_[0-9.]+_arm64\.deb$'
```

缺字段且在终端交互时会逐项询问。脚本会校验：

- Debian/APT 包名：`package` 必须等于 `.deb` 的 `Package`，且匹配 `^[a-z0-9][a-z0-9.+-]+$`
- 与现有清单的 `id` / `package` 去重
- 本机有 `apt-cache` / `snap` 时，拦截与 Ubuntu 自带 apt 或 snap 同名的冲突
- 默认请求目标仓库 `/releases/latest`，每个架构正则必须唯一匹配一个正式版 `.deb`；离线可加 `--skip-remote-check`

校验通过后写入 `config/packages.json`，并调用 `scripts/sync.sh --check-catalog-only`。也可按 `templates/package_github_deb.json` 手工追加（保留已有条目）：

```json
{
  "id": "example-app",
  "repository": "official-owner/example-app",
  "package": "example-app",
  "description": "软件用途的简短说明",
  "source_url": "https://github.com/official-owner/example-app",
  "license": "MIT",
  "ubuntu_series": "supported",
  "architectures": {
    "amd64": "^example-app_[0-9.]+_amd64\\.deb$",
    "arm64": "^example-app_[0-9.]+_arm64\\.deb$"
  }
}
```

字段要点：`id` 以 ASCII 字母或数字开头，只含字母、数字、`_`、`.`、`-`，且不能含 `..`。`repository` 必须是上游官方 GitHub `owner/repository`。`ubuntu_series` 为 `"supported"`（当前标准支持集合）或其子集。`architectures` 目前支持 `amd64`、`arm64`，每个正则必须恰好匹配一个官方正式版 `.deb`。缺官方 SHA256 digest、匹配不唯一、包身份不符或同版本换字节时拒绝发布。版本、大小和摘要由官方发布与包元数据取得，不手填。清单生效后，下一次 `auto_check.sh` 或手动发版会纳入；已加源使用者重跑同一条加源命令即可。

`source_type` 省略表示官方 GitHub `.deb`；`go_official_archive` 表示核验 Go 官方归档后由本仓构包。Go 清单里的 `repository` 仍指向 `golang/go`，生成包的发布仓库由 `--package-repository` 指定。上游只有归档、没有官方 `.deb` 时，在 `scripts/` 实现构包并接入 `gen_debs.sh`，不复制发布流程，也不在客户端安装阶段联网下载主程序。

## 巡检与发版

日常巡检用 `scripts/auto_check.sh`（须在有 `origin` 推送权限、工作区干净的仓库运行）：

- 先同步 `origin/main` 与 `origin/apt-hub-pages` 的 `state.json`；工作区不干净或与 `origin/main` 分叉则拒绝
- 构包类（如 golang）：比对上游最新稳定版和 `build_inputs_sha256`
- 外链 `.deb`（如 rustdesk）：比对各自 GitHub `/releases/latest`
- 签名续签：默认 `--renew-days 7`（索引 `Valid-Until` 为 14 天）；`0` 表示不检查
- 无更新：打印状态并 exit 0，不改仓库
- `--dry-run`：仍做探测和本地预验，不调用 `git_tag.sh`、不提交、不推送
- 预验：构包类在本机架构跑 `build.sh --arch` 与 `build.sh test`；外链 `.deb` 校验资产 URL 可达（HTTP 200/302）且元数据合法
- 预验通过且非 dry-run 时，写下固定范式原因并调用 `git_tag.sh`，例如 `auto-update: golang 1.27.4 -> 1.27.5`、`auto-update: rustdesk 1.4.6 -> 1.4.7`、`auto-renew: apt signing refresh`

```bash
bash scripts/auto_check.sh --dry-run
bash scripts/auto_check.sh
```

`VERSION` 只属于维护脚本，禁止手工修改。手动发版在干净仓库执行：

```bash
bash git_tag.sh
```

无参数与 `auto` 等价：进位版本（末段加 1，超过 `999` 向前进位）、写 `changelog/vX.Y.Z.md`、提交 `Release:--: vX.Y.Z_...`，并原子推送当前分支、版本 tag 与浮动标签 `latest`。`-get_pre_del_tag_name` 只查询前一版本。不手填版本、不重写已有 `vX.Y.Z`。真实发版须经用户明确授权。

随后 Actions 仅在 `push: tags` 走 `Release → Build → PublishPages → RemoveOldRelease`。`workflow_dispatch` 只用于换钥等手动重签（`rotate_from`），不在 Actions 里调用 `git_tag.sh`，也不在 `main` 上上传资产。

构包与复用（只针对 `go_official_archive`）：

- 包版本形如 `2:上游版本-基础修订`，不随仓库 tag 或重签而变化，不手填修订，不替换已发布字节
- 目标 tag 尚无包、且与上一已发布标签的 `build_inputs_sha256`（只由 `scripts/gen_deb_golang.sh` 与 `config/go.json` 计算）及 Go 官方归档元数据一致时，复用旧 `.deb` 原字节
- 构建输入或 Go 上游变化时拒绝复用，在目标版重新构包
- 空 Release 只补包或补复用，不因此新打 tag

`RemoveOldRelease` 在 `Release` 与 `PublishPages` 成功后清理两代前的 Release；不足两代或当前索引仍引用的资产不删。签名私钥、换钥见[使用与部署](nees_user_read.md#恢复与换钥)。

本地生成签源候选（不上传、不推送、不部署）可用：

```bash
bash scripts/update_sources.sh --catalog config/packages.json --previous tmp/previous --work-dir tmp/update-001 --gnupghome '<签名密钥目录>' --fingerprint '<公开指纹>' --site-url 'https://packages.example.test/tools' --package-repository '<自己的owner/repo>' --release-tag '<本次页面vX.Y.Z>' --package-release-tag '<实际包来源vX.Y.Z>'
```

`tmp/previous` 须为已有发布快照或首次使用的空目录；工作目录必须是新建或空目录。`--package-release-tag` 省略时与页面版本相同。

## systemd 定时巡检

在对 `origin` 有推送权限、且已配置 git 用户名和邮箱的 Linux 机器上启用。需要 systemd 240 及以上（Ubuntu 22.04、24.04 满足）。模板：

- `templates/systemd/apt-hub-auto-check.service`：系统级。`sudo` 安装到 `/etc/systemd/system/`。`User=` / `Group=` 是仓库维护者，不是用 root 跑 `auto_check.sh`
- `templates/systemd/apt-hub-auto-check.user.service`：普通用户级。安装时复制为 `~/.config/systemd/user/apt-hub-auto-check.service`（不要保留 `.user` 后缀，以便与 timer 的 `Unit=` 对齐）
- `templates/systemd/apt-hub-auto-check.timer`：两套共用，安装后单元名都是 `apt-hub-auto-check.timer`

每次触发覆盖同一个文件 `tmp/auto_check.last.log`（`StandardOutput=truncate:`，`StandardError=inherit`），不向 journald 堆积历史。该文件在已忽略的 `tmp/` 下，不会让工作区变脏，也就不会被 `auto_check.sh` 拒绝。仓库跟踪 `tmp/.gitkeep`，保证克隆后日志目录已存在。默认每天北京时间 12:17 运行；无更新时 exit 0 且不打 tag。把下面的仓库路径换成实际位置。

### 系统级（sudo 安装）

```bash
repo=/home/certa/workspace/apt-hub
user="$(id -un)"
sudo sed "s|@REPO@|${repo}|g; s|@USER@|${user}|g" \
  "${repo}/templates/systemd/apt-hub-auto-check.service" \
  | sudo tee /etc/systemd/system/apt-hub-auto-check.service >/dev/null
sudo sed "s|@REPO@|${repo}|g" \
  "${repo}/templates/systemd/apt-hub-auto-check.timer" \
  | sudo tee /etc/systemd/system/apt-hub-auto-check.timer >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now apt-hub-auto-check.timer
sudo systemctl list-timers apt-hub-auto-check.timer
```

手动触发、查看最近一次日志、停用并卸载：

```bash
repo=/home/certa/workspace/apt-hub
sudo systemctl start apt-hub-auto-check.service
cat "${repo}/tmp/auto_check.last.log"
sudo systemctl disable --now apt-hub-auto-check.timer
sudo rm -f /etc/systemd/system/apt-hub-auto-check.service \
  /etc/systemd/system/apt-hub-auto-check.timer
sudo systemctl daemon-reload
```

### 普通用户级（systemd --user）

单元装在用户目录，不必写入 `/etc`。若希望注销后定时器仍运行，需要对该用户开启 linger（若当前用户无权执行，再加 `sudo`）：

```bash
repo=/home/certa/workspace/apt-hub
mkdir -p ~/.config/systemd/user
sed "s|@REPO@|${repo}|g" \
  "${repo}/templates/systemd/apt-hub-auto-check.user.service" \
  > ~/.config/systemd/user/apt-hub-auto-check.service
sed "s|@REPO@|${repo}|g" \
  "${repo}/templates/systemd/apt-hub-auto-check.timer" \
  > ~/.config/systemd/user/apt-hub-auto-check.timer
systemctl --user daemon-reload
systemctl --user enable --now apt-hub-auto-check.timer
loginctl enable-linger "$(id -un)" || sudo loginctl enable-linger "$(id -un)"
systemctl --user list-timers apt-hub-auto-check.timer
```

手动触发、查看最近一次日志、停用并卸载：

```bash
repo=/home/certa/workspace/apt-hub
systemctl --user start apt-hub-auto-check.service
cat "${repo}/tmp/auto_check.last.log"
systemctl --user disable --now apt-hub-auto-check.timer
rm -f ~/.config/systemd/user/apt-hub-auto-check.service \
  ~/.config/systemd/user/apt-hub-auto-check.timer
systemctl --user daemon-reload
```

卸载用户级单元时不要顺手关闭 linger，除非确认本机没有其他用户服务依赖它。

## 本地验证

依赖：Bash、curl、jq、GnuPG、dpkg、`apt-ftparchive`、`readelf`、`xxd`、PATH 中的 ShellCheck、Ubuntu 官方 archive keyring。Node.js 只用于测试夹具。项目不在本机自动安装依赖。测试在 `tmp/` 使用临时密钥和测试包，不安装测试包、不改系统软件源。访问 Ubuntu 官方源失败不算测试通过。

```bash
bash tests/sync_test.sh && bash tests/render_test.sh && bash tests/workflow_test.sh && bash tests/git_tag_test.sh && bash tests/auto_update_test.sh && bash tests/auto_check_test.sh && bash tests/add_package_test.sh && bash tests/add_source_test.sh && bash tests/update_sources_test.sh && bash tests/go_deb_test.sh && bash tests/go_source_test.sh && bash tests/release_test.sh && bash tests/ubuntu_test.sh
```

## 发布数据与并发

- `apt-hub-pages` 只保存签名索引、公钥、分流列表、已发布元数据和 `add_source.sh`，不存 `.deb`。官方 `.deb` 由客户端按已签名元数据从官方地址获取；Go 包从本仓 Release assets 获取。
- `data/published.json` 只记录成功部署后的状态，不手填未生效软件。
- `scripts/render.sh` 只替换 README 中 `APT-HUB:PACKAGES:BEGIN` / `END` 两条独占行之间的区域；区域外正文由人维护。标记缺失或重复则拒绝写入。
- 站点版本使用本仓 `vX.Y.Z`，不是上游软件版本。
- 定时、手动与 tag 的 Actions 共用 `apt-hub-publish` 并发组，运行中的链不会被取消。
- `git_tag.sh` 对每个远端用一次 atomic 更新分支、版本 tag 和 `latest`：分支只快进，版本 tag 只创建，`latest` 只替换预期旧值。任一 ref 失败则整笔失败，不拆分重试、不改已有版本 tag。
- README 回写必须基于该运行检出的源码。main 已推进到新业务或正文变化时，旧运行失败且不回写；只有 main 是原源码后继且文件树恰好等于本次生成结果时才按幂等成功。
