#!/bin/sh
# =============================================================================
# le-oneclick — Let's Encrypt 证书一键签发 / 安装 / 自动续期
#
# 一条命令完成：环境自检与依赖安装 → 交互式输入域名 → 签发 → 落地成
#               指定文件名 → 配置自动续期 → 校验并给出监控建议
#
# 用法：  sudo sh le-oneclick.sh
#         sudo sh le-oneclick.sh -d example.com -e you@example.com -y
#
# 许可证：MIT
# =============================================================================
set -eu

# 固定 PATH 与 umask：避免调用者环境里的可写目录劫持 root 阶段的外部命令，
# 并让新建文件默认不带 group/other 权限（证书随后显式 chmod）。
# 测试可用 LE_ONECLICK_PATH 覆盖（仅影响非提权场景）。
if [ -n "${LE_ONECLICK_PATH:-}" ]; then
  PATH="$LE_ONECLICK_PATH"
else
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
fi
export PATH
umask 077

APP="le-oneclick"
VERSION="1.1.0"

# ----------------------------- 默认值 -----------------------------------------
DOMAINS=""                      # 空格分隔，可多个
EMAIL="${ACME_EMAIL:-}"
INSTALL_DIR="/etc/V2ray"        # 证书落地目录
CRT_NAME="full_chain.pem"       # 证书文件名（完整链）
KEY_NAME="private.key"          # 私钥文件名
SERVICE=""                      # 续期后需要重启的服务名，留空则只重写文件
WEBROOT=""                      # 非空则用 webroot 验证，否则 standalone
KEYLEN="2048"                   # 2048 / 3072 / 4096 / ec-256 / ec-384
STAGING=0
ASSUME_YES=0
DRY_RUN=0
NO_INSTALL=0
ACME_PATH_IN=""                 # --acme-path：指定已安装的 acme.sh
ACME_HOME="${ACME_HOME:-/root/.acme.sh}"
ACME_VERSION="${ACME_VERSION:-}"   # 钉定上游 tag，如 3.1.4；留空用官方安装器
ACME_SHA256="${ACME_SHA256:-}"     # 下载内容的期望 SHA256；留空跳过校验
ACME_ALLOW_OLD="${ACME_ALLOW_OLD:-0}"  # 1 = 允许继续使用 <3.0.6 的 acme.sh
DIR_SET=0                       # --dir 是否由用户显式指定

TMPFILE=""

# ----------------------------- 输出辅助 ---------------------------------------
say()  { printf '%s\n' "$*"; }
info() { printf '[..] %s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[!!] %s\n' "$*" >&2; }
die()  { printf '[xx] %s\n' "$*" >&2; exit 1; }
hr()   { printf '%s\n' '------------------------------------------------------------'; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry] %s\n' "$*"
    return 0
  fi
  "$@"
}

