####################################################
# Local OpenResty (nginx + lua) server
# Equivalent to nginx.dockerfile but with local
# WordPress config.
# ##################################################

FROM openresty/openresty:alpine AS nginx

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
    && chown -R hale:hale /usr/local/openresty/nginx

# Copy configuration, Lua module and error pages
COPY opt/nginx/nginx.conf          /usr/local/openresty/nginx/conf/nginx.conf
COPY opt/nginx/localwordpress.conf /usr/local/openresty/nginx/conf/conf.d/
COPY opt/scripts/firewall.lua      /usr/local/openresty/nginx/lua/firewall.lua
COPY opt/nginx/error-pages/        /usr/local/openresty/nginx/html/error-pages/

# Switch to non-root user (numeric UID for consistency with production)
USER 1002

EXPOSE 443
EXPOSE 8080

# Start in the foreground
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]


####################################################
# Lua test suite image
# luarocks, busted, and luasocket (needed for
# integration specs that connect to Redis directly).
# ##################################################

FROM openresty/openresty:alpine AS test

RUN apk add --no-cache \
        lua5.1-dev \
        luarocks5.1 \
        gcc \
        musl-dev \
    && luarocks-5.1 install busted \
    && luarocks-5.1 install luasocket \
    && luarocks-5.1 install lua-cjson \
    && apk del gcc musl-dev lua5.1-dev \
    && rm -rf /root/.cache

WORKDIR /app

COPY opt/lua/  .

ENTRYPOINT ["busted"]
