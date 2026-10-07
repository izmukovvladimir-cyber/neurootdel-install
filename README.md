# НЕЙРООТДЕЛ AI Agent -- Quick Start

Установщик персонального AI-агента на базе Claude Code с Telegram-интерфейсом.

Одна команда -- и у вас свой AI-агент на VPS, который отвечает в Telegram.

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/izmukovvladimir-cyber/neurootdel-install/main/install.sh -o /root/neurootdel-install.sh && sudo bash /root/neurootdel-install.sh
```

## Что устанавливается

| Компонент | Версия | Назначение |
|---|---|---|
| Node.js | 22.x | Среда для Claude Code CLI |
| Python | 3.12+ | Скрипты |
| Claude Code | latest | AI-агент (Anthropic, Opus -- код/ревью, Sonnet -- субагенты) |
| Bun + [Telegram-плагин](https://github.com/izmukovvladimir-cyber/dashi-plugin-claude-code) | latest (main) | Связь агента с Telegram |
| Caddy | latest | Веб-сервер для вебхуков |
| UFW + fail2ban | -- | Безопасность сервера |

Дополнительно: curl, wget, git, jq, htop, tmux, build-essential.

## Архитектура

```
Telegram --> Bot API --> Telegram-плагин (MCP-канал) --> Claude Code --> ответ
                                     |
                              channel.env
                           (bot token,
                            user ID,
                            workspace)
```

Плагин работает как systemd-сервис `channel-jarvis`: Claude Code запущен в tmux, плагин получает сообщения из Telegram и передаёт их в ту же сессию, ответ уходит обратно в Telegram.

## После установки

1. **Авторизуйте Claude Code** -- запустите `claude` в терминале, пройдите OAuth-авторизацию (Anthropic Max подписка, $100-200/мес)

2. **Настройте бота** -- откройте `/etc/vladimir-plugin/jarvis/channel.env` (от root; на серверах, поставленных до переименования, `/etc/dashi-plugin/jarvis/channel.env`):
   - Создайте бота через [@BotFather](https://t.me/BotFather) в Telegram
   - `TELEGRAM_BOT_TOKEN=<токен бота>`
   - Свой Telegram user ID (из [@userinfobot](https://t.me/userinfobot)) впишите в ОБЕ строки:
     `TELEGRAM_ALLOWED_USER_IDS=<id>` и `TELEGRAM_ALLOWED_CHAT_IDS=<id>` (без второй бот молча не видит личку)
   - Вопросы «разрешить команду?» (permission relay) получает только владелец: плагин берёт их адресатов из `TELEGRAM_ALLOWED_USER_IDS`. Не вписывайте туда чужие ID. Без `TELEGRAM_ALLOWED_USER_IDS` плагин не запустится (встроенного ID владельца в нём нет).

3. **Запустите агента**:
   ```bash
   sudo systemctl enable channel-jarvis
   sudo systemctl restart channel-jarvis
   ```

4. **Напишите боту** -- агент ответит

## Требования

- **ОС:** Ubuntu 22.04 или 24.04
- **Архитектура:** amd64 или arm64
- **Ресурсы:** минимум 2 vCPU, 4 GB RAM
- **Подписка:** Anthropic Max ($100-200/мес) -- оплата картой на сайте Anthropic

## Рекомендации по VPS

Для запуска агента нужен VPS с Ubuntu. Проверенные провайдеры:

| Провайдер | Цена от | Локация | Ссылка |
|---|---|---|---|
| Timeweb Cloud | ~500 руб/мес | Россия, Нидерланды | [timeweb.cloud](https://timeweb.cloud/r/pt392094) |
| VDSina | ~500 руб/мес | Россия, Нидерланды | [vdsina.com](https://www.vdsina.com/?partner=6x47zemriu8q) |
| DigitalOcean | $12/мес | Европа, США | [digitalocean.com](https://m.do.co/c/63cded1ddfa3) |
| Hetzner | 7.99 EUR/мес | Германия, Финляндия | [hetzner.com/cloud](https://hetzner.com/cloud) |

Для пользователей из РФ рекомендуем Timeweb Cloud или VDSina (оплата рублями, серверы в РФ и EU).

## Структура файлов (v2.2.0 dual-path)

Пользователь агента `neurootdel` (`/home/neurootdel`). Сервер, где уже стоит прежняя
установка с пользователем `edgelab`, при повторном запуске остаётся на `edgelab` и старых путях.

```
~/.claude/                     # Anthropic CLI home
  CLAUDE.md                    # stub, указывает на agent workspace
  settings.json                # 400K context + permissions
  plugins/                     # Superpowers и другие плагины
    config.json                # реестр плагинов
    superpowers/               # git clone izmukovvladimir-cyber/superpowers
  mcp.json                     # Day-2 expansion point