cleanup() {
  restore_stty
  if [ -n "$TMPFILE" ] && [ -f "$TMPFILE" ]; then
    rm -f "$TMPFILE" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' HUP INT TERM

usage() {
  cat <<'EOF'
le-oneclick —— Let's Encrypt 证书一键签发 / 安装 / 自动续期

用法:
  sh le-oneclick.sh [选项]

选项:
  -d, --domain <域名>       要签发的域名，多个用逗号或空格分隔；交互模式下会提示输入
  -e, --email <邮箱>        ACME 账户邮箱（也可用环境变量 ACME_EMAIL）
      --dir <目录>          证书落地目录（绝对路径）  默认 /etc/V2ray
      --crt-name <文件名>   证书文件名（完整链）      默认 full_chain.pem
      --key-name <文件名>   私钥文件名                默认 private.key
      --service <服务名>    续期后重启的 systemd 服务，如 nginx / xray；留空只重写文件
      --webroot <目录>      HTTP-01 webroot 模式（已有 Web 服务占用 80 时使用）
      --keylength <长度>    2048（默认）/ 3072 / 4096 / ec-256 / ec-384
      --staging             使用 Let's Encrypt 测试环境（证书不被浏览器信任，慎用）
      --no-install          禁止联网安装 acme.sh（未找到就直接报错）
      --acme-path <路径>    指定已安装的 acme.sh，跳过安装
  -y, --yes                 全部使用默认值，不逐项确认（需配合 -d/-e）
      --dry-run             只做环境检查并打印将要执行的命令，不产生任何变更
  -h, --help                显示本帮助
  -V, --version             显示版本

环境变量:
  ACME_EMAIL                同 -e
  ACME_HOME                  acme.sh 安装目录        默认 /root/.acme.sh
  ACME_VERSION               钉定上游版本 tag（如 3.1.4），留空用官方安装器
  ACME_SHA256                下载文件的期望 SHA256，留空跳过校验

示例:
  sudo sh le-oneclick.sh
  sudo sh le-oneclick.sh -d example.com -e admin@example.com -y
  sudo sh le-oneclick.sh -d "example.com www.example.com" -e admin@example.com \
       --dir /etc/ssl/example.com --crt-name fullchain.pem --key-name privkey.pem \
       --service nginx -y
  sudo sh le-oneclick.sh -d example.com -e admin@example.com --dry-run -y

退出码:
  0  成功（含“已有有效证书、跳过签发”）
  1  失败或被取消

说明:
  * 通配符证书（*.example.com）需要 DNS-01 验证，本脚本不处理；
  * standalone 模式需要 80 端口空闲且公网可达；webroot 模式需要已有 Web 服务；
  * 域名若走 CDN 代理（如 Cloudflare 橙云），HTTP-01 验证会失败，需改为“仅 DNS”；
  * --service 依赖 systemd（使用 systemctl restart），非 systemd 系统请留空。
EOF
}

# ----------------------------- 参数解析 ---------------------------------------
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -d|--domain)
        [ "$#" -ge 2 ] || die "$1 需要参数"
        DOMAINS="${DOMAINS} $(printf '%s' "$2" | tr ',' ' ')"; shift 2 ;;
      --domain=*) DOMAINS="${DOMAINS} $(printf '%s' "${1#*=}" | tr ',' ' ')"; shift ;;
      -e|--email)
        [ "$#" -ge 2 ] || die "$1 需要参数"
        EMAIL="$2"; shift 2 ;;
      --email=*) EMAIL="${1#*=}"; shift ;;
      --dir)
        [ "$#" -ge 2 ] || die "$1 需要参数"
        INSTALL_DIR="$2"; DIR_SET=1; shift 2 ;;
      --dir=*) INSTALL_DIR="${1#*=}"; DIR_SET=1; shift ;;
      --crt-name)
        [ "$#" -ge 2 ] || die "$1 需要参数"
        CRT_NAME="$2"; shift 2 ;;
      --crt-name=*) CRT_NAME="${1#*=}"; shift ;;
      --key-name)
        [ "$#" -ge 2 ] || die "$1 需要参数"
        KEY_NAME="$2"; shift 2 ;;
      --key-name=*) KEY_NAME="${1#*=}"; shift ;;
      --service)
        [ "$#" -ge 2 ] || die "$1 需要参数"
        SERVICE="$2"; shift 2 ;;
      --service=*) SERVICE="${1#*=}"; shift ;;
      --webroot)
        [ "$#" -ge 2 ] || die "$1 需要参数"
        WEBROOT="$2"; shift 2 ;;
      --webroot=*) WEBROOT="${1#*=}"; shift ;;
      --keylength)
        [ "$#" -ge 2 ] || die "$1 需要参数"
        KEYLEN="$2"; shift 2 ;;
      --keylength=*) KEYLEN="${1#*=}"; shift ;;
      --acme-path)
        [ "$#" -ge 2 ] || die "$1 需要参数"
        ACME_PATH_IN="$2"; shift 2 ;;
      --acme-path=*) ACME_PATH_IN="${1#*=}"; shift ;;
      --staging) STAGING=1; shift ;;
      --no-install) NO_INSTALL=1; shift ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -V|--version) printf '%s %s\n' "$APP" "$VERSION"; exit 0 ;;
      *) die "未知参数: $1（用 --help 查看用法）" ;;
    esac
  done
}

# ----------------------------- 校验函数 ---------------------------------------
valid_domain() {
  case "$1" in
    *"*"*) return 1 ;;
    *" "*) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
}

valid_email() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
}

# 目录：必须是绝对路径；不能含单引号/换行（会进入 --reloadcmd 的 shell 字符串）；
# 不能含 .. 或 . 路径段。
valid_dir() {
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *\'*) return 1 ;;
  esac
  case "/$1/" in
    */../*|*/./*) return 1 ;;
  esac
  if [ "$(printf '%s' "$1" | tr -d '\n')" != "$1" ]; then
    return 1
  fi
  return 0
}

# 文件名：不允许空、. 、.. 、前导 - 、路径分隔符
valid_name() {
  case "$1" in
    ''|.|..|-*) return 1 ;;
    */*) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
}

valid_service() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9@._-]+$'
}

valid_keylen() {
  case "$1" in
    2048|3072|4096|ec-256|ec-384) return 0 ;;
    *) return 1 ;;
  esac
}

trailing_content() {
  # 去掉首尾空白（只处理空格）
  printf '%s' "$1" | tr ' ' '\n' | sed '/^$/d' | tr '\n' ' ' | sed 's/ *$//'
}

mask_email() {
  _u=$(printf '%s' "$1" | cut -d@ -f1)
  _d=$(printf '%s' "$1" | cut -d@ -f2)
  if [ "${#_u}" -le 2 ]; then
    printf '***@%s' "$_d"
  else
    printf '%s***@%s' "$(printf '%s' "$_u" | cut -c1)" "$_d"
  fi
}

# ----------------------------- 交互辅助 ---------------------------------------
ANS=""
BS_CHAR=$(printf '\010')   # 退格（Ctrl-H）
DEL_CHAR=$(printf '\177')  # 退格（DEL / 0x7f）
STTY_SAVED=""

# 有些终端（云控制台、部分 SSH 客户端）把退格发成 ^H，而内核的 erase 是 ^?，
# 于是删除键不生效、输入里留下 ^H。这里按字符模拟一次退格，兜底把输入修好。
normalize_input() {
  printf '%s\n' "$1" | awk -v bs="$BS_CHAR" -v del="$DEL_CHAR" '
    { out = ""; n = 0
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == bs || c == del) {
          if (n > 0) { out = substr(out, 1, n - 1); n-- }
          continue
        }
        out = out c; n++
      }
      print out; exit
    }' | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

save_stty() {
  if [ -z "$STTY_SAVED" ] && [ -t 0 ] && command -v stty >/dev/null 2>&1; then
    STTY_SAVED=$(stty -g 2>/dev/null || true)
  fi
}

restore_stty() {
  if [ -n "$STTY_SAVED" ]; then
    stty "$STTY_SAVED" 2>/dev/null || true
    STTY_SAVED=""
  fi
}

