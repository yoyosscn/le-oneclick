# le-oneclick

> 一条命令完成 Let's Encrypt 证书的**环境自检 → 签发 → 改名为指定文件名 → 落地到指定目录 → 自动续期**。

适用于自建节点 / 自托管服务（Xray、sing-box、Nginx、Trojan 等）：
每台机器独立子域、独立私钥，不使用 DNS API 凭据，也不需要手工合并证书链。

```sh
sudo sh le-oneclick.sh
```

---

## 特性

- **先查环境再干活**：识别发行版与包管理器，检查并（询问后）安装 `curl` / `openssl` / `socat` / `crontab`；检查 ACME 接口连通性、80 端口占用、域名解析。
- **交互式输入域名**：环境检查通过后才提示输入域名与邮箱，带格式校验；也支持全参数化用于自动化。
- **一键落地**：按你指定的文件名与目录写出（默认 `/etc/V2ray/full_chain.pem` + `/etc/V2ray/private.key`），**无需手工合并证书链**。
- **自动续期**：由 acme.sh 的定时任务检查（新版按 ARI 建议窗口，约每 6 小时；旧版每天一次），续期后自动重写同样的文件；可选续期后重启 systemd 服务。
- **安全加固**：固定 `PATH` 与 `umask`、校验脚本自身权限后才自动提权、对目录/文件名/服务名做白名单校验、拒绝符号链接目标、显式收紧私钥权限。
- **可演练**：`--dry-run` 只做检查并打印将要执行的命令，不产生任何变更。
- **可移植**：纯 POSIX `sh`，不依赖 bash 特性；包管理器自动识别（`apt` / `dnf` / `yum` / `apk` / `pacman` / `zypper`）。

---

## 环境要求

- Linux，具备 root 权限（脚本会先校验自身路径权限，再自动用 `sudo` 重提权）
- 一条已解析到本机的域名（A 记录指向本机公网 IP；NAT 环境需做 80 端口映射）
- 公网 **80** 端口可达（HTTP-01 验证需要）；出站 443 可达（ACME 接口、获取 acme.sh）
- 域名不能走 CDN 代理（Cloudflare 必须是“仅 DNS”灰云），否则验证请求不会到达本机

> 通配符证书（`*.example.com`）走 DNS-01 验证，需要 DNS API 凭据，本脚本不处理，请直接使用 acme.sh 的 DNS 模式。

> 兼容性说明：脚本按 POSIX `sh` 编写，设计上覆盖主流发行版，但**尚未在每个发行版逐一实测**。
> 已知边界：`--service` 依赖 systemd；Alpine 的 `crontab` 由 busybox 提供。
> 遇到兼容问题欢迎提 Issue，并附 `/etc/os-release` 与 `sh --version`。

---

## 在服务器上使用（一次配置，长期自动续期）

### 第 0 步：准备好域名

1. 在 DNS 里给这台服务器加一条 **A 记录**，指向它的公网 IP（本机有 IPv6 再加 AAAA，没有就只加 A）。
2. 如果域名托管在 Cloudflare：这条记录必须是**「仅 DNS」灰云**。橙云（代理）模式下验证请求会打在 Cloudflare 边缘，HTTP-01 必然失败。
3. 确认服务器**公网 80 端口可达**：云厂商安全组、本机 `ufw`/`firewalld`、NAT 端口映射都要放行。

### 第 1 步：把脚本放到服务器上

```sh
# 方式 A：在自己电脑上传（推荐放 /root 或 ~ 下）
scp le-oneclick.sh root@<服务器IP>:/root/

# 方式 B：直接在服务器上下载
curl -fsSL -o ~/le-oneclick.sh https://raw.githubusercontent.com/<owner>/<repo>/main/le-oneclick.sh
# 可选：核对 Release 公布的 SHA256
sha256sum ~/le-oneclick.sh
```

> `<owner>/<repo>` 是占位符，替换成实际仓库地址；也可以直接用 Release 资产：
> `https://github.com/<owner>/<repo>/releases/download/v1.1.0/le-oneclick.sh`
>
> 放在 `/tmp` 也能跑（脚本允许带 sticky 位的公共目录），但**不要**放在 `/var/www`、`/home/xxx/uploads` 这类同组/他人可写的目录里 ——
> 自动提权前脚本会校验自身与所在目录的权限，不安全的路径会直接拒绝。

