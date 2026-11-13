#!/usr/bin/env bash
# ============================================================
#  mtg (MTProto Proxy) 一键部署脚本
#  支持: Debian/Ubuntu (systemd) 与 Alpine (OpenRC)
#  功能: 交互式配置 -> 部署 -> 开机自启 -> 保活 -> 输出链接
#        并安装管理面板命令 `tg`
#
#  用法:
#    bash deploy-mtg.sh                     # 交互式
#    bash deploy-mtg.sh -y -p 443 -d www.bing.com
#    bash deploy-mtg.sh --dry-run -y        # 只生成配置不装服务
# ============================================================
set -euo pipefail

# ---------- 常量 ----------
INSTALL_DIR="${MTG_HOME:-/opt/mtg}"
CONF="${MTG_CONF:-/etc/mtg.toml}"
STATE="${MTG_STATE:-$INSTALL_DIR/state.env}"
BIN="${MTG_BIN:-$INSTALL_DIR/mtg}"
TG_CLI="${MTG_TG:-/usr/local/bin/tg}"
SERVICE=mtg
DEFAULT_VERSION="2.3.0"

# ---------- 颜色 ----------
if [ -t 1 ]; then
  R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[0;33m'; B=$'\033[0;36m'; D=$'\033[2m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; D=""; N=""
fi

log()  { printf '%s[*]%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[!]%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s[✗]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# ---------- 参数 ----------
PORT=""; DOMAIN=""; CONC=""; BLOCK=""; DOPPEL=""; PUBLIC_IP=""
YES=0; DRY=0

usage() {
cat <<'EOF'
用法: bash deploy-mtg.sh [选项]

  -p, --port N          监听端口（默认 443）
  -d, --domain HOST     FakeTLS 伪装域名（默认 www.bing.com）
  -c, --concurrency N   最大并发连接（默认 2048）
      --ip ADDR         指定公网 IP（默认自动探测）
      --no-blocklist    不启用 IP 黑名单
      --no-doppelganger 不启用流量模仿
  -y, --yes             全部使用默认值，不交互
      --dry-run         只生成配置和链接，不安装服务
  -h, --help            显示帮助

部署完成后输入 `tg` 打开管理面板。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--port) PORT="${2:-}"; shift 2 ;;
    -d|--domain) DOMAIN="${2:-}"; shift 2 ;;
    -c|--concurrency) CONC="${2:-}"; shift 2 ;;
    --ip) PUBLIC_IP="${2:-}"; shift 2 ;;
    --no-blocklist) BLOCK="n"; shift ;;
    --no-doppelganger) DOPPEL="n"; shift ;;
    -y|--yes) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1（--help 查看用法）" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo -i 或 sudo bash $0）"

# ---------- 环境检测 ----------
detect_init() {
  if [ -f /etc/alpine-release ]; then echo openrc
  elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then echo systemd
  else echo none; fi
}
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l) echo armv7 ;;
    armv6l) echo armv6 ;;
    i386|i686) echo 386 ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}
INIT="${MTG_INIT:-$(detect_init)}"
ARCH="$(detect_arch)"
[ "$INIT" = none ] && warn "未检测到 systemd/OpenRC，服务将不会开机自启（可用 --dry-run 仅生成配置）"

# ---------- 交互 ----------
ask() { # ask 变量名 提示 默认值
  local __var="$1" __prompt="$2" __default="$3" __in=""
  if [ "$YES" = 1 ]; then printf -v "$__var" '%s' "$__default"; return; fi
  printf '  %s %s%s%s [%s]: ' "$__prompt" "$D" "" "$N" "$__default"
  if [ -r /dev/tty ]; then read -r __in < /dev/tty || true; else read -r __in || true; fi
  [ -z "$__in" ] && __in="$__default"
  printf -v "$__var" '%s' "$__in"
}

port_busy() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
  elif command -v netstat >/dev/null 2>&1; then netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
  else return 1; fi
}

echo
echo "=============================================================="
printf '  %smtg 一键部署%s  (%s / %s)\n' "$B" "$N" "$INIT" "$ARCH"
echo "=============================================================="
echo

