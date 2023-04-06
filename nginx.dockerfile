FROM --platform=linux/amd64 nginxinc/nginx-unprivileged:1.23.3

RUN chgrp -R root /var/run/nginx-cache /var/run /var/log/nginx && \
    chmod -R 770 /var/run/nginx-cache /var/run /var/log/nginx

# Copy custom NGINX configurations required for WordPress Multisite
COPY opt/nginx/nginx.conf /etc/nginx/
COPY opt/nginx/wordpress.conf /etc/nginx/conf.d/

RUN rm -r /etc/nginx/conf.d/default.conf
