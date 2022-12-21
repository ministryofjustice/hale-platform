FROM --platform=linux/amd64 nginxinc/nginx-unprivileged:1.2.3

COPY ./nginx/default.conf /etc/nginx/conf.d/default.conf
COPY ./nginx/nginx.conf /etc/nginx/
