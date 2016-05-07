#!/bin/bash

set -e

# generates secret configuration from real file and secret template
# @params template
# @
gen() {
    conf_dir="./confs"
    template=$1
    echo "Generating ${template}..."
    cat "${conf_dir}/${template}.in" > $template
    shift
    args=( "$@" )
    for ((i = 0; i < "${#args[@]}"; i += 2)); do
        echo -n "    ${args[$i]}: " >> $template
        cat "${conf_dir}/${args[$i+1]}" | base64 -w 0 >> $template
        echo "" >> $template
    done
}

gen "secret-kf-conf.yaml" "conf.yaml" "kf.yaml"
gen "secret-kf-kafkafeeder.yaml" "kafkafeeder.yaml" "kf-kafkafeeder.yaml"
gen "secret-tarsier-conf.yaml" "tarsier.yaml" "tarsier.yaml"
gen "secret-tarsier-kafkafeeder.yaml" "kafkafeeder.yaml" "tarsier-kafkafeeder.yaml"
gen "secret-tarsier-cert.yaml" "service.pem" "service.pem" "service.key" "service.key"

echo "== ALL DONE =="