# 把 erase 改成 ^H，让之后的提示可以正常退格（退出时恢复原设置）
repair_erase_key() {
  if [ ! -t 0 ]; then return 0; fi
  command -v stty >/dev/null 2>&1 || return 0
  save_stty
  stty erase '^H' 2>/dev/null || true
}

ask() {
  _text="$1"
  _def="${2:-}"
  if [ ! -t 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
    die "当前不是交互终端，请用 -d/--domain、-e/--email 等参数指定；或用 -y 配合参数"
  fi
  printf '%s' "$_text"
  if [ -n "$_def" ]; then
    printf ' [%s]' "$_def"
  fi
  printf ': '
  IFS= read -r _line || return 1

  case "$_line" in
    *"$BS_CHAR"*|*"$DEL_CHAR"*)
      _fixed=$(normalize_input "$_line")
      repair_erase_key
      _line="$_fixed"
      if [ -t 1 ]; then
        printf '\n'
        warn "检测到删除键未生效（输入中出现 ^H/^?）：已按退格重新处理 → ${_line:-（空）}"
        warn "终端删除键已临时设为 ^H，后续输入可直接退格（脚本退出时恢复原设置）"
        printf '%s%s\n' "$_text" "$_line"
      fi
      ;;
    *)
      _line=$(printf '%s' "$_line" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      ;;
  esac

  if [ -z "$_line" ]; then
    _line="$_def"
  fi
  ANS="$_line"
}

confirm() {
  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi
  ask "$1 (y/N)" "n" || return 1
  case "$ANS" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# ----------------------------- 环境检查 ---------------------------------------
need_root() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    warn "当前用户不是 root；--dry-run 只打印，不会真正写入"
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || die "请以 root 运行：sudo sh $0"
  command -v stat >/dev/null 2>&1 || die "缺少 stat，无法校验脚本权限；请直接以 root 运行"
  SELF_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd) || die "无法定位脚本目录"
  SELF="$SELF_DIR/$(basename "$0")"
  [ -f "$SELF" ] || die "无法定位脚本自身: $SELF"

  check_safe_file() {
    _p="$1"; _what="$2"
    _m=$(stat -c '%a' "$_p" 2>/dev/null) || die "无法读取权限: $_p"
    _o=$(stat -c '%u' "$_p" 2>/dev/null) || die "无法读取属主: $_p"
    [ "$_o" = "$(id -u)" ] || die "$_what 属主异常（$_p），拒绝自动提权"
    if [ $(( 0$_m & 0022 )) -ne 0 ]; then
      die "$_what 可被他人写入（mode $_m: $_p），拒绝自动提权；请重新下载或 chmod 644"
    fi
  }
  check_safe_dir() {
    _p="$1"
    _m=$(stat -c '%a' "$_p" 2>/dev/null) || die "无法读取目录权限: $_p"
    _o=$(stat -c '%u' "$_p" 2>/dev/null) || die "无法读取目录属主: $_p"
    if [ $(( 0$_m & 0020 )) -ne 0 ]; then
      die "脚本所在目录可被同组写入（mode $_m: $_p），拒绝自动提权；请移到自己的 home 或 /root 下"
    fi
    if [ $(( 0$_m & 0002 )) -ne 0 ]; then
      if [ $(( 0$_m & 1000 )) -eq 0 ]; then
        die "脚本所在目录可被他人写入且无 sticky 位（mode $_m: $_p），拒绝自动提权"
      fi
      # 带 sticky 的公共目录（如 /tmp 的 1777）可接受：他人无法替换属于你的文件
      return 0
    fi
    if [ "$_o" != "0" ] && [ "$_o" != "$(id -u)" ]; then
      die "脚本所在目录属主异常（$_p），拒绝自动提权"
    fi
  }
  check_safe_file "$SELF" "脚本文件"
  check_safe_dir "$SELF_DIR"

  info "需要 root 权限，使用 sudo 重新执行"
  if [ -n "$EMAIL" ]; then
    exec sudo env ACME_HOME="$ACME_HOME" ACME_VERSION="$ACME_VERSION" ACME_SHA256="$ACME_SHA256" \
      sh "$SELF" "$@" -e "$EMAIL"
  fi
  exec sudo env ACME_HOME="$ACME_HOME" ACME_VERSION="$ACME_VERSION" ACME_SHA256="$ACME_SHA256" \
    sh "$SELF" "$@"
}

detect_os() {
  OS_NAME="unknown"
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null || true
    OS_NAME="${PRETTY_NAME:-${NAME:-unknown}}"
  elif [ "$(uname -s 2>/dev/null || echo unknown)" = "Darwin" ]; then
    OS_NAME="macOS"
  fi
  ok "操作系统: $OS_NAME"
}

detect_pm() {
  PM=""
  for c in apt-get dnf yum microdnf apk pacman zypper; do
    if command -v "$c" >/dev/null 2>&1; then
      PM="$c"
      return 0
    fi
  done
}

# 把“需要的命令”映射成当前发行版的包名
map_pkg() {
  case "$1" in
    curl) echo "curl" ;;
    openssl) echo "openssl" ;;
    socat) echo "socat" ;;
    crontab)
      case "$PM" in
        apt-get) echo "cron" ;;
        apk) echo "" ;;
        pacman) echo "cronie" ;;
        *) echo "cronie" ;;
      esac ;;
    *) echo "$1" ;;
  esac
}

