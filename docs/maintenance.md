# 维护说明

[返回 README](../README.md) · [首次启用](nees_user_read.md)

## 软件清单

`config/packages.json` 是接入软件的配置入口，`packages` 可包含多个软件，不为每个软件复制同步脚本。官方已有 GitHub `.deb` 的新条目优先用 `scripts/add_package.sh` 写入，或照 `templates/package_github_deb.json` 填写。

- `id`：本仓唯一标识；`package` 必须等于 `.deb` 的 `Package`。
- `repository`：上游官方 GitHub `owner/repository`，不填第三方下载镜像。Go 条目仍指向 `golang/go`，生成包的发布仓库通过 `--package-repository` 单独指定。
- `source_type`：省略时读取官方 GitHub `.deb`；`go_official_archive` 表示核验 Go 官方归档后，由本仓构包与发版。原始归档与生成包的出处、摘要和大小分别记录。
- `description`：README 与静态页使用的简短说明。
- `source_url`、`license`：官方源码入口和许可信息；再分发条件仍须维护者核对。
- `architectures`：Debian 架构到发布资产名称正则的对应关系；每个架构必须唯一匹配一个真实 `.deb`。首版支持 `amd64`、`arm64`，不代表 Ubuntu 或上游支持的全部架构。
- `ubuntu_series`：`"supported"` 表示当前标准支持集合；也可填写明确的 Ubuntu 代号数组，但必须是该集合的子集。上游有限制时应收窄，不能因本机能下载就任意扩大。

清单新增后，下一次发布会纳入新软件，并从相同的已发布状态生成各 Ubuntu 代号的 `repos/<代号>.sources` 聚合配置；存量使用者重跑同一加源命令即可纳入。版本、包大小和摘要由官方发布及实际包元数据取得，不手填。

### 新增软件

官方已有 GitHub `.deb` 时，优先在仓库根目录执行：

```bash
bash scripts/add_package.sh --id example-app --repository official-owner/example-app \
  --package example-app --description '软件用途的简短说明' \
  --source-url https://github.com/official-owner/example-app --license MIT \
  --arch 'amd64=^example-app_[0-9.]+_amd64\.deb$' \
  --arch 'arm64=^example-app_[0-9.]+_arm64\.deb$'
```

脚本会检查 Debian/APT 包名、与现有清单去重，并在本机有 `apt-cache` / `snap` 时拦截 Ubuntu 同名冲突；默认再请求目标仓库 `/releases/latest`，确认每个架构正则只匹配一个 `.deb`。离线调试可加 `--skip-remote-check`。校验通过后写入 `config/packages.json`，并调用 `scripts/sync.sh --check-catalog-only`。

也可以将下面的对象手工加入 `packages` 数组，保留已有条目，按真实信息替换占位值：

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

`id` 以 ASCII 字母或数字开头，只含字母、数字、`_`、`.`、`-`，且不能含 `..`。`package` 必须等于 `.deb` 的 `Package` 字段，并遵守 Debian/APT 包名约定（以小写字母或数字开头，其后只使用小写字母、数字、`-`、`+`、`.`）；选名时必须与 Ubuntu 自带的 apt 包和 snap 包名错开，避免同名冲突。每个架构的正则必须恰好匹配一个官方正式版 `.deb`。缺官方 SHA256 digest、匹配不唯一、包身份不符或同版本换字节时拒绝发布。上游只有归档时，在 `scripts/` 实现具体构包处理并接入 `gen_debs.sh`，不复制发布流程或在客户端联网安装主程序。

## 发布数据与列表

