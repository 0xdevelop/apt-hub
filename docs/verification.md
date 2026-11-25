# 验证记录

## 2026-11-25 跨标签同输入 Go 资产原字节复用与只读基线核对

- **运行环境与状态记录回退**：现场工作区位于 `spark-901f` (`/home/certa/workspace/apt-hub`)；本仓库未启用/未连接 `xjb` 项目、任务或局域网后端锁（未初始化或改动任何服务/密钥/认证），按既有 Markdown 状态回退约定将完整记录记于本文件及 `docs/maintenance.md`。本地仓库在提交前已快进合入 `origin/main` 回写提交 `55e73cb`。
- **工作流与非发版触发核查**：`.github/workflows/release.yml` 仅在 `push.tags: ['v*']`、`schedule`、`workflow_dispatch` 触发；普通推送至 `main` 分支不触发发版、构包、上传或 Pages 部署。`RemoveOldRelease` 保持三代 `by-hash` 保留窗口及仅检查当前 `Packages`/`Packages.gz` 引用的清理策略，未改动 `v0.0.10` 或生产 Release 资产。
- **线上 `v0.0.13` 只读真实证据（严格区分于本地隔离夹具）**：
  - 线上 `v0.0.13` Release 具备完整 4 个资产（`golang_1.27.4-2_amd64.deb`、`golang_1.27.4-2_arm64.deb`、`golang.provenance.json`、`SHA256SUMS`）；`golang.provenance.json` SHA-256 为 `c7500fecb8aa47375615fefc5d6aa0c8f344bde33e03039d33c648e7020c111d`，`generated_at_utc=2026-11-02T20:36:20Z`，`upstream` 为 `go1.27.4`（`epoch=2`、`revision=2`）。
  - 本机当前 `sha256sum scripts/gen_deb_golang.sh config/go.json | sha256sum` 为 `feb45c05245fcf1ba6a1c97dae0c9233634a85b2699473f8da6e626a4783739a`，与线上 `v0.0.13` `golang.provenance.json` 的 `build_inputs_sha256` 一致；`go.dev` 最新稳定版仍为 `go1.27.4`。未在生产执行 `git_tag.sh`、打新 tag、`workflow_dispatch`、生产资产修改或删除。
- **构建输入闭包审查（仅限源码结构证据）**：
  - 沿实际构包调用链 `build.sh:87-108` → `gen_debs.sh:293-369` → `scripts/gen_deb_golang.sh:1-879` 核对：
    - `build.sh` 不传模板、补丁或额外构包环境变量；`gen_debs.sh` 仅从 `config/packages.json` 读取唯一 `go_official_archive` 的 `id`（`golang`，仅用于重命名 `${go_id}.provenance.json`）并以 `--config "${ROOT}/config/go.json"` 调用 `scripts/gen_deb_golang.sh`（`gen_debs.sh:342,352,361-362`）。`config/packages.json` 的 `package` 与 `architectures` 组合一致性由 `scripts/release_assets.sh` 的 `validate_constructed_dir` 与 `check_reuse_source_matches_current` 交叉校验。
    - `scripts/gen_deb_golang.sh` 不读取外部补丁、`templates/`（仅用于 `render.sh`）或辅助子脚本；控制字段、路径布局、`umask 022`、`LC_ALL=C`/`LANG=C`/`LANGUAGE=C`、`SOURCE_DATE_EPOCH`（仅取自认证上游 `go/VERSION`）及 `dpkg-deb --build --root-owner-group -Zgzip -z9` 均硬编码于脚本内，包元数据（`package`、`epoch`、`revision`、`architectures`、`description`、`maintainer`、`homepage`、`section`、`priority`）来自 `config/go.json`，脚本第 787 行自身即按 `scripts/gen_deb_golang.sh` 与 `config/go.json` 计算 `build_inputs_sha256`。
  - **审查边界声明**：上述结论仅依据仓库源码调用结构与配置封装，**不声称消除了宿主/CI 外部工具链版本差异**（如 `dpkg-deb`、`gzip`、`tar` 等二进制自身版本升级可能带来的隐式字节差异）；当前复用契约沿用既有已验证包/输入/架构契约，不扩大修改 `build_inputs_sha256` 构成。
- **实现改动（共 9 个文件）**：
  - `scripts/release_assets.sh`：为 `plan` 增加同输入跨标签复用判定（输出 `reuse_from_tag`），新增 `prepare-reuse`（校验旧 Release 完整性与当前构建输入/Go 上游一致性，原字节保留 `.deb`、保留原构建 `generated_at_utc`/`build_inputs_sha256`/`upstream`/`packages` 并写入确定性 `reused_from`、重算 `SHA256SUMS`），在 `validate_constructed_dir` 增加 `match_current_config` 参数复用同一套字节/control 校验，并在 `local-status`、`stage-upload`、`remote-status` 校验 `reused_from`。
  - `.github/workflows/release.yml`：`release` job 透传 `reuse_from_tag`，`Build` job 在 `build_packages == '0' && reuse_from_tag != ''` 时走 `prepare-reuse` -> `local-status` -> `stage-upload` -> 上传 4 资产 -> `remote-status` -> `publish_apt_site.sh publish`。
  - `scripts/sync.sh`：校验活跃/存量 `golang.provenance.json` 的 `reused_from` 结构、标签顺序、仓库与目标标签匹配；修复跨标签同版本同字节迁移时 `updated_at` 匹配规则（优先按 `package + architecture` 比对旧 `sha256`），避免因资产 URL 标签路径变化导致 `updated_at` 误刷新。
  - `tests/auto_update_test.sh`、`tests/workflow_test.sh`、`tests/release_test.sh`、`tests/go_source_test.sh` 与 `docs/maintenance.md`、`docs/verification.md`。