### 第 2 步：执行（交互式，一条命令）

```sh
sudo sh ~/le-oneclick.sh
```

普通用户执行时，脚本会先校验自身路径是否安全，再用 `sudo` 重新执行（会提示输入一次 sudo 密码）。

接下来你只要回答两个问题：

```text
[..] 操作系统: Debian GNU/Linux 12 (bookworm)
[OK] 包管理器: apt-get
[OK] 验证方式: standalone（80 端口空闲，签发时临时占用数秒）
[OK] 依赖检查通过（curl / openssl / socat / crontab 已就绪）
[OK] ACME 接口可达
------------------------------------------------------------
请填写签发信息（直接回车使用默认值）
要签发证书的域名（多个用空格或逗号分隔）: node1.example.com
ACME 账户邮箱（用于到期提醒）: admin@example.com
------------------------------------------------------------
即将执行：
  域名        : node1.example.com
  邮箱        : a***@example.com
  验证方式    : standalone（临时占用 80）
  证书        : /etc/V2ray/full_chain.pem
  私钥        : /etc/V2ray/private.key
  续期后动作  : 仅重写文件，不重启任何服务
------------------------------------------------------------
确认开始签发？ (y/N): y
```

如果你机器上 80 端口**已有 Nginx/Apache 在监听**，脚本会在环境检查阶段停下来，让你输入站点根目录，之后改用 webroot 验证（不停服务）。

之后脚本自动走完：

```
环境检查 → 安装/复用 acme.sh → 固定 Let's Encrypt CA
  → 签发 → 安装（改名落地） → 校验 → 检查续期任务
```

### 第 3 步：确认结果

```sh
ls -l /etc/V2ray/
# -rw-r--r--  root root  full_chain.pem
# -rw-r-----  root root  private.key

grep -c -- '-----BEGIN CERTIFICATE-----' /etc/V2ray/full_chain.pem   # 2
openssl x509 -in /etc/V2ray/full_chain.pem -noout -subject -dates -issuer
openssl rsa -in /etc/V2ray/private.key -noout -modulus | sha256sum \
  && openssl x509 -in /etc/V2ray/full_chain.pem -noout -modulus | sha256sum   # 两行一致
crontab -l | grep acme.sh        # 续期任务
```

脚本结尾也会自动打印这些校验项（链段数、签发者、SAN 是否覆盖域名、证书与私钥是否匹配、到期时间、权限、续期任务）。

### 第 4 步：之后什么都不用做

- 续期由 acme.sh 的 crontab 每天/每 6 小时检查，临期自动续期；
- 续期后会**自动重新写** `/etc/V2ray/full_chain.pem` 和 `private.key`，并重新 chmod，路径和文件名不变；
- 同一台机器再跑一次脚本是幂等的：已有有效证书会跳过签发，只重新安装一次文件。

要改目录/文件名/重启服务，重跑一次并带上参数即可（会覆盖 acme.sh 里保存的安装路径，之后续期按新路径走）：

```sh
sudo sh ~/le-oneclick.sh -d node1.example.com -e admin@example.com --service 你的服务名 -y
```

### 非交互用法（批量/自动化）

```sh
# 80 端口空闲的纯代理节点（standalone）
sudo sh le-oneclick.sh -d example.com -e admin@example.com -y

# 已有 Nginx 占用 80：走 webroot（先把 examples/nginx-acme-location.conf 放进站点配置）
sudo sh le-oneclick.sh -d example.com -e admin@example.com \
  --webroot /var/www/letsencrypt -y

# 自定义文件名与目录
sudo sh le-oneclick.sh -d "example.com www.example.com" -e admin@example.com \
  --dir /etc/ssl/example.com --crt-name fullchain.pem --key-name privkey.pem \
  --service nginx -y

# 演练：只检查并打印命令，不产生变更（-y 用于非交互环境）
sudo sh le-oneclick.sh -d example.com -e admin@example.com --dry-run -y

# 首次上线的稳妥做法：测试环境演练（自动隔离到 /root/le-oneclick-staging）
sudo sh le-oneclick.sh -d example.com -e admin@example.com --staging -y
```

