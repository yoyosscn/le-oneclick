# 贡献指南

感谢你愿意改进 `le-oneclick`。提交前请先读一下这几条，能让合并快很多。

## 开发环境

- 只需要一个 POSIX `sh`（bash / dash / busybox ash 都可以）
- 推荐安装 [shellcheck](https://github.com/koalaman/shellcheck)：`shellcheck -S error -x le-oneclick.sh`
- 不需要 root 即可运行测试。

## 本地测试

```sh
sh tests/run.sh
```

测试覆盖：语法检查、`--help/--version`、辅助函数单元测试（域名/邮箱/文件名/目录校验等）、
`--dry-run` 端到端（用 mock 的 `id`/`curl`/`crontab` 避免真的改动系统）。

也建议在用真实 acme.sh 之前，先用 `--staging --dir /tmp/le-test` 演练一次完整流程。

参与本项目即表示你同意遵守 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。

## 代码约定

- 保持 **POSIX sh**：不要用 bash 专有语法（数组、`[[ ]]`、`local`、`pipefail`、`$'...'`）。
- 所有变量加引号；路径进 shell 字符串时要考虑特殊字符。
- 新增面向用户的选项时，同步更新：`usage()`、`README.md` 的参数表、`CHANGELOG.md`。
- 凡是会改动系统的操作，都要在 `--dry-run` 下变成打印而不是执行。

## 提交信息

使用 `<类型>: <简述>`，例如：

```
feat: 支持 --keylength ec-256
fix: standalone 模式在 80 端口被占用时给出明确提示
docs: 补充 Cloudflare 代理模式的说明
```

## 报告问题

- 功能缺陷 / 兼容性问题：开 Issue，附发行版、`sh` 实现（dash/ash/bash）、`acme.sh` 版本、完整命令与输出（注意去掉自己的域名）。
- 安全问题：请按 [SECURITY.md](SECURITY.md) 私下报告，不要公开提 Issue。
- 脱敏提醒：贴日志前请把真实域名、IP、邮箱替换成 `example.com` / `192.0.2.1` / `admin@example.com`。
