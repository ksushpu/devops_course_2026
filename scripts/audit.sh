#!/usr/bin/env bash
set -uo pipefail

PASS=0; FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo " [OK]    $desc"; ((PASS++))
    else
        echo " [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"
        ((FAIL++))
    fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён" "no" "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no" "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"

actual_port="$(sudo sshd -T | awk '/^port/{print $2; exit}')"
if [[ "$actual_port" != "22" ]]; then
    check "SSH использует нестандартный порт" "non-22" "non-22"
else
    check "SSH использует нестандартный порт" "non-22" "22"
fi

check "Максимум попыток аутентификации равен 3" "3" "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"

incoming_policy="$(sudo ufw status verbose | grep 'Default:' | sed -E 's/.*Default: ([^ ]+) \(incoming\).*/\1/')"
check "Политика входящего трафика — deny" "deny" "$incoming_policy"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "              %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"

# а) служба nginx активна
# Команда systemctl is-active выводит "active", если служба работает.
status_nginx="$(systemctl is-active nginx)"
check "Служба Nginx активна" "active" "$status_nginx"

# б) конфигурация nginx синтаксически корректна
# nginx -t пишет результат в stderr/stdout. Нам важен код возврата.
# Если код 0 -> "syntax ok", иначе -> "syntax error".
# Используем конструкцию || для перехвата ошибки, чтобы не остановить скрипт при set -e (хотя у нас set -u, но лучше явно обработать).
if sudo nginx -t > /dev/null 2>&1; then
    conf_status="syntax ok"
else
    conf_status="syntax error"
fi
check "Конфигурация Nginx синтаксически корректна" "syntax ok" "$conf_status"

# в) сертификат истекает не ранее чем через 30 дней
# openssl x509 -checkend <seconds> возвращает 0 (истина), если срок больше seconds.
# 30 дней = 30 * 24 * 60 * 60 = 2592000 секунд.
CERT_PATH="/etc/ssl/certs/devops.crt"
# Проверяем наличие файла сначала, чтобы избежать ошибки openssl, если файла нет
if [[ -f "$CERT_PATH" ]]; then
    if openssl x509 -in "$CERT_PATH" -noout -checkend 2592000 > /dev/null 2>&1; then
        cert_validity="valid for >= 30 days"
    else
        cert_validity="expires soon or already expired"
    fi
else
    cert_validity="file not found"
fi
check "Сертификат действителен минимум 30 дней" "valid for >= 30 days" "$cert_validity"

# г) нет файлов с правом записи всем И права ключа равны 600
SITE_DIR="/var/www/devops-site"
# find ... -perm -o+w находит файлы, где бит записи установлен для others.
# Если таких файлов нет, вывод пустой.
world_writable_files=$(find "$SITE_DIR" -perm -o+w 2>/dev/null)
KEY_PATH="/etc/ssl/private/devops.key"
key_perms=$(sudo stat -c '%a' "$KEY_PATH" 2>/dev/null || echo "missing")

if [[ -z "$world_writable_files" ]] && [[ "$key_perms" == "600" ]]; then
    security_check="secure"
else
    security_check="violation detected"
fi

check "Нет world-writable файлов в сайте и права ключа 600" "secure" "$security_check"

echo "Итого: OK=$PASS, FAIL=$FAIL"

if (( FAIL > 0 )); then
    exit 1
fi
exit 0