[ -z "$PORT" ]   && ask PORT   "监听端口" "443"
[ -z "$DOMAIN" ] && ask DOMAIN "FakeTLS 伪装域名" "www.bing.com"
[ -z "$CONC" ]   && ask CONC   "最大并发连接" "2048"
[ -z "$BLOCK" ]  && ask BLOCK  "启用 IP 黑名单(拦截扫描器) y/n" "y"
[ -z "$DOPPEL" ] && ask DOPPEL "启用流量模仿(doppelganger) y/n" "y"

# 端口校验
case "$PORT" in ''|*[!0-9]*) die "端口必须是数字: $PORT" ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "端口范围 1-65535"
while port_busy "$PORT"; do
  warn "端口 $PORT 已被占用"
  [ "$YES" = 1 ] && die "请用 -p 指定其它端口"
  ask PORT "换一个端口" "$((PORT+1))"
done

# 域名校验（简单形式）
case "$DOMAIN" in
  *[!a-zA-Z0-9.-]*|'') die "域名格式不正确: $DOMAIN" ;;
esac

echo
log "开始部署：端口=$PORT 域名=$DOMAIN 并发=$CONC 黑名单=$BLOCK 模仿=$DOPPEL"

# ---------- 公网 IP ----------
if [ -z "$PUBLIC_IP" ]; then
  log "探测公网 IP..."
  PUBLIC_IP="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null \
            || curl -4 -fsS --max-time 6 https://ip.sb 2>/dev/null \
            || curl -4 -fsS --max-time 6 https://ifconfig.me 2>/dev/null || true)"
  [ -z "$PUBLIC_IP" ] && warn "公网 IP 探测失败，链接中的服务器地址可能为空（可用 --ip 指定）"
fi
[ -n "$PUBLIC_IP" ] && ok "公网 IP: $PUBLIC_IP"

# ---------- 依赖 ----------
for c in curl tar; do command -v "$c" >/dev/null 2>&1 || die "缺少依赖: $c"; done

# ---------- 版本 & 下载 ----------
VER="$DEFAULT_VERSION"
log "查询最新版本..."
_latest="$(curl -fsSL --max-time 10 https://api.github.com/repos/9seconds/mtg/releases/latest 2>/dev/null \
          | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"v\?//; s/"$//' || true)"
[ -n "${_latest:-}" ] && VER="$_latest"
ok "mtg 版本: $VER"

mkdir -p "$INSTALL_DIR"

if [ -x "$INSTALL_DIR/mtg-$VER-linux-$ARCH/mtg" ]; then
  ok "本地已存在 $VER，跳过下载"
else
  URL="https://github.com/9seconds/mtg/releases/download/v${VER}/mtg-${VER}-linux-${ARCH}.tar.gz"
  log "下载 $URL"
  TMP="$(mktemp -d)"
  if ! curl -fsSL --max-time 300 -o "$TMP/mtg.tar.gz" "$URL"; then
    rm -rf "$TMP"; die "下载失败，请检查网络或代理"
  fi
  tar -xzf "$TMP/mtg.tar.gz" -C "$INSTALL_DIR"
  rm -rf "$TMP"
fi

MG_BIN="$INSTALL_DIR/mtg-$VER-linux-$ARCH/mtg"
[ -x "$MG_BIN" ] || die "二进制不存在: $MG_BIN"
ln -sf "$MG_BIN" "$BIN"
ok "二进制: $BIN -> $MG_BIN"

# ---------- 用户 ----------
if ! id mtg >/dev/null 2>&1; then
  if command -v adduser >/dev/null 2>&1 && [ "$INIT" = openrc ]; then
    addgroup -S mtg 2>/dev/null || true
    adduser -S -D -H -s /sbin/nologin -G mtg mtg 2>/dev/null || true
  else
    useradd -r -s /usr/sbin/nologin -M mtg 2>/dev/null || true
  fi
fi
id mtg >/dev/null 2>&1 && ok "运行用户: mtg" || warn "无法创建 mtg 用户，将以 root 运行"

