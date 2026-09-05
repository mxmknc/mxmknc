# Реанимация VPN-сервера

Три скрипта. Запускать на сервере под root, по порядку.

| Скрипт | Что делает | Меняет систему |
|---|---|---|
| `diag.sh` | Собирает полную картину: порты, firewall, сервисы, контейнеры, логи, OOM | нет |
| `revive.sh` | Поднимает то, что уже настроено, но лежит (docker, контейнеры, systemd-юниты, форвардинг, правила ufw) | да, аккуратно |
| `setup.sh` | Ставит с нуля Xray VLESS+REALITY (TCP/443) и AmneziaWG (UDP), выдаёт ссылку и QR | да, ставит пакеты |

## Порядок действий

```bash
# 1. Понять, что происходит (ничего не ломает)
bash <(curl -sSL https://raw.githubusercontent.com/mxmknc/mxmknc/claude/vpn-server-connection-issue-0tmmyo/vpn/diag.sh)

# 2. Попробовать поднять существующую конфигурацию
bash <(curl -sSL https://raw.githubusercontent.com/mxmknc/mxmknc/claude/vpn-server-connection-issue-0tmmyo/vpn/revive.sh)

# 3. Если п.2 не помог — развернуть заново
bash <(curl -sSL https://raw.githubusercontent.com/mxmknc/mxmknc/claude/vpn-server-connection-issue-0tmmyo/vpn/setup.sh)
```

`revive.sh` по умолчанию проверяет UDP/35557 и TCP/443. Другие порты:

```bash
AWG_PORT=51820 XRAY_PORT=8443 bash revive.sh
```

## setup.sh

Разворачивает два независимых канала, чтобы один страховал другой:

1. **Xray VLESS + REALITY + XTLS-Vision, TCP/443.** REALITY проксирует чужой TLS-хендшейк
   реального сайта, поэтому для DPI соединение неотличимо от обычного захода на этот сайт —
   ни сертификата своего, ни домена не нужно. Маскировочный сайт (`dest`) подбирается
   автоматически: скрипт замеряет из Мадрида задержку до кандидатов и берёт тот, что
   отвечает быстрее всех при TLS 1.3 + HTTP/2.
2. **AmneziaWG, UDP.** Обфусцированный WireGuard: мусорные пакеты перед хендшейком (`Jc/Jmin/Jmax`),
   изменённые размеры служебных пакетов (`S1/S2`) и подменённые типы заголовков (`H1..H4`) —
   сигнатура WireGuard пропадает. Параметры генерируются случайными на каждой установке.

Флаги:

```
--xray-only | --awg-only     ставить только один канал
--port-xray N                порт Xray (по умолчанию 443)
--port-awg N                 порт AmneziaWG (по умолчанию 51820)
--sni HOST                   задать маскировочный сайт вручную
add-client ИМЯ               добавить ещё одно устройство и выйти
```

Всё, что скрипт сгенерировал, лежит в `/root/vpn/`:
`xray.env`, `awg.env`, `vless.txt`, `<имя>-amneziawg.conf`, `peers.list`.
Повторный запуск переиспользует эти ключи и не рвёт существующих клиентов.

## Куда вставлять конфиги

* **VLESS-ссылка** — v2rayNG, Hiddify, NekoBox, Streisand, FoXray, v2rayN.
* **AmneziaWG .conf** — AmneziaVPN (`+` → «Файл конфигурации») или AmneziaWG-клиент.

## Проверка снаружи

Порт открыт или нет — видно без всякого клиента:

```
https://check-host.net/check-tcp?host=IP:443
```

* `Connected` — сервис слушает;
* `Connection refused` — сервис не запущен (SYN дошёл, ответил RST — значит блокировки нет, просто некому отвечать);
* `Connection timed out` — трафик режется по дороге: firewall на сервере или фильтрация у провайдера.

Разница между `refused` и `timed out` — главный диагностический признак: первое чинится на сервере, второе означает блокировку.
