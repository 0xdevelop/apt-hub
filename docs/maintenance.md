# 维护说明

[返回 README](../README.md) · [首次启用](nees_user_read.md)

## 软件清单

`config/packages.json` 是接入软件的配置入口，`packages` 可包含多个软件，不为每个软件复制同步脚本。

- `id`：本仓唯一标识；`package` 必须等于 `.deb` 的 `Package`。
- `repository`：官方 GitHub `owner/repository`，不填第三方下载镜像。
- `description`：README 与静态页使用的简短说明。
- `source_url`、`license`：官方源码入口和许可信息；再分发条件仍须维护者核对。
- `architectures`：Debian 架构到发布资产名称正则的对应关系；每个架构必须唯一匹配一个真实 `.deb`。首版支持 `amd64`、`arm64`，不代表 Ubuntu 或上游支持的全部架构。
- `ubuntu_series`：`"supported"` 表示当前标准支持集合；也可填写明确的 Ubuntu 代号数组，但必须是该集合的子集。上游有限制时应收窄，不能因本机能下载就任意扩大。

清单新增后，下一次定时或手动同步会重新纳入全部配置软件。版本、包大小和摘要不手工写进清单；它们从官方发布及实际包元数据获取。官方资产没有 SHA256 digest、匹配歧义、包身份不符或同版本被替换时明确失败，不以自己计算的摘要冒充官方摘要。

## 发布数据与列表

- `apt-data` 分支保存候选仓库及不可变历史数据，包文件不进入主分支。
- `data/published.json` 只记录成功部署后回写的状态，不手动填入尚未生效的软件。
- `templates/readme_packages.md`、`templates/readme_empty.md` 控制列表表头与空态；`templates/index.html` 控制静态页。
- `scripts/render.sh` 只替换 README 中 `APT-HUB:PACKAGES:BEGIN` / `END` 两条独占行之间的区域，区域外正文由人维护。缺失或重复标记会拒绝写入。

签名与候选元数据每日续期，软件的 `updated_at` 不因扫描、重签而变化。Pages 部署失败不能更新主分支为“已生效”；回写失败也不强推覆盖同事提交，修复后重跑使状态收敛。

## 本地验证

需要已有 Bash、curl、jq、GnuPG、dpkg 工具、`apt-ftparchive` 和 Ubuntu 官方 archive keyring。项目不自动在本机安装依赖。

测试在项目 `tmp/` 生成明确标注的测试包和测试密钥；不安装测试包、不改变系统软件源。Ubuntu 测试需要访问官方软件源，网络失败不是测试通过，也不应被标成软件依赖不兼容。

执行完整既有测试：

```bash
bash tests/sync_test.sh && bash tests/render_test.sh && bash tests/ubuntu_test.sh
```

临时测试密钥不可当生产密钥。开发用 `tmp/` 可再生成，不应承载唯一的生产密钥或人工维护数据；测试脚本自己的工作子目录不要混放用户文件。

## 本仓脚本版本

`VERSION` 只属于维护脚本。用户决定发布脚本新版后，先更新 `VERSION`、按正常流程提交且保持工作区干净，再执行对应标签校验，例如当前版本：

```bash
bash git_tag.sh --version 0.1.0
```

该命令只在本地创建对应标签；不会提交、推送、删除或重写历史标签。软件源自动更新不调用它，本次开发也不自动运行本仓发版。

## 容量与迁移

保留旧包和旧 by-hash 是兼容旧客户端的必要条件，不在定时同步时直接删掉。Pages 站点上限与 GitHub 单文件限制可能限制可接入包的体积；不通过拆包或变更上游 `.deb` 规避限制。若需要更大的承载容量，应先明确静态文件托管迁移方案，而不是扩成管理平台。
