# vpn-node-setup

Скрипт для быстрой и безопасной подготовки VPN-ноды на **Ubuntu 24.04**: Remnawave `remnanode` + Xray (VLESS / Reality / XHTTP) в Docker, обычно с `network_mode: host`.

Всё находится в одном файле `install.sh`, поэтому запуск через `curl | bash` работает без клонирования репозитория.

## Быстрый старт

**Фаза 1** настраивает сервер. Порт 22 на этом этапе остаётся открыт:

```bash
curl -fsSL https://raw.githubusercontent.com/loevskiy/vpn-node-setup/main/install.sh | sudo bash -s -- \
  --pubkey "ssh-ed25519 AAAA... me@laptop" \
  --ssh-port 49222 \
  --vpn-ports 443 \
  --panel-ip 203.0.113.10 \
  --ipv6 2001:db8:1::1/64 --ipv6-gw fe80::1
```

**Проверка.** Откройте второе окно и войдите по ключу на новый порт. Первое окно не закрывайте:

```bash
ssh -p 49222 root@<ip-сервера>
```

**Фаза 2** закрывает порт 22 и перезагружает сервер в новое ядро. Запускайте её только после успешной проверки:

```bash
curl -fsSL https://raw.githubusercontent.com/loevskiy/vpn-node-setup/main/install.sh | sudo bash -s -- \
  --pubkey "ssh-ed25519 AAAA... me@laptop" --ssh-port 49222 --finalize
```

Фаза 2 откажется выполняться, если sshd не слушает новый порт или переданного ключа нет в `/root/.ssh/authorized_keys`.

## Флаги

Каждый флаг можно задать переменной окружения. Её имя указано в скобках.

| Флаг | По умолчанию | Описание |
|---|---|---|
| `--pubkey KEY` (`PUBKEY`) | — | **обязателен**, ваш публичный SSH-ключ |
| `--ssh-port N` (`SSH_PORT`) | 49222 | новый порт SSH |
| `--vpn-ports LIST` (`VPN_PORTS`) | 443 | порты через запятую. Порт без протокола открывается для tcp и udp, можно указать `8443/tcp` или `4443/udp` |
| `--node-port N` (`NODE_PORT`) | 2222 | API remnanode, доступен только с адресов панели |
| `--panel-ip LIST` (`PANEL_IP`) | пусто | IP панели через запятую. Если не задан, `NODE_PORT` остаётся закрыт |
| `--ipv6 ADDR/PFX` (`IPV6_ADDR`) | — | статический IPv6 |
| `--ipv6-gw GW` (`IPV6_GW`) | — | IPv6-шлюз. Для шлюза `fe80::…` маршрут автоматически ставится как on-link |
| `--ipv6-if IF` (`IPV6_IF`) | авто | сетевой интерфейс. По умолчанию берётся тот, через который идёт IPv4 default route |
| `--link-mbit N` (`LINK_MBIT`) | 1000 | скорость канала, если ethtool её не сообщает (на virtio так бывает часто) |
| `--forwarding` (`FORWARDING=1`) | выкл | включает ip_forward (для схем вроде WireGuard) |
| `--conntrack-skip` (`CONNTRACK_SKIP=1`) | выкл | NOTRACK для входящего трафика VPN-портов, экономит conntrack |
| `--dev-tools` (`DEV_TOOLS=1`) | выкл | дополнительно ставит build-essential, git и Node.js 24 |
| `--tz ZONE` (`TZ`) | UTC | часовой пояс |
| `--finalize` (`FINALIZE=1`) | — | фаза 2 |
| `--print-tuning [--fake-cpus N --fake-mem-mb N]` | — | только показывает рассчитанный тюнинг, ничего не меняет |

## Что меняется на сервере

- **SSH.** Вход только по ключу, root входит тоже только по ключу. SSH работает на новом порту. Отключена socket-активация `ssh.socket`, потому что в 24.04 она игнорирует `Port`. Удалён `50-cloud-init.conf`, который разрешает пароли, и закомментированы такие же строки в основном `sshd_config`.
- **ufw.** Входящие закрыты, кроме SSH, `VPN_PORTS` (tcp и udp, IPv4 и IPv6) и `NODE_PORT` с адресов `PANEL_IP`.
- **fail2ban.** Работает через journald (`backend = systemd`, `journalmatch` на `ssh.service`). Без этого на 24.04 он не видит попыток входа.
- **Пакеты.** Делается полное обновление и ставится HWE-ядро (`linux-generic-hwe-24.04`).
- **snap.** Сначала удаляются все snap-пакеты, затем сам snapd. Его повторная установка запрещена apt-pin.
- **Docker.** Убунтовские `docker.io`, `containerd`, `runc` и compose v1 удаляются. Ставится `docker-ce` из `download.docker.com`, убунтовские пакеты запрещены pin. Включена ротация логов (`local`, 20 МБ × 3) и `live-restore`.
  - Глобальный `"ip": "127.0.0.1"` намеренно не задан. remnanode работает в `network_mode: host`, поэтому правила ufw действуют на него напрямую.
  - ⚠️ Порты, опубликованные через `-p` из контейнеров в режиме bridge, **обходят ufw**. Не публикуйте лишнего.
