# 首次启用

[返回 README](../README.md)

> 仅在发布工作流成功、README 列表出现已生效软件后使用；测试通过不能代替正式部署。

## 自己部署一套源

1. 使用自己的公开仓库；启用 Actions。fork 的定时工作流需要手动启用。
2. **Settings → Pages → Source** 选择 **Deploy from a branch → `apt-data` → `/ (root)`**。首次没有该分支时，手动运行一次 `Release_Build` 准备 `.nojekyll`，按提示选择发布源后重跑。该分支只保存站点产物，不保存源码、安装包或私钥；已有部署切换时保留自定义域名，不必新增名为 `gh-pages` 的副本。
3. 在 **Settings → Secrets and variables → Actions → Secrets → New repository secret** 添加 `APT_HUB_GPG_PRIVATE_KEY`，值为完整的无口令 ASCII 私钥（含首尾标记）。不要放在 Variables、提交 Git 或发到聊天。
4. 在仓库提交修改后执行 `bash git_tag.sh auto`，由 `Release_Build` 构建、上传该版本 assets 并部署签名源。只重签已有版本时，在 Actions 手动运行同一工作流。成功后使用软件列表中的站点地址；以后由同一工作流定时维护。

公钥由流程导出到 `apt-data` 分支根目录的 `apt-hub.gpg`，部署后固定从 `<站点根地址>/apt-hub.gpg` 下载，不嵌入 Markdown。Pages 地址和发布者身份由 Actions 取得，不需要第二个 Secret。

## 只是使用已发布的源

不需要 fork 或启用 Pages。先核对使用的是可信维护者的站点，在软件列表复制该软件的“一键加源”命令。命令以 `&&` 串联下载、赋予执行权限和运行；入口验证 Ubuntu 代号、架构与签名索引，写入专用公钥和 `.sources`，成功后删除下载副本，失败则保留供重跑。它不会安装软件或修改系统已有源。

例如维护者的站点根为 `https://packages.example.test/tools`，软件标识为 `example-app`：

```bash
curl -fsSL --proto '=https' --proto-redir '=https' -o add_source.sh 'https://packages.example.test/tools/add_source.sh' && chmod a+x ./add_source.sh && sudo ./add_source.sh --site-url 'https://packages.example.test/tools' --software 'example-app'
```

以上为占位示例，不是已上线地址。加源后执行 `sudo apt update && sudo apt install <软件包名>`；以后按普通 APT 流程更新。不支持的 Ubuntu、架构或损坏签名会明确拒绝，不能通过关闭验签继续。

需要手动配置时，下载该站点的 `apt-hub.gpg`，保存到 `/etc/apt/keyrings/apt-hub.gpg`，权限 `0644`；再从软件列表选择对应 Ubuntu 代号的 `.sources`，保存到 `/etc/apt/sources.list.d/apt-hub-<软件标识>.sources`。其 `Signed-By` 必须指向上述公钥。只使用站点已声明支持的架构和 Ubuntu 版本。

索引来自该 Pages，由 APT 按签名索引校验包。RustDesk 等官方已有的 `.deb` 从软件官方地址下载；Go 官方提供归档，由本项目转换成真实 Debian 包后从本仓 Releases assets 下载。源码仓、数据分支和 Pages 不存安装包。不要关闭验签，不使用 `trusted=yes`。客户端须能访问 Pages、对应 GitHub Release 及其下载 CDN；Pages 不代替代理，也不兜底提供被上游删除的原包。

维护者按 [README 的恢复步骤](../README.md#仓库维护者恢复) 选择恢复原钥或换新钥；使用者按 [README 的修复命令](../README.md#使用者恢复) 操作。公钥读取命令见 [公钥放哪里、怎么读](../README.md#公钥放哪里怎么读)。使用者不接触私钥。