# ---------- 生成 secret ----------
SECRET="$("$MG_BIN" generate-secret --hex "$DOMAIN")"
[ -n "$SECRET" ] || die "生成 secret 失败"
ok "FakeTLS 伪装域名: $DOMAIN"

# ---------- 写入配置 ----------
gen_config() {
  local port="$1" domain="$2" conc="$3" block="$4" dopp="$5" ip="$6" secret="$7"
  {
    echo "# mtg v2 configuration (generated by deploy-mtg.sh)"
    echo "secret = \"$secret\""
    echo "bind-to = \"[::]:$port\""
    echo "concurrency = $conc"
    echo "prefer-ip = \"prefer-ipv4\""
    [ -n "$ip" ] && echo "public-ipv4 = \"$ip\""
    echo "auto-update = false"
    echo "tolerate-time-skewness = \"5s\""
    echo
    echo "[domain-fronting]"
    echo "port = 443"
    echo
    echo "[network]"
    echo "dns = \"https://1.1.1.1\""
    echo
    echo "[network.timeout]"
    echo "tcp = \"5s\""
    echo "http = \"10s\""
    echo "idle = \"5m\""
    echo "handshake = \"10s\""
    if [ "$dopp" = "y" ]; then
      echo
      echo "[defense.doppelganger]"
      echo "urls = ["
      echo "    \"https://$domain/\","
      echo "]"
      echo "repeats-per-raid = 10"
      echo "raid-each = \"6h\""
    fi
    echo
    echo "[defense.anti-replay]"
    echo "enabled = true"
    echo "max-size = \"1mib\""
    echo "error-rate = 0.001"
    if [ "$block" = "y" ]; then
      echo
      echo "[defense.blocklist]"
      echo "enabled = true"
      echo "download-concurrency = 2"
      echo "urls = ["
      echo "    \"https://iplists.firehol.org/files/firehol_level1.netset\","
      echo "]"
      echo "update-each = \"24h\""
    fi
  } > "$CONF"
  chmod 640 "$CONF" 2>/dev/null || true
  chown root:mtg "$CONF" 2>/dev/null || chown root:root "$CONF" 2>/dev/null || true
}

mkdir -p "$INSTALL_DIR"
gen_config "$PORT" "$DOMAIN" "$CONC" "$BLOCK" "$DOPPEL" "$PUBLIC_IP" "$SECRET"
ok "配置: $CONF"

# ---------- 状态文件（供 tg 面板使用） ----------
cat > "$STATE" <<EOF
PORT=$PORT
DOMAIN=$DOMAIN
CONCURRENCY=$CONC
BLOCKLIST=$BLOCK
DOPPELGANGER=$DOPPEL
PUBLIC_IP=$PUBLIC_IP
VERSION=$VER
SECRET=$SECRET
INIT=$INIT
CONF=$CONF
BIN=$BIN
MG_BIN=$MG_BIN
EOF
chmod 600 "$STATE"
ok "状态文件: $STATE"

# ---------- 服务安装 ----------
install_systemd() {
  if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    warn "当前环境没有可用的 systemd（容器/非 PID1），跳过服务安装"
    return 0
  fi
  local user_line="User=mtg
Group=mtg"
  local cap_line="AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
  if ! id mtg >/dev/null 2>&1 || [ "$PORT" -lt 1024 ] && ! command -v setcap >/dev/null 2>&1; then :; fi

  # 低端口且无 setcap：systemd 用 AmbientCapabilities 即可（非 root 绑定 443）
  cat > /etc/systemd/system/${SERVICE}.service <<EOF
[Unit]
Description=MTProto Proxy (mtg)
Documentation=https://github.com/9seconds/mtg
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
${user_line}
ExecStart=${BIN} run ${CONF}
Restart=always
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=${CONF}
${cap_line}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || { warn "systemctl daemon-reload 失败"; return 1; }
  systemctl enable ${SERVICE} >/dev/null 2>&1 || true
  systemctl restart ${SERVICE} || { warn "启动失败，请查看: journalctl -u ${SERVICE} -n 50"; return 1; }
  return 0
}

