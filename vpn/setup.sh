#!/usr/bin/env bash
# setup.sh — разворачивает на чистом Ubuntu/Debian VPS два канала, устойчивых к DPI ТСПУ:
#   1) Xray VLESS + REALITY + XTLS-Vision на TCP/443  (основной, маскируется под чужой TLS)
#   2) AmneziaWG (WireGuard с обфускацией) на UDP     (запасной, для Amnezia-клиентов)
# Идемпотентен: повторный запуск не ломает уже настроенное.
#
#   bash <(curl -sSL https://raw.githubusercontent.com/mxmknc/mxmknc/claude/vpn-server-connection-issue-0tmmyo/vpn/setup.sh)
#
# Флаги:
#   --xray-only | --awg-only     ставить только один канал
#   --port-xray N  (по умолч. 443)
#   --port-awg  N  (по умолч. 51820)
#   --sni HOST     принудительный REALITY-dest вместо автоподбора
#   add-client ИМЯ добавить ещё одного пользователя (оба протокола) и выйти

set -uo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

XRAY_PORT=443
AWG_PORT=51820
AWG_IF=awg0
AWG_NET=10.29.7
AWG_DIR=/etc/amnezia/amneziawg
STATE=/root/vpn
FORCE_SNI=""
DO_XRAY=1
DO_AWG=1
ADD_CLIENT=""

ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
inf()  { printf '\033[1;36m[ .. ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1;35m########## %s ##########\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --xray-only) DO_AWG=0 ;;
    --awg-only)  DO_XRAY=0 ;;
    --port-xray) XRAY_PORT="$2"; shift ;;
    --port-awg)  AWG_PORT="$2";  shift ;;
    --sni)       FORCE_SNI="$2"; shift ;;
    add-client)  ADD_CLIENT="${2:-client$RANDOM}"; shift ;;
    -h|--help)   sed -n '2,22p' "$0"; exit 0 ;;
    *) warn "неизвестный аргумент: $1" ;;
  esac
  shift
done

[ "$(id -u)" = "0" ] || { err "нужен root"; exit 1; }
mkdir -p "$STATE"; chmod 700 "$STATE"

SERVER_IP="$(curl -4 -s --max-time 10 https://api.ipify.org 2>/dev/null || true)"
[ -n "$SERVER_IP" ] || SERVER_IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
WAN_IF="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"

# ---------------------------------------------------------------- предпроверка
preflight() {
  hdr "ПРЕДПРОВЕРКА"
  echo "  внешний IP : ${SERVER_IP:-НЕ ОПРЕДЕЛЁН}"
  echo "  интерфейс  : ${WAN_IF:-?}"
  echo "  ядро       : $(uname -r)"
  [ -n "$SERVER_IP" ] || { err "нет исходящего интернета — дальше бессмысленно"; exit 1; }

  # 443 занят?
  if ss -tlnp 2>/dev/null | grep -qE "[:.]${XRAY_PORT}\b"; then
    local who; who="$(ss -tlnp 2>/dev/null | grep -E "[:.]${XRAY_PORT}\b" | head -1)"
    warn "порт ${XRAY_PORT}/tcp уже занят: $who"
    warn "если это старый nginx/xray — скрипт попробует его остановить"
  fi

  inf "ставлю зависимости..."
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq curl wget jq qrencode openssl ca-certificates \
      iproute2 iptables uuid-runtime gnupg >/dev/null 2>&1 \
      && ok "зависимости на месте" || warn "часть пакетов не встала, продолжаю"

  # форвардинг + BBR
  cat > /etc/sysctl.d/99-vpn.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null 2>&1
  ok "ip_forward=$(cat /proc/sys/net/ipv4/ip_forward), cc=$(sysctl -n net.ipv4.tcp_congestion_control)"
}