- **分段门禁执行记录（如实区分原 `build.sh test` `exit 1` 与 12 套分段通过，不冒称单次 `build.sh test` `exit 0`）**：
  - 所有原始与复核日志归档于本仓 Git 忽略目录 `tmp/gate-20261125-reuse/`：
  - **原全量入口 `bash ./build.sh test`（PID `3553500`，未重跑/未中断自然收口）**：**`exit 1`**，日志 `tmp/gate-20261125-reuse/build-test-96709.log`。首项 `tests/ubuntu_test.sh` 因外部网络故障失败（`failures=2`：`curl: (35) ubuntu.com:443 SSL_ERROR_SYSCALL` 及 `verify-ok` 中 `noble/amd64 apt-get update` 超时 `exit=124`），未继续执行后续 11 套件。
  - 确认 `build/upload_tmp_dir` 不存在后，对 12 套测试分段执行并仅对瞬时网络超时套件做有界重试，**12 / 12 全部取得 `exit 0`**：
    1. `bash tests/auto_update_test.sh` -> `pass=14 fail=0`，**`exit 0`**（重构后重跑，覆盖跨 tag 四资产复用、链式复用、真实修改 `scripts/gen_deb_golang.sh` 与 `config/go.json` 触发 `build_inputs_sha256` 失效、缺损旧资产 fail closed），日志 `tmp/gate-20261125-reuse/auto_update_test.log`。
    2. `PATH="$PWD/tmp/go-final-parent/bin:$PATH" bash tests/release_test.sh` -> `TOTAL PASS=86 FAIL=0`，**`exit 0`**（重构后重跑，含 `shellcheck`、`reused_from` 匹配/不匹配），日志 `tmp/gate-20261125-reuse/release_test.log`。
    3. `bash tests/workflow_test.sh` -> `pass=94 fail=0`，**`exit 0`**（抽提 `release.yml` `id: reuse` 与失败传播/tag 不匹配拒绝），日志 `tmp/gate-20261125-reuse/workflow_test.log`。
    4. `bash tests/go_source_test.sh` -> `go_source_test 通过`，**`exit 0`**（跨 tag 复用 `sync`、原 GPG 验签、保留 `updated_at`、隔离 HTTPS `verify_ubuntu.sh --verify-downloads`、已装同 `Version` `dpkg/status` 下 `apt-get --simulate --with-new-pkgs -y upgrade` 输出 `0 upgraded, 0 newly installed, 0 to remove`），日志 `tmp/gate-20261125-reuse/go_source_test.log`。
    5. `PATH="$PWD/tmp/go-final-parent/bin:$PATH" bash tests/sync_test.sh` -> `PASS=117 FAIL=0`，**`exit 0`**，日志 `tmp/gate-20261125-reuse/sync_test.log`。
    6. `PATH="$PWD/tmp/go-final-parent/bin:$PATH" bash tests/render_test.sh` -> `pass=408 fail=0`，**`exit 0`**，日志 `tmp/gate-20261125-reuse/render_test.log`。
    7. `PATH="$PWD/tmp/go-final-parent/bin:$PATH" bash tests/ci_dependencies_test.sh` -> `pass=3 fail=0`，**`exit 0`**，日志 `tmp/gate-20261125-reuse/ci_dependencies_test.log`。
    8. `PATH="$PWD/tmp/go-final-parent/bin:$PATH" bash tests/git_tag_test.sh` -> `pass=18 fail=0`，**`exit 0`**，日志 `tmp/gate-20261125-reuse/git_tag_test.log`。
    9. `PATH="$PWD/tmp/go-final-parent/bin:$PATH" bash tests/add_source_test.sh` -> 通过，**`exit 0`**，日志 `tmp/gate-20261125-reuse/add_source_test.log`。
    10. `bash tests/go_deb_test.sh` -> `TOTAL=142 PASS=142 FAIL=0`，**`exit 0`**，日志 `tmp/gate-20261125-reuse/go_deb_test.log`。
    11. `bash tests/update_sources_test.sh` -> 首次 `real_chain` 因 `jammy/amd64 apt-get update` 超时 `exit=124`（`pass=44 fail=1`, `exit 1`）；有界重试第 1 次通过 `pass=55 fail=0`，**`exit 0`**，日志 `tmp/gate-20261125-reuse/update_sources_test.log`。
    12. `bash tests/ubuntu_test.sh`（PID `3668429`，最多 5 次有界重试）：try1 因 `stonking/arm64 apt-get update` 超时 `exit=124` 退出 `1`（`ubuntu_test.try1.log`）；try2 因 `resolute/arm64 apt-get update` 超时 `exit=124` 退出 `1`（`ubuntu_test.try2.log`）；**try3 全部通过 `failures=0`，`exit 0`**，日志 `tmp/gate-20261125-reuse/ubuntu_test.log`（完整三轮日志 `tmp/gate-20261125-reuse/ubuntu-retry-96713.log`）。
- **未验证项（需后续真实发版时确认）**：
  - 真实远端 GitHub Actions 触发新标签（如未来 `v0.0.14`）时 `release` → `Build(reuse)` → `publish_apt_site.sh` → `RemoveOldRelease` 的端到端在线运行结果（本轮严禁打新 tag、`workflow_dispatch` 或改动生产资产，故仅通过线上 `v0.0.13` 只读核对与完整本地/隔离夹具验证）。

## 2026-11-17 单包与产物分支纠偏

本节取代下文早先对“源码父节点必需”和双包结构的解释，保留旧记录用于对应原始证据。新 Go 产物每架构一个完整 `golang` 包；Debian 修订由基础修订加原 `VERSION` 自动派生，不替换旧版字节。Pages 后续提交只保留上一产物父节点，首次独立根；已推历史不重写。

