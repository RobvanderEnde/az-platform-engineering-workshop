#!/bin/sh
set -e

# Substitute BACKEND_FQDN into the nginx config template
# The variable is injected by Container Apps from the env var
: "${BACKEND_FQDN:?BACKEND_FQDN environment variable is required}"

envsubst '${BACKEND_FQDN}' < /etc/nginx/conf.d/default.conf.template > /etc/nginx/conf.d/default.conf

# Start nginx in foreground
exec nginx -g 'daemon off;'