# ------------------------------------------------------------ выбор REALITY-dest
# Хороший dest: TLS 1.3 + HTTP/2, не Cloudflare, географически близко к серверу,
# и сам сайт не заблокирован в РФ (иначе ТСПУ спалит несоответствие).
pick_sni() {
  if [ -n "$FORCE_SNI" ]; then echo "$FORCE_SNI"; return; fi
  local cands="www.microsoft.com dl.google.com www.samsung.com swcdn.apple.com
               www.nvidia.com www.tesla.com download.jetbrains.com www.philips.es"
  local best="" bestms=99999
  for d in $cands; do
    local t0 t1 out
    t0=$(date +%s%N)
    out=$(timeout 6 openssl s_client -connect "$d:443" -servername "$d" \
          -tls1_3 -alpn h2 </dev/null 2>/dev/null) || continue
    t1=$(date +%s%N)
    echo "$out" | grep -q "TLSv1.3" || continue
    echo "$out" | grep -q "ALPN protocol: h2" || continue
    local ms=$(( (t1-t0)/1000000 ))
    printf '    %-28s TLS1.3+h2  %s ms\n' "$d" "$ms" >&2
    if [ "$ms" -lt "$bestms" ]; then bestms=$ms; best=$d; fi
  done
  [ -n "$best" ] || best="www.microsoft.com"
  echo "$best"
}

# ---------------------------------------------------------------------- XRAY
install_xray() {
  hdr "XRAY  (VLESS + REALITY + XTLS-Vision, TCP/${XRAY_PORT})"

  if ! have xray; then
    inf "ставлю Xray-core..."
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install >/dev/null 2>&1
  fi
  have xray || { err "Xray не установился (проверь исходящий доступ к github.com)"; return 1; }
  ok "xray $(xray version 2>/dev/null | head -1)"

  # ключи и идентификаторы — переиспользуем, если уже генерировали
  if [ -f "$STATE/xray.env" ]; then
    . "$STATE/xray.env"
    ok "использую существующие ключи из $STATE/xray.env"
  else
    UUID="$(xray uuid)"
    local kp; kp="$(xray x25519)"
    PRIVKEY="$(echo "$kp" | awk -F': *' '/[Pp]rivate/{print $2}')"
    PUBKEY="$(echo  "$kp" | awk -F': *' '/[Pp]ublic/{print $2}')"
    SHORTID="$(openssl rand -hex 8)"
    inf "подбираю маскировочный сайт (dest) — замеряю задержку из Мадрида:"
    SNI="$(pick_sni)"
    cat > "$STATE/xray.env" <<EOF
UUID='$UUID'
PRIVKEY='$PRIVKEY'
PUBKEY='$PUBKEY'
SHORTID='$SHORTID'
SNI='$SNI'
EOF
    chmod 600 "$STATE/xray.env"
  fi
  ok "маскируемся под: $SNI"

  # освобождаем порт, если его держит что-то чужое
  if ss -tlnp 2>/dev/null | grep -E "[:.]${XRAY_PORT}\b" | grep -qv xray; then
    for svc in nginx apache2 caddy haproxy v2ray sing-box x-ui; do
      systemctl is-active --quiet "$svc" 2>/dev/null && { warn "останавливаю $svc — держит ${XRAY_PORT}"; systemctl disable --now "$svc" >/dev/null 2>&1; }
    done
  fi

  mkdir -p /usr/local/etc/xray
  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "flow": "xtls-rprx-vision", "email": "main" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": [ "${SNI}" ],
          "privateKey": "${PRIVKEY}",
          "shortIds": [ "${SHORTID}" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "protocol": [ "bittorrent" ], "outboundTag": "block" },
      { "type": "field", "ip": [ "geoip:private" ], "outboundTag": "block" }
    ]
  }
}
EOF

  xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1 \
    || { err "конфиг Xray не прошёл проверку:"; xray run -test -config /usr/local/etc/xray/config.json 2>&1 | tail -10; return 1; }
  ok "конфиг валиден"

  systemctl enable xray >/dev/null 2>&1
  systemctl restart xray
  sleep 2
  if ss -tlnp 2>/dev/null | grep -qE "[:.]${XRAY_PORT}\b.*xray"; then
    ok "xray слушает ${XRAY_PORT}/tcp"
  else
    err "xray НЕ слушает ${XRAY_PORT}. Логи:"; journalctl -u xray -n 20 --no-pager | sed 's/^/    /'; return 1
  fi
}