install_pkgs() {
  if [ "$#" -eq 0 ]; then
    return 0
  fi
  case "$PM" in
    apt-get)
      run apt-get update -qq || warn "apt-get update 失败，继续尝试安装"
      run apt-get install -y -qq "$@" || die "安装失败: apt-get install -y $*" ;;
    dnf|yum|microdnf)
      run "$PM" install -y "$@" || die "安装失败: $PM install -y $*" ;;
    apk)
      run apk add --no-cache "$@" || die "安装失败: apk add --no-cache $*" ;;
    pacman)
      run pacman -Sy --noconfirm "$@" || die "安装失败: pacman -Sy --noconfirm $*" ;;
    zypper)
      run zypper --non-interactive install "$@" || die "安装失败: zypper install $*" ;;
    *)
      die "未识别的包管理器，请手动安装: $*" ;;
  esac
}

check_deps() {
  MISSING=""
  for c in curl openssl crontab; do
    command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"
  done
  if [ -z "$WEBROOT" ]; then
    command -v socat >/dev/null 2>&1 || MISSING="$MISSING socat"
  fi
  MISSING=$(trailing_content "$MISSING")

  if [ -z "$MISSING" ]; then
    ok "依赖检查通过（curl / openssl / crontab${WEBROOT:+，webroot 模式跳过 socat}）"
    return 0
  fi

  warn "缺少依赖: $MISSING"
  if [ -z "$PM" ]; then
    die "未识别包管理器，请手动安装后重试: $MISSING"
  fi

  PKGS=""
  for c in $MISSING; do
    p=$(map_pkg "$c")
    if [ -n "$p" ]; then
      PKGS="$PKGS $p"
    fi
  done
  PKGS=$(trailing_content "$PKGS")

  if [ -n "$PKGS" ]; then
    if [ "$ASSUME_YES" -eq 1 ] || confirm "使用 $PM 安装依赖: $PKGS ?"; then
      info "安装: $PKGS"
      install_pkgs $PKGS
    else
      die "缺少必要依赖，已退出"
    fi
  fi

  for c in curl openssl crontab; do
    command -v "$c" >/dev/null 2>&1 || die "$c 仍未就绪"
  done
  if [ -z "$WEBROOT" ]; then
    command -v socat >/dev/null 2>&1 || die "socat 仍未就绪（standalone 模式必需）"
  fi
  ok "依赖检查完成"
}

check_network() {
  if [ "$STAGING" -eq 1 ]; then
    URL="https://acme-staging-v02.api.letsencrypt.org/directory"
  else
    URL="https://acme-v02.api.letsencrypt.org/directory"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry] 跳过联网检查: $URL"
    return 0
  fi
  if curl -fsS -o /dev/null -m 20 "$URL" 2>/dev/null; then
    ok "ACME 接口可达"
  else
    warn "无法访问 $URL（检查 DNS / 代理 / 防火墙）"
    if ! confirm "仍然继续？"; then
      die "已退出"
    fi
  fi
}

resolve_host() {
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$1" 2>/dev/null | awk 'NR==1{print $1; exit}'
  elif command -v dig >/dev/null 2>&1; then
    dig +short A "$1" 2>/dev/null | awk 'NR==1{print; exit}'
  elif command -v nslookup >/dev/null 2>&1; then
    nslookup "$1" 2>/dev/null | awk '/^Address: /{print $2; exit}'
  fi
}

port80_busy() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -Eq '(^|:)80$'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)80$'
  else
    return 2
  fi
}

check_port80() {
  if [ -n "$WEBROOT" ]; then
    ok "验证方式: webroot（$WEBROOT）"
    return 0
  fi
  BUSY=0
  port80_busy || BUSY=$?
  if [ "$BUSY" -eq 2 ]; then
    warn "系统缺少 ss/netstat，无法检测 80 端口占用；按“空闲”继续（standalone 模式）"
    return 0
  fi
  if [ "$BUSY" -eq 0 ]; then
    warn "80 端口已被占用，standalone 模式无法使用"
    if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
      die "请用 --webroot <网站目录> 指定已有 Web 服务的站点根目录"
    fi
    ask "请输入现有 Web 服务的站点根目录（留空退出）" "" || die "输入已结束"
    if [ -z "$ANS" ]; then
      die "已退出"
    fi
    WEBROOT="$ANS"
    valid_dir "$WEBROOT" || die "--webroot 必须是绝对路径且不含 .. / 单引号: $WEBROOT"
    ok "验证方式: webroot（$WEBROOT）"
  else
    ok "验证方式: standalone（80 端口空闲，签发时临时占用数秒）"
  fi
}

