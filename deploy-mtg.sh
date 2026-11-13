#!/usr/bin/env bash
# ==============================================================================
#  MTG 一键部署脚本  ·  MTProto Proxy (FakeTLS + Domain Fronting)
#  ---------------------------------------------------------------
#  · 支持 Debian/Ubuntu (systemd) 与 Alpine (OpenRC)
#  · 交互式配置 / 全自动部署 / 开机自启 / 进程保活
#  · 自动安装管理面板: tg
#
#  用法:
#    bash deploy-mtg.sh                  # 交互安装（已安装则进菜单）
#    bash deploy-mtg.sh -y -p 443 -d www.bing.com
#    bash deploy-mtg.sh --uninstall
# ==============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------- 基础常量
VERSION_FALLBACK="2.3.0"
INSTALL_DIR="${MTG_HOME:-/opt/mtg}"
CONF="${MTG_CONF:-/etc/mtg.toml}"
STATE="${MTG_STATE:-$INSTALL_DIR/state.env}"
BIN="${MTG_BIN:-$INSTALL_DIR/mtg}"
TG_CLI="${MTG_TG:-/usr/local/bin/tg}"
SERVICE="mtg"
LOG_FILE="/var/log/mtg-install.log"

# ---------------------------------------------------------------- 颜色
if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; BL=$'\033[34m'
  M=$'\033[35m'; C=$'\033[36m'; W=$'\033[97m'; DIM=$'\033[2m'; NC=$'\033[0m'
  BOLD=$'\033[1m'
else
  R=""; G=""; Y=""; BL=""; M=""; C=""; W=""; DIM=""; NC=""; BOLD=""
fi

# ---------------------------------------------------------------- 日志
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
: >"$LOG_FILE" 2>/dev/null || true
_log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }
info() { printf '  %s›%s %s\n' "$C" "$NC" "$*"; _log "INFO $*"; }
ok()   { printf '  %s✔%s %s\n' "$G" "$NC" "$*"; _log "OK   $*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$NC" "$*"; _log "WARN $*"; }
err()  { printf '  %s✘%s %s\n' "$R" "$NC" "$*" >&2; _log "ERR  $*"; }
die()  { err "$*"; printf '\n  %s安装中止%s  日志: %s\n\n' "$R" "$NC" "$LOG_FILE"; exit 1; }

trap 'die "脚本在第 ${LINENO} 行出错（命令: ${BASH_COMMAND}）"' ERR

# ---------------------------------------------------------------- 小组件
BANNER='
   ███╗   ███╗████████╗ ██████╗
   ████╗ ████║╚══██╔══╝██╔════╝
   ██╔████╔██║   ██║   ██║  ███╗
   ██║╚██╔╝██║   ██║   ██║   ██║
   ██║ ╚═╝ ██║   ██║   ╚██████╔╝
   ╚═╝     ╚═╝   ╚═╝    ╚═════╝ '

banner() {
  printf '%s%s%s\n' "$M" "$BANNER" "$NC"
  printf '   %sMTProto Proxy · FakeTLS 一键部署%s\n' "$DIM" "$NC"
  printf '   %s%s%s\n\n' "$DIM" "──────────────────────────────────────────────────────────" "$NC"
}

hr() { printf '   %s%s%s\n' "$DIM" "──────────────────────────────────────────────────────────" "$NC"; }

step() { # step 序号 标题
  printf '\n %s[%s]%s %s%s%s\n' "$C" "$1" "$NC" "$BOLD" "$2" "$NC"
}

spin() { # spin PID 文案
  local pid="$1" msg="$2" i=0 f
  while kill -0 "$pid" 2>/dev/null; do
    case $((i % 4)) in 0) f='|';; 1) f='/';; 2) f='-';; 3) f='\';; esac
    printf '\r  %s%s%s %s' "$C" "$f" "$NC" "$msg"
    i=$((i + 1)); sleep 0.12
  done
  printf '\r\033[K'
}

