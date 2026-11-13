# 使用与部署

[返回 README](../README.md) · [维护说明](maintenance.md)

## 使用已发布的源

> 以下为新版全源入口用法，须在维护者部署本版脚本及聚合配置后使用；当前线上旧脚本尚不支持默认全源。

不需要 fork 或启用 Pages。确认维护者站点可信后，执行 [README](../README.md#一键加源与软件列表) 的统一命令，默认添加本站对当前 Ubuntu 代号、架构支持的全部源。脚本校验公钥、签名索引和包摘要后写入专用 keyring 与各软件 `.sources`，不安装程序、不改其他源；全部成功后删除下载副本，失败保留供重跑。

自部署站点可替换下面的地址，下载、赋权、运行用 `&&` 串联：

```bash
site_url='https://packages.example.test/tools' && mkdir -p tmp/apt-hub-add && (cd tmp/apt-hub-add && curl -fsSL --proto '=https' --proto-redir '=https' -o add_source.sh "$site_url/add_source.sh" && chmod a+x ./add_source.sh && sudo ./add_source.sh --site-url "$site_url")
```

客户端需要 Bash、curl、GnuPG、dpkg、flock 及 Ubuntu 基础命令，可访问 Pages、上游 GitHub Release 和资产 CDN。不支持的系统拒绝；个别软件不支持当前系列或架构时不添加该项；适用项中任何验证失败都不提交半套源。再次运行可纳入后来发布的软件。高级用法仍可传 `--software <软件标识>` 只处理一个源。

加源后按需执行 `sudo apt update && sudo apt install <软件包名>`，以后普通 `sudo apt update && sudo apt upgrade`。Go 的入口包 `golang` 依赖精确同版本 `golang-go`，命令文件由后者提供。`2:` 是沿用 Ubuntu 的 Debian epoch，不是本仓发版版本。

### 手动配置

从站点下载 `apt-hub.gpg` 到 `/etc/apt/keyrings/apt-hub.gpg`（`0644`）；对应 Ubuntu 的聚合配置为 `<站点>/repos/<代号>.sources`，按架构选取支持的条目。单个软件配置仍在 `<站点>/repos/<软件标识>/<代号>.sources`。`Signed-By` 必须指向上述专用公钥，不能关闭验签或使用 `trusted=yes`。

索引来自 Pages；官方已有 `.deb` 从官方地址下载，Go 构造包从本仓 Releases assets 下载。源端只提供元数据，不代替代理或兜底上游已删除的安装包。声明支持表示 APT 验签、下载与依赖解析已验证，不等于上游承诺所有桌面、Wayland、无人值守或目标硬件功能可用。

## 部署自己的源

1. 使用公开仓库并启用 Actions；fork 的定时工作流需要手动启用。
2. 按下节生成专用无口令签名钥，将 `private-key.asc` 完整内容（含首尾标记）保存到 **Settings → Secrets and variables → Actions → Secrets**，名称为 **`APT_HUB_GPG_PRIVATE_KEY`**。不放 Variables、不提交 Git、不发聊天，离线备份密钥目录；`tmp/` 不是备份位置。
3. **Settings → Pages → Source → Deploy from a branch → `apt-data` → `/ (root)`**。首次没有该分支时，运行一次 `Release_Build` 准备 `.nojekyll`，按提示选择来源后重跑。已有部署保留自定义域名。
4. 提交修改后，在干净仓库执行 `bash git_tag.sh`，自动升版并完成构建、assets 上传与签源发布。仅重签已有版本时，在 **Actions → Release_Build → Run workflow** 选 `main`，`rotate_from` 留空。

只需一个私钥 Secret；`GITHUB_TOKEN` 由 Actions 提供，公钥、指纹、站点地址和发布者身份由流程取得。`apt-data` 只保存公开站点产物；推送后显式请求 Pages 构建，核对准确提交及公网状态后才更新 README，不以测试通过冒称上线。

### 生成签名密钥

在有 GnuPG 的可信电脑、项目根目录执行。专用目录不影响默认密钥库：

```bash
umask 077 && mkdir -p tmp && key_dir=$(mktemp -d "$(pwd -P)/tmp/k.XXXXXX") && chmod 700 "$key_dir" && test "$(printf '%s' "$key_dir/S.gpg-agent.browser" | wc -c | tr -d '[:space:]')" -lt 104 && gpg --homedir "$key_dir" --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'apt-hub APT signing' ed25519 sign 0 && fpr=$(gpg --homedir "$key_dir" --batch --with-colons --list-secret-keys | awk -F: '$1=="fpr"{print $10;exit}') && test "${#fpr}" -eq 40 && gpg --homedir "$key_dir" --batch --armor --export-secret-keys "$fpr" >"$key_dir/private-key.asc" && gpg --homedir "$key_dir" --batch --export "$fpr" >"$key_dir/apt-hub.gpg" && printf '%s\n' "$fpr" >"$key_dir/fingerprint.txt" && gpgconf --homedir "$key_dir" --kill gpg-agent && printf '私钥文件：%s/private-key.asc\n公开指纹：%s\n' "$key_dir" "$fpr"
```

路径检查失败或报 `File name too long` 时，改用绝对路径较短的项目副本。

### 查看公钥

公钥只保存在 `apt-data` 根目录的 `apt-hub.gpg`，发布后地址为 `<站点>/apt-hub.gpg`，不在 Markdown 维护第二份。显示指纹而不导入默认密钥库：

```bash
site_url='https://packages.example.test/tools' && mkdir -p tmp && curl -fsSL --proto '=https' --proto-redir '=https' -o tmp/apt-hub-public.gpg "$site_url/apt-hub.gpg" && gpg --batch --show-keys --with-fingerprint tmp/apt-hub-public.gpg
```

下载显示的指纹不能充当独立身份依据，应与维护者可信公告中的完整指纹核对。

## 恢复与换钥

### 维护者恢复

**原钥仍可用**：Secret 有效则无需改动；丢失时从离线备份恢复同一私钥，运行 `Release_Build`，`rotate_from` 留空。公钥未变，使用者无需换钥。

**必须换新钥**：疑似泄露先暂停发布，有撤销证书则公告旧钥撤销。读取要恢复的 `apt-data` 快照的旧公钥指纹：

```bash
mkdir -p tmp && git fetch origin refs/heads/apt-data && git show FETCH_HEAD:apt-hub.gpg >tmp/apt-hub-old.gpg && gpg --batch --show-keys --with-colons tmp/apt-hub-old.gpg >tmp/apt-hub-old.info && old_fpr=$(awk -F: '$1=="fpr" && !seen {print $10; seen=1}' tmp/apt-hub-old.info) && test "${#old_fpr}" -eq 40 && printf 'rotate_from=%s\n' "$old_fpr"
```

生成新钥，更新**同一个 Secret**，运行 `Release_Build` 时 `rotate_from` 填**旧 40 位完整指纹**，不是新指纹。无需旧私钥，不删除 `apt-data`。发布成功后公告新钥 `fingerprint.txt` 的完整指纹。

### 使用者修复

原钥恢复只需 `sudo apt update`。维护者公告换钥后，先独立核实新完整指纹，再统一修复本站全部适用源：

```bash
site_url='https://packages.example.test/tools' && new_fpr='<维护者公告的新完整指纹>' && mkdir -p tmp/apt-hub-repair && (cd tmp/apt-hub-repair && curl -fsSL --proto '=https' --proto-redir '=https' -o add_source.sh "$site_url/add_source.sh" && chmod a+x ./add_source.sh && sudo ./add_source.sh --site-url "$site_url" --replace-key "$new_fpr") && sudo apt update
```

仅修复本源专用 keyring 和匹配源，冲突明确拒绝；失败回滚，恢复失败时保留旧钥备份并显示位置。共享 keyring 的其他源也须属于同一站点，不能静默替换第三方信任。

`NO_PUBKEY` 表示缺公钥，`EXPKEYSIG` 表示钥过期；确认维护者已换钥后再修复。`BADSIG`、摘要或指纹不符必须停止，不关闭验签。
