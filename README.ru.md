# Obscura

Obscura — это серверный набор инструментов на базе Docker Compose для собственной VPN-инфраструктуры.
Он совместим с некоторыми серверными структурами данных Amnezia, но не является форком приложения Amnezia.

Английская версия: [README.md](README.md)

Текущая версия проекта: `0.21.1`

## Что Это Такое

Обычно Amnezia управляется через настольный или мобильный клиент, который подключается к серверу и создает там контейнеры.
Obscura предназначена для тех, кто хочет управлять серверной частью напрямую через обычные Docker Compose команды.

На практике Obscura помогает:
- запустить приватный DNS-резолвер для контейнеров и VPN-сервисов
- при необходимости запустить SOCKS5, AWG и Xray из Compose
- сохранить полезную совместимость с существующими серверными данными Amnezia
- безопаснее проверять и мигрировать поддерживаемое состояние сервисов Amnezia
- добавить необязательные blacklist-правила на хосте для Docker-трафика контейнеров

Чтобы попробовать проект, не нужно понимать все внутренние детали протоколов.
Но нужно уверенно пользоваться Linux shell, Docker и `sudo`.

## Что Уже Работает

Реализовано:
- приватный DNS-резолвер на базе Unbound
- необязательный SOCKS5-прокси
- необязательный AWG-сервис
- необязательный Xray-сервис
- необязательный хостовый blacklist-инструмент
- безопасная команда миграции для поддерживаемого состояния Amnezia AWG, Xray и SOCKS5

Пока запланировано:
- Compose-сервисы для WireGuard, OpenVPN, IPsec и других VPN-протоколов
- более широкая проверка на реальных Linux-хостах и разных настройках межсетевого экрана Docker

## Требования

- Linux-сервер или Docker-хост с Linux-окружением
- Docker Engine
- Docker Compose plugin
- `sudo` доступ для установки, миграции и сетевых задач на хосте

Поддержка IPv6 в Docker полезна, но не обязательна для базовой работы по IPv4.

## Быстрый Старт

Склонируйте репозиторий:

```bash
git clone --recurse-submodules https://github.com/alloploha/amnezia-obscura-compose.git
cd amnezia-obscura-compose
```

Если на Debian или Ubuntu нет `docker compose`:

```bash
sudo bash scripts/install-docker-compose.sh
```

Проверьте готовность хоста:

```bash
bash scripts/check-host.sh
```

Запустите стек по умолчанию:

```bash
docker compose up -d --build
docker compose ps
```

Стек по умолчанию запускает DNS-резолвер.

## Дополнительные Сервисы

Запустить SOCKS5:

```bash
docker compose --profile socks5proxy up -d --build
```

Запустить Xray:

```bash
docker compose --profile xray up -d --build
```

Запустить AWG:

```bash
docker compose --profile awg up -d --build
```

Для AWG на хосте нужны `/dev/net/tun` и поддержка Docker `NET_ADMIN`.
Если вы не уверены, сначала запустите `bash scripts/check-host.sh`.

## Работа Рядом С Amnezia

Obscura может работать рядом с существующей установкой Amnezia для поддерживаемых сервисов.
Для такого режима используйте Compose overlay для Amnezia:

```bash
./scripts/compose-amnezia.sh
```

Перед миграцией live-состояния Amnezia сначала проверьте и сохраните snapshot:

```bash
sudo bash scripts/obscura.sh migrate audit --service all
sudo bash scripts/obscura.sh migrate snapshot --service xray
```

Перед реальной миграцией выполните dry run:

```bash
sudo bash scripts/obscura.sh migrate migrate --service xray --target-container obscura-xray-1 --dry-run
```

По умолчанию migration wrapper создает backups в `/srv/obscura/backups/amnezia-migration` и не печатает ключевой материал.

## Проверка

Запустить стандартные проверки репозитория:

```bash
bash scripts/test-all.sh
```

Запустить проверки Docker-сборки:

```bash
bash scripts/test-all.sh --docker
```

Дополнительные проверки при необходимости:

```bash
bash scripts/test-all.sh --xray-migration
bash scripts/test-all.sh --socks5-compat
bash scripts/test-all.sh --migration-workflow
```

Некоторым проверкам нужен доступ к Docker, и они могут выполняться несколько минут.

## Blacklist Tool

Установить необязательный blacklist-модуль:

```bash
sudo sh scripts/install-blacklist.sh
```

Обновить установленные blacklist-правила:

```bash
sudo sh scripts/refresh-blacklist.sh
```

Удалить systemd-интеграцию blacklist:

```bash
sudo sh scripts/uninstall-blacklist.sh
```

## Где Читать Подробности

Более глубокие технические детали, архитектура, правила совместимости и инструкции для AI agents находятся в [AGENTS.md](AGENTS.md).
Пользовательская документация blacklist-модуля находится в [blacklist/README.md](blacklist/README.md).
