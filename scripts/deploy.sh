#!/usr/bin/env bash
# Доставка статического сайта на devops-vm
# Использование: scripts/deploy.sh [--dry-run]

set -euo pipefail

REMOTE="devops"
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
WINDOWS_HOME="$(cygpath -u "$USERPROFILE")"
CA_CERT="${WINDOWS_HOME}/devops.crt"
SSH_CONFIG="${WINDOWS_HOME}/.ssh/config"
SSH_KEY="${WINDOWS_HOME}/.ssh/devops_vm"

# Определяем корень репозитория — скрипт работает из любой папки
REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
LOCAL_DIR="${REPO_ROOT}/site/"
cd "$REPO_ROOT"

# Разбор аргументов
DRY_RUN=false
if [[ "$#" -gt 1 ]]; then
    echo "Ошибка: допустимый аргумент только --dry-run" >&2
    exit 1
fi

if [[ "$#" -eq 1 ]]; then
    if [[ "$1" == "--dry-run" ]]; then
        DRY_RUN=true
    else
        echo "Ошибка: неизвестный аргумент $1" >&2
        exit 1
    fi
fi

# Проверяем наличие главной страницы
if [[ ! -f "${LOCAL_DIR}index.html" ]]; then
    echo "Ошибка: ${LOCAL_DIR}index.html не найден" >&2
    exit 1
fi

# Запрещаем деплой при любых незакоммиченных изменениях
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Ошибка: в репозитории есть незакоммиченные изменения" >&2
    exit 1
fi

# Проверяем, что SSH не запросит пароль интерактивно
export RSYNC_RSH="ssh -F ${SSH_CONFIG} -i ${SSH_KEY} -o BatchMode=yes -o ConnectTimeout=10"

# Синхронизация
RSYNC_ARGS=(-avz --delete --chmod=D755,F644)
if [[ "$DRY_RUN" == true ]]; then
    RSYNC_ARGS+=(--dry-run)
fi

rsync "${RSYNC_ARGS[@]}" "$LOCAL_DIR" "${REMOTE}:${REMOTE_DIR}/"

# В режиме dry-run сервер не проверяем
if [[ "$DRY_RUN" == true ]]; then
    echo "Dry-run завершён: изменения на сервер не внесены."
    exit 0
fi

# Проверяем доступность сайта с проверкой сертификата
if ! curl --cacert "$CA_CERT" --fail --silent --show-error \
    --output /dev/null "$SITE_URL"; then
    echo "Ошибка: сайт недоступен или сертификат не прошёл проверку" >&2
    exit 1
fi

# Выводим короткий хеш развёрнутого коммита
echo "Деплой успешно завершён: $(git rev-parse --short HEAD)"
exit 0