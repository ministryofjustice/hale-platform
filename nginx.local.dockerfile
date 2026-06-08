####################################################
# Local OpenResty (nginx + lua) server
# Equivalent to nginx.dockerfile but with local
# WordPress config.
# ##################################################

FROM openresty/openresty:1.31.1.1-alpine AS nginx

ENV ENV=local

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
COPY opt/lua/firewall.lua          /usr/local/openresty/nginx/lua/firewall.lua
COPY opt/lua/firewall              /usr/local/openresty/nginx/lua/firewall
COPY opt/nginx/error-pages/        /usr/local/openresty/nginx/html/error-pages/

# Switch to non-root user (numeric UID for consistency with production)
USER 1002

EXPOSE 443
EXPOSE 8080

# Start in the foreground
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]


####################################################
# Lua lint and test suite image
# luarocks, busted, and luasocket (needed for
# integration specs that connect to Redis directly).
# ##################################################

FROM openresty/openresty:1.31.1.1-alpine-fat AS test

# The -alpine-fat image already ships LuaRocks built against OpenResty's
# bundled LuaJIT 2.1 at /usr/local/openresty/luajit/bin/luarocks.
# See: https://github.com/openresty/docker-openresty#luarocks
RUN apk add --no-cache --virtual .build-deps gcc musl-dev openssl-dev \
    && /usr/local/openresty/luajit/bin/luarocks install luasec \
    && /usr/local/openresty/luajit/bin/luarocks install busted \
    && /usr/local/openresty/luajit/bin/luarocks install luasocket \
    && /usr/local/openresty/luajit/bin/luarocks install lua-cjson \
    && /usr/local/openresty/luajit/bin/luarocks install luacheck \
    && apk del .build-deps \
    && rm -rf /root/.cache

ENV PATH="/usr/local/openresty/luajit/bin:${PATH}"

WORKDIR /app

COPY opt/lua/  .

ENTRYPOINT ["/bin/sh", "-c", "luacheck . && busted"]