vless_link() {  # $1 = uuid, $2 = метка
  echo "vless://${1}@${SERVER_IP}:${XRAY_PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBKEY}&sid=${SHORTID}&type=tcp&flow=xtls-rprx-vision#${2}"
}

# ------------------------------------------------------------------ AMNEZIAWG
install_awg() {
  hdr "AMNEZIAWG  (обфусцированный WireGuard, UDP/${AWG_PORT})"

  if ! have awg; then
    inf "подключаю репозиторий Amnezia..."
    if grep -qi ubuntu /etc/os-release; then
      apt-get install -y -qq software-properties-common >/dev/null 2>&1
      add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y -qq linux-headers-"$(uname -r)" >/dev/null 2>&1
      apt-get install -y -qq amneziawg amneziawg-tools >/dev/null 2>&1 \
        || apt-get install -y -qq amneziawg >/dev/null 2>&1
    fi
  fi

  if ! have awg; then
    warn "пакета нет — собираю userspace-версию (amneziawg-go) из исходников, это 2-4 минуты"
    apt-get install -y -qq golang-go git make >/dev/null 2>&1
    local b=/usr/local/src/awg; rm -rf "$b"; mkdir -p "$b"
    ( git clone -q --depth 1 https://github.com/amnezia-vpn/amneziawg-tools "$b/tools" \
      && git clone -q --depth 1 https://github.com/amnezia-vpn/amneziawg-go "$b/go" \
      && make -C "$b/tools/src" -s >/dev/null 2>&1 \
      && make -C "$b/tools/src" install WITH_SYSTEMDUNITS=yes >/dev/null 2>&1 \
      && cd "$b/go" && make -s >/dev/null 2>&1 \
      && install -m755 "$b/go/amneziawg-go" /usr/local/bin/amneziawg-go ) >/dev/null 2>&1
    have awg && ok "userspace amneziawg собран" || { err "AmneziaWG не установился — останется только Xray"; return 1; }
    export WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go
    mkdir -p /etc/systemd/system/awg-quick@.service.d
    printf '[Service]\nEnvironment=WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go\n' \
      > /etc/systemd/system/awg-quick@.service.d/userspace.conf
    systemctl daemon-reload
  fi
  ok "awg: $(awg --version 2>/dev/null | head -1)"

  mkdir -p "$AWG_DIR"; chmod 700 "$AWG_DIR"

  if [ -f "$STATE/awg.env" ]; then
    . "$STATE/awg.env"
    ok "использую существующие параметры обфускации"
  else
    SRV_PRIV="$(awg genkey)"
    SRV_PUB="$(echo "$SRV_PRIV" | awg pubkey)"
    # параметры обфускации: делают хендшейк непохожим на WireGuard
    JC=$((RANDOM % 5 + 3))            # 3..7 мусорных пакетов
    JMIN=$((RANDOM % 20 + 40))        # 40..59
    JMAX=$((JMIN + RANDOM % 60 + 20)) # > JMIN
    S1=$((RANDOM % 80 + 20))
    S2=$((RANDOM % 80 + 20)); while [ $((S1 + 56)) -eq "$S2" ]; do S2=$((S2 + 1)); done
    H1=$((RANDOM * 30000 + 100000)); H2=$((H1 + 77771)); H3=$((H2 + 88881)); H4=$((H3 + 99991))
    cat > "$STATE/awg.env" <<EOF
SRV_PRIV='$SRV_PRIV'
SRV_PUB='$SRV_PUB'
JC=$JC
JMIN=$JMIN
JMAX=$JMAX
S1=$S1
S2=$S2
H1=$H1
H2=$H2
H3=$H3
H4=$H4
EOF
    chmod 600 "$STATE/awg.env"
  fi

  cat > "$AWG_DIR/${AWG_IF}.conf" <<EOF
[Interface]
Address = ${AWG_NET}.1/24
ListenPort = ${AWG_PORT}
PrivateKey = ${SRV_PRIV}
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}
PostUp = iptables -t nat -A POSTROUTING -s ${AWG_NET}.0/24 -o ${WAN_IF} -j MASQUERADE; iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${AWG_NET}.0/24 -o ${WAN_IF} -j MASQUERADE; iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT
EOF
  chmod 600 "$AWG_DIR/${AWG_IF}.conf"

  # переносим уже заведённых пиров обратно в конфиг
  if [ -f "$STATE/peers.list" ]; then
    while IFS='|' read -r pname ppub pip _; do
      [ -n "$ppub" ] && printf '\n[Peer]\n# %s\nPublicKey = %s\nAllowedIPs = %s/32\n' "$pname" "$ppub" "$pip" >> "$AWG_DIR/${AWG_IF}.conf"
    done < "$STATE/peers.list"
  fi

  systemctl enable "awg-quick@${AWG_IF}" >/dev/null 2>&1
  systemctl restart "awg-quick@${AWG_IF}" >/dev/null 2>&1
  sleep 2
  if ss -ulnp 2>/dev/null | grep -qE "[:.]${AWG_PORT}\b"; then
    ok "amneziawg слушает ${AWG_PORT}/udp"
  else
    err "amneziawg не поднялся. Логи:"; journalctl -u "awg-quick@${AWG_IF}" -n 20 --no-pager | sed 's/^/    /'; return 1
  fi
}

