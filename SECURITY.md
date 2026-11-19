# 安全策略

## 报告问题

**请使用 GitHub 的私密漏洞报告，不要公开提交 Issue。**

`https://github.com/yoyosscn/le-oneclick/security/advisories/new`
（仓库页面 → Security → Advisories → Report a vulnerability）

> 若暂时无法开启私密报告，请在此处填写**真实可收信**的专用邮箱，不要使用 `example.com`
> 之类的保留域 —— 那个地址无法投递，等于没有报告渠道。

请尽量包含：复现步骤、影响范围、涉及版本、你的环境（发行版 / `sh` 实现 / acme.sh 版本）。
确认后我们会在修复发布时致谢（除非你希望匿名）。

## 安全模型

本脚本是一个**安装与编排包装器**，本身不实现 ACME 协议，证书签发与续期由上游
[acme.sh](https://github.com/acmesh-official/acme.sh) 完成。请同时关注上游的安全公告。

### 信任边界

| 事项 | 说明 |
|---|---|
| root 权限 | 脚本以 root 运行：需要写 `/root/.acme.sh`、写入证书目录、临时监听 80 端口 |
| 上游客户端 | 首次运行会获取并安装 acme.sh（见下节「供应链」）；若系统已安装 acme.sh，脚本会直接复用，不做远程安装 |
| DNS 凭据 | **不接触**。本项目只使用 HTTP-01（standalone / webroot），不需要任何 DNS API 凭据 |
| 私钥 | 只保存在本机证书目录与 acme.sh 目录中；安装后脚本会显式设为 `640`（证书 `644`），属主 root |
| 日志 | 不额外落盘敏感信息；acme.sh 自身日志位于 `/root/.acme.sh/acme.sh.log`，建议确认其权限为 600 |

### 供应链：acme.sh 的获取方式

- 脚本优先复用系统里已存在的 `acme.sh`（`$ACME_HOME/acme.sh`、`/usr/local/bin`、`PATH` 中），
  只有在找不到时才联网安装。
- 联网安装时从 GitHub 下载 acme.sh 本体到临时文件，可选地校验 SHA256 后再执行安装：
  - `--no-install`：禁止联网安装，未找到 acme.sh 时直接报错并给出手动安装方法；
  - `--acme-path <路径>`：指定已有的 acme.sh；
  - 环境变量 `ACME_SHA256`：期望的安装脚本校验值，不匹配则中止；
  - 环境变量 `ACME_VERSION`：钉定要安装的上游版本 tag（默认 `master`）。
- **已知风险**：安装 acme.sh 会以 root 执行上游脚本，并写入 `crontab` 与 shell 启动文件。
  高安全要求环境建议手动安装 acme.sh（从发行版仓库或官方 tag），再用 `--acme-path` 指定。
- **版本要求**：acme.sh `3.0.6` 以下存在已知的 `eval` 远程执行问题（CVE-2023-38198）。
  脚本默认拒绝使用这类版本；仅在设置 `ACME_ALLOW_OLD=1` 时才继续。

### 已知限制

- 域名通过 CDN 代理时无法完成 HTTP-01 验证（协议限制，不是缺陷）。
- 通配符证书需要 DNS-01 验证，本项目不实现。
- 脚本假定 80 端口可被外网访问；NAT / 容器网络下的特殊情况请自行适配。

### 加固建议

- 使用 `--dry-run` 先检查环境与将要执行的命令。
- 把脚本放在 root 属主、非他人可写的目录里再执行（脚本拒绝在可被他人改写的路径上自动提权）。
- 定期检查 `crontab -l` 与 acme.sh 的续期日志，确认续期没有静默失败。
- 为证书目录设置最小可读权限，不要把私钥放进备份、日志采集或镜像层。
- 关注 acme.sh 上游版本，必要时升级。