多台机器批量执行时，可以这样一台台跑：

```sh
for h in 10.0.0.11 10.0.0.12 10.0.0.13; do
  scp le-oneclick.sh root@$h:/root/
  ssh root@$h "sh /root/le-oneclick.sh -d node-$h.example.com -e admin@example.com -y"
done
```

---

## 参数

| 参数 | 说明 | 默认 |
|---|---|---|
| `-d, --domain <域名>` | 要签发的域名，多个用逗号或空格分隔 | 交互输入 |
| `-e, --email <邮箱>` | ACME 账户邮箱（也可用环境变量 `ACME_EMAIL`） | 交互输入 |
| `--dir <目录>` | 证书落地目录，必须是绝对路径，不能含 `..` / 单引号 / 换行 | `/etc/V2ray` |
| `--crt-name <文件名>` | 证书文件名（完整链），仅允许字母数字与 `. _ -` | `full_chain.pem` |
| `--key-name <文件名>` | 私钥文件名，规则同上 | `private.key` |
| `--service <服务名>` | 续期后重启的 **systemd** 服务，如 `nginx`、`xray`；留空则只重写文件 | 空 |
| `--webroot <目录>` | HTTP-01 webroot 模式（已有 Web 服务占用 80 时使用） | 空（走 standalone） |
| `--keylength <长度>` | `2048` / `3072` / `4096` / `ec-256` / `ec-384` | `2048` |
| `--staging` | 使用 Let's Encrypt 测试环境（证书不被浏览器信任）；未显式指定 `--dir` 时会自动落到 `/root/le-oneclick-staging`，并忽略 `--service` | 关闭 |
| `--no-install` | 禁止联网安装 acme.sh，未找到就直接报错 | 关闭 |
| `--acme-path <路径>` | 指定已安装的 acme.sh，跳过安装 | 空 |
| `-y, --yes` | 不逐项确认（需配合 `-d` 与 `-e`，或设置 `ACME_EMAIL`） | 关闭 |
| `--dry-run` | 只检查与打印，不产生变更（非交互环境仍需 `-y` 才不会被确认步骤拦下） | 关闭 |
| `-h, --help` | 显示帮助 | — |
| `-V, --version` | 显示版本 | — |

### 环境变量

| 变量 | 说明 | 默认 |
|---|---|---|
| `ACME_EMAIL` | 同 `-e` | 空 |
| `ACME_HOME` | acme.sh 安装目录 | `/root/.acme.sh` |
| `ACME_VERSION` | 钉定上游版本 tag（如 `3.1.4`）；留空使用 `master` | 空 |
| `ACME_SHA256` | 下载文件的期望 SHA256；留空跳过完整性校验 | 空 |
| `ACME_ALLOW_OLD` | 设为 `1` 才允许继续使用 < 3.0.6 的 acme.sh（已知 CVE-2023-38198） | `0` |

### 退出码

| 退出码 | 含义 |
|---|---|
| `0` | 成功；也包括“已有有效证书，跳过签发”（acme.sh 返回 2） |
| `1` | 失败或被取消 |

---

## 落地文件

```
/etc/V2ray/full_chain.pem   证书完整链：叶子证书 + 中间证书（通常 2 段 PEM）
/etc/V2ray/private.key      私钥（PEM 文本）
```

- `full_chain.pem` 由 `acme.sh --install-cert --fullchain-file` 直接写出，**本身就是拼接好的完整链**，不需要再 `cat` 合并。
- 第一段是叶子证书（`openssl x509 -in full_chain.pem` 默认读第一段），第二段是中间证书。
- 根证书不会出现在文件里，这是正确做法：根证书由操作系统或客户端信任库提供。
- 权限：证书 `644`、私钥 `640`（属主 root）。安装完成后脚本会**显式再 chmod 一次**，不依赖续期钩子的副作用。
  如果使用方不是 root，请把私钥改成 `root:<组名>` 并保持组可读，同时把 `--reloadcmd` 里的 chmod 一并调整。
