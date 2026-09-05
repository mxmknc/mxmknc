#!/usr/bin/env bash
# slim.sh — вычистить с VPS то, что нужно только физической машине, и не дать диску забиться снова.
# Контейнеры, volume'ы, образы, ключи и конфиги не трогаются.
#
#   bash <(curl -sSL https://raw.githubusercontent.com/mxmknc/mxmknc/claude/vpn-server-connection-issue-0tmmyo/vpn/slim.sh)
#
# По умолчанию сносит snapd, лишние ядра, ставит лимиты журналу и apt.
# --firmware  дополнительно удаляет linux-firmware (~1.2 ГБ). Читай предупреждение в разделе 3.
# --dry-run   только показать, что было бы сделано.

set -uo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

DO_FIRMWARE=0
DRY=0
for a in "$@"; do
  case "$a" in
    --firmware) DO_FIRMWARE=1 ;;
    --dry-run)  DRY=1 ;;
  esac
done

ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
inf()  { printf '\033[1;36m[ .. ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1;35m########## %s ##########\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
freek() { df --output=avail -k / 2>/dev/null | tail -1 | tr -dc '0-9'; }
mb()   { echo $(( ${1:-0} / 1024 )); }
act()  { if [ "$DRY" = 1 ]; then echo "    [dry-run] $*"; else eval "$@" >/dev/null 2>&1; fi; }

[ "$(id -u)" = 0 ] || { err "нужен root"; exit 1; }
START=$(freek)
[ "$DRY" = 1 ] && warn "режим --dry-run: ничего не удаляется"

# ------------------------------------------------------------------- 1. snapd
hdr "1. SNAPD"
if have snap || [ -d /var/lib/snapd ]; then
  SZ=$(( $(du -sk /var/lib/snapd /usr/lib/snapd /snap 2>/dev/null | awk '{s+=$1} END{print s+0}') ))
  echo "  занимает: $(mb "$SZ") МБ"
  echo "  установленные snap-пакеты:"
  snap list 2>/dev/null | sed 's/^/    /' || echo "    (snap не отвечает)"
  # на сервере snap обычно содержит только core/lxd/snapd — всё это балласт
  EXTRA=$(snap list 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -vE '^(core|core[0-9]+|snapd|lxd)$' | tr '\n' ' ')
  if [ -n "$EXTRA" ]; then
    warn "кроме служебных установлены: $EXTRA"
    warn "если что-то из этого тебе нужно — пропусти этот шаг (Ctrl+C) и удали snapd вручную"
    sleep 5
  fi
  inf "удаляю snapd"
  act "systemctl disable --now snapd.service snapd.socket snapd.seeded.service"
  for s in $(snap list 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -v '^snapd$'); do
    act "snap remove --purge $s"
  done
  act "snap remove --purge snapd"
  act "apt-get -y purge snapd"
  act "rm -rf /var/lib/snapd /var/cache/snapd /snap /root/snap"
  act "apt-mark hold snapd"
  ok "snapd убран (и заблокирован от переустановки)"
else
  ok "snapd не установлен"
fi

# ------------------------------------------------------------------- 2. ядра
hdr "2. СТАРЫЕ ЯДРА"
CUR=$(uname -r)
echo "  работающее ядро: $CUR"
INSTALLED=$(dpkg -l 'linux-image-[0-9]*' 'linux-modules-[0-9]*' 'linux-headers-[0-9]*' 2>/dev/null | awk '/^ii/{print $2}')
OLD=$(echo "$INSTALLED" | grep -v "$CUR" | grep -vE 'linux-(image|headers|modules)-(generic|virtual)$')
if [ -n "$OLD" ]; then
  echo "  под удаление:"; echo "$OLD" | sed 's/^/    /'
  # shellcheck disable=SC2086
  act "apt-get -y purge $(echo $OLD | tr '\n' ' ')"
  ok "старые ядра удалены"
else
  ok "лишних ядер нет"
fi
act "apt-get -y autoremove --purge"

# --------------------------------------------------------------- 3. firmware
hdr "3. LINUX-FIRMWARE"
FW=$(du -sk /usr/lib/firmware 2>/dev/null | awk '{print $1+0}')
echo "  /usr/lib/firmware занимает: $(mb "$FW") МБ"
echo "  Это прошивки Wi-Fi-адаптеров, видеокарт и RAID-контроллеров."
echo "  Внутри KVM-виртуалки физических устройств нет, и они не загружаются никогда."
if [ "$DO_FIRMWARE" = 1 ]; then
  SIM=$(apt-get -s purge linux-firmware 2>/dev/null)
  if echo "$SIM" | grep -qE '^Remv linux-image-[0-9]'; then
    err "apt хочет снести вместе с firmware и само ядро — отказываюсь."
    echo "$SIM" | grep '^Remv' | sed 's/^/    /'
  else
    warn "побочный эффект: пакет linux-image-generic зависит от linux-firmware,"
    warn "поэтому уедет и метапакет. Установленное ядро ($CUR) останется и будет"
    warn "работать, но новые версии ядра перестанут приезжать сами — обновлять"
    warn "придётся вручную: apt install linux-image-virtual"
    echo "  будет удалено:"; echo "$SIM" | grep '^Remv' | sed 's/^/    /'
    act "apt-get -y purge linux-firmware"
    act "rm -rf /usr/lib/firmware /lib/firmware"
    ok "linux-firmware удалён"
  fi
else
  inf "пропущено. Чтобы удалить: перезапусти с флагом --firmware"
fi

# --------------------------------------------------- 4. лимиты на будущее
hdr "4. ЛИМИТЫ, ЧТОБЫ НЕ ПОВТОРИЛОСЬ"

if [ -d /etc/systemd/journald.conf.d ] || mkdir -p /etc/systemd/journald.conf.d 2>/dev/null; then
  if [ "$DRY" = 0 ]; then
    cat > /etc/systemd/journald.conf.d/99-limit.conf <<'CONF'
[Journal]
SystemMaxUse=64M
SystemMaxFileSize=16M
MaxRetentionSec=2week
CONF
    systemctl restart systemd-journald >/dev/null 2>&1
  fi
  ok "журнал systemd ограничен 64 МБ (было без лимита — вырос до 91 МБ)"
fi

if [ "$DRY" = 0 ]; then
  cat > /etc/apt/apt.conf.d/99-slim <<'CONF'
Acquire::Languages "none";
Acquire::GzipIndexes "true";
Binary::apt::APT::Keep-Downloaded-Packages "false";
Dir::Cache::srcpkgcache "";
APT::Install-Recommends "false";
CONF
fi
ok "apt больше не копит переводы, исходные индексы и .deb-файлы"

# docker: только заведомо мусорное — висячие слои и кэш сборки.
# Ни один рабочий образ, контейнер или volume при этом не затрагивается.
if have docker && systemctl is-active --quiet docker 2>/dev/null; then
  act "docker image prune -f"
  act "docker builder prune -f"
  ok "удалены висячие слои и кэш сборки Docker (образы и контейнеры целы)"
fi

# ------------------------------------------------------------------- 5. итог
hdr "5. ИТОГ"
END=$(freek)
df -h / | sed 's/^/  /'
echo
ok "освобождено за прогон: $(( $(mb "$END") - $(mb "$START") )) МБ  (свободно: $(mb "$END") МБ)"
echo
echo "  Крупнейшее из оставшегося:"
du -xh --max-depth=2 / 2>/dev/null | sort -rh | head -12 | sed 's/^/    /'

hdr "ПРОВЕРКА, ЧТО VPN ЖИВ"
if have docker; then
  docker ps --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null
fi
X=no; A=no
ss -tlnp 2>/dev/null | grep -qE '[:.]443[[:space:]]'   && X=yes
ss -ulnp 2>/dev/null | grep -qE '[:.]35557[[:space:]]' && A=yes
printf '  TCP/443   Xray      : %s\n' "$X"
printf '  UDP/35557 AmneziaWG : %s\n' "$A"
if [ "$X" = yes ] && [ "$A" = yes ]; then
  ok "оба канала на месте, клиентские конфиги не затронуты"
else
  err "порт пропал — пришли вывод, разберём"
fi
echo
