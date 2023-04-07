FROM --platform=linux/amd64 nginxinc/nginx-unprivileged:latest

# Copy custom NGINX configurations required for WordPress Multisite
COPY opt/nginx/nginx.conf /etc/nginx/
COPY opt/nginx/wordpress.conf /etc/nginx/conf.d/

RUN rm -r /etc/nginx/conf.d/default.conf