~/.claude-lab/{agent}/.claude/ # Agent workspace (например, jarvis)
  CLAUDE.md                    # identity, роль, коммуникация
  core/
    USER.md                    # профиль владельца
    rules.md                   # границы и запреты
    MEMORY.md                  # архив
    LEARNINGS.md               # уроки из ошибок
    hot/handoff.md             # последние 10 записей
    hot/recent.md              # полный журнал
    warm/decisions.md          # решения за 14 дней
  skills/                      # 10 скиллов
    groq-voice/                # транскрипция голоса
    markdown-new/              # markdown extraction
    perplexity-research/       # web research
    datawrapper/               # графики
    excalidraw/                # диаграммы
    youtube-transcript/        # YouTube transcripts
    onboarding/                # 5-вопросный wizard (stub)
    self-compiler/             # self-tuning (stub)
    quick-reminders/           # cron-based reminders
    present/                   # HTML-презентации
  scripts/                     # cron ротации памяти
  logs/

~/.claude-lab/jarvis/.claude/dashi-plugin-claude-code/   # Telegram-канал (плагин)
  plugin/                      # рабочий каталог сессии Claude Code
/etc/vladimir-plugin/jarvis/channel.env   # токен бота, ваш ID, ключ Groq
/etc/systemd/system/channel-jarvis.service
```

Для продвинутой архитектуры с памятью, скиллами и автоматизацией смотрите: [public-architecture-claude-code](https://github.com/izmukovvladimir-cyber/public-architecture-claude-code)

```
~/.claude/                     # Продвинутая архитектура (опционально)
  CLAUDE.md                    # SOUL: identity, роль, характер
  settings.json                # CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000
  core/
    USER.md                    # Профиль владельца (@include)
    rules.md                   # Границы и запреты (@include)
    AGENTS.md                  # Модели, субагенты (on-demand)
    MEMORY.md                  # Архив (on-demand)
    LEARNINGS.md               # Уроки из ошибок (on-demand)
    warm/decisions.md           # Решения за 14 дней (@include)
    hot/handoff.md             # Последние 10 записей (@include)
    hot/recent.md              # Полный журнал (НЕ в контексте)
  tools/TOOLS.md               # Серверы, порты, API (on-demand)
  skills/                      # Скиллы агента
  hooks/                       # Git и session hooks
  scripts/                     # Cron-скрипты ротации памяти
```

4 файла загружаются при старте через @include (~7% от 400К). Остальные -- по запросу через Read tool.

## Настройка контекстного окна

Claude Code имеет базовое окно 1М токенов, но качество ответов лучше при 400К. Рекомендуем:

```bash
# Создайте settings.json (от имени пользователя, не root)
cat > ~/.claude/settings.json << 'EOF'
{
  "env": {
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "400000"
  }
}
EOF
```

Агент будет автоматически сжимать контекст при достижении 400К токенов.

## Полезные команды

```bash
# Статус агента
sudo systemctl status channel-jarvis

# Логи агента
sudo journalctl -u channel-jarvis -f

# Экран сессии Claude Code
sudo -u neurootdel tmux -L channel-jarvis capture-pane -p -t channel-jarvis | tail -30

# Перезапуск после изменения channel.env
sudo systemctl restart channel-jarvis

# Вернуть старый claude-gateway (если сервер ставился раньше, на шлюзе)
sudo bash install.sh --rollback

# Обновить Claude Code
claude update
```

## Сайт

[https://vladimir-izhmukov.ru](https://vladimir-izhmukov.ru)

## Лицензия

MIT
