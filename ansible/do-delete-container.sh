#!/usr/bin/env bash

set -e

path="$(readlink -f "$0")"
owndir="$(dirname "$path")"

customer_name="$1"
domain="$2"

cd "$owndir"

git pull

[[ ! -e "custom_domain" ]] || domain="$(cat "custom_domain")"
if [[ -z "$domain" ]]; then
    domain="$(find /etc/letsencrypt/live/ -type d -name "${customer_name}.*" -printf "%f")"
    # remove customer name
    domain="${domain#*.}"
    if [[ -z "$domain" ]]; then
        echo "Unable to find certificate for customer ${customer_name}"
        exit 0
    fi
else
    extra="$extra le_domain=$domain"
    echo "Using custom domain $domain."
fi

ansible-playbook \
    -v -i hosts \
    -e "customer_name=$customer_name $extra le_domain=${domain}" \
    delete-container.yaml

sed -i "/${customer_name}-svr/d" hosts
