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

gen "secret-conf.yaml" "server.yaml" "conf.yaml"

echo "== ALL DONE =="