候选已通过 Bash、ShellCheck、官方双架构归档构包和资产目录校验；`amd64` 单包在独占根实际安装，输出 `go1.27.4`，离线编译运行成功。独立复核未发现阻断问题。发布及公网站点结论以本次准确运行另记，不把本地验证当作生产成功。

## 2026-11-17 分支历史整理

- 远端只保留 `main` 和 `apt-hub-pages`；主工作树位于 `main`，没有遗留游离 worktree。已删除助手留下的七个 `refs/tmp/*` 临时引用，所指提交仍在 Pages 历史可达，不删除提交对象。
- 改名继承了旧产物历史，但最初产物提交 `31bbbccd` 无父节点，与源码没有共同祖先。新增快进提交 `470c6a70594bcbae028c2ac2be564b5661f38a48`：第一父节点保留原产物 `5bc17057`，第二父节点关联真实 v0.0.5 源码 `0160c5be`，不强推、不重写旧提交。
- 整理前后的站点 tree 均为 `17f55a3f578653b6de0324e7aed89aca1d0963d6`；公网首页、元数据、加源脚本和公钥与原产物逐字一致，六个既有标签没有移动。本轮不升版，不将分支整理当作旧发布作业已修复。
- 初始化缺父节点反例先红后绿；候选 `workflow_test.sh` 为 58 通过、0 失败，Ubuntu 既有真实 Git 子段为 37 通过、0 失败，覆盖旧产物首父、源码父、重复幂等、同树新源码与并发拒绝。Bash 语法与 ShellCheck 通过；未重跑不受影响的网络 APT 矩阵。

## 2026-11-17 公网源与发布收口

- 公网 v0.0.4 与 `apt-hub-pages` 提交 `df6e6c6fac361489f54fd93dfee853246eb1afd6` 的首页、元数据、加源脚本逐字一致；浏览器实际展示四列软件表、三段命令、维护版本与对应 Release／变更记录链接。
- 从公网下载的加源脚本在 `noble` 双架构隔离根完成默认全源添加与成功自删；专用公钥指纹、实际签名索引、APT 候选及六个下载包的摘要、大小和控制字段全部核对通过。Go 包来自本仓 v0.0.4，RustDesk 包来自官方 Release。
- `amd64` Go 两包实际安装到独占根，输出 `go version go1.27.4 linux/amd64`，离线编译运行输出 `apt-hub-public-install-ok`；两架构普通升级计划均从明确的 Ubuntu 旧版状态夹具选择同版本 Go 两包且无删除。这不是 RustDesk 图形界面或 arm64 硬件执行验证。
- 原发布阶段失败语句尚未取得，不能因匿名 API `404` 归因为工作流权限或重复构建。恢复显式 Pages 构建、准确提交及公网三文件回读后，定点红测 `9` 项失败，修正后父固定副本 `57` 项零失败、ShellCheck 退出 `0`；完整 Ubuntu 重跑 `101` 个 `OK`、`failures=0`，不重复执行无关矩阵。

本节公网消费证明 v0.0.4 产物可用，不代表修正后的 Release 工作流已成功。原始日志与逐项退出码在 `tmp/pages-live-final.RxDmR3/`。

## 2026-11-13 Pages 产物分支命名收口

- Pages 公开产物分支统一命名为 `apt-hub-pages`；脚本、工作流调用契约、测试和维护文档已同步，旧命名不再作为运行时输入。
- 原已有公开产物 tip `31bbbccd4caa0c03176e2fdb673888e42089da03` 已原样建立新分支；树内容逐项核对，未含 `.deb`。旧分支暂不删除，待 Pages 来源切换并完成新版公网验收后清理，避免切换期间中断。
- Pages 分支只承载签名索引、元数据、公开公钥、首页和加源脚本；必要二进制由官方原址或对应 Release assets 提供，缺失时发布失败，不把二进制塞入 Pages 分支兜底。
- 分支改名后的工作流夹具为 `48` 项零失败。完整 Ubuntu 维护验收第一次因 `stonking/arm64` 官方源更新超时退出 `1`；同一源码重跑退出 `0`，`101` 个 `OK`、`failures=0`。日志末尾 `1526` 是证据文件数，不是测试项数。
- `v0.0.4` 已由原 `git_tag.sh` 发布；Release 六份资产已列出，`apt-hub-pages` 提交 `df6e6c6fac361489f54fd93dfee853246eb1afd6` 与公网首页、`state.json`、`add_source.sh` 逐字一致；对应 Pages 运行 `44019430517` 成功。首页显示 v0.0.4、新域名和统一全源命令，但 Release 运行 `44018496526` 的站点发布步骤失败，具体失败语句尚无详细日志支持。
- 纠正此前对“重复 Pages API 导致失败”的归因：匿名接口 `404` 只代表当前访问边界，不能证明工作流内请求失败。GitHub 官方明确内置 `GITHUB_TOKEN` 的分支推送不触发 Pages 构建，因此保留显式构建请求，不将删掉请求当作修复。
- 主线 README 的已发布列表已从准确 v0.0.4 产物回写到新域名；固定未部署提示的清理另有回归检查。旧分支已经删除，历史提交完整保留在 `apt-hub-pages` 的祖先中。

## 2026-11-13 简明首页与版本展示

