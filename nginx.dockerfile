FROM nginxinc/nginx-unprivileged:1.22-alpine

COPY ./nginx/nginx.conf /etc/nginx/
#COPY ./nginx/certs /etc/nginx/certs/self-signed
