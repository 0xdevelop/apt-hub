# 首次启用

[返回 README](../README.md)

> 新版尚未完成正式发布；仅在发布工作流成功、README 列表出现已生效软件后使用。

## 自己部署一套源

1. 使用自己的公开仓库；启用 Actions。fork 的定时工作流需要手动启用。
2. **Settings → Pages → Source** 选择 **GitHub Actions**。
3. 在 **Settings → Secrets and variables → Actions** 只添加 `APT_HUB_GPG_PRIVATE_KEY`，值为 Actions 直接用于签名的 ASCII armored 私钥。私钥不提交 Git、不发到聊天。
4. 在 Actions 手动运行 `ubuntu-publish`。成功后使用 Pages 显示的站点地址；以后按工作流定时维护。

公钥和指纹会随源公开；Pages 地址和发布者身份由 Actions 当前上下文取得。不需要第二个 Secret。

## 只是使用已发布的源

不需要 fork 或启用 Pages。先核对使用的是可信维护者的站点，在软件列表复制该软件的“一键加源”命令。命令以 `&&` 串联下载、赋予执行权限和运行；入口验证 Ubuntu 代号、架构与签名索引，写入专用公钥和 `.sources`，成功后删除下载副本，失败则保留供重跑。它不会安装软件或修改系统已有源。

例如维护者的站点根为 `https://packages.example.test/tools`，软件标识为 `example-app`：

```bash
curl -fsSL --proto '=https' --proto-redir '=https' -o add_source.sh 'https://packages.example.test/tools/add_source.sh' && chmod a+x ./add_source.sh && sudo ./add_source.sh --site-url 'https://packages.example.test/tools' --software 'example-app'
```

以上为占位示例，不是已上线地址。加源后执行 `sudo apt update && sudo apt install <软件包名>`；以后按普通 APT 流程更新。不支持的 Ubuntu、架构或损坏签名会明确拒绝，不能通过关闭验签继续。

需要手动配置时，下载该站点的 `apt-hub.gpg`，保存到 `/etc/apt/keyrings/apt-hub.gpg`，权限 `0644`；再从软件列表选择对应 Ubuntu 代号的 `.sources`，保存到 `/etc/apt/sources.list.d/apt-hub-<软件标识>.sources`。其 `Signed-By` 必须指向上述公钥。只使用站点已声明支持的架构和 Ubuntu 版本。

索引来自该 Pages，`.deb` 从软件官方地址下载，由 APT 按签名索引校验。不要关闭验签，不使用 `trusted=yes`。客户端必须同时能访问 Pages、软件官方 Release 与其下载 CDN；Pages 不代替代理，也不兜底提供被上游删除的包。
