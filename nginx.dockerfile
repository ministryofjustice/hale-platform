FROM --platform=linux/amd64 nginxinc/nginx-unprivileged:1.23.3

COPY ./nginx/nginx.conf /etc/nginx/nginx.conf
COPY ./nginx/default.conf /etc/nginx/conf.d/default.conf
