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

使用自己的公开仓库，启用 Actions，并将 **Settings → Pages → Source** 设为 **GitHub Actions**。只需手动配置一个仓库 Actions **Secret**：`APT_HUB_GPG_PRIVATE_KEY`；不是公开的 Variables。工作流自带的 `GITHUB_TOKEN` 无需另建，站点地址、发布者、公钥和指纹由流程取得。

在自己的可信电脑、项目根目录执行下列一行命令（需要已有 GnuPG）。只生成本源专用的无口令签名钥，不改系统默认 GnuPG 密钥库：

```bash
umask 077 && mkdir -p tmp && key_dir=$(mktemp -d "$(pwd -P)/tmp/k.XXXXXX") && chmod 700 "$key_dir" && test "$(printf '%s' "$key_dir/S.gpg-agent.browser" | wc -c | tr -d '[:space:]')" -lt 104 && gpg --homedir "$key_dir" --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'apt-hub APT signing' ed25519 sign 0 && fpr=$(gpg --homedir "$key_dir" --batch --with-colons --list-secret-keys | awk -F: '$1=="fpr"{print $10;exit}') && test "${#fpr}" -eq 40 && gpg --homedir "$key_dir" --batch --armor --export-secret-keys "$fpr" >"$key_dir/private-key.asc" && gpg --homedir "$key_dir" --batch --export "$fpr" >"$key_dir/apt-hub.gpg" && printf '%s\n' "$fpr" >"$key_dir/fingerprint.txt" && gpgconf --homedir "$key_dir" --kill gpg-agent && printf '私钥文件：%s/private-key.asc\n公开指纹：%s\n' "$key_dir" "$fpr"
```

这里用短随机目录 `tmp/k.XXXXXX`，避免深层仓库路径使 macOS 的 GnuPG 套接字路径过长。若旧命令出现 `can't connect to the gpg-agent: File name too long`，后续 `No agent running` 是其连带错误；直接改用本命令，不必重装 GnuPG 或修改默认密钥库。命令在生成前检查套接字路径小于 104 字节，若该检查停止，须换到绝对路径更短的项目副本后重试；单独 `cd` 到原目录不能缩短绝对路径。

将 `private-key.asc` **完整内容**（包括 `BEGIN/END PGP PRIVATE KEY BLOCK`）填入仓库 **Settings → Secrets and variables → Actions → New repository secret**，名称为 `APT_HUB_GPG_PRIVATE_KEY`。私钥是明文导出，文件权限为 `0600`：不要贴到聊天、提交 Git 或放进 Pages。离线备份整个专用密钥目录；`tmp/` 不是长期备份位置。公钥与完整指纹可以公开。

配置后手动运行 Actions 的 `ubuntu-publish`；成功部署并出现已生效列表后再添加源。没有生产密钥时 CI 测试仍可通过，但不代表公网源已上线。

### 私钥丢失或泄露后的维护者处理

- **只丢失本地文件**：若离线备份仍在，恢复原密钥即可，使用者不需要换钥；若原签名钥已无法恢复，再生成新钥。
- **私钥可能泄露**：立即撤销旧 Secret、暂停发布并公告换钥；有撤销证书时同时发布旧钥撤销信息。不能只换一个 Secret 就声称旧钥已不再被所有客户端信任，使用者还要替换本源公钥。

用上面的命令生成另一套新钥，保存旧完整指纹，并更新同一个 `APT_HUB_GPG_PRIVATE_KEY` Secret。在 `ubuntu-publish` 的手动运行页面，将 `rotate_from` 填为旧的完整指纹。流程使用已发布旧公钥校验既有元数据，再以新钥签名，不需要旧私钥，也不删除 `apt-data`。发布成功后，从独立可信渠道公告**新完整指纹**；不要让使用者只信下载站点自己显示的短 Key ID。

### 使用者可能看到的报错与修复

下面是错误形态示例，尖括号内容是占位符，不是实际密钥：

```text
The following signatures couldn't be verified because the public key is not available: NO_PUBKEY <新钥的Key-ID>
The following signatures were invalid: EXPKEYSIG <旧钥的Key-ID> <签名身份>
E: The repository '<源地址> <Ubuntu代号> InRelease' is not signed.
拒绝静默换钥/跨站点同名钥冲突: 已有=<旧完整指纹> 下载=<新完整指纹>
```

`NO_PUBKEY` 常见于维护者已换钥而本机仍装旧公钥；`EXPKEYSIG` 表示签名钥已过期，不能直接当成一次正常轮换。`BADSIG`、摘要不符或指纹与维护者公告不一致时先停止，不用关闭验签来“修复”。

确认维护者通过独立可信渠道公布的新完整指纹后，填写下面三个值。`site_url` 是已上线的真实 Pages 根地址，`software` 是已添加的软件标识（如 `rustdesk` 或 `golang`），`new_fpr` 必须是公告中的 **40 位完整十六进制指纹**：

```bash
site_url='https://packages.example.test/tools' && software='rustdesk' && new_fpr='<维护者公告的新完整指纹>' && curl -fsSL --proto '=https' --proto-redir '=https' -o add_source.sh "$site_url/add_source.sh" && chmod a+x ./add_source.sh && sudo ./add_source.sh --site-url "$site_url" --software "$software" --replace-key "$new_fpr" && sudo apt update
```

上述地址和指纹是占位示例，先替换再执行。入口核对新指纹、签名与索引，只修复本源专用 `/etc/apt/keyrings/apt-hub.gpg` 和匹配的 `.sources`，不改其他软件源；提交失败时恢复旧公钥，若恢复也失败则报错并保留备份、显示恢复路径，不继续运行 APT。成功后删除下载副本。共享同一专用公钥的本源软件不用逐一导入公钥。**不要使用 `trusted=yes`、`--allow-unauthenticated`、`apt-key`，也不要删除整个 `/etc/apt/sources.list.d/`。**

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
- **维护脚本版本**：沿用根目录 `VERSION` 与 `git_tag.sh`，不再增加并行 `VERSION.txt`；用户执行发版命令才进行对应提交和标签操作，软件日常更新不冒用仓库脚本版本。

## 非破坏性原则

本地开发与验收不改系统 APT 源、keyring 或 dpkg 状态，不安装 RustDesk，不改 Git/SSH、shell 配置或 OpenClash。生产签名私钥由用户放在 Actions Secret 中；公钥和指纹随源公开。首次部署前没有可承诺生效的公网源地址。
