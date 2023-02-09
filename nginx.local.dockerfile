FROM --platform=linux/arm64v8 arm64v8/nginx

RUN apt-get -y update
RUN apt-get -y install vim

# Copy custom NGINX configurations required for WordPress Multisite
COPY opt/nginx/nginx.conf /etc/nginx/
COPY opt/nginx/localwordpress.conf /etc/nginx/conf.d/

RUN rm -r /etc/nginx/conf.d/default.conf

EXPOSE 443 
EXPOSE 8080