install_openrc() {
  if ! command -v rc-service >/dev/null 2>&1; then
    warn "未找到 rc-service，跳过服务安装"
    return 0
  fi
  local user="mtg:mtg"
  # 低端口 + 无法 setcap 时退回 root
  if [ "$PORT" -lt 1024 ]; then
    if command -v setcap >/dev/null 2>&1; then
      setcap cap_net_bind_service=+ep "$MG_BIN" 2>/dev/null || user="root:root"
    else
      user="root:root"
      warn "系统缺少 setcap，低端口 $PORT 将以 root 运行（建议改用 >=1024 的端口）"
    fi
  fi

  cat > /etc/init.d/${SERVICE} <<EOF
#!/sbin/openrc-run
name="mtg"
description="MTProto proxy service"
command="${BIN}"
command_args="run ${CONF}"
command_user="${user}"
command_background="yes"
pidfile="/run/${SERVICE}.pid"
output_log="/var/log/${SERVICE}.log"
error_log="/var/log/${SERVICE}.log"

depend() {
    need net
    after firewall
}
EOF
  chmod +x /etc/init.d/${SERVICE}
  touch /var/log/${SERVICE}.log
  chown "${user%%:*}" /var/log/${SERVICE}.log 2>/dev/null || true
  rc-update add ${SERVICE} default >/dev/null 2>&1 || true
  rc-service ${SERVICE} restart >/dev/null 2>&1 || rc-service ${SERVICE} start
}

install_watchdog() {
  command -v rc-service >/dev/null 2>&1 || return 0
  # systemd 已带 Restart=always，无需看护
  [ "$INIT" = systemd ] && return 0
  mkdir -p /etc/periodic/5min
  cat > /etc/periodic/5min/mtg-watchdog <<'EOS'
#!/bin/sh
pgrep -f "/opt/mtg/mtg run" >/dev/null 2>&1 || rc-service mtg start >/dev/null 2>&1
EOS
  chmod +x /etc/periodic/5min/mtg-watchdog
  # 确保 crontab 有 5min 项
  if [ -f /etc/crontabs/root ]; then
    grep -q "run-parts /etc/periodic/5min" /etc/crontabs/root || \
      echo "*/5	*	*	*	*	run-parts /etc/periodic/5min" >> /etc/crontabs/root
  else
    mkdir -p /etc/crontabs
    echo "*/5	*	*	*	*	run-parts /etc/periodic/5min" > /etc/crontabs/root
  fi
  rc-service crond start >/dev/null 2>&1 || true
  rc-update add crond default >/dev/null 2>&1 || true
  ok "保活: 每 5 分钟检查一次，异常自动拉起"
}

# ---------- 防火墙 ----------
open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$PORT"/tcp >/dev/null 2>&1 && ok "ufw 已放行 $PORT/tcp"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 && ok "firewalld 已放行 $PORT/tcp"
  else
    printf '  %s提示: 若外部连不上，请确认云厂商安全组已放行 TCP %s%s\n' "$D" "$PORT" "$N"
  fi
}