# ----------------------------- 交互采集 ---------------------------------------
collect_input() {
  hr
  say "请填写签发信息（直接回车使用默认值）"

  if [ -z "$DOMAINS" ] && [ "$ASSUME_YES" -eq 1 ]; then
    die "-y/--yes 模式必须用 -d/--domain 指定域名"
  fi
  if [ -z "$EMAIL" ] && [ "$ASSUME_YES" -eq 1 ]; then
    die "-y/--yes 模式必须用 -e/--email（或 ACME_EMAIL）指定邮箱"
  fi

  if [ -z "$DOMAINS" ]; then
    while :; do
      ask "要签发证书的域名（多个用空格或逗号分隔）" "" || die "输入已结束"
      DOMAINS=$(trailing_content "$(printf '%s' "$ANS" | tr ',' ' ')")
      if [ -z "$DOMAINS" ]; then
        warn "域名不能为空"
        continue
      fi
      BAD=""
      set -f
      for d in $DOMAINS; do
        valid_domain "$d" || BAD="$BAD $d"
      done
      set +f
      if [ -z "$BAD" ]; then
        break
      fi
      warn "域名格式不合法:$BAD（暂不支持通配符 *.example.com）"
    done
  fi

  set -f
  for d in $DOMAINS; do
    valid_domain "$d" || die "域名格式不合法: $d（暂不支持通配符）"
  done
  set +f

  if [ -z "$EMAIL" ]; then
    while :; do
      ask "ACME 账户邮箱（用于到期提醒）" "" || die "输入已结束"
      if valid_email "$ANS"; then
        EMAIL="$ANS"
        break
      fi
      warn "邮箱格式不合法"
    done
  fi
  valid_email "$EMAIL" || die "邮箱格式不合法: $EMAIL"

  valid_dir "$INSTALL_DIR" || die "--dir 必须是绝对路径，且不能含 .. / 单引号 / 换行: $INSTALL_DIR"
  valid_name "$CRT_NAME" || die "证书文件名不合法（仅允许字母、数字、. _ -）: $CRT_NAME"
  valid_name "$KEY_NAME" || die "私钥文件名不合法（仅允许字母、数字、. _ -）: $KEY_NAME"
  if [ -n "$SERVICE" ]; then
    valid_service "$SERVICE" || die "服务名不合法（仅允许字母、数字、@ . _ -）: $SERVICE"
    command -v systemctl >/dev/null 2>&1 || die "--service 依赖 systemd（未找到 systemctl）；非 systemd 系统请留空此参数"
  fi
  valid_keylen "$KEYLEN" || die "不支持的 --keylength: $KEYLEN（可选 2048 / 3072 / 4096 / ec-256 / ec-384）"
  if [ -n "$WEBROOT" ]; then
    valid_dir "$WEBROOT" || die "--webroot 必须是绝对路径，且不能含 .. / 单引号 / 换行: $WEBROOT"
  fi

  case "$INSTALL_DIR" in
    /|/etc|/root|/usr|/bin|/sbin|/lib|/lib64|/boot|/dev|/proc|/sys|/home|/var)
      if ! confirm "警告：--dir 指向系统目录（$INSTALL_DIR），可能覆盖系统文件。继续？"; then
        die "已取消"
      fi ;;
  esac

  if [ "$STAGING" -eq 1 ]; then
    if [ "$DIR_SET" -eq 0 ]; then
      INSTALL_DIR="/root/le-oneclick-staging"
      warn "测试环境：未显式指定 --dir，已自动隔离到 $INSTALL_DIR（不会覆盖生产证书）"
    else
      warn "测试环境：你显式指定了 --dir，测试证书会写入 $INSTALL_DIR（可能覆盖生产证书）"
    fi
    if [ -n "$SERVICE" ]; then
      warn "测试环境：忽略 --service，不会重启任何服务"
      SERVICE=""
    fi
    if [ "$DRY_RUN" -eq 0 ]; then
      warn "测试环境签出的证书不被任何客户端信任，仅用于验证流程"
      if ! confirm "确认继续？"; then
        die "已取消"
      fi
    fi
  fi
}

show_plan() {
  hr
  say "即将执行："
  say "  域名        : $DOMAINS"
  say "  邮箱        : $(mask_email "$EMAIL")"
  say "  验证方式    : $([ -n "$WEBROOT" ] && echo "webroot（$WEBROOT）" || echo "standalone（临时占用 80）")"
  say "  证书        : $INSTALL_DIR/$CRT_NAME"
  say "  私钥        : $INSTALL_DIR/$KEY_NAME"
  say "  续期后动作  : $([ -n "$SERVICE" ] && echo "重启 $SERVICE" || echo "仅重写文件，不重启任何服务")"
  if [ "$STAGING" -eq 1 ]; then
    say "  环境        : Let's Encrypt 测试环境（证书不被浏览器信任）"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  模式        : dry-run（只检查与打印，不产生变更）"
  fi
  hr
}

# ----------------------------- 签发流程 ---------------------------------------
ACME=""
RC=0

first_domain() {
  set -f
  for d in $DOMAINS; do
    printf '%s' "$d"
    break
  done
  set +f
}