- 新域名首页与加源脚本逐字匹配旧 `apt-hub-pages` 提交，聚合源配置仍返回 `404`；这次确认的是旧产物尚未更新，不将问题归咎于浏览器缓存。
- 现有 HTML 模板新增用途、显式维护版本、站点根地址、统一加源命令、安装／普通升级命令和四列软件表。当前 Release 与 Markdown 变更记录绑定同一标签，“最新发行版”只链接 GitHub `releases/latest`。
- 最终固定副本运行渲染测试 `408` 项、发布测试 `48` 项，均零失败；真实 detached tag 下的 README 回写段两项通过。维护入口真实签源、APT 下载及渲染集成 `55` 项通过，退出均为 `0`。最后增量保留版本参数与调用契约，只收紧包名校验、简化升级命令并扩展公网回读。
- 原子拒绝非法版本参数及命令注入反例通过；公网回读测试确认仅 `state.json` 相同但首页或加源脚本滞后时不能返回部署成功。独占 Chrome 实际 DOM 为四列表头、三段可复制命令及准确版本链接，未加载前端框架或外部字体。
- Bash 语法、全部受影响生产脚本和测试的 ShellCheck、文档链接核对通过；`VERSION`、`git_tag.sh`、工作流、配置、生产列表和宿主基线未改。

以上为本地集成结果，正式发布与公网消费者结果须另记，不能作为新站点已经生效的证明。原始记录位于 `tmp/pages-live-final.RxDmR3/`。

## 2026-11-13 仓库级加源与展示精简

- 原 `add_source.sh` 默认处理当前 Ubuntu、架构适用的全部源，保留单软件参数。完整隔离测试 `152` 项、零失败，退出 `0`；真实 TLS、GPG 验签与 APT 更新通过。覆盖已有单源补齐、重复字节不变、新增软件纳入、第二项签名损坏／冲突／写入失败、TERM 回滚、锁与显式换钥。
- 父验证用真实 `sync.sh` 输出的双软件聚合配置，经独占 HTTPS 站点运行全源入口，真实 APT 同时得到两个包的 `1.0.0` 候选；重复执行不改已装源文件，第二项 Packages 摘要损坏时拒绝且原单源、公钥保持不变。生产者产物摘要未变，不是手写候选自证。
- 受影响范围分别复跑：同步 `117` 个记录用例、维护入口 `50` 项、Go 接源 `73` 个记录用例，退出均为 `0`、零失败。展示套件 `279` 项零失败；真实发布数据两次生成结果一致，独占 Chrome 实际 DOM 为四列表头和一条不带软件筛选参数的仓库命令。
- 旧失败记录保留：测试副本漏 `VERSION` 导致临时目录定位错误；在签名末尾追加空行没有破坏签名。补齐副本输入，并改为篡改已签名正文、由真实 `gpgv` 先确认坏签名后，原反例通过。另修正发布脚本否定断言漏目标文件的问题，实际禁用命令能触发失败、注释不误报。
- Bash 语法、受影响脚本及测试的 ShellCheck、文档链接和命令语法通过。宿主 APT、keyring、dpkg 状态、Git 配置以及 `VERSION`、`git_tag.sh`、工作流、软件配置和生产列表按本轮基线核对未变。

本节是本地集成验收，不表示新版全源脚本或三段发布链已经在 Pages 生效。原始日志与逐套退出码位于 `tmp/readme-all-sources/`。

## 2026-11-12 已上线基线与本次架构调整

