#!/usr/bin/env bash
# revive.sh — поднять уже настроенный сервер (AmneziaVPN/Docker/Xray/WG), который перестал отвечать.
# Ничего не переустанавливает. Сначала диагностирует, потом чинит очевидное.
#
#   bash <(curl -sSL https://raw.githubusercontent.com/mxmknc/mxmknc/claude/vpn-server-connection-issue-0tmmyo/vpn/revive.sh)

set -uo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

AWG_PORT="${AWG_PORT:-35557}"     # из твоего spain_0826_validate.conf
XRAY_PORT="${XRAY_PORT:-443}"

ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
inf()  { printf '\033[1;36m[ .. ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1;35m########## %s ##########\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
listen_tcp() { ss -tlnp 2>/dev/null | grep -qE "[:.]${1}[[:space:]]"; }
listen_udp() { ss -ulnp 2>/dev/null | grep -qE "[:.]${1}[[:space:]]"; }

[ "$(id -u)" = 0 ] || { err "нужен root"; exit 1; }

# ------------------------------------------------------------------ 1. ресурсы
hdr "1. РЕСУРСЫ (частая причина «всё легло»)"
DISK_PCT=$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')
echo "  диск /: ${DISK_PCT}% занято"
[ "${DISK_PCT:-0}" -ge 95 ] && err "ДИСК ЗАБИТ — контейнеры/сервисы не стартуют. Чистим docker: docker system prune -af"
free -m | sed 's/^/  /'
if dmesg -T 2>/dev/null | grep -qiE "out of memory|oom-killer"; then
  err "в dmesg есть OOM — процессы убивало по памяти:"
  dmesg -T 2>/dev/null | grep -iE "out of memory|oom-killer" | tail -3 | sed 's/^/    /'
  warn "лечится swap-файлом (см. конец вывода)"
else
  ok "OOM не было"
fi
echo "  аптайм: $(uptime -p 2>/dev/null)"

# ---------------------------------------------------------------- 2. что слушает
hdr "2. ЧТО СЛУШАЕТ СЕЙЧАС"
ss -tulnp 2>/dev/null | sed 's/^/  /'

BEFORE_XRAY=no; BEFORE_AWG=no
listen_tcp "$XRAY_PORT" && BEFORE_XRAY=yes
listen_udp "$AWG_PORT"  && BEFORE_AWG=yes
echo
echo "  TCP/${XRAY_PORT} (Xray) слушает: ${BEFORE_XRAY}"
echo "  UDP/${AWG_PORT} (AmneziaWG) слушает: ${BEFORE_AWG}"

# -------------------------------------------------------------------- 3. docker
hdr "3. DOCKER / КОНТЕЙНЕРЫ AMNEZIA"
if have docker; then
  if ! systemctl is-active --quiet docker 2>/dev/null; then
    warn "docker не запущен — стартую"
    systemctl enable --now docker >/dev/null 2>&1
    sleep 3
  fi
  systemctl is-active --quiet docker 2>/dev/null && ok "docker работает" || err "docker не поднялся: $(systemctl is-active docker 2>&1 | head -1)"
  systemctl is-enabled --quiet docker 2>/dev/null || { warn "docker был не в автозапуске — включаю"; systemctl enable docker >/dev/null 2>&1; }

  echo "  --- контейнеры ---"
  docker ps -a --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null

  STOPPED=$(docker ps -aq --filter "status=exited" --filter "status=created" 2>/dev/null)
  if [ -n "$STOPPED" ]; then
    warn "есть остановленные контейнеры — запускаю"
    # shellcheck disable=SC2086
    docker start $STOPPED >/dev/null 2>&1
    sleep 5
    echo "  --- после запуска ---"
    docker ps -a --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null
  else
    ok "остановленных контейнеров нет"
  fi

  # автозапуск контейнеров после ребута
  for c in $(docker ps -aq 2>/dev/null); do
    pol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null)
    if [ "$pol" = "no" ] || [ -z "$pol" ]; then
      docker update --restart=unless-stopped "$c" >/dev/null 2>&1 && \
        inf "включил автозапуск для $(docker inspect -f '{{.Name}}' "$c" 2>/dev/null | tr -d /)"
    fi
  done

  # логи упавших
  for c in $(docker ps -aq --filter "status=exited" 2>/dev/null); do
    n=$(docker inspect -f '{{.Name}}' "$c" | tr -d /)
    err "контейнер $n всё ещё не работает, последние строки лога:"
    docker logs --tail 15 "$c" 2>&1 | sed 's/^/    /'
  done
