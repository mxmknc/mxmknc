#!/usr/bin/env bash
# diag.sh — быстрая диагностика VPN-сервера. Ничего не меняет, только читает.
# Запуск:  bash <(curl -sSL https://raw.githubusercontent.com/mxmknc/mxmknc/claude/vpn-server-connection-issue-0tmmyo/vpn/diag.sh)

export LC_ALL=C
h() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
run() { if have "${1%% *}"; then eval "$*" 2>&1 | sed 's/^/  /'; else echo "  (нет команды: ${1%% *})"; fi; }

h "СИСТЕМА"
run 'cat /etc/os-release | grep PRETTY'
run 'uname -r'
run 'uptime'
echo "  RAM:"; free -h 2>/dev/null | sed 's/^/    /'
echo "  DISK:"; df -h / 2>/dev/null | sed 's/^/    /'
echo "  virt: $(systemd-detect-virt 2>/dev/null || echo '?')"

h "ВНЕШНИЙ IP / СЕТЬ"
run 'ip -4 -br addr'
run 'ip route show default'
echo "  внешний IP: $(curl -4 -s --max-time 8 https://api.ipify.org 2>/dev/null || echo 'нет исходящего интернета!')"

h "КТО СЛУШАЕТ ПОРТЫ (главное!)"
if have ss; then
  echo "  --- TCP ---"; ss -tlnp 2>/dev/null | sed 's/^/  /'
  echo "  --- UDP ---"; ss -ulnp 2>/dev/null | sed 's/^/  /'
else
  run 'netstat -tulnp'
fi

h "FIREWALL"
echo "  --- ufw ---";      run 'ufw status verbose'
echo "  --- nftables ---"; run 'nft list ruleset | head -60'
echo "  --- iptables filter ---"; run 'iptables -S'
echo "  --- iptables nat ---";    run 'iptables -t nat -S'

h "СЕРВИСЫ VPN"
for s in xray v2ray sing-box wg-quick@wg0 awg-quick@awg0 amnezia-wireguard docker openvpn shadowsocks-libev hysteria-server; do
  st=$(systemctl is-active "$s" 2>/dev/null || true)
  en=$(systemctl is-enabled "$s" 2>/dev/null || true)
  [ -n "$st" ] && [ "$st" != "inactive" -o "$en" = "enabled" ] && printf '  %-24s active=%-10s enabled=%s\n' "$s" "$st" "$en"
done
echo "  (пусто выше = ни один VPN-сервис не запущен)"

h "DOCKER (Amnezia ставит контейнеры)"
if have docker; then
  run 'docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"'
else
  echo "  docker не установлен -> AmneziaVPN здесь не разворачивался"
fi

h "КОНФИГИ НА ДИСКЕ"
for p in /usr/local/etc/xray /etc/xray /opt/amnezia /etc/wireguard /etc/amnezia /etc/amneziawg /etc/sing-box /etc/x-ui /usr/local/x-ui; do
  [ -e "$p" ] && { echo "  $p:"; ls -la "$p" 2>/dev/null | sed 's/^/    /'; }
done

h "ЯДРО / МОДУЛИ"
run 'lsmod | grep -E "wireguard|amneziawg|tun" '
echo "  ip_forward = $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
echo "  /dev/net/tun: $([ -c /dev/net/tun ] && echo есть || echo НЕТ)"
run 'sysctl net.ipv4.tcp_congestion_control'

h "ПОСЛЕДНИЕ ОШИБКИ"
run 'journalctl -p err -n 30 --no-pager'
echo "  --- OOM? ---"; run 'dmesg -T 2>/dev/null | grep -iE "out of memory|oom-killer" | tail -5'

h "ЛОГИ XRAY / WG (если есть)"
run 'journalctl -u xray -n 25 --no-pager'
run 'journalctl -u "awg-quick@*" -n 15 --no-pager'

printf '\n\033[1;32mГотово. Скопируй весь вывод и пришли его.\033[0m\n'
