#!/usr/bin/env bash
set -euo pipefail            # стоп на первой ошибке и на пустой переменной

PREFIX=klyushova-01

delete_if_exists() {
  local resource_type="$1"
  local resource_name="$2"

  if yc $resource_type get "$resource_name" >/dev/null 2>&1; then
    yc $resource_type delete "$resource_name"
  else
    echo "Ресурс $resource_name не найден, пропускаем"
  fi
}

delete_if_exists "load-balancer network-load-balancer" "$PREFIX-lb"
delete_if_exists "load-balancer target-group" "$PREFIX-tg"

yc compute instance list --format json |
  jq -r '.[].name' |
  { grep -E "^${PREFIX}-app-[0-9]+$" || true; } |
  while read -r name; do
    delete_if_exists "compute instance" "$name"
  done

delete_if_exists "compute instance" "$PREFIX-app-private"

yc vpc subnet update \
  --name "$PREFIX-subnet-a" \
  --disassociate-route-table

delete_if_exists "vpc route-table" "$PREFIX-rt"

delete_if_exists "vpc subnet" "$PREFIX-subnet-a"
delete_if_exists "vpc subnet" "$PREFIX-subnet-b"
delete_if_exists "vpc network" "$PREFIX-net"