run_bg() { # run_bg "文案" 命令...
  local msg="$1"; shift
  ( "$@" ) >>"$LOG_FILE" 2>&1 &
  local pid=$!
  spin "$pid" "$msg"
  if wait "$pid"; then ok "$msg"; else die "$msg 失败（详见 $LOG_FILE）"; fi
}

kv() { printf '   %s%-12s%s %s\n' "$DIM" "$1" "$NC" "$2"; }

# ---------------------------------------------------------------- 参数
PORT=""; DOMAIN=""; CONC=""; BLOCK=""; DOPPEL=""; PUBLIC_IP=""
YES=0; DRY=0; UNINSTALL=0; BBR=""

usage() {
  cat <<EOF
${BOLD}用法${NC}: bash deploy-mtg.sh [选项]

  -p, --port N          监听端口
  -d, --domain HOST     FakeTLS 伪装域名（默认 www.bing.com）
  -c, --concurrency N   最大并发连接（默认 2048）
      --ip ADDR         指定公网 IP
      --no-blocklist    不启用 IP 黑名单
      --no-doppelganger 不启用流量模仿
      --no-bbr          不启用 BBR
  -y, --yes             全部默认值，非交互
      --dry-run         只生成配置与链接，不装服务
      --uninstall       卸载
  -h, --help            帮助

部署完成后输入 ${BOLD}tg${NC} 打开管理面板。
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
    --no-bbr) BBR="n"; shift ;;
    -y|--yes) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1（--help 查看用法）" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo -i 或 sudo bash $0）"

# ---------------------------------------------------------------- 系统探测
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

sysinfo() {
  local os kern cpu cores mem disk virt
  os="$( (. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}") )"
  kern="$(uname -r)"
  cpu="$(grep -m1 -E 'model name|Processor' /proc/cpuinfo 2>/dev/null | sed 's/.*: //' | cut -c1-40)"
  cores="$(nproc 2>/dev/null || echo '?')"
  mem="$(free -h 2>/dev/null | awk '/^Mem:/{print $3" / "$2}')"
  disk="$(df -h / 2>/dev/null | awk 'NR==2{print $3" / "$2" ("$5")"}')"
  virt="$(systemd-detect-virt 2>/dev/null || echo '-')"
  [ "$virt" = "none" ] && virt="物理机"

  printf '\n'
  printf '   %s系统%s  %-28s %s内核%s  %s\n' "$DIM" "$NC" "$os" "$DIM" "$NC" "$kern"
  printf '   %s架构%s  %-28s %s虚拟%s  %s\n' "$DIM" "$NC" "$(uname -m) / $ARCH" "$DIM" "$NC" "$virt"
  printf '   %sCPU %s  %-28s %s内存%s  %s\n' "$DIM" "$NC" "${cpu:-未知} x${cores}" "$DIM" "$NC" "${mem:-?}"
  printf '   %s磁盘%s  %-28s %s初始化%s %s\n' "$DIM" "$NC" "${disk:-?}" "$DIM" "$NC" "$INIT"
}

# ---------------------------------------------------------------- 卸载
do_uninstall() {
  banner
  step "卸载" "移除 mtg 及其服务"
  printf '   将删除: 服务 / 配置 / 二进制 / 面板命令\n\n'
  printf '   确认卸载? (yes/no): '
  local yn=""; read -r yn < /dev/tty 2>/dev/null || read -r yn || true
  [ "$yn" = "yes" ] || { echo "   已取消"; exit 0; }
  case "$INIT" in
    systemd) systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true; rm -f /etc/systemd/system/${SERVICE}.service; systemctl daemon-reload >/dev/null 2>&1 || true ;;
    openrc)  rc-service "$SERVICE" stop >/dev/null 2>&1 || true; rc-update del "$SERVICE" default >/dev/null 2>&1 || true; rm -f /etc/init.d/$SERVICE ;;
  esac
  rm -f /etc/periodic/5min/mtg-watchdog 2>/dev/null || true
  rm -rf "$INSTALL_DIR" "$CONF" "$TG_CLI"
  ok "卸载完成"
  exit 0
}
[ "$UNINSTALL" = 1 ] && do_uninstall