- **Лишние службы.** Отключены ModemManager, multipathd, udisks2, apport, packagekit и motd-news.
- **Система.** journald ограничен 500 МБ. Включены irqbalance, fstrim.timer и chrony. Автоперезагрузка unattended-upgrades отключена.
- **IPv6.** Пишется в отдельный netplan-файл `60-vpn-node-ipv6.yaml`. Перед `netplan apply` скрипт проверяет, что IPv4 после слияния конфигов не потерялся. Если потерялся, файл удаляется и ничего не применяется.

## Автотюнинг при каждой загрузке

`vpn-node-tune.service` (oneshot, до старта docker) при каждой загрузке запускает `/usr/local/sbin/vpn-node-tune`. Скрипт заново определяет количество ядер, объём RAM и скорость канала (через ethtool, иначе берётся `LINK_MBIT` из `/etc/default/vpn-node-tune`) и пересчитывает настройки. После ресайза VM достаточно перезагрузиться.

- **Буферы сокетов.** `rmem_max`, `wmem_max` и максимум `tcp_rmem`/`tcp_wmem` считаются как BDP (скорость × 200 мс). Ограничения: не больше RAM/32, минимум 4 МБ, максимум 256 МБ.
- **Память стеков.** `tcp_mem` составляет 6/12/20 % RAM, `udp_mem` 4/8/12 % (значения в страницах).
- **UDP для QUIC, XHTTP и Hysteria.** `udp_rmem_min` и `udp_wmem_min` равны 16 КБ, `rmem_default` и `wmem_default` берутся из расчёта буфера.
- **conntrack.** `nf_conntrack_max` = 65536 на каждый ГБ RAM (минимум 65536), hashsize = max/4. Таймауты укорочены: established 1 ч, time_wait и close_wait 15 с, udp 30/120 с.
- **TCP.** BBR + fq, `tcp_notsent_lowat=16384`, `slow_start_after_idle=0`, `mtu_probing=1`, `fastopen=3`. Keepalive 300/30/5 для долгих прокси-соединений. Также `fin_timeout=15`, `tw_reuse`, диапазон портов 1024–65535.
- **Очереди.** `netdev_max_backlog` и `netdev_budget` масштабируются по скорости канала и ядрам. `somaxconn` и `tcp_max_syn_backlog` = 4096 × ядра (до 65535).
- **Лимиты.** `file-max`, `nofile` (1M) и `min_free_kbytes` (1,5 % RAM, от 16 МБ до 256 МБ) считаются от RAM.
- **zram.** При RAM ≤ 2,5 ГБ размер RAM/2, при ≤ 8,5 ГБ размер RAM/4, при большем объёме zram выключен. Изменение действует со следующей загрузки.
- **Сетевая карта.** RX/TX ring-буферы поднимаются до максимума, включаются GRO, GSO и TSO, `txqueuelen` ставится 10000. RPS, RFS и XPS распределяются по всем ядрам на каждую очередь.
- **CPU.** Governor `performance` включается, если гипервизор даёт им управлять.

Посмотреть, что будет рассчитано для другого железа:

```bash
bash install.sh --print-tuning --fake-cpus 2 --fake-mem-mb 4096 --link-mbit 1000
```

| CPU/RAM/канал | buf_max | tcp_mem (стр.) | conntrack_max | backlog | somaxconn | min_free | zram |
|---|---|---|---|---|---|---|---|
| 1 / 1 ГБ / 1G | 23 МБ | 15728 31457 52428 | 65536 | 25000 | 4096 | 16 МБ | RAM/2 |
| 2 / 4 ГБ / 1G | 23 МБ | 62914 125829 209715 | 262144 | 25000 | 8192 | 61 МБ | RAM/4 |
| 4 / 8 ГБ / 1G | 23 МБ | 125829 251658 419430 | 524288 | 25000 | 16384 | 123 МБ | RAM/4 |
| 16 / 32 ГБ / 10G | 238 МБ | 503316 1006632 1677721 | 2097152 | 250000 | 65535 | 256 МБ | выкл |

## Откат

- **Тюнинг.** `systemctl disable --now vpn-node-tune`, затем `rm /etc/sysctl.d/90-vpn-node.conf /etc/modprobe.d/vpn-node-conntrack.conf /etc/systemd/zram-generator.conf` и перезагрузка.
- **NOTRACK.** Удалите из `/etc/ufw/before.rules` и `/etc/ufw/before6.rules` блок `# BEGIN vpn-node-notrack … # END`, затем `ufw reload`.
- **SSH.** Настройки лежат в `/etc/ssh/sshd_config.d/00-vpn-node.conf`. Временно вернуть порт 22 можно так: `echo 'Port 22' >> /etc/ssh/sshd_config.d/00-vpn-node.conf && ufw allow 22/tcp && systemctl restart ssh`.
- **IPv6.** `rm /etc/netplan/60-vpn-node-ipv6.yaml && netplan apply`.
- **Потерян доступ по SSH.** Зайдите через VNC-консоль хостинга и выполните `ufw disable`.

Скрипт идемпотентен, повторный запуск безопасен. Секретов в нём нет.
