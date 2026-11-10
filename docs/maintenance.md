# 维护说明

[返回 README](../README.md) · [首次启用](nees_user_read.md)

## 软件清单

`config/packages.json` 是接入软件的配置入口，`packages` 可包含多个软件，不为每个软件复制同步脚本。

- `id`：本仓唯一标识；`package` 必须等于 `.deb` 的 `Package`。
- `repository`：上游官方 GitHub `owner/repository`，不填第三方下载镜像。Go 条目仍指向 `golang/go`，生成包的发布仓库通过 `--package-repository` 单独指定。
- `source_type`：省略时读取官方 GitHub `.deb`；`go_official_archive` 表示核验 Go 官方归档后，由本仓构包与发版。原始归档与生成包的出处、摘要和大小分别记录。
- `description`：README 与静态页使用的简短说明。
- `source_url`、`license`：官方源码入口和许可信息；再分发条件仍须维护者核对。
- `architectures`：Debian 架构到发布资产名称正则的对应关系；每个架构必须唯一匹配一个真实 `.deb`。首版支持 `amd64`、`arm64`，不代表 Ubuntu 或上游支持的全部架构。
- `ubuntu_series`：`"supported"` 表示当前标准支持集合；也可填写明确的 Ubuntu 代号数组，但必须是该集合的子集。上游有限制时应收窄，不能因本机能下载就任意扩大。

清单新增后，下一次定时或手动同步会重新纳入全部配置软件。版本、包大小和摘要不手工写进清单；它们从官方发布及实际包元数据获取。官方资产没有 SHA256 digest、匹配歧义、包身份不符或同版本被替换时明确失败，不以自己计算的摘要冒充官方摘要。

## 发布数据与列表

- `apt-data` 分支保存签名索引、公开公钥、分流列表、已发布元数据和 `add_source.sh`，不保存 `.deb`。RustDesk 等官方原包由客户端从官方地址获取；Go 生成包从本仓 Releases assets 获取。
- `data/published.json` 只记录成功部署后回写的状态，不手动填入尚未生效的软件。
- `templates/readme_packages.md`、`templates/readme_empty.md` 控制列表表头与空态；`templates/index.html` 控制静态页。
- `scripts/render.sh` 只替换 README 中 `APT-HUB:PACKAGES:BEGIN` / `END` 两条独占行之间的区域，区域外正文由人维护。缺失或重复标记会拒绝写入。

签名与候选元数据每日续期，软件的 `updated_at` 不因扫描、重签而变化。Pages 部署失败不能更新主分支为“已生效”；回写失败也不强推覆盖同事提交，修复后重跑使状态收敛。

## 一条命令检查并更新候选

Actions 和本地维护共用 `scripts/update_sources.sh`。本地运行时提供已有签名密钥目录和公开指纹；指纹不是 Secret，Actions 会从导入的签名私钥取得。

```bash
bash scripts/update_sources.sh --catalog config/packages.json --previous tmp/previous --work-dir tmp/update-001 --gnupghome '<签名密钥目录>' --fingerprint '<公开指纹>' --site-url 'https://packages.example.test/tools' --package-repository '<自己的owner/repo>' --go-release-tag 'golang-<上游版本>-<修订>' --go-downloads-json '<构包时冻结的官方索引JSON>'
```

其余参数是候选目录、站点和发行版数据输入；入口只生成候选，不上传、不推送、不部署。

以上地址、版本和指纹均需替换；`tmp/previous` 须为已有发布快照或首次使用的空目录，工作目录必须是新建或空目录。Go 精确 tag 必须已完成 `golang`、`golang-go` × `amd64`、`arm64` 四个包的构建、上传与回验，不能仅凭本地产物声称已发布。入口包依赖同版本工具链；控制字段使用完整 `2:上游版本-修订`，资产文件名和 `golang-上游版本-修订` 标签不带 epoch。`gen_deb_golang.sh` 独立构包，`build.sh` 扩展调用，Actions 共用发版、构建上传和按引用清理流程。源码、`apt-data` 和 Pages 仍不保存大包。

签名私钥生成、备份、换钥和客户端报错修复统一见 [README](../README.md#维护者首次启用与签名密钥)。只更新同一个 `APT_HUB_GPG_PRIVATE_KEY` Secret；换钥时显式提供旧完整指纹，客户端显式核对新完整指纹。

## 本地验证

需要已有 Bash、curl、jq、GnuPG、dpkg 工具、`apt-ftparchive`、`readelf`、`xxd`、Node.js、PATH 中可调用的 ShellCheck 和 Ubuntu 官方 archive keyring。Node.js 仅用于测试的隔离 HTTPS 夹具，不是源维护脚本或客户端的运行依赖。项目不自动在本机安装依赖。

测试在项目 `tmp/` 使用临时测试密钥和测试包；不安装测试包、不改变系统软件源。Ubuntu 测试需要访问官方软件源，网络失败不是测试通过。

执行完整既有测试：

```bash
bash tests/sync_test.sh && bash tests/render_test.sh && bash tests/workflow_test.sh && bash tests/add_source_test.sh && bash tests/update_sources_test.sh && bash tests/go_deb_test.sh && bash tests/go_source_test.sh && bash tests/release_test.sh && bash tests/ubuntu_test.sh
```

测试密钥只用于本地 `tmp/`，不放进生产 Actions Secret；测试目录不要混放用户文件。

## 本仓脚本版本

`VERSION` 只属于维护脚本。发版入口沿模板保留自动补丁版本与交互指定版本；用户运行这些命令会提交版本和变更记录、创建标签并推送，不是只读校验：

```bash
bash git_tag.sh auto
```

需要指定版本时用 `bash git_tag.sh custom`；`bash git_tag.sh --version 0.1.0` 仅在 `VERSION` 已等于该号且工作区干净时创建标签并推送，不改版本文件。入口不移动 `latest`、不重写已有标签。软件源日常更新不调用它，本地验收只在隔离 Git 仓库运行，不在主仓发版。

## 上游与历史索引

保留必要的历史 by-hash 元数据。安装包不进入 Git 或 Pages，因此 Git 单文件大小不是接入软件包的限制；上游删除历史包后，本项目不承诺仍能下载该版本，也不静默转用第三方镜像。
