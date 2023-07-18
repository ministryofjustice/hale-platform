FROM --platform=linux/amd64 nginxinc/nginx-unprivileged:latest

# Extend NGINX configurations to support WordPress Multisite
# and apply our own custom configurations
COPY opt/nginx/nginx.conf /etc/nginx/
COPY opt/nginx/wordpress.conf /etc/nginx/conf.d/
