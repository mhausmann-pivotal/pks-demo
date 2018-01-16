FROM debian:stretch

LABEL maintainer="Alex Guedes <aguedes@pivotal.io>"

RUN set -x \
	&& apt-get update \
	&& apt-get install -y nginx \
	&& sed -i '/[::]/d' /etc/nginx/sites-available/default

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]