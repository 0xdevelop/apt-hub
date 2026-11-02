# 实施计划

## 用户已定边界

来源：2026-11-02 首次需求及随后两条澄清。

- 通用第三方 Ubuntu APT 源，服务于没有官方 APT 源但提供官方 `.deb` 的软件；RustDesk 首个接入。
- 用户澄清：“几个 shell 脚本进行下维护配合 github actions 就能做到”；不做管理平台。
- GitHub Actions 定时扫描上游版本，变化后更新软件源；静态网页只罗列已生效版本、最后更新时间和简单说明。
- “对应的 readme.md 里面的列表区域通过模板处理的脚本更新对应版本及简单说明”。
- `git_tag.sh` 只管理本仓库脚本版本，与源内各软件版本分离。
- 计划先行，Cursor 实现脚本和测试，小哈维护 README、上下文与严格验收；完整功能验收后允许 commit+push。
- 用户操作集中 `docs/nees_user_read.md` 并从 README 链接；不破坏系统。

前一版把范围扩为服务或管理平台是小哈的理解偏差，已纠正；旧讨论留存在本地会话记录，不作为后续依据。本轮不需要 Go 应用，不运行 Go 模板初始化、不引入 API/MySQL/认证/业务调度。定时由 Actions 承担。

## 首个完整闭环

1. JSON 清单声明软件名、GitHub 官方仓、amd64/arm64 资产规则、简短说明及许可/源码入口。不要硬编码 RustDesk 安装逻辑；至少用两个独立测试软件验证通用性。
2. Shell 调 GitHub Releases API，选择真实稳定版与唯一匹配资产；不拼接 `latest` 旧版本地址。校验官方资产 SHA256、实际大小及包内 Package/Version/Architecture；无摘要、歧义、降级或上游替换同版本包均拒绝。
3. 原样保存 `.deb`，用 `dpkg-deb`、`apt-ftparchive`、GnuPG 构建带 SHA256/by-hash 的签名仓库。软件包与历史 by-hash 索引保留，兼容旧客户端；不写自制包解析器和签名算法。
4. 失败时不改变既有仓库；同一输出目录单写者、发布前完整校验、重复运行无软件变化时保持生效版本更新时间。输出目录和临时目录必须显式、限制在安全作用域。
5. Actions 保存发布数据、上传静态 Pages artifact，部署成功后才将已发布状态及 README 模板列表写回主分支。不能在部署失败前宣称软件已生效。签名续期与软件版本变化分开，定时无人修改 README 正文。
6. README 的固定标记区域由模板渲染；静态网页复用同一份已发布状态。标记缺失/重复拒绝，渲染幂等，未发布状态不冒充线上版本。
7. `git_tag.sh` 只对维护脚本创建版本标签；不在软件更新时发脚本版本、不重写历史标签、不自动 push/发版。

## 非破坏性约束

- 不改本机 `/etc/apt`、全局 keyring、dpkg 数据、Git/SSH、shell 环境、OpenClash，不安装 RustDesk。
- 不代填生产签名身份、不把私钥或令牌提交仓库、不自动开启 Pages/修改仓库设置。
- 测试密钥和所有临时产物只在项目 `tmp/`；正式生产密钥与分发许可由用户掌握。
- 不能用 `trusted=yes`、`allow-unauthenticated`、跳过 TLS 或换不可信镜像掩盖失败。
- 不引入 Go、Python、常驻服务、数据库、前端框架或通用插件框架。

## 分批执行与验收

| 批次 | 交付 | 验收 |
|---|---|---|
| 1 | 本计划、软件清单和发布状态契约 | 用户澄清逐条覆盖；必要用户操作清楚 |
| 2 | Cursor 实现同步、签名构建、README/网页模板、Actions、脚本版本标签工具 | Shell 语法、配置校验、已有能力复用与范围核对 |
| 3 | Cursor 自测；小哈实际读取实现并独立复测 | 真实 APT 验签/update/download/模拟升级；两次发布、幂等、存量保留与旧索引读取 |
| 4 | 独立代码审查并修复明确问题 | 错误密钥/篡改/架构错配/中断/并发/越界/同版本替换拒绝且不破坏旧版 |
| 5 | README、用户操作与验收报告闭环，提交推送 | 主分支展示只含真实已发布数据；无临时产物/密钥/agent 身份；远端提交核对 |

真实 RustDesk amd64/arm64 包需下载并核验，至少经隔离 APT 获取；包依赖与无人值守桌面功能不以“可下载”代替安装兼容验收。测试包是明确标注的本地夹具，不伪装为 RustDesk 实际安装成功。

## 失败处理

- 网络超时、404、限流、缺摘要：有界失败，不更新已发布状态。
- 元数据/摘要/架构不符或降级：拒绝，原样保留既有仓库。
- 签名失败、磁盘异常、并发写入：不切换发布结果；锁随进程退出释放。
- 新版发布时旧客户端仍引用旧 by-hash：保留旧索引和包。
- Pages 部署失败或主分支有并发变更：不错误提交生效列表；不 force-push 覆盖同事修改。
- 生产密钥或 Pages 未就绪：工作流明确阻塞，不以测试密钥或占位地址发布。

## 能力与依据

已核对本仓初始源码面只有 LICENSE 与 README，未有既存同步器。本机已有 Bash、curl、jq、dpkg-deb、apt-ftparchive、GnuPG、flock、APT；Cursor CLI 已认证。用户的 shell_tools 未见可直接复用的 APT 发布/标签工具；Go 模板的 git_tag.sh 耦合 Go 配置、API 文档和推送/历史清理，不能直接用于本项目。实现只补当前闭环必要脚本。

权威参考：

- Debian 仓库格式与 by-hash：https://wiki.debian.org/DebianRepository/Format
- APT Signed-By：https://manpages.debian.org/testing/apt/sources.list.5.en.html
- GitHub Pages 自定义工作流：https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages
- GitHub Releases API：https://docs.github.com/en/rest/releases/releases
- RustDesk 官方发布：https://github.com/rustdesk/rustdesk/releases

## Ubuntu 官方支持对齐与并行边界

用户补充原话（2026-11-02）：“注意要从 ubuntu 每个版本支持和官方对齐哦”“任务可以并行拆开让多个 cursor 去帮你执行哦”。

按官方发行时间与标准支持结束日期筛选当前发行版；ESM/Ubuntu Pro 不混作普通免费支持。不只看 meta-release 的 Supported 字段，也不只测本机版本。每个发布组合都用对应 Ubuntu 官方签名软件源与隔离 APT 状态解析精确包版本依赖；未通过就不发布本批、不覆盖旧站点。此验证不冒充 GUI 功能或真实安装兼容性测试。

Cursor A 独占同步与签名仓库；Cursor B 独占模板展示与本仓标签；Cursor C 独占 Ubuntu 支持核对、依赖验证与 Actions。接口先约定，各自仅改所属文件，小哈统一集成和验收。没有生产成功部署时，README 的线上列表保持空，不把本地下载成功当“已生效”。

## 上线条件

当前 GitHub API 返回仓库 `has_pages: false`，且生产签名凭证未配置核实。上线所需设置由用户操作，见 [需要用户处理的事项](nees_user_read.md)。本地完整闭环验收与公网实际上线分开汇报，不能混为一谈。
