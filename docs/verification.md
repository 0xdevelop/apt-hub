# 验证记录

日期：2026-11-02。以下记录区分本地实测、隔离夹具与尚未执行的生产操作。

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

生产 Pages 尚未启用，生产签名 secrets/提交身份 vars 由用户配置。因此未执行 GitHub Actions 真发布、生产 Pages 部署或客户端添加源，也未验证这些外部配置已正确。

用户启用流程见 [首次启用与需要用户处理的事项](nees_user_read.md)。本地闭环可用与公网源实际上线是不同验收事实。

本轮完整日志与候选产物位于项目 `tmp/controller-live/`，不提交；夹具测试的失败路径证据分别位于 `tmp/sync-test/`、`tmp/render-test/`、`tmp/ubuntu-test/`。
