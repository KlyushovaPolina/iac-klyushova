#!/usr/bin/env bash
set -u

PREFIX=klyushova-01
APP_PORT=8003
LB_NAME="$PREFIX-lb"
APP_VM_NAME="$PREFIX-app-private"

FAILED=0

echo "==> Проверка балансировщика"

LB_IP=$(yc load-balancer network-load-balancer get "$LB_NAME" --format json 2>/dev/null |
  jq -r '.listeners[0].address')

if [[ -z "$LB_IP" || "$LB_IP" == "null" ]]; then
  echo "✗ не удалось получить IP-адрес балансировщика"
  FAILED=1
else
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 "http://$LB_IP/")

  if [[ "$HTTP_CODE" == "200" ]]; then
    echo "✓ балансировщик отвечает: 200"
  else
    echo "✗ балансировщик отвечает: $HTTP_CODE"
    FAILED=1
  fi
fi


echo "==> Проверка распределения запросов"

RESPONDED_VMS=""

if [[ -n "${LB_IP:-}" && "${LB_IP:-}" != "null" ]]; then
  for _ in $(seq 1 10); do
    RESPONSE=$(curl -s --max-time 5 "http://$LB_IP/" || true)

    VM_NAME=$(echo "$RESPONSE" |
      grep -oE "${PREFIX}-app-[0-9]+" |
      head -n 1 || true)

    if [[ -n "$VM_NAME" ]]; then
      RESPONDED_VMS="${RESPONDED_VMS}${VM_NAME}"$'\n'
    fi
  done

  UNIQUE_VMS=$(printf '%s' "$RESPONDED_VMS" |
    sort -u |
    sed '/^$/d')

  VM_COUNT=$(printf '%s\n' "$UNIQUE_VMS" |
    sed '/^$/d' |
    wc -l)

  if [[ "$VM_COUNT" -gt 1 ]]; then
    echo "✓ ответили машины: $(printf '%s\n' "$UNIQUE_VMS" | paste -sd ', ' -)"
  else
    echo "✗ распределение не работает: ответила одна машина"
    if [[ -n "$UNIQUE_VMS" ]]; then
      echo "  ответила машина: $UNIQUE_VMS"
    else
      echo "  имя машины в ответе не найдено"
    fi
    FAILED=1
  fi
else
  echo "✗ распределение не проверено: отсутствует IP балансировщика"
  FAILED=1
fi


echo "==> Проверка сервера приложения"

APP_IP=$(yc compute instance get "$APP_VM_NAME" --format json 2>/dev/null |
  jq -r '.network_interfaces[0].primary_v4_address.address')

WEB_VM_NAME="$PREFIX-app-1"
WEB_IP=$(yc compute instance get "$WEB_VM_NAME" --format json 2>/dev/null |
  jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')

if [[ -z "$APP_IP" || "$APP_IP" == "null" ]]; then
  echo "✗ не удалось получить внутренний IP сервера приложения"
  FAILED=1
elif [[ -z "$WEB_IP" || "$WEB_IP" == "null" ]]; then
  echo "✗ не удалось получить внешний IP веб-сервера"
  FAILED=1
else
  if ssh -n "student@$WEB_IP" \
      "curl -fs --max-time 5 http://$APP_IP:$APP_PORT/ >/dev/null"; then
    echo "✓ сервер приложения доступен с $WEB_VM_NAME по внутреннему адресу"
  else
    echo "✗ сервер приложения недоступен с $WEB_VM_NAME"
    FAILED=1
  fi
fi

if [[ "$FAILED" -eq 0 ]]; then
  exit 0
else
  exit 1
fi