check_acme_version() {
  _v=$("$ACME" --version 2>/dev/null | awk '/[0-9]+\.[0-9]+\.[0-9]+/{print $0; exit}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
  [ -n "$_v" ] || return 0
  if awk -v a="$_v" 'BEGIN{split(a,x,"."); if (x[1]<3) exit 1; if (x[1]==3 && x[2]==0 && x[3]<6) exit 1; exit 0}'; then
    return 0
  fi
  if [ "${ACME_ALLOW_OLD:-0}" = "1" ]; then
    warn "acme.sh $_v 低于 3.0.6（CVE-2023-38198），已按 ACME_ALLOW_OLD=1 继续"
    return 0
  fi
  die "acme.sh $_v 低于 3.0.6，存在已知的远程执行问题（CVE-2023-38198）；请先升级，或设置 ACME_ALLOW_OLD=1 显式承担风险"
}

find_acme() {
  if [ -n "$ACME_PATH_IN" ]; then
    [ -x "$ACME_PATH_IN" ] || die "--acme-path 不可执行: $ACME_PATH_IN"
    ACME="$ACME_PATH_IN"
    return 0
  fi
  for p in "$ACME_HOME/acme.sh" /usr/local/bin/acme.sh /usr/bin/acme.sh /usr/local/sbin/acme.sh; do
    if [ -x "$p" ]; then
      ACME="$p"
      return 0
    fi
  done
  p=$(command -v acme.sh 2>/dev/null || true)
  if [ -n "$p" ] && [ -x "$p" ]; then
    ACME="$p"
    return 0
  fi
  return 1
}

download() {
  # $1=url  $2=dest
  curl -fsSL --proto '=https' --retry 3 --connect-timeout 10 -m 180 -o "$2" "$1"
}

install_acme() {
  if find_acme; then
    ok "复用已安装的 acme.sh: $ACME"
    check_acme_version
    return 0
  fi
  if [ "$NO_INSTALL" -eq 1 ]; then
    die "未找到 acme.sh，且指定了 --no-install。请手动安装后重试，或用 --acme-path 指定"
  fi
  ACME="$ACME_HOME/acme.sh"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "[dry] 下载并安装 acme.sh（email=$(mask_email "$EMAIL")，版本=${ACME_VERSION:-master}，home=$ACME_HOME）"
    return 0
  fi

  TMPFILE=$(mktemp "${TMPDIR:-/tmp}/le-oneclick-acme.XXXXXX") || die "创建临时文件失败"
  if [ -n "$ACME_VERSION" ]; then
    _tag="$ACME_VERSION"
  else
    _tag="master"
  fi
  URL="https://raw.githubusercontent.com/acmesh-official/acme.sh/${_tag}/acme.sh"
  info "下载 acme.sh（$_tag）: $URL"
  download "$URL" "$TMPFILE" || die "下载失败: $URL"

  if [ -n "$ACME_SHA256" ]; then
    _got=$(sha256sum "$TMPFILE" 2>/dev/null | awk '{print $1}' || true)
    [ -n "$_got" ] || die "系统缺少 sha256sum，无法校验；请安装 coreutils 或去掉 ACME_SHA256"
    if [ "$_got" != "$ACME_SHA256" ]; then
      die "SHA256 校验失败（期望 $ACME_SHA256，实际 $_got），已中止"
    fi
    ok "SHA256 校验通过"
  else
    warn "未设置 ACME_SHA256，跳过完整性校验；高安全环境请用 ACME_VERSION + ACME_SHA256 钉定"
  fi

  sh "$TMPFILE" --install --home "$ACME_HOME" --accountemail "$EMAIL" || die "acme.sh 安装失败"
  if [ ! -x "$ACME" ]; then
    if [ -x "$HOME/.acme.sh/acme.sh" ]; then
      ACME="$HOME/.acme.sh/acme.sh"
      ACME_HOME="$HOME/.acme.sh"
      warn "安装器未使用 $ACME_HOME，已改用 $ACME"
    else
      die "安装后仍未找到 acme.sh（检查 ACME_HOME，或手动安装后用 --acme-path 指定）"
    fi
  fi
  rm -f "$TMPFILE" 2>/dev/null || true
  TMPFILE=""
  ok "acme.sh 安装完成: $ACME"
}

set_ca() {
  info "固定使用 Let's Encrypt（acme.sh v3 默认 CA 是 ZeroSSL）"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "[dry] $ACME --set-default-ca --server letsencrypt --home $ACME_HOME"
    return 0
  fi
  if ! "$ACME" --set-default-ca --server letsencrypt --home "$ACME_HOME" >/dev/null 2>&1; then
    die "设置默认 CA 失败；为避免用错 CA 签发，请手动执行：$ACME --set-default-ca --server letsencrypt"
  fi
}

is_ec_key() {
  case "$KEYLEN" in
    ec-*) return 0 ;;
    *) return 1 ;;
  esac
}

issue_cert() {
  info "申请证书"
  if [ "$DRY_RUN" -eq 0 ] && [ -n "$WEBROOT" ]; then
    mkdir -p "$WEBROOT/.well-known/acme-challenge" || die "创建 webroot 目录失败: $WEBROOT"
    # 挑战文件必须对 Web 服务可读：显式放开目录可读/可进入（umask 077 会建成 700）
    chmod 755 "$WEBROOT" "$WEBROOT/.well-known" "$WEBROOT/.well-known/acme-challenge" 2>/dev/null || true
  fi
  set -- --issue --keylength "$KEYLEN" --home "$ACME_HOME"
  if [ "$STAGING" -eq 1 ]; then
    set -- "$@" --server letsencrypt_test
  else
    set -- "$@" --server letsencrypt
  fi
  if [ -n "$WEBROOT" ]; then
    set -- "$@" --webroot "$WEBROOT"
  else
    set -- "$@" --standalone
  fi
  set -f
  for d in $DOMAINS; do
    set -- "$@" -d "$d"
  done
  set +f

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry] %s' "$ACME"
    for a in "$@"; do printf ' %s' "$a"; done
    printf '\n'
    return 0
  fi

  set +e
  # 子进程用宽松 umask，保证挑战文件对 Web 服务可读；不影响脚本自身的 077
  ( umask 022; "$ACME" "$@" )
  RC=$?
  set -e
  case "$RC" in
    0) ok "证书申请成功" ;;
    2) ok "已有有效证书，跳过签发（acme.sh 返回 2）" ;;
    *)
      warn "签发失败（返回码 $RC）"
      warn "建议：加 --staging 先演练（会自动隔离到测试目录）；并检查 80 端口是否公网可达"
      die "已退出"
      ;;
  esac
}