- 原发布运行 [43185095856](https://github.com/0xdevelop/apt-hub/actions/runs/43185095856) 成功；公网首页、公钥与 `state.json` 实际返回 `200`，签名索引验签通过。隔离 APT 根完成更新、下载和安装计划；下载的 Go 包另在独占根内实际安装，并离线编译运行成功。下文“尚未上线”“列表为空”属于当时快照，不是当前状态。
- 本轮新入口 `build.sh → gen_debs.sh → scripts/gen_deb_golang.sh` 已用官方 Go `1.27.4` 双架构归档构出四个包，`SHA256SUMS`、控制字段与精确依赖核对通过；四个 `.deb` 与已发布的同 Debian 版本逐字一致。证据：`tmp/first-live-deploy/template-realignment/official-inputs/build.rc`、`build.log` 与 `official-build/`。
- 本次按用户要求收敛为一个 `release.yml`，保留 `Release → Build → RemoveOldRelease`，构造文件直接归对应本仓 `vX.Y.Z` assets；Pages 复用 `apt-hub-pages` 纯站点产物分支，不再使用 Actions Artifacts 或额外发布工作流。
- 固定源码执行完整 `build.sh test`，九套测试全部完成、退出 `0`；真实上传文件测试前后逐字一致。随后仅修复上传接线：无构造条目时跳过上传，首次上传复用完整目录校验，构建、测试和校验失败显式传播。集成后定点复跑发版测试 `71` 项、工作流测试 `39` 项，均零失败；全仓 ShellCheck 通过。独立复审通过，生产文件与获批快照一致。
- 从真实 YAML 抽取上传步骤重放：构建退出 `23`、测试退出 `24`、本地校验退出 `1`，均不写入上传成功输出；官方 `.deb` 清单直接跳过构建与上传。当前真实官方 Go 构造文件通过同一本地校验。证据：`tmp/first-live-deploy/template-realignment/final-parent/`、`integrated/`、`parent-review-delta/` 与 `review-delta-verdict.stream.jsonl`。
- 上述是本地集成与复审结果，不是新工作流的生产发布。切换 Pages 发布源、对应新版本的 GitHub 运行及公网消费者仍须实际验证；旧线上成功不能代替本轮验收。

> **当前范围修订（用户 2026-11-09 后续决定）**：RustDesk 官方 `.deb` 原样直下；Go 官方归档由独立脚本构成 Debian 包，经本仓 Releases assets 分发。用户随后要求 Go 的包名为 `golang`，因此下文旧 `apt-hub-go` 产物结果只对应旧快照；新包名、同版本 `golang-go` 依赖及已有 Ubuntu 包的升级必须另验。下文早期“不另设本项目下载落点”等结论只反映当时的范围，已被该决定替代，保留作历史记录，不是当前限制。`f5c1eb3` 是供跨机评审的阶段快照，尚未完成本轮验收；其 CI 在 ShellCheck 失败，后续测试未执行。新一轮结果须与该快照分开记录。

## 2026-11-06 元数据适配版实测

本轮使用当前生产脚本，从官方 API 获取 RustDesk 稳定版 `1.5.1`，临时核验官方包并生成签名候选；站点目录不含 `.deb`。真实重复同步后，`state.json`、软件更新时间与 Packages 保持不变。

- Ubuntu `jammy`、`noble`、`resolute`、`stonking` × `amd64`、`arm64`，八个组合全部完成隔离 APT 验签更新和精确版本依赖解析，均为 `update_exit=0`、`simulate_exit=0`。
- 使用仅监听本机回环地址的临时 HTTPS 元数据站点，客户端启用 TLS 验证、专用公钥与 `Signed-By`；真实 `mirror+https` 更新成功，两个架构的 by-hash 索引请求均为 HTTP 200。
- 两个架构的真实 APT 包下载均经过官方 `github.com` → `release-assets.githubusercontent.com`，下载后 SHA256、包名、版本与架构核对通过。本站访问日志没有 `.deb` 请求。
- 首次 HTTPS 测试服务的响应语义不完整导致超时，换用独立本地静态测试服务后通过；一次官方下载超时后重试完成。二者不冒充一次成功的生产部署。
- 独立临时 Chrome 实际渲染候选列表，核对版本、Ubuntu、架构和 `.sources` 链接通过；不接管用户浏览器。
- 以真实 RustDesk 候选元数据执行下载入口副本 → 一键加源 → 隔离 APT 验签更新，`apt-cache policy rustdesk` 显示 `Candidate: 1.5.1`；标准 `/etc/os-release` 链接布局、专用 `Signed-By`、by-hash 请求通过，下载副本成功自删、源码保留，系统配置摘要未变。证据 `installer-official.rc` 为 `installer_official_exit=0`。该步骤是本地 HTTPS 候选验收，不是公网 Pages 上线。
- 无 Bun 环境执行发布工作流的签名与身份定向测试退出 `0`，`pass=19 fail=0`；渲染测试 `pass=194 fail=0`。
- 最后增量在独立副本完整复跑：同步 `PASS=111 FAIL=0`、一键加源 `TOTAL=54 PASS=54 FAIL=0`，退出均为 `0`。另以独立完整入口探针核对 20 个存量边界，全部符合预期；资产 URL 与认证 `Filename` 不一致、路径穿越、压缩索引篡改和第三方分流均被拒绝，输入及旁路哨兵不变。端口占用负向控制确认测试拒绝启动且不杀原监听进程。证据位于 `final-regression/` 与 `delta-green-parent/`，不是远端 CI 或生产上线结果。
- 发布门禁最后增量经独立副本实际执行当前工作流消费者，`70` 项通过、`0` 失败，退出 `0`；批量 FIFO、符号链接、`.deb` 及 `find` 失败均拒绝且不输出成功。证据 `gate-final-parent/consumers.log` 与 `consumers.rc`；当前两份源码摘要与验收快照一致。
- README 新增的软件条目模板已实际提取为 JSON，通过正则正反检查与当前生产 `validate_catalog` 校验。该模板仅适用于官方 GitHub Releases `.deb`，不证明 Go 已接入。
- 修复 GPG 测试目录的进程生命周期后，完整 `tests/ubuntu_test.sh` 退出 `0`，`failures=0`。覆盖官方支持期、双软件矩阵、依赖／网络／签名失败分类、源标识符、实际隔离 Git 保存／读回和并发拒绝；不是仅检查工作流文本。
- 真实执行发布工作流的签名与发布者身份步骤通过；生产 Pages 尚未部署。
- 系统 APT 配置、keyring、dpkg 状态、仓库 `.git/config` 与 LICENSE 的逐文件摘要核对未变；临时 HTTPS 服务与该轮签名私钥已清理。

原始证据位于项目 `tmp/controller-final-20261106/`：官方矩阵 `live/verify/summary.json`，HTTPS 与官方下载 `live/https-consumer*/`，浏览器 `browser/page.dom.html`，完整性基线 `system-before.sha256`。下载实测证明 APT 获取与依赖解析，不代表安装运行、GUI、Wayland 或无人值守功能已验证。

**最终修复复审、完整工程测试、远端 CI 与首次生产 Pages 部署仍需分别验收。本节不宣称公网源已上线，生产列表仍为空。**

## Go 构包与维护入口的本地增量验收

本节与前述 RustDesk 元数据链分开记录，不表示 Go 已接入统一发布或公网源。

- 维护入口 `scripts/update_sources.sh` 在独立副本完成真实同步、隔离 APT 校验和渲染，`45` 项通过、`0` 失败。不可枚举的已有工作目录和空输出的 `find` 错误均在写入前拒绝；原文件摘要与目录权限保持。该小增量已通过独立复审。
- Go 官方 `1.27.3` 归档生成独立包 `apt-hub-go=1.27.3-1`，分别记录原始归档和生成 `.deb` 的摘要、大小。独立副本默认离线测试 `103` 项通过，复用官方缓存的实测 `125` 项通过，退出均为 `0`。最终独立复审曾发现架构枚举错误传播缺口，随后用完整构包入口确认：`jq` 输出部分架构后失败时，脚本仍成功提交缺架构候选；此前绿测未覆盖此路径。后续已改为先确认完整枚举成功再读取架构，并在独立副本复跑 `116` 项离线测试通过，原部分输出失败反例现退出非零且无最终产物。
- `amd64` 生成包解包后实际输出 `go version go1.27.3 linux/amd64`，离线编译并运行程序输出 `apt-hub-go-hello`。`arm64` 仅完成构包及 ELF 架构核查，没有冒称已在对应硬件执行。
- 隔离签名源下的 `apt -s upgrade` 与 `apt-get -s upgrade` 均选择 `apt-hub-go` 从明确标注的旧版状态夹具 `0.0.1-1` 升到 `1.27.3-1`，不删除包、不改 Ubuntu Go。它们是升级计划验证，不是实际安装升级。
- 真实故障注入确认：无法枚举的输出目录不覆写用户文件；Go 树复制失败时不产出成功包；完整双架构产物与来源记录经目录切换一起提交；提交失败恢复原空目录的 inode 与权限。当前源码与系统保护摘要核对通过。

证据在项目 `tmp/update-fix-parent/`、`tmp/go-final-parent/` 及其中的原始日志、退出码、来源记录和源码快照。以上证明本地构包与升级计划，不证明 Go 存在可供本源使用的官方 `.deb`。此前把未完成事项写成“正式包承载”不符合仅维护元数据的边界；不会为生成包另设本项目下载落点。后续阶段 CI 结果见下节，不把本地结果写入已生效列表。

## 2026-11-09 阶段交付与来源边界核对

- 提交 `322c3b64dbf325637790e42bfb2d240efe6dec55` 已推送 `main`，远端 [ubuntu-test](https://github.com/0xdevelop/apt-hub/actions/runs/42590643708) 为 `completed/success`；该阶段验证不等于生产部署。
- 同步 `111`、渲染 `246`、工作流 `28`、加源 `54`、维护入口 `45`、Go 离线 `116` 项分别零失败。完整 Ubuntu 测试第一次因一个组合获取官方索引超时退出 `1`，随后完整重跑退出 `0`、`failures=0`，四个版本 × 两种架构均通过。原失败和重试日志分开保留。
- 按用户再次明确的“仓库只存包信息、安装包从官方地址下载”，本项目不在 Releases 转存安装包。实际读取 [Go 官方发布索引](https://go.dev/dl/?mode=json) 和[安装说明](https://go.dev/doc/install)，当前 Linux 发布资产为 `tar.gz`；对已有且摘要匹配的官方归档执行 `dpkg-deb --info`，退出 `2`，报告“并非 Debian 格式的包文件”；用隔离配置执行 `apt-get -s install` 同一归档，退出 `100`，报告“不支持的文件”。这是格式差异，不是给索引补一个下载地址即可解决。
- 本地 Go 构包结果与官方包直下的验收仍须分开，未将 Go 写入已生效列表，也未改动 RustDesk 已验证的直下链。原始证据在 `tmp/stage-publish-parent/`、`tmp/go-arch-resume-parent/` 和 `tmp/official-download-boundary/`。

## 2026-11-09 新版构包与客户端增量

- `f5c1eb3` 的远端 [ubuntu-test](https://github.com/0xdevelop/apt-hub/actions/runs/42611676892) 在 ShellCheck 步骤失败，后续功能测试被跳过；外层测试循环退出 `0` 也不等于其中每个测试通过。
- 在独立副本用根 `build.sh` 调用 `gen_deb_golang.sh`，从摘要已与官方索引核对的 Go `1.27.3` 双架构归档生成 `apt-hub-go=1.27.3-1`；产物摘要、大小及控制字段核对通过。此处复用官方归档缓存，没有创建生产 Release。
- 将该真实构包产物经生产 `sync.sh` 生成签名候选，再使用隔离 HTTPS 元数据站点和明确标注的 Release 资产夹具，由真实 `add_source.sh`、APT `mirror+https` 完成双架构更新、下载、摘要与控制字段检查。TLS 验证开启；元数据站点的 `.deb` 请求为 `0`，独立资产服务取得两个包，观察到四次成功 by-hash 请求。
- `apt-get --simulate upgrade` 分别输出 `Inst apt-hub-go [0.0.1-1] (1.27.3-1 … [amd64])` 和对应 `arm64` 行，没有 `Remv`；旧版本仅是隔离状态夹具，不是实际安装升级。`amd64` 解包后实际输出 `go version go1.27.3 linux/amd64`，`arm64` 未在目标硬件运行。
- README 的密钥命令曾在 Linux 成功，但用户 Mac 实测发现深层路径触发 `gpg-agent: File name too long`。已改为项目 `tmp/` 下的短随机目录并检查套接字路径字节数；新版命令已逐字完成生成、私钥 `0600`、目录 `0700`、签名与验签，测试私钥随后清理。Linux 的运行时套接字目录不能作为 macOS 实跑证据。

本节证据位于 `tmp/accept-v17/live-parent/` 和 `tmp/accept-v17/gpg-path/`，系统 APT、keyring、dpkg 状态及 Git 配置摘要核对未变。发版和维护脚本的最后修复、完整工程测试及新提交 CI 仍在收口，不把这些局部结果写成生产源已上线。

## `golang` 新包名的隔离实测

本节是用户要求改名后的新产物验证，不沿用旧 `apt-hub-go` 结果，也不表示已完成生产发布。

- 使用冻结的 Go 官方 `1.27.3` 双架构归档，通过根 `build.sh` 实际生成 `golang`、`golang-go` × `amd64`、`arm64` 四个 `.deb`，`SHA256SUMS`、大小、控制字段和来源记录核对通过。完整包版本为 `2:1.27.3-1`，入口包依赖同版本工具链；两个包的上游摘要分别绑定同架构官方归档。
- 将四个真实产物经当前 `sync.sh` 生成签名候选，当前 `verify_ubuntu.sh --verify-downloads` 对两个架构均返回 `update_exit=0`、`simulate_exit=0`、`download_exit=0`、`upgrade_exit=0`。独立 HTTPS 资产服务明确为未上传的 Release 夹具，TLS 验证开启，不把本地成功称为公网下载成功。
- 另以真实 Ubuntu `noble` 八个相关包的控制字段构成隔离旧状态，使用真实 APT 下载四个新包并执行普通 `apt-get --simulate upgrade`，未启用 `--with-new-pkgs`。两个架构均选择 `golang`、`golang-go` 从 `2:1.22~2build1` 升到 `2:1.27.3-1`，无 `Remv`；元数据服务收到的 `.deb` 请求为 `0`。
- 在独占非系统根内，用真实 Ubuntu `golang-go` 包的旧命令文件及隔离依赖状态执行 `dpkg --root ... --force-not-root --install`，新两包实际解包并配置成功；`go`、`gofmt` 和 `/usr/lib/go` 的所有权归 `golang-go`。旧依赖包文件并未完整安装，这不是一台真实旧系统的全盘升级。首次验收夹具的文件清单含空首项，dpkg 拒绝；修正夹具后重试通过，两个日志分别保留。
- `amd64` 的新包实际输出 `go version go1.27.3 linux/amd64`，通过普通 `go`、`gofmt` 链接离线编译并执行程序。`arm64` 核对 ELF 与链接，没有在目标硬件运行。
- 父代理在固定副本复跑构包 `123`、发版 `65`、工作流 `29`、渲染 `248` 项，均零失败；同步 `111`、Go 接源 `31` 项也零失败。更新入口的旧夹具未接真实 APT 下载通道、客户端解析边界和最终全仓检查仍在收口，不能据局部绿测宣布本轮全部通过。

原始证据：`tmp/accept-v18-build/`、`tmp/accept-v18-core/tmp/live-e2e/`、`tmp/accept-v18-dpkg-retry/` 与各固定副本的日志、退出码、源码摘要。系统 APT、keyring、dpkg 状态和 Git 配置摘要未变，父代理的临时 HTTPS 服务、签名私钥及 TLS 私钥已清理。

## 2026-11-10 最终回归与定点修复

本轮与前述阶段快照分开记录，尚未触发生产 Release 或 Pages 部署。

- 固定源码副本执行构包 `130`、发版 `73`、工作流 `29`、渲染 `248`、加源 `118`、Go 接源 `55` 项，逐项退出 `0`。更新入口首次因 Ubuntu 官方 `ports.ubuntu.com` 的 `jammy/arm64` 索引下载超时退出 `1`；保留原记录，同一源码完整重试 `50` 项通过、退出 `0`，没有关闭下载验证或替换官方下载原点。
- 同一副本使用冻结的官方 Go `1.27.3` 归档执行真实构包验收，`152` 项通过；实际 `go version` 为 `go1.27.3 linux/amd64`，离线编译运行输出 `golang-hello`。`arm64` 仍只验证包、ELF 和 APT，不宣称目标硬件执行。
- 独立复审发现的四包集合重复、枚举部分成功后错误被吞、rename 后 TERM 回滚窗口、Deb822 注释夹续行漏检，均补入能复现原缺口的测试。父代理另外直接调用最终发版函数：正常四包通过，重复组合、孤儿坏包、畸形官方索引和失败枚举均被拒绝，未调用发布写操作。
- 最终加源回归实际覆盖新建公钥、替换公钥和写入 `.sources` 后收到 TERM 的回滚，以及恢复自身失败时保留旧公钥备份；合法注释、多 URI、多 keyring、大小写与续行反例均按预期处理。
- Go 接源回归恢复了缺标签、缺架构或依赖包、内外层摘要不符、同版本内容替换、错误旧指纹、独立新钥验签、基础模式不下载及资产 URL 篡改等已有边界。全仓 ShellCheck、Bash 语法、测试用 Node 夹具语法与 JSON 校验通过；移除了测试中四条未读取的赋值，没有改变执行路径。
- 重复构包比较发现 `Installed-Size` 受磁盘实际分配量影响：两个架构的安装数据流相同，控制字段各差 `4 KiB`，不是程序内容漂移。已按包成员逻辑字节计算并排除 `DEBIAN`，父代理验证同内容、不同磁盘分配与控制目录大小仍得到相同结果；枚举输出完整后返回错误也会拒绝。修正后的官方归档完整验收为 `161` 项通过、退出 `0`，发版 `73` 项和渲染 `248` 项复跑通过。相同官方归档再次经根 `build.sh` 构建，四个 `.deb`、`provenance.json` 和 `SHA256SUMS` 均逐字一致。
- 限定增量独立复审确认此前发版两项缺口闭合，离线真实函数探针 `19` 项通过；客户端两项缺口的定向测试 `12` 项通过，同测旧版有 `5` 项失败。父代理核对原始结果与源码摘要，批准仅适用于这些确切切片，不以报告代替实际测试。最后的 `Installed-Size` 增量也通过独立复审；带空格路径、稀疏文件、`find` 部分输出后失败及 `stat` 失败均按预期处理。

证据位于 `tmp/release-final-parent/evidence/`。本批系统源、keyring、dpkg 状态和 Git 配置按新基线核对不变；旧基线中的 dpkg 状态变化对应系统升级日志，未将系统自动更新回滚。测试私钥与临时 HTTPS 服务按独占范围清理，软件列表仍为空。

## 修订前历史记录

日期：2026-11-02。**以下为修订前镜像实现的验证记录，不作为当前“元数据适配、官方直下”方案已经通过的证据。新版结果须另外实测补记。** 记录区分本地实测、隔离夹具与尚未执行的生产操作。

## 真实官方包与 APT 闭环

RustDesk 官方稳定发布 `1.5.0`，实际下载的两种包均通过官方 GitHub 资产 SHA256、大小及包内 `Package=rustdesk`、`Version=1.5.0`、架构核对；未执行包维护脚本。

| Ubuntu | 代号 | amd64 | arm64 |
|---|---|---|---|
| 22.04 LTS | jammy | 验签更新、精确版本依赖解析通过 | 验签更新、精确版本依赖解析通过 |
| 24.04 LTS | noble | 验签更新、精确版本依赖解析通过 | 验签更新、精确版本依赖解析通过 |
| 26.04 LTS | resolute | 验签更新、精确版本依赖解析通过 | 验签更新、精确版本依赖解析通过 |
| 26.10 | stonking | 验签更新、精确版本依赖解析通过 | 验签更新、精确版本依赖解析通过 |

按权威 `distro-info-data` 标准支持日期筛选并与 Ubuntu 官方发行周期页对照；还实际下载对应 Ubuntu 官方 archive/ports 的 8 份 InRelease，以系统 Ubuntu archive keyring 验签通过。未把 Pro/ESM 状态混作标准支持。

从实际官方包生成签名候选仓库后，对照软件清单、发布状态与验证结果，程序化核对组合完整且不重复，实际验证 8 个组合全部 `update_exit=0`、`simulate_exit=0`。各组合使用隔离 APT 配置、索引、状态及日志，不继承系统安装状态。

另经真实 APT 从候选源获取 amd64、arm64 两个 RustDesk 包，摘要均与官方资产一致。使用明确标注的“已安装旧版 1.4.9”隔离状态夹具执行模拟操作，APT 输出：

```text
Inst rustdesk [1.4.9] (1.5.0 apt-hub:jammy [amd64])
```

这是升级计划验证，不是真实旧版安装，更没有执行 212 个依赖包或 RustDesk 的安装。依赖解析通过不代表已验证 GUI、无人值守、Wayland、目标硬件或上游对所有版本的正式兼容承诺。

真实重复同步也已执行，`state.json` 与软件更新时间保持不变。

## 脚本、模板与失败路径

- 同步测试：小哈实际重跑，`PASS=54 FAIL=0`。覆盖两个测试软件、双架构、首次/再次发布、幂等、旧包及旧 by-hash 保留、上游降级/同版本替换、缺摘要、官方资产地址越界、索引生成失败、锁竞争、路径与清理哨兵。
- 渲染与脚本标签测试：小哈实际重跑，`pass=117 fail=0`。覆盖固定标记缺失/重复/倒序、区域外字节保持、幂等、HTML/Markdown 转义、符号链接及标签职责。
- 通过独立临时 Chrome 实际加载静态空态页与真实候选列表页；DOM 核对软件、版本、Ubuntu、架构、UTC 更新时间和简单说明。该浏览器使用项目 `tmp/` 中的隔离 profile，不是接管用户 Chrome。
- Bash 语法与工作流 YAML 已实际检查，Actions 引用固定官方 tag 对应的 commit SHA。
- 本机没有 ShellCheck，未安装，也不将其列为已通过。

本地夹具中的远端 API 响应明确为测试数据，不作为 GitHub 网络可用性的证据；真实包和官方 Ubuntu 仓库部分使用了真实网络。

## 独立审查与集成

独立 Cursor 审查没有代替小哈读取源码和实际复测。审查拦截了临时目录所有权、路径重叠删除、吞掉索引错误、README 未绑定确切发布数据等问题。

工作流另被发现误要求站点根级 `by-hash`，而真实布局位于 `dists/<series>/main/binary-<arch>/by-hash`；该问题已修复。小哈随后实际运行最终 `tests/ubuntu_test.sh`，结果 `failures=0`。测试实际执行保存路径的 copy/add 与隔离 Git 操作，覆盖首次保存、再次保存、精确 SHA 读回、并发推进拒绝、未知历史文件拒绝及 Git 100MiB 单文件门禁，而非只检查工作流字符串。

最终独立审查结果为 `passed=true`，无剩余必须修复项；小哈已将报告中的生产文件 SHA256 与实际文件逐一对照。真实包矩阵验收之后，验证脚本的增量仅固定英文 locale，原真验命令也显式使用该 locale；最终测试另覆盖中文环境错误分类。

还启动了仅监听本机回环地址的临时 HTTP 静态服务，用真正的 APT 强制 `Acquire::By-Hash=force`。日志记录对 `dists/jammy/main/binary-amd64/by-hash/SHA256/...` 的请求及 HTTP 200，随后通过 HTTP 下载真实 RustDesk 包并核对官方摘要成功。测试服务已停止，未留监听端口。

## 非破坏性核对

本轮开始前记录并随后实际复核：Ubuntu 系统软件源、系统 dpkg status、Ubuntu archive keyring、仓库 `.git/config` 和原 LICENSE 的 SHA256 均保持不变。

正式生产私钥未进入项目；本地签名只使用明确隔离的测试身份。主分支 `data/published.json` 保持空列表，不把本地验证候选版本写成线上“已生效”。

## 尚未执行的生产操作

生产 Pages 尚未启用，生产签名私钥由用户配置。因此未执行 GitHub Actions 真发布、生产 Pages 部署或客户端添加源，也未验证这些外部配置已正确。

用户启用流程见 [首次启用与需要用户处理的事项](nees_user_read.md)。本地闭环可用与公网源实际上线是不同验收事实。

本轮完整日志与候选产物位于项目 `tmp/controller-live/`，不提交；夹具测试的失败路径证据分别位于 `tmp/sync-test/`、`tmp/render-test/`、`tmp/ubuntu-test/`。
