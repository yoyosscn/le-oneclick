#!/bin/sh
# 轻量测试：不需要 root、不联网、不会改动系统。
# 用法：  sh tests/run.sh [主脚本路径]
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
SCRIPT="${1:-$ROOT/le-oneclick.sh}"
FAIL=0

if [ ! -f "$SCRIPT" ]; then
  echo "找不到主脚本: $SCRIPT" >&2
  exit 1
fi

hr() { echo '------------------------------------------------------------'; }

hr
echo "1) 语法检查（sh -n）"
if sh -n "$SCRIPT"; then
  echo "   OK"
else
  echo "   FAIL"; FAIL=1
fi

hr
echo "2) 帮助与版本"
if sh "$SCRIPT" --help | grep -q 'le-oneclick'; then
  echo "   OK --help"
else
  echo "   FAIL --help"; FAIL=1
fi
if sh "$SCRIPT" --version | grep -Eq '^le-oneclick [0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "   OK --version"
else
  echo "   FAIL --version"; FAIL=1
fi

hr
echo "3) 单元测试（source 后测试辅助函数）"
LE_ONECLICK_LIB=1
export LE_ONECLICK_LIB
# shellcheck disable=SC1090
. "$SCRIPT"
set +e 2>/dev/null || true
# 关键：不要在后面的子进程里继续带着这个标记，否则脚本会只定义函数、不执行主流程
unset LE_ONECLICK_LIB

rc_of() { # 返回 0/1，不依赖 set -e 行为
  if "$@" >/dev/null 2>&1; then
    echo 0
  else
    echo 1
  fi
}

check() { # 描述 期望 实际
  if [ "$2" = "$3" ]; then
    printf '   OK   %s\n' "$1"
  else
    printf '   FAIL %s（期望 %s，实际 %s）\n' "$1" "$2" "$3"
    FAIL=1
  fi
}

check "合法域名 example.com"        0 "$(rc_of valid_domain example.com)"
check "合法域名 sub.example.com"    0 "$(rc_of valid_domain sub.example.com)"
check "合法域名 a-b.example.com"    0 "$(rc_of valid_domain a-b.example.com)"
check "拒绝空域名"                  1 "$(rc_of valid_domain '')"
check "拒绝通配符"                  1 "$(rc_of valid_domain '*.example.com')"
check "拒绝带空格"                  1 "$(rc_of valid_domain 'a b.example.com')"
check "拒绝无点号"                   1 "$(rc_of valid_domain 'localhost')"

check "合法邮箱"                    0 "$(rc_of valid_email admin@example.com)"
check "拒绝无 @ 邮箱"               1 "$(rc_of valid_email 'admin.example.com')"
check "拒绝通配符文件名"            1 "$(rc_of valid_name '../x.pem')"
check "拒绝 .. 文件名"              1 "$(rc_of valid_name '..')"
check "拒绝 . 文件名"               1 "$(rc_of valid_name '.')"
check "拒绝前导 - 文件名"           1 "$(rc_of valid_name '-x.pem')"
check "接受默认证书名"              0 "$(rc_of valid_name full_chain.pem)"
check "接受默认私钥名"              0 "$(rc_of valid_name private.key)"
check "拒绝相对目录"                1 "$(rc_of valid_dir 'relative/path')"
check "拒绝 .. 目录段"              1 "$(rc_of valid_dir '/etc/../root')"
check "拒绝含单引号目录"            1 "$(rc_of valid_dir "/tmp/a'b")"
check "接受绝对目录"                0 "$(rc_of valid_dir '/etc/V2ray')"
check "拒绝非法 keylength"          1 "$(rc_of valid_keylen '1024')"
check "接受 2048"                   0 "$(rc_of valid_keylen '2048')"
check "接受 ec-256"                 0 "$(rc_of valid_keylen 'ec-256')"

check "trim 多空格"    "a.example.com b.example.com" "$(trailing_content '  a.example.com   b.example.com  ')"

hr
echo "4) dry-run 端到端（mock 掉 id/curl/crontab，不会写入系统）"
MOCK="$HERE/mock/bin"
chmod +x "$MOCK"/* 2>/dev/null || true
WORK=$(mktemp -d 2>/dev/null || echo "/tmp/le-oneclick-test.$$")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

RC=0
OUT=$(LE_ONECLICK_PATH="$MOCK:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  sh "$SCRIPT" \
  -d example.com -e admin@example.com -y --dry-run \
  --webroot "$WORK/webroot" --dir "$WORK/certs" 2>&1) || RC=$?

if [ "$RC" -eq 0 ]; then
  echo "   OK 退出码 0"
else
  echo "   FAIL 退出码 $RC"; echo "$OUT" | sed 's/^/     /'; FAIL=1
fi

for expect in '第一步：环境检查' '--install-cert' 'full_chain.pem' 'private.key' 'dry-run 结束'; do
  if printf '%s' "$OUT" | grep -q -- "$expect"; then
    echo "   OK 输出包含: $expect"
  else
    echo "   FAIL 输出缺少: $expect"; FAIL=1
  fi
done

if [ -e "$WORK/certs" ]; then
  echo "   FAIL dry-run 不应创建目录 $WORK/certs"; FAIL=1
else
  echo "   OK dry-run 未产生任何文件"
fi

hr
if [ "$FAIL" -eq 0 ]; then
  echo "全部通过"
else
  echo "存在失败项"
fi
exit "$FAIL"
