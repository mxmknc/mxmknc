#!/usr/bin/env bash
# freespace.sh — освободить диск и поднять Docker, НЕ ТРОГАЯ данные.
#
# Гарантия: скрипт не удаляет ни контейнеры, ни volume'ы, ни образы, ни конфиги.
# Все ключи Amnezia/Xray остаются на месте — старые конфиги у клиентов продолжат работать.
# Чистится только заведомо одноразовое: логи, кэш пакетов, временные файлы, build-кэш.
#
#   bash <(curl -sSL https://raw.githubusercontent.com/mxmknc/mxmknc/claude/vpn-server-connection-issue-0tmmyo/vpn/freespace.sh)

set -uo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

AWG_PORT="${AWG_PORT:-35557}"
XRAY_PORT="${XRAY_PORT:-443}"

ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
inf()  { printf '\033[1;36m[ .. ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1;35m########## %s ##########\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
freek() { df --output=avail -k / 2>/dev/null | tail -1 | tr -dc '0-9'; }
human() { numfmt --to=iec --suffix=B $(( ${1:-0} * 1024 )) 2>/dev/null || echo "${1}K"; }

[ "$(id -u)" = 0 ] || { err "нужен root"; exit 1; }

START_FREE=$(freek)
hdr "0. ЧТО ЕСТЬ СЕЙЧАС"
df -h / | sed 's/^/  /'
echo
echo "  Крупнейшие каталоги (может занять полминуты):"
du -xh --max-depth=3 / 2>/dev/null | sort -rh | head -20 | sed 's/^/    /'
echo
echo "  Крупнейшие отдельные файлы:"
find / -xdev -type f -size +50M 2>/dev/null -printf '%s\t%p\n' | sort -rn | head -15 \
  | awk -F'\t' '{printf "    %6.1f MB  %s\n", $1/1048576, $2}'

# ------------------------------------------------------- 1. логи контейнеров
hdr "1. ЛОГИ DOCKER-КОНТЕЙНЕРОВ (обычно главный пожиратель)"
# json-логи можно безопасно обнулить прямо на диске, даже когда демон лежит.
# Сами контейнеры и их данные при этом не затрагиваются.
CNT=0; SAVED=0
for f in /var/lib/docker/containers/*/*-json.log; do
  [ -f "$f" ] || continue
  sz=$(( $(stat -c%s "$f" 2>/dev/null || echo 0) / 1024 ))
  [ "$sz" -gt 0 ] || continue
  printf '    %8s  %s\n' "$(human "$sz")" "$(basename "$(dirname "$f")" | cut -c1-12)"
  : > "$f" 2>/dev/null && { CNT=$((CNT+1)); SAVED=$((SAVED+sz)); }
done
[ "$CNT" -gt 0 ] && ok "обнулено логов: $CNT, освобождено ~$(human $SAVED)" || ok "логов контейнеров нет или они пустые"

# ------------------------------------------------------------- 2. системные
hdr "2. СИСТЕМНЫЕ ЛОГИ И КЭШИ"
if have journalctl; then
  before=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]' | head -1)
  journalctl --rotate >/dev/null 2>&1
  journalctl --vacuum-size=32M >/dev/null 2>&1
  ok "journald: было ${before:-?} -> $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]' | head -1)"
fi

find /var/log -type f \( -name '*.gz' -o -name '*.xz' -o -name '*.old' -o -regex '.*\.[0-9]+' \) -delete 2>/dev/null
for f in /var/log/syslog /var/log/messages /var/log/kern.log /var/log/auth.log /var/log/daemon.log /var/log/ufw.log /var/log/btmp /var/log/wtmp /var/log/lastlog; do
  [ -f "$f" ] && : > "$f" 2>/dev/null
done
ok "ротированные и крупные системные логи очищены"

apt-get clean >/dev/null 2>&1
rm -rf /var/lib/apt/lists/* 2>/dev/null
ok "кэш apt очищен"

rm -rf /tmp/* /var/tmp/* 2>/dev/null
rm -rf /root/.cache/* 2>/dev/null
rm -f /var/crash/* /core /var/lib/systemd/coredump/* 2>/dev/null
ok "временные файлы и core-дампы удалены"

# старые ядра (текущее не трогаем)
if have dpkg; then
  CUR=$(uname -r)
  OLD=$(dpkg -l 'linux-image-[0-9]*' 2>/dev/null | awk '/^ii/{print $2}' | grep -v "$CUR" | head -5)
  if [ -n "$OLD" ]; then
    # shellcheck disable=SC2086
    apt-get -y purge $OLD >/dev/null 2>&1 && ok "удалены старые ядра: $(echo $OLD | tr '\n' ' ')"
  fi
  apt-get -y autoremove --purge >/dev/null 2>&1
fi

NOW_FREE=$(freek)
echo
ok "свободно стало: $(human "$NOW_FREE")  (было $(human "$START_FREE"))"
df -h / | sed 's/^/  /'

# ------------------------------------------ 3. ограничить логи на будущее
hdr "3. ЧТОБЫ НЕ ПОВТОРИЛОСЬ"
mkdir -p /etc/docker
if [ -f /etc/docker/daemon.json ] && have jq && jq -e . /etc/docker/daemon.json >/dev/null 2>&1; then
  cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
  jq '. + {"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' \
     /etc/docker/daemon.json.bak > /etc/docker/daemon.json 2>/dev/null \
     && ok "daemon.json дополнен ротацией логов (бэкап: daemon.json.bak)"
elif [ ! -f /etc/docker/daemon.json ]; then
  cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
  ok "включена ротация логов Docker (10 МБ x 3 на контейнер)"
else
  warn "daemon.json существует, но не разобран — оставляю как есть"
fi

# ------------------------------------------------------------- 4. поднимаем
hdr "4. ПОДНИМАЕМ DOCKER И КОНТЕЙНЕРЫ"
if [ "$NOW_FREE" -lt 262144 ]; then
  err "свободно меньше 256 МБ — Docker может снова не стартовать."
  echo "  Пришли вывод раздела 0 (крупнейшие каталоги и файлы) — посмотрим, что ещё съело диск."
fi

systemctl reset-failed docker 2>/dev/null
systemctl restart docker >/dev/null 2>&1
for i in $(seq 1 20); do
  systemctl is-active --quiet docker 2>/dev/null && break
  sleep 2
done
if systemctl is-active --quiet docker 2>/dev/null; then
  ok "docker поднялся"
else
  err "docker всё ещё не стартует: $(systemctl is-active docker 2>&1 | head -1)"
  journalctl -u docker -n 25 --no-pager 2>/dev/null | sed 's/^/    /'
fi
systemctl enable docker >/dev/null 2>&1

if have docker && systemctl is-active --quiet docker 2>/dev/null; then
  echo "  --- контейнеры ---"
  docker ps -a --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null
  STOPPED=$(docker ps -aq --filter status=exited --filter status=created 2>/dev/null)
  if [ -n "$STOPPED" ]; then
    inf "запускаю остановленные контейнеры..."
    # shellcheck disable=SC2086
    docker start $STOPPED >/dev/null 2>&1
    sleep 6
  fi
  for c in $(docker ps -aq 2>/dev/null); do
    docker update --restart=unless-stopped "$c" >/dev/null 2>&1
  done
  ok "автозапуск контейнеров после перезагрузки включён"
  echo "  --- итоговое состояние ---"
  docker ps -a --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null
  for c in $(docker ps -aq --filter status=exited 2>/dev/null); do
    err "не поднялся: $(docker inspect -f '{{.Name}}' "$c" 2>/dev/null | tr -d /)"
    docker logs --tail 15 "$c" 2>&1 | sed 's/^/    /'
  done
fi

# форвардинг (в прошлый раз не записался из-за отсутствия места)
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-vpn-forward.conf 2>/dev/null
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
echo "  ip_forward = $(cat /proc/sys/net/ipv4/ip_forward)"

# ---------------------------------------------------------------- 5. проверка
hdr "5. ПРОВЕРКА ПОРТОВ"
ss -tulnp 2>/dev/null | grep -vE '127\.0\.0\.1|\[::1\]' | sed 's/^/  /'
echo
X=no; A=no
ss -tlnp 2>/dev/null | grep -qE "[:.]${XRAY_PORT}[[:space:]]" && X=yes
ss -ulnp 2>/dev/null | grep -qE "[:.]${AWG_PORT}[[:space:]]"  && A=yes
printf '  TCP/%-6s Xray      : %s\n' "$XRAY_PORT" "$X"
printf '  UDP/%-6s AmneziaWG : %s\n' "$AWG_PORT" "$A"
echo
if [ "$X" = yes ] || [ "$A" = yes ]; then
  ok "ПОДНЯЛОСЬ. Старые конфиги должны заработать без изменений — пробуй прямо сейчас."
  echo "  Проверить снаружи: https://check-host.net/check-tcp?host=83.147.243.77:${XRAY_PORT}"
else
  err "порты пустые. Пришли вывод целиком — разберём."
fi
echo