next_peer_ip() {
  local last=1
  [ -f "$STATE/peers.list" ] && last=$(awk -F'|' '{split($3,a,"."); if(a[4]>m) m=a[4]} END{print (m?m:1)}' "$STATE/peers.list")
  echo "${AWG_NET}.$((last + 1))"
}

add_awg_peer() {  # $1 = имя
  local name="$1" priv pub ip
  priv="$(awg genkey)"; pub="$(echo "$priv" | awg pubkey)"; ip="$(next_peer_ip)"
  echo "${name}|${pub}|${ip}|" >> "$STATE/peers.list"

  printf '\n[Peer]\n# %s\nPublicKey = %s\nAllowedIPs = %s/32\n' "$name" "$pub" "$ip" >> "$AWG_DIR/${AWG_IF}.conf"
  awg set "$AWG_IF" peer "$pub" allowed-ips "${ip}/32" 2>/dev/null

  cat > "$STATE/${name}-amneziawg.conf" <<EOF
[Interface]
PrivateKey = ${priv}
Address = ${ip}/32
DNS = 1.1.1.1, 8.8.8.8
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
PublicKey = ${SRV_PUB}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${SERVER_IP}:${AWG_PORT}
PersistentKeepalive = 25
EOF
  chmod 600 "$STATE/${name}-amneziawg.conf"
}

# -------------------------------------------------------------------- firewall
firewall() {
  hdr "FIREWALL"
  if have ufw && ufw status 2>/dev/null | grep -qi "^Status: active"; then
    ufw allow 22/tcp                >/dev/null 2>&1
    ufw allow "${XRAY_PORT}"/tcp    >/dev/null 2>&1
    ufw allow "${AWG_PORT}"/udp     >/dev/null 2>&1
    ufw route allow in on "$AWG_IF" >/dev/null 2>&1
    ok "ufw активен, порты 22/tcp ${XRAY_PORT}/tcp ${AWG_PORT}/udp открыты"
  else
    ok "ufw не активен — входящий трафик не режется"
  fi
  iptables -S INPUT 2>/dev/null | head -1 | grep -q "DROP\|REJECT" && \
    warn "политика INPUT не ACCEPT — проверь 'iptables -S' вручную"
}

