FROM openresty/openresty:alpine

# Install additional Alpine packages
RUN apk update && apk add curl ca-certificates

# Create non-root user (UID/GID 1002 to match org standard)
RUN addgroup -g 1002 -S hale \
    && adduser -u 1002 -D -S -G hale -h /var/cache/nginx hale

# Create required directories with correct ownership
RUN mkdir -p /usr/local/openresty/nginx/logs \
    && mkdir -p /usr/local/openresty/nginx/client_body_temp \
    && mkdir -p /usr/local/openresty/nginx/proxy_temp \
    && mkdir -p /usr/local/openresty/nginx/fastcgi_temp \
    && mkdir -p /usr/local/openresty/nginx/uwsgi_temp \
    && mkdir -p /usr/local/openresty/nginx/scgi_temp \
    && mkdir -p /usr/local/openresty/nginx/cache \
    && chown -R hale:hale /usr/local/openresty/nginx

# Copy configuration, Lua module and error pages
COPY opt/nginx/nginx.conf          /usr/local/openresty/nginx/conf/nginx.conf
COPY opt/nginx/wordpress.conf      /usr/local/openresty/nginx/conf/conf.d/
COPY opt/lua/firewall.lua          /usr/local/openresty/nginx/lua/firewall.lua
COPY opt/lua/firewall              /usr/local/openresty/nginx/lua/firewall
COPY opt/nginx/error-pages/        /usr/local/openresty/nginx/html/error-pages/

# Switch to non-root user (must use numeric UID for K8s runAsNonRoot verification)
USER 1002

EXPOSE 8080

# Start in the foreground
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