- 文件名可自定义；业界常写作 `fullchain.pem` / `privkey.pem`，与默认值语义相同。

典型使用方（以 Xray 为例）：

```json
"certificates": [{
  "certificateFile": "/etc/V2ray/full_chain.pem",
  "keyFile": "/etc/V2ray/private.key"
}]
```

---

## 验证方式

| 场景 | 方式 | 说明 |
|---|---|---|
| 80 端口空闲（纯代理节点常见） | `standalone`（默认） | acme.sh 临时监听 80 端口，数秒完成验证，签完即释放 |
| 已有 Nginx/Apache 占用 80 | `--webroot <站点目录>` | 不停服务；需在 80 端口的 server 块里放行挑战路径 |

Nginx 放行挑战路径（完整示例见 [examples/nginx-acme-location.conf](examples/nginx-acme-location.conf)）：

```nginx
# 必须放在监听 80 的 server 块内
location ^~ /.well-known/acme-challenge/ {
    root /var/www/letsencrypt;
    default_type text/plain;
    try_files $uri =404;
}
```

注意：`^~` 只能压过正则 location；若该 server 块里有**无条件**的 `return 301 https://...`，
挑战路径仍然会被跳转。这种情况需要给 `/.well-known/` 加例外，或改用 DNS-01。

---

## 自动续期

- acme.sh 安装时会写入 `crontab`。**3.1.4 及以上**默认约每 6 小时检查一次，并按 ARI（ACME Renewal Info）建议的窗口续期；旧版本是每天一次。
- 续期成功后，acme.sh 会**自动重写** `--dir` 下的同样两个文件，并执行安装时登记的 `--reloadcmd`（chmod；若指定了 `--service` 则重启服务）。
- **首次安装时也会立即执行一次 `--reloadcmd`**，所以 `--service` 指定的服务会被重启一次。
- 手动触发一次续期（EC 证书必须加 `--ecc`）：

  ```sh
  # RSA（默认）
  /root/.acme.sh/acme.sh --renew -d example.com --force
  # EC（--keylength ec-256 / ec-384 签的）
  /root/.acme.sh/acme.sh --renew -d example.com --force --ecc
  ```

- 建议额外加一条到期告警：

  ```sh
  openssl x509 -in /etc/V2ray/full_chain.pem -noout -checkend 1296000 \
    || echo "证书将在 15 天内过期"
  ```

> standalone 模式在每次续期时都会临时占用 80 端口，请保持该端口长期公网可达；若将来有服务要常驻监听 80，请改用 `--webroot`。
>
> 关于更短的有效期：Let's Encrypt 计划自 2027-02-10 起把默认证书缩短到 64 天、后续到 45 天。
> acme.sh ≥ 3.1.4 默认按 ARI 续期，无需手动调阈值；只有在旧版或禁用 ARI 时，才需要在 acme.sh 侧显式设置 `--days`。

---

## 常见问题

**1. 80 端口不通 / 验证超时**
安全组、云防火墙、本机 `firewalld`/`ufw` 都要放行 80；NAT 环境要做端口映射。只开 443 无法完成 HTTP-01。

**2. 域名托管在 Cloudflare**
必须把记录改为「仅 DNS」（灰云）。代理模式（橙云）下验证请求会打到 Cloudflare 边缘而非你的机器。

**3. 有 AAAA 记录但 IPv6 不通**
Let's Encrypt 会优先尝试 IPv6，导致验证失败。不打算支持 IPv6 就不要发布 AAAA。

**4. 反复失败被限流**
授权失败限制为「每个账号、每个域名、每小时 5 次」。调试请用 `--staging`：脚本在未显式指定 `--dir` 时会自动把测试证书隔离到 `/root/le-oneclick-staging`，不会覆盖生产证书。

**5. 不要删除 `/root/.acme.sh/<域名>/`**
删掉相当于重新签发，连续重签会撞上「同一组域名每 7 天 5 张」的上限，恢复速度约每 34 小时一张。EC 证书目录是 `<域名>_ecc/`。

**6. 证书更新了但服务没生效**
如果使用方不重新读取证书文件，需要重启该进程。用 `--service` 指定 systemd 服务名即可自动重启；未指定时脚本只重写文件。