- `apt-hub-pages` 分支只保存签名索引、公开公钥、分流列表、已发布元数据和 `add_source.sh`，不承担通用二进制存储。RustDesk 等官方 `.deb` 由客户端按已签名元数据从官方地址获取；Go 生成包从对应本仓 Release assets 获取。缺少可验证的官方包或构造包时，发布直接拒绝，不把二进制塞进 Pages 分支。
- `data/published.json` 只记录成功部署后回写的状态，不手动填入尚未生效的软件。
- Pages 提交只沿上一份产物追加，首次创建独立产物历史；不追加源码父提交。站点文件未变时复用原产物提交，版本对应关系由发布记录和页面链接表达。
- `templates/readme_packages.md`、`templates/readme_empty.md` 控制列表表头与空态；`templates/index.html` 控制首页。页面显示用途、当前站点版本、源根地址、加源与安装命令和软件短表，随同一次发布自动生成。
- 站点版本使用本次本仓 `vX.Y.Z`，不是 Go 或 RustDesk 的软件版本。当前发行版和变更记录链接固定到该标签；“最新发行版”链接使用 GitHub `releases/latest`，不依赖脚本维护的 `latest` 标签。变更记录沿用 `changelog/vX.Y.Z.md` 的 GitHub 渲染页，不另建前端或 Markdown 解析器。
- `scripts/render.sh` 只替换 README 中 `APT-HUB:PACKAGES:BEGIN` / `END` 两条独占行之间的区域，区域外正文由人维护。缺失或重复标记会拒绝写入。

`RemoveOldRelease` 沿母版依赖 `Release` 与 `Build` 成功后自动运行，适用于 tag、定时与手动运行，也覆盖无变化复用和同版本恢复。清理目标由本次维护版本连续递减两次取得；不足两代跳过，仅检查当前 `Packages`/`Packages.gz` 索引是否仍引用 `releases/download/<旧tag>/` 资产，仍被当前索引引用时不删，不因保留的历史 `by-hash` 而阻止删除两代前旧 Release（若旧缓存客户端仍命中历史索引，须先执行 `apt update` 刷新索引）。它不是遍历所有旧 Release 的批量清空；Pages 侧三代历史 `by-hash` 的保留逻辑不因重新索引而取消。

签名与候选元数据每日续期，软件的 `updated_at` 不因扫描、重签而变化。Pages 部署失败不能更新主分支为“已生效”；回写失败也不强推覆盖同事提交，修复后重跑使状态收敛。

## 一条命令检查并更新候选

Actions 和本地维护共用 `scripts/update_sources.sh`。本地运行时提供已有签名密钥目录和公开指纹；指纹不是 Secret，Actions 会从导入的签名私钥取得。

```bash
bash scripts/update_sources.sh --catalog config/packages.json --previous tmp/previous --work-dir tmp/update-001 --gnupghome '<签名密钥目录>' --fingerprint '<公开指纹>' --site-url 'https://packages.example.test/tools' --package-repository '<自己的owner/repo>' --release-tag '<本次页面vX.Y.Z>' --package-release-tag '<实际包来源vX.Y.Z>'
```

其余参数是候选目录、站点和发行版数据输入；入口只生成候选，不上传、不推送、不部署。

以上地址、版本和指纹均需替换；`tmp/previous` 须为已有发布快照或首次使用的空目录，工作目录必须是新建或空目录。`--release-tag` 是页面维护版本；`--package-release-tag` 必须指向实际存在且通过核验的包资产，省略时与页面版本相同。Go 每个架构只发布一个完整 `golang` 包，控制字段为 `2:上游版本-基础修订`；包版本不随仓库 tag 重发或页面重签而变化，不手填修订，不替换已发布字节。当新目标 `vX.Y.Z` 尚未有包资产、且上一已发布标签（由 `apt-hub-pages` 的 `state.json` 指向）经完整校验后与当前构包输入指纹 `build_inputs_sha256`（仅由 `scripts/gen_deb_golang.sh` 与 `config/go.json` 计算，不纳入 `config/packages.json` 全文）、`config/packages.json` 中 `go_official_archive` 的 `package`/`architectures` 兼容性，以及另行核对的当前 Go 官方归档元数据（版本、架构、URL、SHA-256、size）均一致时，工作流通过 `scripts/release_assets.sh prepare-reuse` 直接下载旧 Release `.deb` 原字节上传新目标 Release，不重打包、不涨 `revision`；`golang.provenance.json` 保持原 `generated_at_utc`、`build_inputs_sha256`、`upstream` 与 `packages` 不变，仅补充 `reused_from`（含 `repository`、`origin_release_tag`、`source_release_tag`、`source_provenance_sha256`、`target_release_tag`）区分原构建来源与本次复用信息，并按目标版实际 3 个文件重新生成 `SHA256SUMS`。随后由 `scripts/sync.sh` 重建仅指向本版的 `Packages`/`Packages.gz`/`by-hash`/`Release` 并用原 GPG 私钥重签 `InRelease`/`Release.gpg`。

