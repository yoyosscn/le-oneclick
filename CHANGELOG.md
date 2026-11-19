# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与语义化版本。

## [1.1.0] - 2026-11-19

安全与健壮性加固版本（1.0.0 未公开发布，直接以 1.1.0 作为首个公开版本）。

### 新增

- `--no-install` / `--acme-path`：支持复用已安装的 acme.sh，或在禁止联网的环境中直接报错。
- 环境变量 `ACME_VERSION` / `ACME_SHA256`：可钉定上游版本、校验下载文件完整性。
- 复用旧版 acme.sh 时检测版本，低于 3.0.6 会提示已知远程执行问题（CVE-2023-38198）。
- 校验证书签发者与 SAN 是否覆盖全部域名。
- `--service` 指定的服务名会校验，并要求系统存在 `systemctl`。
- 退出码说明（0 成功 / 1 失败或取消）。

### 修复

- **命令注入**：`--dir` / `--crt-name` / `--key-name` / `--service` 会进入 `--reloadcmd` 的 shell 字符串，
  现对全部取值做白名单/格式校验（拒绝单引号、换行、`..`、路径分隔符）。
- **提权安全**：自动 `sudo` 前先把脚本路径绝对化并校验属主与权限，拒绝在他人可写的目录（如 `/tmp`）提权。
- **PATH 劫持**：启动时固定 `PATH`，不再使用调用者环境中的可执行文件搜索路径。
- **私钥权限窗口**：以 `umask 077` 启动，并在安装后显式 `chmod 644/640`，不依赖续期钩子的副作用。
- **符号链接**：证书目录与最终文件若是符号链接则直接拒绝。
- **`--staging` 风险**：使用测试环境时会明确警告会覆盖目标目录中的同名生产证书，并要求二次确认。
- **CA 固定**：`--set-default-ca` 失败时直接退出（避免误用 acme.sh 默认的 ZeroSSL 签发），`--issue` 显式带 `--server letsencrypt`。
- 80 端口检测：缺少 `ss`/`netstat` 时给出明确提示，而不是继续猜测。
- 证书段数统计改用 `awk`，避免 `grep -c` 无匹配时的退出码把 `set -e` 打断。
- `--domain a.com,b.com` 的逗号分隔现在会被正确拆分。
- 交互与非交互模式：`-y` 缺少域名/邮箱时直接报错，不再进入等待输入的循环。
- `--staging` 隔离：未显式指定 `--dir` 时自动写到 `/root/le-oneclick-staging`，并忽略 `--service`（不会重启生产服务）；
  staging 改用 `--server letsencrypt_test`，不再与 `--server letsencrypt` 叠加。
- 校验时识别 `(STAGING)` 签发者：非 staging 运行却装到测试证书会直接报错。
- acme.sh 调用统一传 `--home`，自定义 `ACME_HOME` 时不再出现“安装成功但找不到”。
- 自动提权改为用八进制位运算检查文件与目录的组/他人写权限，并透传 `ACME_HOME` / `ACME_VERSION` / `ACME_SHA256`。
- 交互输入遇到 EOF（Ctrl-D）立即报错退出，不再死循环；Ctrl-C 会清理临时文件并以 130 退出。
- webroot 模式：显式创建并放开 `.well-known/acme-challenge/` 目录权限，签发子进程用 `umask 022`，避免挑战文件 600 导致 Web 服务读不到。
- 目标目录与目标文件：写入前拒绝符号链接、拒绝组/他人可写目录；证书目录显式 `chmod 755`。
- 兼容旧 OpenSSL：`-ext` 失败时回退 `-text` 解析 SAN，`pkey` 失败时回退 `rsa`/`ec` 提取公钥。
- acme.sh < 3.0.6 默认拒绝执行（`ACME_ALLOW_OLD=1` 可显式放行）。
- `-d ''` / `--domain=` 只留空白的情况会被归一化，不再绕过域名校验。
- 环境检查顺序调整：先判断 80 端口与验证方式，再检查依赖，避免因缺少 `socat` 直接退出而错过 webroot 选项。
- 自动提权路径校验细化：允许带 sticky 位的公共目录（如 `/tmp` 的 1777），仍拒绝同组/他人可写或属主异常的路径。
- 安装完成后检查 cron 守护进程是否真的在运行（避免 crontab 有任务但 cron 没启动导致续期静默失败）。
- 交互输入的退格兼容：部分终端/云控制台把删除键发送成 `^H`（或 `^?`），而内核 erase 键设置不匹配，
  导致删除键无效、输入里出现 `^H`。现在会按字符模拟退格自动修正，并把终端的 erase 键临时改成 `^H`
  （退出时恢复原设置），输入框也顺带去掉了误粘贴的 `\r` 与首尾空白。

### 变更

- 摘要与日志中的邮箱做打码显示。
- 续期任务检查会排除 `crontab` 中的注释行。
- 文档修正：acme.sh 新版续期频率与 ARI、EC 证书需要 `--ecc`、`--service` 仅支持 systemd。

### 测试与工程

- 新增 `tests/run.sh`：语法检查、`--help`/`--version`、辅助函数单元测试、`--dry-run` 端到端（mock `id`/`curl`/`crontab`）。
- 新增 GitHub Actions CI（shellcheck + 测试）。
- 新增 `.editorconfig`、`.gitattributes`、`CONTRIBUTING.md`、`SECURITY.md`、`CODE_OF_CONDUCT.md`、Issue 模板。

## [1.0.0] - 2026-11-19

### 新增

- 一键签发脚本：环境自检 → 交互式输入域名 → 签发 → 按指定文件名/目录落地 → 自动续期 → 校验。
- 环境自检：发行版与包管理器识别、依赖检查与安装、ACME 接口连通性、80 端口占用。
- 支持 `standalone`（默认）与 `--webroot` 两种验证方式。
- 证书与私钥文件名可配置（默认 `full_chain.pem` / `private.key`），目录默认 `/etc/V2ray`。
- `--staging` 演练模式与 `--dry-run` 空跑模式。