# ---------- 管理面板 tg ----------
install_tg_cli() {
  cat > "$1" <<'EOS'
#!/usr/bin/env bash
# tg - mtg 管理面板
set -uo pipefail
STATE="${MTG_STATE:-/opt/mtg/state.env}"
[ -f "$STATE" ] || { echo "未找到状态文件 $STATE，请先运行部署脚本"; exit 1; }
# shellcheck disable=SC1090
. "$STATE"
BIN="${BIN:-/opt/mtg/mtg}"
CONF="${CONF:-/etc/mtg.toml}"
INIT="${INIT:-systemd}"

C_B=$'\033[0;36m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_R=$'\033[0;31m'; C_D=$'\033[2m'; C_N=$'\033[0m'

save_state() {
  cat > "$STATE" <<EOF
PORT=$PORT
DOMAIN=$DOMAIN
CONCURRENCY=$CONCURRENCY
BLOCKLIST=$BLOCKLIST
DOPPELGANGER=$DOPPELGANGER
PUBLIC_IP=$PUBLIC_IP
VERSION=$VERSION
SECRET=$SECRET
INIT=$INIT
CONF=$CONF
BIN=$BIN
MG_BIN=$MG_BIN
EOF
  chmod 600 "$STATE"
}

gen_config() {
  {
    echo "# mtg v2 configuration (generated by deploy-mtg.sh)"
    echo "secret = \"$SECRET\""
    echo "bind-to = \"[::]:$PORT\""
    echo "concurrency = $CONCURRENCY"
    echo "prefer-ip = \"prefer-ipv4\""
    [ -n "$PUBLIC_IP" ] && echo "public-ipv4 = \"$PUBLIC_IP\""
    echo "auto-update = false"
    echo "tolerate-time-skewness = \"5s\""
    echo
    echo "[domain-fronting]"
    echo "port = 443"
    echo
    echo "[network]"
    echo "dns = \"https://1.1.1.1\""
    echo
    echo "[network.timeout]"
    echo "tcp = \"5s\""
    echo "http = \"10s\""
    echo "idle = \"5m\""
    echo "handshake = \"10s\""
    if [ "$DOPPELGANGER" = "y" ]; then
      echo
      echo "[defense.doppelganger]"
      echo "urls = ["
      echo "    \"https://$DOMAIN/\","
      echo "]"
      echo "repeats-per-raid = 10"
      echo "raid-each = \"6h\""
    fi
    echo
    echo "[defense.anti-replay]"
    echo "enabled = true"
    echo "max-size = \"1mib\""
    echo "error-rate = 0.001"
    if [ "$BLOCKLIST" = "y" ]; then
      echo
      echo "[defense.blocklist]"
      echo "enabled = true"
      echo "download-concurrency = 2"
      echo "urls = ["
      echo "    \"https://iplists.firehol.org/files/firehol_level1.netset\","
      echo "]"
      echo "update-each = \"24h\""
    fi
  } > "$CONF"
  chmod 640 "$CONF" 2>/dev/null || true
  chown root:mtg "$CONF" 2>/dev/null || true
}

svc() {
  case "$INIT" in
    systemd) systemctl "$@" mtg ;;
    openrc)  case "$1" in
               restart|start|stop|status) rc-service mtg "$1" ;;
               *) systemctl "$@" mtg 2>/dev/null ;;
             esac ;;
    *) return 1 ;;
  esac
}

status_line() {
  local st
  st=$(svc is-active 2>/dev/null || true)
  case "$INIT" in
    systemd) st=$(systemctl is-active mtg 2>/dev/null || true);;
    openrc)  st=$(rc-service mtg status 2>/dev/null | grep -o 'started\|stopped\|crashed' | head -1);;
  esac
  if pgrep -f "$BIN run" >/dev/null 2>&1; then
    printf '  %s运行中%s  (端口 %s, 域名 %s)\n' "$C_G" "$C_N" "$PORT" "$DOMAIN"
  else
    printf '  %s未运行%s  (状态: %s)\n' "$C_R" "$C_N" "${st:-unknown}"
  fi
}

show_link() {
  local out tg tme
  out=$("$BIN" access "$CONF" -i "$PUBLIC_IP" -p "$PORT" 2>/dev/null) || { echo "读取配置失败"; return 1; }
  tg=$(printf '%s' "$out" | grep -o '"tg_url": "[^"]*"' | head -1 | sed 's/.*: "//; s/"$//')
  tme=$(printf '%s' "$out" | grep -o '"tme_url": "[^"]*"' | head -1 | sed 's/.*: "//; s/"$//')
  echo
  echo "  代理链接:"
  echo "    $tg"
  echo "  网页链接:"
  echo "    $tme"
  if command -v qrencode >/dev/null 2>&1; then
    echo
    qrencode -t ANSIUTF8 "$tg" 2>/dev/null | sed 's/^/    /'
  else
    echo
    echo "  ${C_D}二维码(在线生成): https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=$(printf '%s' "$tg" | sed 's/:/%3A/g; s/\//%2F/g; s/?/%3F/g; s/&/%26/g; s/=/%3D/g')${C_N}"
  fi
}