# ---------------------------------------------------------------- 交互
ask() { # ask 变量 提示 默认
  local __v="$1" __p="$2" __d="$3" __i=""
  if [ "$YES" = 1 ]; then printf -v "$__v" '%s' "$__d"; return; fi
  printf '   %s%s%s [%s%s%s]: ' "$W" "$__p" "$NC" "$G" "$__d" "$NC"
  if [ -r /dev/tty ]; then read -r __i < /dev/tty || true; else read -r __i || true; fi
  [ -z "$__i" ] && __i="$__d"
  printf -v "$__v" '%s' "$__i"
}

port_busy() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]${p}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | awk 'NR>2{print $4}' | grep -qE "[:.]${p}$"
  else
    return 1
  fi
}

valid_port() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# ---------------------------------------------------------------- 主流程
banner
sysinfo

# 已安装 -> 菜单
if [ -x "$TG_CLI" ] && [ -f "$STATE" ] && [ "$DRY" = 0 ] && [ "$YES" = 0 ] && [ -z "$PORT$DOMAIN" ]; then
  hr
  printf '   %s已检测到已安装的 mtg%s\n\n' "$Y" "$NC"
  printf '   1) 打开管理面板 (tg)\n'
  printf '   2) 重新安装 / 覆盖配置\n'
  printf '   3) 查看当前代理链接\n'
  printf '   4) 卸载\n'
  printf '   0) 退出\n\n'
  printf '   请选择 [0]: '
  sel=""; read -r sel < /dev/tty 2>/dev/null || read -r sel || true
  case "${sel:-0}" in
    1) exec "$TG_CLI" ;;
    2) : ;;
    3) exec "$TG_CLI" link ;;
    4) do_uninstall ;;
    *) exit 0 ;;
  esac
fi

# ---- 1. 依赖
step "1/7" "环境与依赖"
if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
  info "安装基础依赖 curl tar ..."
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl tar >/dev/null 2>&1 || die "apk 安装依赖失败"
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl tar ca-certificates >/dev/null 2>&1 || die "apt 安装依赖失败"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q curl tar ca-certificates >/dev/null 2>&1 || die "dnf 安装依赖失败"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl tar ca-certificates >/dev/null 2>&1 || die "yum 安装依赖失败"
  else
    die "无法自动安装依赖，请手动安装 curl tar"
  fi
fi
ok "curl $(curl --version 2>/dev/null | head -1 | awk '{print $2}') / tar 就绪"

if ! command -v qrencode >/dev/null 2>&1; then
  printf '   %s可选依赖 qrencode 未安装，将尝试安装（失败则用在线二维码）...%s\n' "$DIM" "$NC"
  if command -v apk >/dev/null 2>&1; then apk add --no-cache qrencode >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qrencode >/dev/null 2>&1 || true
  fi
fi
command -v qrencode >/dev/null 2>&1 && ok "qrencode 就绪（可生成终端二维码）"

# ---- 2. 参数
step "2/7" "代理配置"
ask PORT   "监听端口" "${PORT:-443}"
while ! valid_port "$PORT"; do
  warn "端口必须是 1-65535 的整数"
  [ "$YES" = 1 ] && die "端口非法: $PORT"
  ask PORT "监听端口" "443"
done
while port_busy "$PORT"; do
  warn "端口 $PORT 已被其它程序占用"
  [ "$YES" = 1 ] && die "端口 $PORT 被占用，请用 -p 换一个"
  ask PORT "监听端口" "$((PORT + 1))"
  valid_port "$PORT" || PORT=443
done
ok "端口 $PORT 可用"

ask DOMAIN "FakeTLS 伪装域名" "${DOMAIN:-www.bing.com}"
case "$DOMAIN" in
  *[!a-zA-Z0-9.-]*|'') die "域名格式不正确: $DOMAIN" ;;
esac

ask CONC "最大并发连接" "${CONC:-2048}"
case "$CONC" in ''|*[!0-9]*) die "并发数必须是正整数" ;; esac
[ "$CONC" -ge 1 ] || die "并发数必须 >= 1"

