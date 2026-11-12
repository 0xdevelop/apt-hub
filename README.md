# apt-hub

收集有官方发布下载、但没有官方 Ubuntu APT 源的软件，为其补齐符合 Ubuntu 规则的安装与升级来源。首批目标为 **Go（golang）与 RustDesk**，后续按软件条目和必要的适配脚本接入。

源码仓、数据分支和 Pages 只保存脚本、包信息及签名 APT 元数据。RustDesk 等官方已有 `.deb` 的软件原样核验、官方直下；Go 官方提供 Linux `tar.gz`，由本项目打成真正的 Debian 包并通过本仓 Releases assets 分发，不冒称官方 `.deb`。客户端始终使用标准 APT，不在安装脚本里联网拉取主程序。Go 的安装入口为 `golang`，依赖同版本的 `golang-go` 工具链包；安装后使用普通 `go`、`gofmt` 命令。

> 尚未完成首次生产部署，当前软件列表为空。按下文配置唯一签名私钥与 Pages，待 `ubuntu-publish` 成功后，再使用已生效列表中的加源命令。

维护以 Shell + GitHub Actions 为主，优先复用标准 APT 的索引与下载分流能力；静态页和 README 展示已生效版本。

## 已生效的软件

下面区域只反映成功部署后的状态，不把上游“已发布”或本地“已下载”冒充本源“已生效”。

<!-- APT-HUB:PACKAGES:BEGIN -->
尚未完成首次发布
<!-- APT-HUB:PACKAGES:END -->

## 新增其他软件

首批目标仍是 **Go 与 RustDesk**，不预先接入其他软件。官方已有 `.deb` 的条目复用下方模板；Go 由独立 `gen_deb_golang.sh` 核对官方归档后构包，`build.sh` 以扩展方式调用，双架构 `.deb`、摘要和来源记录作为本仓 Release assets。Go 包与官方原始归档分别记录摘要、大小与出处，只有完整构建、上传和索引验证成功后才列为已生效。

以后接入同类 `.deb` 软件，将下面的对象复制到 `config/packages.json` 的 `packages` 数组中，填写真实官方信息并保留已有条目，无需再复制一套同步脚本：

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

以上名称、许可和文件名均为占位示例，必须按上游实际情况填写：