`git_tag.sh`（无参数默认为 `auto`）触发同一条三段式发布链；`build.sh` 调用 `gen_debs.sh` 按清单处理软件，Go 专用格式转换位于 `scripts/gen_deb_golang.sh`。官方已有 `.deb` 只发现和核验官方发布，不转存；构造包、`<软件id>.provenance.json` 与 `SHA256SUMS` 才进入 `build/upload_tmp_dir/`，直接上传到对应本仓版本的 assets。归档、内部索引、日志和测试不进入发布成果。Pages 复用 `apt-hub-pages` 产物分支发布，只保存公开站点与签名索引，不走 Actions Artifacts，也不再另建站点副本。

签名私钥生成、备份、换钥和客户端报错修复见[使用与部署](nees_user_read.md#恢复与换钥)。只更新同一个 `APT_HUB_GPG_PRIVATE_KEY` Secret。

## 本地验证

需要已有 Bash、curl、jq、GnuPG、dpkg 工具、`apt-ftparchive`、`readelf`、`xxd`、Node.js、PATH 中可调用的 ShellCheck 和 Ubuntu 官方 archive keyring。Node.js 仅用于测试的隔离 HTTPS 夹具，不是源维护脚本或客户端的运行依赖。项目不自动在本机安装依赖。

测试在项目 `tmp/` 使用临时测试密钥和测试包；不安装测试包、不改变系统软件源。Ubuntu 测试需要访问官方软件源，网络失败不是测试通过。

执行完整既有测试：

```bash
bash tests/sync_test.sh && bash tests/render_test.sh && bash tests/workflow_test.sh && bash tests/git_tag_test.sh && bash tests/auto_update_test.sh && bash tests/auto_check_test.sh && bash tests/add_package_test.sh && bash tests/add_source_test.sh && bash tests/update_sources_test.sh && bash tests/go_deb_test.sh && bash tests/go_source_test.sh && bash tests/release_test.sh && bash tests/ubuntu_test.sh
```

测试密钥只用于本地 `tmp/`，不放进生产 Actions Secret；测试目录不要混放用户文件。

## 本仓脚本版本

`VERSION` 只属于维护脚本，禁止手工修改。统一通过下列命令自动递增、生成变更记录、提交、打标签并推送：

```bash
bash git_tag.sh
```

脚本沿用 `project_template_go/git_tag.sh`，只适配根目录 `VERSION` 和本仓变更记录，不生成 Go API 文档。无参数与 `auto` 等价；`-get_pre_del_tag_name` 仅查询前一版本。发版保留母版的分支、`latest` 与版本标签推送，以及本地旧标签清理；首次没有 `latest` 或本地旧标签时不会因此失败，历史变更记录保留。

首次脚本标签为 `v0.0.1`；以后末段逐次加 1，超过 `999` 向前进位。不手填版本、不重写已有 `vX.Y.Z` 标签；`latest` 是随发版更新的浮动标签。日常联动更新由 `scripts/auto_check.sh`（systemd 或手动，支持 `--dry-run`）巡检全部已支持软件：构包类比对上游稳定版与 `build_inputs_sha256`，外链 `.deb` 比对 GitHub `/releases/latest`，签名默认超过 7 天续签（`Valid-Until` 为 14 天）。有更新并完成本地预验后，写下固定范式原因并调用 `git_tag.sh` 进位；随后 Actions 仅在 `push: tags` 上沿母版四段 `Release → Build → PublishPages → RemoveOldRelease` 构包或复用、上传、重索引和清理。无更新不升版。`workflow_dispatch` 只用于换钥等手动重签，不在 Actions 里调用 `git_tag.sh`。当前标签已完整且无变化时 Build 跳过构包，由 Pages 重签；新目标标签空或可续接复用且上一标签构建输入与 Go 上游未变时，跨标签复用旧 `.deb` 原字节并生成本版完整四资产；输入或 Go 上游变化时拒绝旧产物复用并在目标版重新构包；空 Release 按需补构包或补复用，部分上传只补字节一致的缺项。真实发版须经用户明确授权。

## systemd 定时巡检

在对 `origin` 有推送权限、且已配置 git 用户名和邮箱的 Linux 机器上启用。需要 systemd 240 及以上（Ubuntu 22.04、24.04 满足）。模板在 `templates/systemd/`：

- `apt-hub-auto-check.service`：系统级单元（`sudo` 安装到 `/etc/systemd/system/`）。单元里的 `User=` / `Group=` 仍是仓库维护者，不是用 root 跑 `auto_check.sh`。
- `apt-hub-auto-check.user.service`：普通用户级单元，安装时复制为 `~/.config/systemd/user/apt-hub-auto-check.service`（不要保留 `.user` 后缀，以便与 timer 的 `Unit=` 对齐）。
- `apt-hub-auto-check.timer`：两套共用，安装后单元名都是 `apt-hub-auto-check.timer`。

每次触发都会截断并覆盖同一个日志文件 `tmp/auto_check.last.log`（`StandardOutput=truncate:`，`StandardError=inherit`），不向 journald 堆积历史输出。该路径位于已忽略的 `tmp/` 下，不会把工作区弄脏，也就不会被 `auto_check.sh` 拒绝。仓库跟踪 `tmp/.gitkeep`，保证克隆后日志目录已存在。

默认每天北京时间 12:17 运行；无更新时脚本 exit 0 且不打 tag。把下面命令中的仓库路径换成实际位置。

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

手动触发一次、查看最近一次日志、停用并卸载：

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

不需要把单元安装到 `/etc`。若希望注销后定时器仍运行，需要对该用户开启 linger（若当前用户无权执行，再加 `sudo`）：

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

手动触发一次、查看最近一次日志、停用并卸载：

```bash
repo=/home/certa/workspace/apt-hub
systemctl --user start apt-hub-auto-check.service
cat "${repo}/tmp/auto_check.last.log"
systemctl --user disable --now apt-hub-auto-check.timer
rm -f ~/.config/systemd/user/apt-hub-auto-check.service \
  ~/.config/systemd/user/apt-hub-auto-check.timer
systemctl --user daemon-reload
```

卸载用户级单元时不要顺手关闭 linger，除非你确认本机没有其他用户服务依赖它。

## 自动巡检与本地发版重合

定时、手动运行与版本 tag 的 Actions 共用 `apt-hub-publish` 并发组，运行中的链不会被新事件取消；这不锁住本地终端，也不保证排队事件按顺序逐个执行。

`git_tag.sh` 对每个远端用一个 atomic 事务更新当前分支、新版本 tag 和 `latest`：分支仅快进，版本 tag 只创建，`latest` 只替换刚读到的预期旧值。不再先删远端 `latest`。任一 ref 竞争、权限拒绝或服务不支持 atomic，整笔失败，不拆分重试、不改已有版本 tag；多远端之间不是一个跨服务器事务。失败后保留本地提交供核对，不自动重写用户历史。

Pages 部署之后，README 回写基于该运行实际检出的源码生成，而不是在最新 main 上盲目追加。main 已推进到新业务、版本或正文变化时，旧运行明确失败、不回写且不进入清理；新版本事件可以随后继续。只有 main 是原源码后继且整棵文件树恰好等于本次生成结果时才按幂等成功。回写时的普通非强推继续保护并发推进；已部署 Pages 可能短暂先于失败的旧回写，需后继运行收敛。过时事件仍受 Release 阶段严格保护，不能将历史 run 重跑等同于自动发布最新源码。

并发交错已在本机隔离 bare 远端验证，不代表真实 GitHub 同时发版已经实测。不要为了测试重打标签或覆盖线上资产。

## 上游与历史索引

保留必要的历史 by-hash 元数据。安装包不进入 Git 或 Pages，因此 Git 单文件大小不是接入软件包的限制；上游删除历史包后，本项目不承诺仍能下载该版本，也不静默转用第三方镜像。