prepare_dir() {
  if [ -L "$INSTALL_DIR" ]; then
    die "拒绝符号链接目录: $INSTALL_DIR"
  fi
  if [ -e "$INSTALL_DIR" ]; then
    [ -d "$INSTALL_DIR" ] || die "目标不是目录: $INSTALL_DIR"
    _m=$(stat -c '%a' "$INSTALL_DIR" 2>/dev/null || echo 0)
    _o=$(stat -c '%u' "$INSTALL_DIR" 2>/dev/null || echo -1)
    [ "$_o" = "0" ] || warn "目标目录属主不是 root: $INSTALL_DIR"
    if [ $(( 0$_m & 0022 )) -ne 0 ]; then
      die "目标目录可被他人写入（mode $_m）: $INSTALL_DIR；请换一个目录"
    fi
  else
    mkdir -p "$INSTALL_DIR" || die "创建目录失败: $INSTALL_DIR"
    chmod 755 "$INSTALL_DIR" || die "设置目录权限失败: $INSTALL_DIR"
  fi
}

install_cert() {
  ID=$(first_domain)
  if [ "$DRY_RUN" -eq 0 ]; then
    prepare_dir
    # 写入前先拒绝符号链接目标，避免 root 写穿到任意文件
    for f in "$INSTALL_DIR/$CRT_NAME" "$INSTALL_DIR/$KEY_NAME"; do
      if [ -L "$f" ]; then
        die "拒绝符号链接目标: $f"
      fi
    done
  fi

  RELOAD="chmod 644 '$INSTALL_DIR/$CRT_NAME'; chmod 640 '$INSTALL_DIR/$KEY_NAME'"
  if [ -n "$SERVICE" ]; then
    RELOAD="$RELOAD; systemctl restart '$SERVICE'"
  fi

  info "写出证书与私钥"
  set -- --install-cert -d "$ID" \
    --home "$ACME_HOME" \
    --fullchain-file "$INSTALL_DIR/$CRT_NAME" \
    --key-file "$INSTALL_DIR/$KEY_NAME" \
    --reloadcmd "$RELOAD"
  if is_ec_key; then
    set -- "$@" --ecc
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry] %s' "$ACME"
    for a in "$@"; do printf ' %s' "$a"; done
    printf '\n'
    return 0
  fi

  "$ACME" "$@" || die "acme.sh --install-cert 失败（证书未正确安装）"

  CRT="$INSTALL_DIR/$CRT_NAME"
  KEY="$INSTALL_DIR/$KEY_NAME"
  [ -f "$CRT" ] && [ ! -L "$CRT" ] || die "证书文件异常（不存在或为符号链接）: $CRT"
  [ -f "$KEY" ] && [ ! -L "$KEY" ] || die "私钥文件异常（不存在或为符号链接）: $KEY"
  # 不依赖 reloadcmd 的副作用，立刻收紧权限
  chmod 644 "$CRT" || die "设置证书权限失败: $CRT"
  chmod 640 "$KEY" || die "设置私钥权限失败: $KEY"
  ok "已写入: $CRT 与 $KEY"
}

verify_cert() {
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry] 跳过证书校验"
    return 0
  fi
  CRT="$INSTALL_DIR/$CRT_NAME"
  KEY="$INSTALL_DIR/$KEY_NAME"

  BLOCKS=$(awk '/-----BEGIN CERTIFICATE-----/{n++} END{print n+0}' "$CRT" 2>/dev/null || echo 0)
  END=$(openssl x509 -in "$CRT" -noout -enddate 2>/dev/null | cut -d= -f2 || true)
  [ -n "$END" ] || END="unknown"
  say "  证书文件    : $CRT（$BLOCKS 段 PEM）"
  say "  到期时间    : $END"
  if [ "$BLOCKS" -ge 2 ]; then
    ok "包含中间证书，构成完整链（无需手工合并）"
  else
    warn "证书链只有 $BLOCKS 段，可能缺少中间证书"
  fi

  ISS=$(openssl x509 -in "$CRT" -noout -issuer 2>/dev/null || true)
  case "$ISS" in
    *"(STAGING)"*)
      if [ "$STAGING" -eq 1 ]; then
        warn "签发者: Let's Encrypt 测试环境（(STAGING)，证书不被任何客户端信任）"
      else
        die "检测到测试环境证书，但本次未使用 --staging（疑似误覆盖生产证书）: $ISS"
      fi ;;
    *"Let's Encrypt"*) ok "签发者: Let's Encrypt" ;;
    "") warn "无法读取签发者" ;;
    *) warn "签发者不是 Let's Encrypt: $ISS（可能沿用了 acme.sh 的旧默认 CA）" ;;
  esac

  SAN=$(openssl x509 -in "$CRT" -noout -ext subjectAltName 2>/dev/null \
        | tr ',' '\n' | sed -n 's/.*DNS:\([^ ,]*\).*/\1/p' || true)
  if [ -z "$SAN" ]; then
    # 老版本 OpenSSL 没有 -ext，退化为解析 -text
    SAN=$(openssl x509 -in "$CRT" -noout -text 2>/dev/null \
          | tr ',' '\n' | sed -n 's/.*DNS:\([^ ,]*\).*/\1/p' || true)
  fi
  if [ -n "$SAN" ]; then
    MISS_SAN=""
    set -f
    for d in $DOMAINS; do
      if ! printf '%s\n' "$SAN" | grep -qxF -- "$d"; then
        MISS_SAN="$MISS_SAN $d"
      fi
    done
    set +f
    if [ -z "$MISS_SAN" ]; then
      ok "证书 SAN 覆盖全部域名"
    else
      warn "证书 SAN 中缺少:$MISS_SAN（可能装错了证书）"
    fi
  fi

  CRT_PUB=$(openssl x509 -in "$CRT" -noout -pubkey 2>/dev/null || true)
  KEY_PUB=$(openssl pkey -in "$KEY" -pubout 2>/dev/null \
            || openssl rsa -in "$KEY" -pubout 2>/dev/null \
            || openssl ec -in "$KEY" -pubout 2>/dev/null || true)
  if [ -n "$CRT_PUB" ] && [ "$CRT_PUB" = "$KEY_PUB" ]; then
    ok "证书与私钥匹配"
  else
    warn "证书与私钥不匹配，请检查"
  fi

  if openssl x509 -in "$CRT" -noout -checkend 604800 >/dev/null 2>&1; then
    ok "剩余有效期超过 7 天"
  else
    warn "剩余有效期不足 7 天，请检查续期任务"
  fi

  say "  文件权限    :"
  ls -l "$CRT" "$KEY" 2>/dev/null | sed 's/^/    /' || true
}

