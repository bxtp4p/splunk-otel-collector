FROM nginx:1.27.4

RUN rm /etc/nginx/conf.d/default.conf
COPY status.conf /etc/nginx/conf.d/status.conf
COPY htpasswd /etc/nginx/.htpasswd