[ -z "$BLOCK" ]  && ask BLOCK  "启用 IP 黑名单(拦扫描器) y/n" "y"
[ -z "$DOPPEL" ] && ask DOPPEL "启用流量模仿(doppelganger) y/n" "y"
[ -z "$BBR" ]    && ask BBR    "启用 BBR 拥塞控制加速 y/n" "y"

# ---- 3. 预检
step "3/7" "连通性预检"
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null \
            || curl -4 -fsS --max-time 6 https://ip.sb 2>/dev/null \
            || curl -4 -fsS --max-time 6 https://ifconfig.me 2>/dev/null || true)"
fi
[ -n "$PUBLIC_IP" ] && ok "公网 IPv4: $PUBLIC_IP" || warn "公网 IPv4 探测失败（链接中服务器地址可能为空，可用 --ip 指定）"

IPV6="$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
[ -n "$IPV6" ] && info "公网 IPv6: $IPV6" || true

if getent hosts "$DOMAIN" >/dev/null 2>&1 || command -v dig >/dev/null 2>&1; then
  ok "伪装域名解析正常: $DOMAIN"
else
  warn "伪装域名 $DOMAIN 解析失败，客户端可能无法连接"
fi

if curl -sI --max-time 8 "https://$DOMAIN/" >/dev/null 2>&1; then
  ok "伪装域名 HTTPS 可达（TLS 伪装可用）"
else
  warn "伪装域名 HTTPS 探测失败，建议换一个域名（如 www.apple.com）"
fi

# ---- 4. 汇总确认
step "4/7" "确认配置"
printf '\n'
kv "监听端口" "$PORT"
kv "伪装域名" "$DOMAIN"
kv "并发上限" "$CONC"
kv "IP 黑名单" "$BLOCK"
kv "流量模仿" "$DOPPEL"
kv "BBR 加速" "$BBR"
kv "公网 IP" "${PUBLIC_IP:-未探测到}"
printf '\n'
if [ "$YES" = 0 ]; then
  printf '   开始部署? (Y/n): '
  _yn=""; read -r _yn < /dev/tty 2>/dev/null || read -r _yn || true
  case "${_yn:-y}" in y|Y|yes|YES) : ;; *) echo "   已取消"; exit 0 ;; esac
fi

# ---- 5. 安装二进制
step "5/7" "安装 mtg"
mkdir -p "$INSTALL_DIR"

VER="$VERSION_FALLBACK"
_latest="$(curl -fsSL --max-time 10 https://api.github.com/repos/9seconds/mtg/releases/latest 2>/dev/null \
          | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"v\?//; s/"$//' || true)"
[ -n "${_latest:-}" ] && VER="$_latest"

if [ -x "$INSTALL_DIR/mtg-$VER-linux-$ARCH/mtg" ]; then
  ok "已存在 mtg $VER，跳过下载"
else
  URL="https://github.com/9seconds/mtg/releases/download/v${VER}/mtg-${VER}-linux-${ARCH}.tar.gz"
  TMP="$(mktemp -d)"
  if ! curl -fsSL --max-time 300 -o "$TMP/mtg.tar.gz" "$URL" 2>>"$LOG_FILE"; then
    rm -rf "$TMP"; die "下载失败: $URL"
  fi
  tar -xzf "$TMP/mtg.tar.gz" -C "$INSTALL_DIR" || { rm -rf "$TMP"; die "解压失败"; }
  rm -rf "$TMP"
  ok "下载并解压 mtg $VER ($ARCH)"
fi

MG_BIN="$INSTALL_DIR/mtg-$VER-linux-$ARCH/mtg"
[ -x "$MG_BIN" ] || die "二进制缺失: $MG_BIN"
ln -sf "$MG_BIN" "$BIN"
ok "二进制: $BIN"

if ! id mtg >/dev/null 2>&1; then
  if command -v adduser >/dev/null 2>&1 && [ "$INIT" = openrc ]; then
    addgroup -S mtg 2>/dev/null || true
    adduser -S -D -H -s /sbin/nologin -G mtg mtg 2>/dev/null || true
  else
    useradd -r -s /usr/sbin/nologin -M mtg 2>/dev/null || true
  fi