check_renewal() {
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  if command -v crontab >/dev/null 2>&1 \
    && crontab -l 2>/dev/null | grep -Ev '^[[:space:]]*#' | grep -q 'acme\.sh.*--cron'; then
    ok "自动续期任务已存在（crontab）"
    say "   acme.sh 3.1.4+ 默认每 6 小时检查一次，并按 ARI 建议窗口续期；旧版本为每天一次"
    check_cron_daemon
  else
    warn "未检测到 acme.sh 的 crontab 任务，请确认 cron 服务已安装并在运行"
    warn "也可手动加入: 0 3 * * * \"$ACME\" --cron --home \"$ACME_HOME\" > /dev/null"
  fi
}

check_cron_daemon() {
  for s in cron crond cronie; do
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$s" 2>/dev/null; then
      ok "cron 服务运行中: $s"
      return 0
    fi
  done
  if command -v pgrep >/dev/null 2>&1; then
    if pgrep -x crond >/dev/null 2>&1 || pgrep -x cron >/dev/null 2>&1; then
      ok "cron 进程运行中"
      return 0
    fi
  fi
  warn "未检测到运行中的 cron 服务：续期任务可能不会执行"
  warn "请执行: systemctl enable --now cron（或 crond / cronie），并确认开机自启"
}

summary() {
  hr
  ID=$(first_domain)
  if [ "$DRY_RUN" -eq 1 ]; then
    say "dry-run 结束：未做任何变更。去掉 --dry-run 即可正式执行。"
    return 0
  fi
  say "完成。"
  say ""
  say "  · 证书文件：$INSTALL_DIR/$CRT_NAME（完整链，叶子 + 中间证书）"
  say "  · 私钥文件：$INSTALL_DIR/$KEY_NAME"
  say "  · 续期方式：acme.sh 定时任务自动检查并续期（新版按 ARI 建议窗口）"
  if [ -n "$SERVICE" ]; then
    say "  · 续期后自动重启：$SERVICE（首次安装时已执行过一次）"
  else
    say "  · 续期后只重写文件，不重启任何服务"
  fi
  say ""
  if is_ec_key; then
    say "  · 手动续期：$ACME --renew -d $ID --force --ecc（EC 证书必须带 --ecc）"
  else
    say "  · 手动续期：$ACME --renew -d $ID --force"
  fi
  say "  · 到期告警：openssl x509 -in $INSTALL_DIR/$CRT_NAME -noout -checkend 1296000 \\"
  say "              || echo '证书将在 15 天内过期'"
  say ""
  say "  注意：standalone 模式在每次续期时会临时占用 80 端口，请保持公网可达。"
  hr
}

# ----------------------------- 主流程 -----------------------------------------
main() {
  parse_args "$@"
  # 归一化域名列表，防止 -d '' / --domain= 只留空白绕过后续校验
  DOMAINS=$(trailing_content "$DOMAINS")

  hr
  say "$APP $VERSION —— Let's Encrypt 证书一键签发"
  hr

  say "第一步：环境检查"
  need_root "$@"
  detect_os
  detect_pm
  if [ -n "$PM" ]; then
    ok "包管理器: $PM"
  else
    warn "未识别包管理器（若依赖齐全可忽略）"
  fi
  check_port80
  check_deps
  check_network
  hr

  collect_input

  set -f
  for d in $DOMAINS; do
    IP=$(resolve_host "$d" || true)
    if [ -n "$IP" ]; then
      say "  解析: $d -> $IP"
    else
      warn "解析: $d 未解析到 IP（Cloudflare 请确认是“仅 DNS”而不是橙云代理）"
    fi
  done
  set +f

  show_plan
  if ! confirm "确认开始签发？"; then
    die "已取消"
  fi

  hr
  say "第二步：准备 ACME 客户端"
  install_acme
  set_ca

  hr
  say "第三步：签发证书"
  issue_cert

  hr
  say "第四步：安装证书"
  install_cert
  verify_cert

  hr
  say "第五步：自动续期"
  check_renewal

  summary
}

# 允许测试脚本 source 本文件以复用函数（不触发主流程）
if [ "${LE_ONECLICK_LIB:-0}" != "1" ]; then
  main "$@"
fi