restart_service() {
  if svc restart >/dev/null 2>&1; then
    sleep 2
    printf '  %s已重启%s\n' "$C_G" "$C_N"
  else
    printf '  %s重启失败，请检查日志%s\n' "$C_R" "$C_N"
  fi
}

menu() {
  while true; do
    clear 2>/dev/null || true
    echo "=============================================================="
    echo "                 mtg 管理面板  (输入数字选择)"
    echo "=============================================================="
    status_line
    echo "--------------------------------------------------------------"
    echo "  1) 查看代理链接 / 二维码"
    echo "  2) 修改监听端口"
    echo "  3) 修改伪装域名 (自动重新生成 secret)"
    echo "  4) 修改并发数"
    echo "  5) 重启服务"
    echo "  6) 启动 / 停止"
    echo "  7) 查看日志"
    echo "  8) 升级 mtg 版本"
    echo "  9) 卸载"
    echo "  0) 退出"
    echo "--------------------------------------------------------------"
    printf "  请选择: "
    local c=""
    read -r c < /dev/tty 2>/dev/null || read -r c || true
    case "$c" in
      1) show_link; printf "\n  按回车继续..."; read -r _ < /dev/tty 2>/dev/null || true ;;
      2) printf "  新端口 [%s]: " "$PORT"; read -r np < /dev/tty 2>/dev/null || read -r np || true
         if [ -n "${np:-}" ] && [ "$np" != "$PORT" ]; then
           PORT="$np"; gen_config; save_state; restart_service; show_link
         fi
         printf "\n  按回车继续..."; read -r _ < /dev/tty 2>/dev/null || true ;;
      3) printf "  新伪装域名 [%s]: " "$DOMAIN"; read -r nd < /dev/tty 2>/dev/null || read -r nd || true
         if [ -n "${nd:-}" ] && [ "$nd" != "$DOMAIN" ]; then
           DOMAIN="$nd"
           SECRET=$("$BIN" generate-secret --hex "$DOMAIN")
           gen_config; save_state; restart_service
           echo "  新 secret 已生成（旧链接失效，请重新分享）"; show_link
         fi
         printf "\n  按回车继续..."; read -r _ < /dev/tty 2>/dev/null || true ;;
      4) printf "  新并发数 [%s]: " "$CONCURRENCY"; read -r nc < /dev/tty 2>/dev/null || read -r nc || true
         if [ -n "${nc:-}" ]; then CONCURRENCY="$nc"; gen_config; save_state; restart_service; fi
         printf "\n  按回车继续..."; read -r _ < /dev/tty 2>/dev/null || true ;;
      5) restart_service; printf "\n  按回车继续..."; read -r _ < /dev/tty 2>/dev/null || true ;;
      6) printf "  1) 启动  2) 停止 : "; read -r op < /dev/tty 2>/dev/null || read -r op || true
         case "$op" in
           1) svc start >/dev/null 2>&1 && echo "  已启动" ;;
           2) svc stop >/dev/null 2>&1 && echo "  已停止" ;;
         esac
         printf "\n  按回车继续..."; read -r _ < /dev/tty 2>/dev/null || true ;;
      7) echo "  (Ctrl+C 退出日志)"; tail -f /var/log/mtg.log 2>/dev/null || journalctl -u mtg -f --no-pager ;;
      8) echo "  请重新运行部署脚本并指定新版本，或执行:"
         echo "    curl -fsSL https://raw.githubusercontent.com/9seconds/mtg/master/README.md >/dev/null"
         printf "\n  按回车继续..."; read -r _ < /dev/tty 2>/dev/null || true ;;
      9) printf "  确认卸载? (yes/no): "; read -r yn < /dev/tty 2>/dev/null || read -r yn || true
         [ "$yn" = "yes" ] || continue
         case "$INIT" in
           systemd) systemctl disable --now mtg >/dev/null 2>&1; rm -f /etc/systemd/system/mtg.service; systemctl daemon-reload ;;
           openrc)  rc-service mtg stop >/dev/null 2>&1; rc-update del mtg default >/dev/null 2>&1; rm -f /etc/init.d/mtg /etc/periodic/5min/mtg-watchdog ;;
         esac
         rm -rf /opt/mtg /etc/mtg.toml "$0"
         echo "  已卸载"; exit 0 ;;
      0|"") exit 0 ;;
    esac
  done
}