1. `id` 是唯一源标识，以 ASCII 字母或数字开头，只含字母、数字、`_`、`.`、`-`，不能含 `..`；`package` 必须等于官方包内的 `Package`。
2. `repository` 必须是软件官方仓库。每个架构的正则须恰好匹配一个正式版本 `.deb`，且官方资产提供 SHA256 digest；缺摘要或匹配不唯一时拒绝发布，不自行补一个“官方摘要”。只填写上游实际提供的架构。
3. `ubuntu_series` 可用 `"supported"`，也可按上游限制填写当前标准支持期内的代号数组；发布前仍逐项验证依赖。版本、文件大小和摘要由脚本读取，不手填、不把预发布版本当稳定版。
4. 提交条目后，在自己的仓库手动运行 Actions 的 `ubuntu-publish`，或等待定时执行。维护侧共用 `scripts/update_sources.sh`，一次完成同步、验证和列表生成；本地显式参数示例见[维护说明](docs/maintenance.md#一条命令检查并更新候选)，生产签名与 Pages 的启用见[首次启用](docs/nees_user_read.md)。
5. 只有部署成功，软件才进入上面的已生效列表；使用者复制对应的“一键加源”命令，此后按普通 APT 安装、升级。

只有归档包的上游需要像 Go 一样增加独立构包脚本，由 `build.sh` 扩展调用，再将真实 Debian 包、摘要与来源记录接入同一发布链。不能把归档改后缀冒充 `.deb`，也不在客户端安装脚本中临时下载主程序。

## 维护者首次启用与签名密钥

1. **生成密钥**：在已安装 GnuPG 的可信电脑、项目根目录执行，生成专用无口令签名钥，不改默认密钥库。

```bash
umask 077 && mkdir -p tmp && key_dir=$(mktemp -d "$(pwd -P)/tmp/k.XXXXXX") && chmod 700 "$key_dir" && test "$(printf '%s' "$key_dir/S.gpg-agent.browser" | wc -c | tr -d '[:space:]')" -lt 104 && gpg --homedir "$key_dir" --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'apt-hub APT signing' ed25519 sign 0 && fpr=$(gpg --homedir "$key_dir" --batch --with-colons --list-secret-keys | awk -F: '$1=="fpr"{print $10;exit}') && test "${#fpr}" -eq 40 && gpg --homedir "$key_dir" --batch --armor --export-secret-keys "$fpr" >"$key_dir/private-key.asc" && gpg --homedir "$key_dir" --batch --export "$fpr" >"$key_dir/apt-hub.gpg" && printf '%s\n' "$fpr" >"$key_dir/fingerprint.txt" && gpgconf --homedir "$key_dir" --kill gpg-agent && printf '私钥文件：%s/private-key.asc\n公开指纹：%s\n' "$key_dir" "$fpr"
```

若路径长度检查未通过或 GnuPG 报 `File name too long`，换到绝对路径更短的项目副本重试。

2. **保存私钥**：仓库 **Settings → Secrets and variables → Actions → Secrets → New repository secret**，名称填 `APT_HUB_GPG_PRIVATE_KEY`，值填 `private-key.asc` **完整内容（含首尾标记）**。若误放在 **Variables**，请移到 **Secrets** 并删除同名 Variable；工作流只读取 Secret。离线备份整个密钥目录，不将私钥发到聊天或提交 Git；`tmp/` 不是备份位置。
3. **启用 Pages**：**Settings → Pages → Source → GitHub Actions**。只需上述一个 Secret；`GITHUB_TOKEN` 由 Actions 自带。
4. **发布**：**Actions → ubuntu-publish → Run workflow**，分支选 `main`，首次 `rotate_from` 留空。部署成功后再用已生效列表中的加源命令；CI 通过不代表源已上线。

### 公钥放哪里、怎么读

公钥**不复制进 Markdown**。发布流程从私钥导出独立文件 `apt-hub.gpg`：仓库保存在 `apt-data` 分支根目录，部署后位于 **`<站点根地址>/apt-hub.gpg`**。加源脚本固定从该地址读取，并写入使用者的 `/etc/apt/keyrings/apt-hub.gpg`；不用额外的公钥 Secret 或另一套读取规则。

下面命令仅显示公钥和完整指纹，不导入默认密钥库。将站点地址替换为已部署的 Pages 根地址；首次发布前该文件尚不存在：

```bash
site_url='https://packages.example.test/tools' && mkdir -p tmp && curl -fsSL --proto '=https' --proto-redir '=https' -o tmp/apt-hub-public.gpg "$site_url/apt-hub.gpg" && gpg --batch --show-keys --with-fingerprint tmp/apt-hub-public.gpg
```

下载文件可供程序直接读取；其指纹应与维护者公告的完整指纹一致，不能把同次下载显示的指纹当作独立证明。

### 仓库维护者恢复

**A. 原钥可用：不换钥**

1. Actions Secret 仍有效则不用改；若 Secret 丢失，将备份 `private-key.asc` 的完整内容恢复到同名 Secret。
2. **Actions → ubuntu-publish → Run workflow**，选 `main`，`rotate_from` **留空**。
3. 发布成功即恢复。公钥没变，使用者无需操作。

**B. 原钥无法恢复或疑似泄露：换新钥**

1. 疑似泄露时先暂停发布；有撤销证书则公告旧钥撤销。以下步骤用于已经发布过的源。
2. 在仓库根目录执行下列命令，从工作流要恢复的 `apt-data` 快照读取**旧完整指纹**：

```bash
mkdir -p tmp && git fetch origin refs/heads/apt-data && git show FETCH_HEAD:apt-hub.gpg >tmp/apt-hub-old.gpg && gpg --batch --show-keys --with-colons tmp/apt-hub-old.gpg >tmp/apt-hub-old.info && old_fpr=$(awk -F: '$1=="fpr" && !seen {print $10; seen=1}' tmp/apt-hub-old.info) && test "${#old_fpr}" -eq 40 && printf 'rotate_from=%s\n' "$old_fpr"
```

3. 用上面的生成命令创建新钥，将新 `private-key.asc` 完整内容更新到**同一个 Secret**。
4. **Actions → ubuntu-publish → Run workflow**，选 `main`，`rotate_from` 填步骤 2 的**旧 40 位完整指纹**，不是新指纹。无需旧私钥，不删除 `apt-data`。
5. 发布成功后，公告新钥生成目录中 `fingerprint.txt` 的**新完整指纹**，通知使用者按下节修复。

### 使用者恢复

- 维护者恢复的是原钥：不用换公钥，只执行 `sudo apt update`。
- 维护者公告已换钥：先核实公告的**新 40 位完整指纹**，再执行下列命令。将占位值替换为真实站点根地址、自己已添加的软件标识（`golang` 或 `rustdesk`）和新指纹：

```bash
site_url='https://packages.example.test/tools' && software='golang' && new_fpr='<维护者公告的新完整指纹>' && mkdir -p tmp/apt-hub-repair && (cd tmp/apt-hub-repair && curl -fsSL --proto '=https' --proto-redir '=https' -o add_source.sh "$site_url/add_source.sh" && chmod a+x ./add_source.sh && sudo ./add_source.sh --site-url "$site_url" --software "$software" --replace-key "$new_fpr") && sudo apt update
```

脚本会下载新公钥、核对指纹及签名，只修复本源专用公钥和匹配的 `.sources`；共享该公钥的本源软件修复一次即可。成功后删除下载脚本；失败回滚，回滚失败则保留备份并显示恢复路径。

常见报错：`NO_PUBKEY` 表示缺公钥，`EXPKEYSIG` 表示钥已过期；须确认维护者已换钥再执行换钥修复。`BADSIG`、摘要或指纹不符应停止，不关闭验签。

## 文档

- [首次启用](docs/nees_user_read.md)：一个签名私钥和 Pages。
- [维护说明](docs/maintenance.md)：软件清单、模板区域、定时更新与脚本版本的职责。
- [本次验证记录](docs/verification.md)：真实包、Ubuntu/架构矩阵、隔离 APT 下载与未覆盖事项。
- [实施计划与验收边界](docs/plan.md)：需求出处、Ubuntu 支持对齐、并行实施和失败处理。

## 更新流程

维护侧：软件条目 → 固定本次官方版本与摘要 → 原包核验或独立构包 → 发版、构建并上传 assets、按引用清理冗余 → 校验真实包下载与签名 APT 元数据 → Ubuntu 依赖及升级验证 → 部署 → 回写已生效状态和列表。没有版本变化时复用已确认且不可变的产物；任一步失败，不将候选写成已生效。

使用侧：添加源后执行 `sudo apt update && sudo apt upgrade`；首次安装 Go 执行 `sudo apt install golang`，RustDesk 执行 `sudo apt install rustdesk`。Go 由 `golang` 入口包依赖同版本 `golang-go`，包版本沿用 Ubuntu 的 `2:` epoch（例如 `2:1.27.3-1`），不能仅比较去掉 epoch 的数字。软件更新遵循 Debian 包版本、依赖关系和签名校验，不要求用户另跑专用升级器。没有版本变化时不伪造软件更新时间，签名索引仍定期续期。

APT 的索引请求与包请求分流：签名索引来自 Pages；RustDesk 原样包来自官方，Go 生成包来自本仓 Releases assets。Git 源码与 `apt-data` 不存大包。清理只处理本项目生成包版本，仍被有效索引引用的 assets 必须保留；官方历史包被上游删除时不承诺兜底，也不静默换用第三方镜像。

## Ubuntu 与软件支持

按发行日期和标准支持结束日期对齐当前 Ubuntu 发行版，ESM/Ubuntu Pro 不等同于普通标准支持。每个声明发布的“Ubuntu 代号 × 架构 × 软件版本”都必须在对应官方签名源下通过隔离 APT 依赖解析。

这里的验证证明包能被 APT 验签、获取并解析依赖，**不等于上游对所有 Ubuntu 版本作兼容承诺，也不等于已验证桌面显示、无人值守或目标硬件功能。** 上游明确限制版本或架构时须收窄清单，不以其他架构代替。

## 版本职责

- **上游软件版本**：从官方发布取得，不手工追写一份 Go 版本文件。
- **Debian 包版本**：`config/go.json` 的 `epoch` 固定为 Ubuntu 兼容的 `2`，`revision` 为打包修订；控制字段组成 `2:上游版本-修订`。同一包版本不覆盖替换，资产文件名和 Release 标签不带 epoch。
- **维护脚本版本**：只通过 `bash git_tag.sh auto` 自动递增并生成版本提交和 `vX.Y.Z` 标签，不手改 `VERSION`、不手填版本。首次标签为 `v0.0.1`，以后末段每次加 1，超过 `999` 向前进位（如 `0.0.999 → 0.1.0`）。沿母版三段式发布和清理旧版本；日常接源更新不升脚本版本。

## 非破坏性原则

本地开发与验收不改系统 APT 源、keyring 或 dpkg 状态，不安装 RustDesk，不改 Git/SSH、shell 配置或 OpenClash。生产签名私钥由用户放在 Actions Secret 中；公钥和指纹随源公开。首次部署前没有可承诺生效的公网源地址。
