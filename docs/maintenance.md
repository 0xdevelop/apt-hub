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

清单新增后，下一次发布会纳入新软件，并从相同的已发布状态生成各 Ubuntu 代号的 `repos/<代号>.sources` 聚合配置；存量使用者重跑同一加源命令即可纳入。版本、包大小和摘要由官方发布及实际包元数据取得，不手填。

### 新增软件

官方已有 `.deb` 时，将下面的对象加入 `config/packages.json` 的 `packages` 数组，保留已有条目，按真实信息替换占位值：

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

`id` 以 ASCII 字母或数字开头，只含字母、数字、`_`、`.`、`-`，且不能含 `..`；每个架构的正则必须恰好匹配一个官方正式版 `.deb`。缺官方 SHA256 digest、匹配不唯一、包身份不符或同版本换字节时拒绝发布。上游只有归档时，在 `scripts/` 实现具体构包处理并接入 `gen_debs.sh`，不复制发布流程或在客户端联网安装主程序。

## 发布数据与列表

- `apt-data` 分支保存签名索引、公开公钥、分流列表、已发布元数据和 `add_source.sh`，不保存 `.deb`。RustDesk 等官方原包由客户端从官方地址获取；Go 生成包从本仓 Releases assets 获取。
- `data/published.json` 只记录成功部署后回写的状态，不手动填入尚未生效的软件。
- `templates/readme_packages.md`、`templates/readme_empty.md` 控制列表表头与空态；`templates/index.html` 控制首页。页面显示用途、当前站点版本、源根地址、加源与安装命令和软件短表，随同一次发布自动生成。
- 站点版本使用本次本仓 `vX.Y.Z`，不是 Go 或 RustDesk 的软件版本。当前发行版和变更记录链接固定到该标签；“最新发行版”链接使用 GitHub `releases/latest`，不维护另一个 `latest` 标签。变更记录沿用 `changelog/vX.Y.Z.md` 的 GitHub 渲染页，不另建前端或 Markdown 解析器。
- `scripts/render.sh` 只替换 README 中 `APT-HUB:PACKAGES:BEGIN` / `END` 两条独占行之间的区域，区域外正文由人维护。缺失或重复标记会拒绝写入。

签名与候选元数据每日续期，软件的 `updated_at` 不因扫描、重签而变化。Pages 部署失败不能更新主分支为“已生效”；回写失败也不强推覆盖同事提交，修复后重跑使状态收敛。

## 一条命令检查并更新候选

Actions 和本地维护共用 `scripts/update_sources.sh`。本地运行时提供已有签名密钥目录和公开指纹；指纹不是 Secret，Actions 会从导入的签名私钥取得。

```bash
bash scripts/update_sources.sh --catalog config/packages.json --previous tmp/previous --work-dir tmp/update-001 --gnupghome '<签名密钥目录>' --fingerprint '<公开指纹>' --site-url 'https://packages.example.test/tools' --package-repository '<自己的owner/repo>' --release-tag '<已上传资产的本仓vX.Y.Z>'
```

其余参数是候选目录、站点和发行版数据输入；入口只生成候选，不上传、不推送、不部署。

以上地址、版本和指纹均需替换；`tmp/previous` 须为已有发布快照或首次使用的空目录，工作目录必须是新建或空目录。本仓 `vX.Y.Z` 必须已有该版的构造包与来源记录，不能仅凭本地产物声称已发布。Go 入口包依赖同版本工具链，控制字段为 `2:上游版本-修订`；这些软件版本不是本仓 Release 标签。

`git_tag.sh`（无参数默认为 `auto`）触发同一条三段式发布链；`build.sh` 调用 `gen_debs.sh` 按清单处理软件，Go 专用格式转换位于 `scripts/gen_deb_golang.sh`。官方已有 `.deb` 只发现和核验官方发布，不转存；构造包、`<软件id>.provenance.json` 与 `SHA256SUMS` 才进入 `build/upload_tmp_dir/`，直接上传到对应本仓版本的 assets。归档、内部索引、日志和测试不进入发布成果。Pages 复用 `apt-data` 产物分支发布，只保存公开站点与签名索引，不走 Actions Artifacts，也不再另建站点副本。

签名私钥生成、备份、换钥和客户端报错修复见[使用与部署](nees_user_read.md#恢复与换钥)。只更新同一个 `APT_HUB_GPG_PRIVATE_KEY` Secret。

## 本地验证

需要已有 Bash、curl、jq、GnuPG、dpkg 工具、`apt-ftparchive`、`readelf`、`xxd`、Node.js、PATH 中可调用的 ShellCheck 和 Ubuntu 官方 archive keyring。Node.js 仅用于测试的隔离 HTTPS 夹具，不是源维护脚本或客户端的运行依赖。项目不自动在本机安装依赖。

测试在项目 `tmp/` 使用临时测试密钥和测试包；不安装测试包、不改变系统软件源。Ubuntu 测试需要访问官方软件源，网络失败不是测试通过。

执行完整既有测试：

```bash
bash tests/sync_test.sh && bash tests/render_test.sh && bash tests/workflow_test.sh && bash tests/add_source_test.sh && bash tests/update_sources_test.sh && bash tests/go_deb_test.sh && bash tests/go_source_test.sh && bash tests/release_test.sh && bash tests/ubuntu_test.sh
```

测试密钥只用于本地 `tmp/`，不放进生产 Actions Secret；测试目录不要混放用户文件。

## 本仓脚本版本

`VERSION` 只属于维护脚本，禁止手工修改。统一通过下列命令自动递增、生成变更记录、提交、打标签并推送：

```bash
bash git_tag.sh
```

首次脚本标签为 `v0.0.1`；以后末段逐次加 1，超过 `999` 向前进位。不手填版本、不重写已有标签。Actions 沿母版三段式，仅适配构包扩展、依赖和产物路径；软件源日常更新不递增维护脚本版本。真实发版须经用户明确授权。

## 上游与历史索引

保留必要的历史 by-hash 元数据。安装包不进入 Git 或 Pages，因此 Git 单文件大小不是接入软件包的限制；上游删除历史包后，本项目不承诺仍能下载该版本，也不静默转用第三方镜像。
