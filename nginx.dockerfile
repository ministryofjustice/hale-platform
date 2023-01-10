FROM --platform=linux/amd64 nginx:latest
#FROM --platform=linux/amd64 nginxinc/nginx-unprivileged:1.23.3

RUN apt-get -y update
RUN apt-get -y install vim

# Copy custom NGINX configurations required for WordPress Multisite
COPY opt/nginx/nginx.conf /etc/nginx/
COPY opt/nginx/wordpress.conf /etc/nginx/conf.d/
