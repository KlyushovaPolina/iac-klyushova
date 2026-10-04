#!/usr/bin/env bash
set -euo pipefail

PREFIX=klyushova-01
ZONE_A=ru-central1-a
ZONE_B=ru-central1-b
CIDR_A=10.11.1.0/24
CIDR_B=10.11.2.0/24
APP_PORT=8003
GREETING=labwork
BOOT_SIZE=15
IMAGE_FAMILY=ubuntu-2404-lts

VM_COUNT="${VM_COUNT:-2}"

if [[ $# -gt 0 ]]; then
    if [[ "$1" != "--vm-count" ]]; then
        echo "Ошибка: неизвестный аргумент: $1" >&2
        exit 1
    fi

    if [[ $# -lt 2 ]]; then
        echo "Ошибка: для --vm-count нужно указать количество машин" >&2
        exit 1
    fi

    VM_COUNT="$2"
fi

if ! [[ "$VM_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "Ошибка: количество машин должно быть положительным целым числом" >&2
    exit 1
fi


echo "==> сеть и подсети"

if yc vpc network get "$PREFIX-net" >/dev/null 2>&1; then
  echo "Сеть $PREFIX-net уже существует"
else
  yc vpc network create --name "$PREFIX-net"
fi

if yc vpc subnet get "$PREFIX-subnet-a" >/dev/null 2>&1; then
  echo "Подсеть $PREFIX-subnet-a уже существует"
else
  yc vpc subnet create --name "$PREFIX-subnet-a" --network-name "$PREFIX-net" \
    --zone "$ZONE_A" --range "$CIDR_A"
fi

if yc vpc subnet get "$PREFIX-subnet-b" >/dev/null 2>&1; then
  echo "Подсеть $PREFIX-subnet-b уже существует"
else
  yc vpc subnet create --name "$PREFIX-subnet-b" --network-name "$PREFIX-net" \
    --zone "$ZONE_B" --range "$CIDR_B"
fi

echo "==> NAT-шлюз"

NAT_NAME="$PREFIX-nat"

if yc vpc gateway get "$NAT_NAME" >/dev/null 2>&1; then
  echo "NAT-шлюз $NAT_NAME уже существует"
else
  yc vpc gateway create \
    --name "$NAT_NAME"
fi

echo "==> таблица маршрутизации"

ROUTE_TABLE_NAME="$PREFIX-rt"

GW_ID=$(yc vpc gateway get "$NAT_NAME" --format json | jq -r '.id')

if yc vpc route-table get "$ROUTE_TABLE_NAME" >/dev/null 2>&1; then
  echo "Таблица маршрутизации $ROUTE_TABLE_NAME уже существует"
else
  yc vpc route-table create \
    --name "$ROUTE_TABLE_NAME" \
    --network-name "$PREFIX-net" \
    --route "destination=0.0.0.0/0,gateway-id=$GW_ID"
fi

yc vpc subnet update \
  --name "$PREFIX-subnet-a" \
  --route-table-name "$ROUTE_TABLE_NAME"

echo "==> файл настройки из шаблона"
SSH_KEY=$(cat ~/.ssh/id_ed25519.pub)
export APP_PORT GREETING SSH_KEY
envsubst '${APP_PORT} ${GREETING} ${SSH_KEY}' \
  < hw-01/cloud-init.tpl.yaml > hw-01/cloud-init.yaml

echo "==> сервер приложения"

APP_VM_NAME="$PREFIX-app-private"

if yc compute instance get "$APP_VM_NAME" >/dev/null 2>&1; then
  echo "Сервер приложения $APP_VM_NAME уже существует"
else
  yc compute instance create \
    --name "$APP_VM_NAME" \
    --zone "$ZONE_A" \
    --platform standard-v3 \
    --cores=2  --core-fraction=20 --memory=2 \
    --preemptible \
    --create-boot-disk image-folder-id=standard-images,image-family="$IMAGE_FAMILY",type=network-hdd,size="$BOOT_SIZE" \
    --network-interface subnet-name="$PREFIX-subnet-a" \
    --hostname "$APP_VM_NAME" \
    --metadata-from-file user-data=hw-01/cloud-init.yaml
fi

echo "==> машины"
ZONES=("$ZONE_A" "$ZONE_B")
SUBNETS=("$PREFIX-subnet-a" "$PREFIX-subnet-b")

for i in $(seq 1 "$VM_COUNT"); do
  idx=$(( (i - 1) % 2 ))

  VM_NAME="$PREFIX-app-$i"

  if yc compute instance get "$VM_NAME" >/dev/null 2>&1; then
    echo "Виртуальная машина $VM_NAME уже существует"
    continue
  fi

  yc compute instance create \
    --name "$PREFIX-app-$i" \
    --zone "${ZONES[$idx]}" \
    --platform standard-v3 \
    --cores=2 --core-fraction=20 --memory=2 \
    --preemptible \
    --create-boot-disk image-folder-id=standard-images,image-family="$IMAGE_FAMILY",type=network-hdd,size="$BOOT_SIZE" \
    --network-interface subnet-name="${SUBNETS[$idx]}",nat-ip-version=ipv4 \
    --hostname "$PREFIX-app-$i" \
    --metadata-from-file user-data=hw-01/cloud-init.yaml
done

echo "==> целевая группа"

if yc load-balancer target-group get "$PREFIX-tg" >/dev/null 2>&1; then
  echo "Целевая группа $PREFIX-tg уже существует"
else
  TARGETS=""

  for i in $(seq 1 "$VM_COUNT"); do
    idx=$(( (i - 1) % 2 ))
    IP=$(yc compute instance get "$PREFIX-app-$i" --format json \
      | jq -r '.network_interfaces[0].primary_v4_address.address')
    TARGETS="$TARGETS --target subnet-name=${SUBNETS[$idx]},address=$IP"
  done
  yc load-balancer target-group create --name "$PREFIX-tg" $TARGETS
fi

echo "==> балансировщик"

if yc load-balancer network-load-balancer get "$PREFIX-lb" >/dev/null 2>&1; then
  echo "Балансировщик $PREFIX-lb уже существует"
else
  TG_ID=$(yc load-balancer target-group get --name "$PREFIX-tg" --format json | jq -r .id)

  yc load-balancer network-load-balancer create \
    --name "$PREFIX-lb" \
    --region-id ru-central1 \
    --listener name=http,port=80,target-port="$APP_PORT",external-ip-version=ipv4 \
    --target-group target-group-id="$TG_ID",healthcheck-name=http,healthcheck-interval=2s,healthcheck-timeout=1s,healthcheck-unhealthythreshold=2,healthcheck-healthythreshold=2,healthcheck-http-port="$APP_PORT",healthcheck-http-path=/
fi