fi
id mtg >/dev/null 2>&1 && ok "运行用户: mtg" || warn "将以内核默认用户运行"

SECRET="$("$MG_BIN" generate-secret --hex "$DOMAIN")"
[ -n "$SECRET" ] || die "生成 FakeTLS secret 失败"
ok "FakeTLS secret 已生成"

# ---- 6. 配置
step "6/7" "写入配置"

gen_config() {
  local port="$1" domain="$2" conc="$3" block="$4" dopp="$5" ip="$6" secret="$7"
  {
    echo "# mtg v2 configuration"
    echo "# generated by deploy-mtg.sh  $(date '+%F %T')"
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

gen_config "$PORT" "$DOMAIN" "$CONC" "$BLOCK" "$DOPPEL" "$PUBLIC_IP" "$SECRET"
ok "配置: $CONF"

cat > "$STATE" <<EOF
PORT=$PORT
DOMAIN=$DOMAIN
CONCURRENCY=$CONC
BLOCKLIST=$BLOCK
DOPPELGANGER=$DOPPEL
PUBLIC_IP=$PUBLIC_IP
IPV6=$IPV6
VERSION=$VER
SECRET=$SECRET
INIT=$INIT
CONF=$CONF
BIN=$BIN
MG_BIN=$MG_BIN
EOF
chmod 600 "$STATE"
ok "状态: $STATE"

# ---- 7. 服务 / 保活 / 面板
step "7/7" "注册服务与面板"

install_systemd() {
  if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    warn "当前环境无 systemd（容器/非 PID1），跳过服务注册"
    return 1
  fi
  cat > /etc/systemd/system/${SERVICE}.service <<EOF
[Unit]
Description=MTProto Proxy (mtg)
Documentation=https://github.com/9seconds/mtg
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mtg
Group=mtg
ExecStart=${BIN} run ${CONF}
Restart=always
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=${CONF}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$SERVICE" >/dev/null 2>&1 || systemctl restart "$SERVICE"
  ok "systemd 服务已启用（开机自启 + 崩溃自动重启）"
}

install_openrc() {
  if ! command -v rc-service >/dev/null 2>&1; then
    warn "未找到 OpenRC，跳过服务注册"
    return 1
  fi
  local user="mtg:mtg"
  if [ "$PORT" -lt 1024 ]; then
    if command -v setcap >/dev/null 2>&1 && setcap cap_net_bind_service=+ep "$MG_BIN" 2>/dev/null; then
      ok "已授予低端口绑定能力 (setcap)"
    else
      user="root:root"
      warn "无法 setcap，低端口 $PORT 将以 root 运行"
    fi
  fi
  cat > /etc/init.d/$SERVICE <<EOF
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
  chmod +x /etc/init.d/$SERVICE
  touch /var/log/${SERVICE}.log
  chown "${user%%:*}" /var/log/${SERVICE}.log 2>/dev/null || true
  rc-update add "$SERVICE" default >/dev/null 2>&1 || true
  rc-service "$SERVICE" restart >/dev/null 2>&1 || rc-service "$SERVICE" start
  ok "OpenRC 服务已启用（开机自启）"
}

install_watchdog() {
  [ "$INIT" = systemd ] && return 0
  command -v rc-service >/dev/null 2>&1 || return 0
  mkdir -p /etc/periodic/5min
  cat > /etc/periodic/5min/mtg-watchdog <<'EOS'
#!/bin/sh
pgrep -f "/opt/mtg/mtg run" >/dev/null 2>&1 || rc-service mtg start >/dev/null 2>&1
EOS
  chmod +x /etc/periodic/5min/mtg-watchdog
  if [ -f /etc/crontabs/root ]; then
    grep -q "run-parts /etc/periodic/5min" /etc/crontabs/root || \
      printf '*/5\t*\t*\t*\t*\trun-parts /etc/periodic/5min\n' >> /etc/crontabs/root
  else
    mkdir -p /etc/crontabs
    printf '*/5\t*\t*\t*\t*\trun-parts /etc/periodic/5min\n' > /etc/crontabs/root
  fi
  rc-service crond start >/dev/null 2>&1 || true
  rc-update add crond default >/dev/null 2>&1 || true
  ok "看护已启用（每 5 分钟自检，异常自动拉起）"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$PORT"/tcp >/dev/null 2>&1 && ok "ufw 已放行 $PORT/tcp"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1 && ok "firewalld 已放行 $PORT/tcp"
  else
    info "未检测到本机防火墙，请确认云厂商安全组已放行 TCP $PORT"
  fi
}

enable_bbr() {
  [ "$BBR" = "y" ] || return 0
  local avail
  avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  modprobe tcp_bbr 2>/dev/null || true
  avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if echo "$avail" | grep -qw bbr; then
    cat > /etc/sysctl.d/99-bbr.conf <<'EOS'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOS
    sysctl --system >/dev/null 2>&1 || true
    ok "BBR 已启用（$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)）"
  else
    warn "内核不支持 BBR，已跳过"
  fi
}

# ---------------------------------------------------------------- tg 面板
install_tg_cli() {
  cat > "$1" <<'EOS'
#!/usr/bin/env bash
# tg - mtg 管理面板 (由 deploy-mtg.sh 生成)
set -uo pipefail
STATE="${MTG_STATE:-/opt/mtg/state.env}"
[ -f "$STATE" ] || { echo "未找到 $STATE，请先运行部署脚本"; exit 1; }
# shellcheck disable=SC1090
. "$STATE"
BIN="${BIN:-/opt/mtg/mtg}"
CONF="${CONF:-/etc/mtg.toml}"
INIT="${INIT:-systemd}"

G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; D=$'\033[2m'; B=$'\033[1m'; N=$'\033[0m'

save_state() {
  cat > "$STATE" <<EOF2
PORT=$PORT
DOMAIN=$DOMAIN
CONCURRENCY=$CONCURRENCY
BLOCKLIST=$BLOCKLIST
DOPPELGANGER=$DOPPELGANGER
PUBLIC_IP=$PUBLIC_IP
IPV6=${IPV6:-}
VERSION=$VERSION
SECRET=$SECRET
INIT=$INIT
CONF=$CONF
BIN=$BIN
MG_BIN=$MG_BIN
EOF2
  chmod 600 "$STATE"
}

gen_config() {
  {
    echo "# mtg v2 configuration"
    echo "# generated by deploy-mtg.sh  $(date '+%F %T')"
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
               start|stop|restart|status) rc-service mtg "$1" ;;
               *) return 1 ;;
             esac ;;
    *) return 1 ;;
  esac
}

status_line() {
  if pgrep -f "$BIN run" >/dev/null 2>&1; then
    printf '   %s● 运行中%s   端口 %s   域名 %s   并发 %s\n' "$G" "$N" "$PORT" "$DOMAIN" "$CONCURRENCY"
  else
    printf '   %s● 未运行%s   端口 %s   域名 %s\n' "$R" "$N" "$PORT" "$DOMAIN"
  fi
}

links() {
  local out tg tme
  out=$("$BIN" access "$CONF" -i "$PUBLIC_IP" -p "$PORT" 2>/dev/null) || { echo "读取配置失败"; return 1; }
  tg=$(printf '%s' "$out" | grep -o '"tg_url": "[^"]*"' | head -1 | sed 's/.*: "//; s/"$//')
  tme=$(printf '%s' "$out" | grep -o '"tme_url": "[^"]*"' | head -1 | sed 's/.*: "//; s/"$//')
  echo
  printf '   %s代理链接%s\n   %s\n\n' "$B" "$N" "$tg"
  printf '   %s网页链接%s\n   %s\n' "$B" "$N" "$tme"
  if command -v qrencode >/dev/null 2>&1; then
    echo
    qrencode -t ANSIUTF8 "$tg" 2>/dev/null | sed 's/^/   /'
  fi
}

restart_svc() {
  if svc restart >/dev/null 2>&1; then sleep 2; printf '   %s✔ 已重启%s\n' "$G" "$N"
  else printf '   %s✘ 重启失败%s（可能无 init 系统）\n' "$R" "$N"; fi
}

menu() {
  while true; do
    clear 2>/dev/null || true
    printf '\n   %sMTG 管理面板%s\n' "$B" "$N"
    printf '   %s────────────────────────────────────%s\n' "$D" "$N"
    status_line
    printf '   %s────────────────────────────────────%s\n' "$D" "$N"
    printf '   1) 代理链接 / 二维码      5) 重启服务\n'
    printf '   2) 修改监听端口           6) 启动 / 停止\n'
    printf '   3) 修改伪装域名           7) 查看日志\n'
    printf '   4) 修改并发数             8) 卸载\n'
    printf '   0) 退出\n'
    printf '   %s────────────────────────────────────%s\n' "$D" "$N"
    printf '   选择: '
    local c=""; read -r c < /dev/tty 2>/dev/null || read -r c || true
    case "$c" in
      1) links; printf '\n   回车继续...'; read -r _ < /dev/tty 2>/dev/null || true ;;
      2) printf '   新端口 [%s]: ' "$PORT"; read -r v < /dev/tty 2>/dev/null || read -r v || true
         if [ -n "${v:-}" ]; then
           PORT="$v"; gen_config; save_state; restart_svc; links
         fi
         printf '\n   回车继续...'; read -r _ < /dev/tty 2>/dev/null || true ;;
      3) printf '   新伪装域名 [%s]: ' "$DOMAIN"; read -r v < /dev/tty 2>/dev/null || read -r v || true
         if [ -n "${v:-}" ] && [ "$v" != "$DOMAIN" ]; then
           DOMAIN="$v"; SECRET=$("$BIN" generate-secret --hex "$DOMAIN")
           gen_config; save_state; restart_svc
           printf '   %s! secret 已重新生成，旧链接失效%s\n' "$Y" "$N"; links
         fi
         printf '\n   回车继续...'; read -r _ < /dev/tty 2>/dev/null || true ;;
      4) printf '   新并发数 [%s]: ' "$CONCURRENCY"; read -r v < /dev/tty 2>/dev/null || read -r v || true
         if [ -n "${v:-}" ]; then CONCURRENCY="$v"; gen_config; save_state; restart_svc; fi
         printf '\n   回车继续...'; read -r _ < /dev/tty 2>/dev/null || true ;;
      5) restart_svc; printf '\n   回车继续...'; read -r _ < /dev/tty 2>/dev/null || true ;;
      6) printf '   1) 启动  2) 停止 : '; read -r op < /dev/tty 2>/dev/null || read -r op || true
         case "$op" in 1) svc start >/dev/null 2>&1 && echo "   已启动";; 2) svc stop >/dev/null 2>&1 && echo "   已停止";; esac
         printf '\n   回车继续...'; read -r _ < /dev/tty 2>/dev/null || true ;;
      7) tail -n 80 -f /var/log/mtg.log 2>/dev/null || journalctl -u mtg -n 80 -f --no-pager ;;
      8) printf '   确认卸载? (yes/no): '; read -r yn < /dev/tty 2>/dev/null || read -r yn || true
         [ "$yn" = "yes" ] || continue
         case "$INIT" in
           systemd) systemctl disable --now mtg >/dev/null 2>&1; rm -f /etc/systemd/system/mtg.service; systemctl daemon-reload >/dev/null 2>&1 ;;
           openrc)  rc-service mtg stop >/dev/null 2>&1; rc-update del mtg default >/dev/null 2>&1; rm -f /etc/init.d/mtg /etc/periodic/5min/mtg-watchdog ;;
         esac
         rm -rf /opt/mtg /etc/mtg.toml "$0"
         echo "   已卸载"; exit 0 ;;
      0|"") exit 0 ;;
    esac
  done
}

