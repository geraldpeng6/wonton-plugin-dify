#!/bin/bash
# 来自上游 docker/nginx/docker-entrypoint.sh，去掉了 HTTPS 和 certbot 分支：
# TLS 由核心网关负责，这里只做 http。模板经 envsubst 落到正式路径后启动 nginx。
# envsubst 只替换容器里存在的变量，避免把 nginx 自己的 $http_host、$remote_addr 替换成空。
set -e

env_vars=$(printenv | cut -d= -f1 | sed 's/^/$/g' | paste -sd, -)

envsubst "$env_vars" < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
envsubst "$env_vars" < /etc/nginx/proxy.conf.template > /etc/nginx/proxy.conf
envsubst "$env_vars" < /etc/nginx/conf.d/default.conf.template > /etc/nginx/conf.d/default.conf

exec nginx -g 'daemon off;'
