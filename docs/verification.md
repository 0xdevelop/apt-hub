# 验证记录

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

证据在项目 `tmp/update-fix-parent/`、`tmp/go-final-parent/` 及其中的原始日志、退出码、来源记录和源码快照。Go 的统一维护接线、正式包承载、远端 CI 与生产部署尚未验收，不把上述本地结果写入已生效列表。

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