case "${1:-}" in
  status)  status_line ;;
  link)    links ;;
  restart) restart_svc ;;
  port)    PORT="${2:?用法: tg port 443}"; gen_config; save_state; restart_svc; links ;;
  domain)  DOMAIN="${2:?用法: tg domain www.bing.com}"; SECRET=$("$BIN" generate-secret --hex "$DOMAIN"); gen_config; save_state; restart_svc; links ;;
  concurrency) CONCURRENCY="${2:?用法: tg concurrency 4096}"; gen_config; save_state; restart_svc ;;
  log)     tail -n 100 /var/log/mtg.log 2>/dev/null || journalctl -u mtg -n 100 --no-pager ;;
  "")      menu ;;
  *)       echo "用法: tg [status|link|port N|domain HOST|concurrency N|restart|log]" ;;
esac
EOS
  chmod +x "$1"
}

if [ "$DRY" = 1 ]; then
  warn "dry-run：跳过服务安装与启动"
  install_tg_cli "$INSTALL_DIR/tg.dryrun"
else
  install_systemd || install_openrc || true
  install_watchdog
  open_firewall
  enable_bbr
  install_tg_cli "$TG_CLI"
fi


# ---------------------------------------------------------------- 结果
sleep 1
TG_URL=""; TME_URL=""
if [ -x "$BIN" ] && [ -f "$CONF" ]; then
  OUT="$("$BIN" access "$CONF" -i "$PUBLIC_IP" -p "$PORT" 2>/dev/null || true)"
  TG_URL="$(printf '%s' "$OUT" | grep -o '"tg_url": "[^"]*"' | head -1 | sed 's/.*: "//; s/"$//')"
  TME_URL="$(printf '%s' "$OUT" | grep -o '"tme_url": "[^"]*"' | head -1 | sed 's/.*: "//; s/"$//')"
fi

echo
printf '   %s╭──────────────────────────────────────────────────%s\n' "$G" "$NC"
printf '   %s│%s  %s部署完成 · mtg 已就绪%s\n' "$G" "$NC" "$BOLD" "$NC"
printf '   %s├──────────────────────────────────────────────────%s\n' "$G" "$NC"
printf '   %s│%s  服务器    %s\n' "$G" "$NC" "$PUBLIC_IP"
printf '   %s│%s  端口      %s\n' "$G" "$NC" "$PORT"
printf '   %s│%s  伪装域名  %s\n' "$G" "$NC" "$DOMAIN"
printf '   %s│%s  配置文件  %s\n' "$G" "$NC" "$CONF"
printf '   %s╰──────────────────────────────────────────────────%s\n' "$G" "$NC"

if [ -n "$TG_URL" ]; then
  echo
  printf '   %s代理链接%s\n' "$BOLD" "$NC"
  printf '   %s\n' "$TG_URL"
  echo
  printf '   %s网页链接%s\n' "$BOLD" "$NC"
  printf '   %s\n' "$TME_URL"

  echo
  printf '   %s分享给朋友（复制后直接在 Telegram 里发送即可）%s\n' "$DIM" "$NC"
  printf '   我的 Sky 私服代理：%s\n' "$TME_URL"

  if command -v qrencode >/dev/null 2>&1; then
    echo
    qrencode -t ANSIUTF8 "$TG_URL" 2>/dev/null | sed 's/^/   /'
  else
    echo
    printf '   %s二维码在线生成:%s https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=%s\n' \
      "$DIM" "$NC" "$(printf '%s' "$TG_URL" | sed 's/:/%3A/g; s/\//%2F/g; s/?/%3F/g; s/&/%26/g; s/=/%3D/g')"
  fi
fi

echo
hr
printf '   管理面板：输入 %stg%s 查看状态 / 改端口 / 改域名 / 取链接 / 日志 / 卸载\n' "$BOLD" "$NC"
printf '   安装日志：%s\n' "$LOG_FILE"
hr
echo

if [ -z "$TG_URL" ]; then
  warn "链接生成失败，请手动执行: $BIN access $CONF -i $PUBLIC_IP -p $PORT"
fi