case "${1:-}" in
  status)  status_line ;;
  link)    show_link ;;
  restart) restart_service ;;
  port)    [ -n "${2:-}" ] || { echo "用法: tg port 443"; exit 1; }
           case "$2" in ''|*[!0-9]*) echo "端口必须为数字"; exit 1;; esac
           PORT="$2"; gen_config; save_state; restart_service; show_link ;;
  domain)  [ -n "${2:-}" ] || { echo "用法: tg domain www.bing.com"; exit 1; }
           DOMAIN="$2"; SECRET=$("$BIN" generate-secret --hex "$DOMAIN")
           gen_config; save_state; restart_service
           echo "已更换伪装域名，secret 已重新生成（旧链接失效）"; show_link ;;
  concurrency) [ -n "${2:-}" ] || { echo "用法: tg concurrency 4096"; exit 1; }
           CONCURRENCY="$2"; gen_config; save_state; restart_service ;;
  log)     tail -n 100 /var/log/mtg.log 2>/dev/null || journalctl -u mtg -n 100 --no-pager ;;
  "")      menu ;;
  *)       echo "用法: tg [status|link|port N|domain HOST|concurrency N|restart|log]" ;;
esac
EOS
  chmod +x "$1"
}

# ---------- 执行 ----------
if [ "$DRY" = 1 ]; then
  warn "dry-run 模式：跳过服务安装与启动"
  install_tg_cli "$INSTALL_DIR/tg.dryrun"
  ok "面板脚本(测试用): $INSTALL_DIR/tg.dryrun"
else
  case "$INIT" in
    systemd) install_systemd && ok "systemd 服务已安装并开机自启: mtg" || warn "服务未安装（配置已生成，可手动运行）" ;;
    openrc)  install_openrc;  ok "OpenRC 服务已安装并开机自启: mtg" ;;
    none)    warn "无可用 init 系统，未安装服务（可手动运行: $BIN run $CONF）" ;;
  esac
  install_watchdog
  open_firewall
  install_tg_cli "$TG_CLI"
  ok "管理面板已安装: 输入 tg 打开"
fi

# ---------- 输出链接 ----------
echo
echo "=============================================================="
if [ -x "$BIN" ] && [ -f "$CONF" ]; then
  OUT="$("$BIN" access "$CONF" -i "$PUBLIC_IP" -p "$PORT" 2>/dev/null || true)"
  TG_URL="$(printf '%s' "$OUT" | grep -o '"tg_url": "[^"]*"' | head -1 | sed 's/.*: "//; s/"$//')"
  TME_URL="$(printf '%s' "$OUT" | grep -o '"tme_url": "[^"]*"' | head -1 | sed 's/.*: "//; s/"$//')"
  echo "  部署完成"
  echo "--------------------------------------------------------------"
  echo "  服务器   : $PUBLIC_IP"
  echo "  端口     : $PORT"
  echo "  伪装域名 : $DOMAIN"
  echo "  配置文件 : $CONF"
  echo "  状态文件 : $STATE"
  echo "--------------------------------------------------------------"
  [ -n "${TG_URL:-}" ] && echo "  代理链接 : $TG_URL"
  [ -n "${TME_URL:-}" ] && echo "  网页链接 : $TME_URL"
  echo "--------------------------------------------------------------"
  echo "  管理面板 : tg        (状态/改端口/改域名/看链接/日志/卸载)"
  echo "=============================================================="
  if [ -z "${TG_URL:-}" ]; then
    warn "链接生成失败，请手动执行: $BIN access $CONF -i $PUBLIC_IP -p $PORT"
  fi
else
  warn "配置或二进制缺失，部署未完成"
fi

if command -v qrencode >/dev/null 2>&1 && [ -n "${TG_URL:-}" ]; then
  echo
  qrencode -t ANSIUTF8 "$TG_URL" || true
fi
