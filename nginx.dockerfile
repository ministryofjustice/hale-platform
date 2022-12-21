FROM --platform=linux/amd64 nginxinc/nginx-unprivileged:1.23-alpine

COPY ./nginx/default.conf /etc/nginx/conf.d/default.conf
COPY ./nginx/nginx.conf /etc/nginx/
#COPY ./nginx/certs /etc/nginx/certs/self-signed