**7. 在容器 / 精简系统里没有 `ss`**
脚本会提示“无法检测 80 端口占用”，按空闲处理。此时请自行确认 80 未被占用。

**8. 想复现已安装的 acme.sh，不联网**
用 `--acme-path /usr/local/bin/acme.sh`，或 `--no-install` 让它直接报错并提示手动安装方法。

**9. 输入时按删除键出现 `^H`，删不掉**
这是终端的删除键（`^H`/`^?`）与内核 `erase` 设置不匹配造成的显示问题，常见于云控制台网页终端和部分 SSH 客户端。
脚本会按字符模拟退格把输入修好，并把终端删除键临时改成 `^H`（退出脚本时恢复原设置）：
看到 `^H` 不用管，正常继续输入并回车，最终拿到的值是正确的。
如果还想让显示也正常，可以先手动执行 `stty erase ^H` 再运行脚本。

---

## 安全说明

- 脚本以 root 运行：签发需要写 `/root/.acme.sh`、写证书目录，并临时监听 80 端口（低端口需要特权）。
- **自动提权前会校验脚本自身**：必须是当前用户所有，且所在路径不可被他人改写（拒绝 `/tmp` 这类目录），否则要求你直接以 root 运行。
- **获取 acme.sh 的供应链**：优先复用系统里已安装的 acme.sh；只有在找不到时才联网安装。
  安装时从 GitHub 下载 acme.sh 本体到临时文件，可用 `ACME_SHA256` 校验、`ACME_VERSION` 钉定版本；
  复用的 acme.sh 低于 3.0.6 时默认拒绝执行（可用 `ACME_ALLOW_OLD=1` 显式承担风险）。
  高安全环境建议手动安装后用 `--acme-path` 指定。
- 不存储任何 DNS API 凭据，也不接触域名注册商账号；私钥只落在本机。
- `--dry-run` 可以在不产生任何变更的前提下检查环境与命令。

发现安全问题请见 [SECURITY.md](SECURITY.md)（请使用 GitHub 私密漏洞报告，不要公开提 Issue）。

---

## 卸载

```sh
# 1) 删除本域名的续期配置（EC 证书加 --ecc）
/root/.acme.sh/acme.sh --remove -d example.com

# 2) 如需彻底移除 acme.sh（含 cron 任务）
/root/.acme.sh/acme.sh --uninstall

# 3) 删除证书文件（按你实际使用的 --dir）
rm -f /etc/V2ray/full_chain.pem /etc/V2ray/private.key
```

是否同时向 CA 吊销证书：`/root/.acme.sh/acme.sh --revoke -d example.com`（EC 证书加 `--ecc`）。
若设置过 `ACME_HOME`，上面的路径要相应替换。

---

## 开发

- 主脚本：`le-oneclick.sh`（POSIX sh，单文件；运行依赖系统 `curl` / `openssl` / `socat` / `crontab` 与上游 acme.sh）
- 测试：`sh tests/run.sh`（不需要 root，不联网，不会改动系统）
- 代码风格：`.editorconfig`；提交前建议 `shellcheck -S warning -x le-oneclick.sh`
- 贡献指南：[CONTRIBUTING.md](CONTRIBUTING.md)　变更日志：[CHANGELOG.md](CHANGELOG.md)

---

## 发布到 GitHub 前的检查

1. 替换占位符：README 中的 `<owner>/<repo>`、SECURITY.md 中的 GitHub 仓库地址。
2. 仓库 Settings → Security → 开启 **Private vulnerability reporting**（私密漏洞报告）。
3. 可选：把 LICENSE 的版权主体改成你自己或组织名。
4. `git init` 只在**本项目目录**内进行；不要把工作区里其他含真实域名/证书/私钥的文件一起提交
   （`.gitignore` 已忽略 `*.pem` / `*.key` 等常见后缀，但仍建议 `git status` 自查一遍）。
5. 打 tag（如 `v1.1.0`），在 Release 中附上 `le-oneclick-1.1.0.tar.gz` 与对应的 `.sha256`。

---

## 许可证

[MIT](LICENSE)