# ---------------------------------------------------------------------- report
report() {
  hdr "ГОТОВО — ЗАБИРАЙ КОНФИГИ"
  echo
  echo "Сервер: ${SERVER_IP}   (всё сохранено в ${STATE}/)"
  echo

  if [ "$DO_XRAY" = 1 ] && [ -f "$STATE/xray.env" ]; then
    local link; link="$(vless_link "$UUID" "Madrid-Reality")"
    printf '\033[1;32m--- 1. XRAY / VLESS-REALITY (основной, TCP/%s) ---\033[0m\n' "$XRAY_PORT"
    echo "Ссылка (вставить в v2rayNG / Hiddify / Streisand / NekoBox / FoXray):"
    echo
    echo "$link"
    echo
    echo "$link" > "$STATE/vless.txt"
    have qrencode && { echo "QR:"; qrencode -t ANSIUTF8 -m 1 "$link"; }
    echo
  fi

  if [ "$DO_AWG" = 1 ] && [ -f "$STATE/main-amneziawg.conf" ]; then
    printf '\033[1;32m--- 2. AMNEZIAWG (запасной, UDP/%s) ---\033[0m\n' "$AWG_PORT"
    echo "Файл: ${STATE}/main-amneziawg.conf"
    echo "Импорт: AmneziaVPN -> + -> Файл конфигурации, либо AmneziaWG-клиент."
    echo
    sed 's/^/    /' "$STATE/main-amneziawg.conf"
    echo
    have qrencode && { echo "QR (AmneziaWG / WireGuard-совместимые клиенты):"; qrencode -t ANSIUTF8 -m 1 < "$STATE/main-amneziawg.conf"; }
    echo
  fi

  hdr "ПРОВЕРКА СНАРУЖИ"
  echo "  Открой https://check-host.net/check-tcp?host=${SERVER_IP}:${XRAY_PORT}"
  echo "  Должно быть 'Connected', а не 'Connection refused'."
  echo
  echo "  Добавить ещё устройство:  bash $0 add-client имя"
  echo
}

# ------------------------------------------------------------------------ main
if [ -n "$ADD_CLIENT" ]; then
  [ -f "$STATE/xray.env" ] && . "$STATE/xray.env"
  [ -f "$STATE/awg.env" ]  && . "$STATE/awg.env"
  hdr "ДОБАВЛЯЮ КЛИЕНТА: $ADD_CLIENT"
  if [ -f /usr/local/etc/xray/config.json ] && have xray; then
    NEWID="$(xray uuid)"
    tmp=$(mktemp)
    jq --arg id "$NEWID" --arg em "$ADD_CLIENT" \
      '.inbounds[0].settings.clients += [{"id":$id,"flow":"xtls-rprx-vision","email":$em}]' \
      /usr/local/etc/xray/config.json > "$tmp" && mv "$tmp" /usr/local/etc/xray/config.json
    systemctl restart xray && ok "xray: клиент добавлен"
    echo; vless_link "$NEWID" "$ADD_CLIENT"; echo
  fi
  if have awg && [ -f "$AWG_DIR/${AWG_IF}.conf" ]; then
    add_awg_peer "$ADD_CLIENT"
    ok "amneziawg: пир добавлен -> $STATE/${ADD_CLIENT}-amneziawg.conf"
    have qrencode && qrencode -t ANSIUTF8 -m 1 < "$STATE/${ADD_CLIENT}-amneziawg.conf"
  fi
  exit 0
fi

preflight
[ "$DO_XRAY" = 1 ] && { install_xray || DO_XRAY=0; }
if [ "$DO_AWG" = 1 ]; then
  if install_awg; then
    [ -f "$STATE/main-amneziawg.conf" ] || add_awg_peer main
  else
    DO_AWG=0
  fi
fi
firewall
report
