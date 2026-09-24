# claude-code-vpn-harness

Небольшой набор bash-скриптов для случая: **агентный harness (Claude Code и
подобные) блокирует любую команду с буквальным `sudo` в тексте, а поднять
OpenVPN легитимно требует passwordless sudo**.

Решение — не обходить хук, а вынести `sudo` из текста команды агента в
отдельный, version-controlled, аудируемый скрипт. Подробности и мотивация —
в [`SKILL.md`](./SKILL.md).

## Быстрый старт

```bash
git clone <this-repo> vpn-harness
cd vpn-harness

brew install openvpn
mkdir -p ~/.vpn
cp ~/Downloads/your-profile.ovpn ~/.vpn/default.ovpn
chmod 600 ~/.vpn/default.ovpn

# passwordless sudo — только для этих двух точных команд
echo "$(whoami) ALL=(ALL) NOPASSWD: $(command -v openvpn)" | sudo tee -a /etc/sudoers.d/openvpn-nopass
echo "$(whoami) ALL=(ALL) NOPASSWD: /usr/bin/pkill -f openvpn" | sudo tee -a /etc/sudoers.d/openvpn-nopass
echo "$(whoami) ALL=(ALL) NOPASSWD: /usr/bin/killall openvpn" | sudo tee -a /etc/sudoers.d/openvpn-nopass
sudo chmod 440 /etc/sudoers.d/openvpn-nopass

export VPN_CHECK_HOST=your-internal-gitlab.example.com

./scripts/git-push-vpn.sh
```

## Использование как Claude Code Skill

```bash
# в конкретном проекте
cp -r vpn-harness /path/to/your/project/.claude/skills/vpn-harness

# или глобально для всех проектов
cp -r vpn-harness ~/.claude/skills/vpn-harness
```

После этого Claude Code сам предложит использовать скрипты, когда увидит
таймаут `git push`/`git fetch` на внутренний хост или блокировку команды с
`sudo`.

## Файлы

| Файл | Назначение |
|---|---|
| `SKILL.md` | Определение навыка для Claude Code — когда и как применять |
| `scripts/vpn-run.sh` | Универсальная обёртка: поднять VPN → выполнить произвольную команду → погасить |
| `scripts/git-push-vpn.sh` | Специализация под `git push`, с short-circuit «нечего пушить» |
| `scripts/git-fetch-vpn.sh` | Специализация под `git fetch` |

## Конфигурация (env vars)

| Переменная | Обязательна | По умолчанию | Смысл |
|---|---|---|---|
| `VPN_CHECK_HOST` | да | — | Внутренний хост, по которому проверяем «уже на VPN?» |
| `VPN_CHECK_PORT` | нет | `22` | Порт для проверки доступности |
| `OVPN_CONFIG` | нет | `~/.vpn/default.ovpn` | Путь к `.ovpn`-профилю |
| `OPENVPN_BIN` | нет | автоопределение | Путь к бинарнику `openvpn` |
| `MAX_WAIT_SECONDS` | нет | `15` | Сколько ждать подключения |
| `KEEP_VPN` | нет | — | Если `1` — не гасить VPN после выполнения команды |

## Безопасность — что именно это даёт и не даёт

- Скрипты **не обходят** anti-privilege-escalation защиту harness'а — они
  меняют, *где* лежит `sudo` (в файле, не в команде агента), а не *что*
  разрешено делать через sudo.
- В `sudoers` разрешены ровно **две команды**: запуск `openvpn --config ...`
  и остановка (`killall openvpn`, с `pkill -f openvpn` как запасным вариантом) —
  не общий `NOPASSWD: ALL`. Просмотреть/отозвать: `/etc/sudoers.d/openvpn-nopass`.

  Останавливаем через `killall`: он сверяет только **имя процесса**.
  `pkill -f` сверяет всю строку запуска, и это здесь опасно — под шаблон
  попадает и сама команда остановки, и любая посторонняя команда, где просто
  упомянут openvpn. Дважды наблюдалось на практике: у агента обрывалась
  собственная команда, а в другой раз обёртка повышения прав погибала раньше
  демона — скрипт рапортовал об успехе, демон продолжал работать. Такой
  «осиротевший» демон занимает единственную сессию сертификата на сервере,
  и вторая машина подключиться уже не может.
- Скрипты не хранят и не логируют VPN-credentials — только путь до `.ovpn`
  файла (сам файл — вне репозитория, в `~/.vpn/`, `chmod 600`).

## Лицензия

MIT — см. [`LICENSE`](./LICENSE).
