# apt-hub

为没有官方 Ubuntu APT 源的软件提供签名索引，使用标准 APT 安装与升级。官方 `.deb` 直接从上游下载；Go 官方归档转换为 Debian 包后由本仓 Releases 分发。Git 和 Pages 不存安装包。

## 使用

下方一键命令一次添加本站对当前 Ubuntu、架构支持的全部软件源，不安装软件。以后新增软件，重新执行同一条命令即可纳入；已有源保持幂等。加源脚本成功自删，失败保留。

加源后按需安装、正常升级：

```bash
sudo apt update && sudo apt install golang rustdesk
sudo apt update && sudo apt upgrade
```

Go 安装后直接使用 `go`、`gofmt`。环境要求、手动配置与换钥见[使用与部署](docs/nees_user_read.md)。

## 一键加源与软件列表

列表取自已发布状态。**全源加源是本轮新版功能，尚未部署到 Pages；下列统一命令须待本版部署后使用。**

<!-- APT-HUB:PACKAGES:BEGIN -->
<a id="apt-hub-add-source"></a>

```bash
curl -fsSL --proto '=https' --proto-redir '=https' -o add_source.sh 'https://0xdevelop.m-b-crazy.com/add_source.sh' && chmod a+x ./add_source.sh && sudo ./add_source.sh --site-url 'https://0xdevelop.m-b-crazy.com'
```

| 软件 | 版本 | 支持环境 | 说明 |
| --- | --- | --- | --- |
| [golang](https://github.com/0xdevelop/apt-hub/releases/tag/golang-1.27.4-1) | 2:1.27.4-1 | jammy, noble, resolute, stonking · amd64, arm64 | Go 官方 Linux 归档构建的工具链 |
| [rustdesk](https://github.com/rustdesk/rustdesk/releases/tag/1.5.3) | 1.5.3 | jammy, noble, resolute, stonking · amd64, arm64 | 开源远程桌面 |
<!-- APT-HUB:PACKAGES:END -->

## 维护

首次部署只需一个签名私钥 Secret 和 Pages，步骤见[部署与密钥](docs/nees_user_read.md#部署自己的源)。日常发布在干净仓库执行：

```bash
bash git_tag.sh
```

默认自动升版。同一工作流完成 `Release → Build → RemoveOldRelease`：构造包上传对应本仓 `vX.Y.Z` assets，签名站点保存到 `apt-data` 并发布，成功后回写列表。日常检查与索引续签也由该工作流定时执行。

## 文档

- [使用与部署](docs/nees_user_read.md)：加源、Pages、签名密钥与恢复。
- [维护说明](docs/maintenance.md)：新增软件、版本职责与本地验证。
- [验证记录](docs/verification.md) · [需求与边界](docs/plan.md)。