else
  echo "  docker не установлен"
fi

# ----------------------------------------------------------------- 4. systemd
hdr "4. SYSTEMD-СЕРВИСЫ"
for s in xray v2ray sing-box hysteria-server openvpn; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${s}\."; then
    st=$(systemctl is-active "$s" 2>/dev/null)
    if [ "$st" != "active" ]; then
      warn "$s = $st, пробую поднять"
      systemctl enable --now "$s" >/dev/null 2>&1; sleep 2
      st=$(systemctl is-active "$s" 2>/dev/null)
      [ "$st" = active ] && ok "$s поднят" || { err "$s не стартует:"; journalctl -u "$s" -n 15 --no-pager | sed 's/^/    /'; }
    else ok "$s работает"; fi
  fi
done
for u in $(systemctl list-unit-files 2>/dev/null | grep -oE '^(awg|wg)-quick@[^ ]+\.service' | sort -u); do
  st=$(systemctl is-active "$u" 2>/dev/null)
  if [ "$st" != active ]; then
    warn "$u = $st, поднимаю"; systemctl enable --now "$u" >/dev/null 2>&1; sleep 2
    systemctl is-active --quiet "$u" && ok "$u поднят" || { err "$u не стартует:"; journalctl -u "$u" -n 15 --no-pager | sed 's/^/    /'; }
  else ok "$u работает"; fi
done

# --------------------------------------------------------------- 5. wireguard
hdr "5. СОСТОЯНИЕ WIREGUARD / AMNEZIAWG"
for cmd in awg wg; do
  have "$cmd" && { echo "  --- $cmd show ---"; $cmd show 2>&1 | sed 's/^/  /'; }
done
if have docker; then
  for c in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'amnezia|awg|wireguard'); do
    echo "  --- внутри контейнера $c ---"
    docker exec "$c" sh -c 'awg show 2>/dev/null || wg show 2>/dev/null' 2>&1 | sed 's/^/    /'
  done
fi
echo "  ip_forward = $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]; then
  warn "форвардинг выключен — трафик клиентов никуда не пойдёт, включаю"
  echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-vpn-forward.conf
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
fi

# ---------------------------------------------------------------- 6. firewall
hdr "6. FIREWALL"
if have ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
  ufw status numbered | sed 's/^/  /'
  for r in "22/tcp" "${XRAY_PORT}/tcp" "${AWG_PORT}/udp"; do
    ufw allow "$r" >/dev/null 2>&1 && inf "ufw allow $r"
  done
else
  ok "ufw неактивен"
fi
echo "  --- iptables INPUT ---"; iptables -S INPUT 2>/dev/null | sed 's/^/  /'
POL=$(iptables -S INPUT 2>/dev/null | head -1)
case "$POL" in *DROP*|*REJECT*) warn "политика INPUT = $POL — убедись, что ${AWG_PORT}/udp и ${XRAY_PORT}/tcp разрешены";; esac
echo "  --- nat POSTROUTING ---"; iptables -t nat -S POSTROUTING 2>/dev/null | sed 's/^/  /'
iptables -t nat -S POSTROUTING 2>/dev/null | grep -q MASQUERADE || \
  warn "нет MASQUERADE — даже при успешном хендшейке интернета у клиента не будет"

# ------------------------------------------------------------------ 7. итог
hdr "7. ИТОГ"
AFTER_XRAY=no; AFTER_AWG=no
listen_tcp "$XRAY_PORT" && AFTER_XRAY=yes
listen_udp "$AWG_PORT"  && AFTER_AWG=yes
printf '  TCP/%-6s Xray      : было=%-3s стало=%s\n' "$XRAY_PORT" "$BEFORE_XRAY" "$AFTER_XRAY"
printf '  UDP/%-6s AmneziaWG : было=%-3s стало=%s\n' "$AWG_PORT" "$BEFORE_AWG" "$AFTER_AWG"
echo
if [ "$AFTER_XRAY" = yes ] || [ "$AFTER_AWG" = yes ]; then
  ok "что-то поднялось — пробуй подключиться клиентом ПРЯМО СЕЙЧАС"
else
  err "сервисы так и не слушают порты."
  echo "  Значит чинить нечего — надо ставить заново:"
  echo "    bash <(curl -sSL https://raw.githubusercontent.com/mxmknc/mxmknc/claude/vpn-server-connection-issue-0tmmyo/vpn/setup.sh)"
fi
echo
echo "  Если мало памяти — добавь swap одной командой:"
echo "    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab"
echo
