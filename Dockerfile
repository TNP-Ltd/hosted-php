FROM debian:bookworm-slim

ENV PHP_INI_DIR /etc/php/5.6/apache2
ENV APACHE_CONFDIR /etc/apache2
ENV APACHE_ENVVARS $APACHE_CONFDIR/envvars

COPY sury-repo.asc /etc/apt/keyrings/sury-repo.asc

# install php5.6
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		ca-certificates \
		curl \
	;

# install apache2
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends apache2; \
	rm -rf /var/lib/apt/lists/*; \
	# generically convert lines like
	#   export APACHE_RUN_USER=www-data
	# into
	#   : ${APACHE_RUN_USER:=www-data}
	#   export APACHE_RUN_USER
	# so that they can be overridden at runtime ("-e APACHE_RUN_USER=...")
	sed -ri 's/^export ([^=]+)=(.*)$/: ${\1:=\2}\nexport \1/' "$APACHE_ENVVARS"; \
	\
	# setup directories and permissions
	. "$APACHE_ENVVARS"; \
	for dir in \
		"$APACHE_LOCK_DIR" \
		"$APACHE_RUN_DIR" \
		"$APACHE_LOG_DIR" \
	# https://salsa.debian.org/apache-team/apache2/-/commit/b97ca8714890ead1ba6c095699dde752e8433205
		"$APACHE_RUN_DIR/socks" \
	; do \
		rm -rvf "$dir"; \
		mkdir -p "$dir"; \
		chown "$APACHE_RUN_USER:$APACHE_RUN_GROUP" "$dir"; \
	# allow running as an arbitrary user (https://github.com/docker-library/php/issues/743)
		chmod 1777 "$dir"; \
	done; \
	# delete the "index.html" that installing Apache drops in here
	rm -rvf /var/www/html/*; \
	# logs should go to stdout / stderr
	ln -sfT /dev/stderr "/var/log/apache2/error.log"; \
	ln -sfT /dev/stdout "/var/log/apache2/access.log"; \
	ln -sfT /dev/stdout "/var/log/apache2/other_vhosts_access.log";


# # add sury repo and install php5.6
RUN set -eux; \
	echo "deb [signed-by=/etc/apt/keyrings/sury-repo.asc] https://packages.sury.org/php/ bookworm main" > /etc/apt/sources.list.d/php-sury.list ; \
	apt-get update; \
	apt install -y  \
		php5.6 \
	; \
	rm -rf /var/lib/apt/lists/*

# persistent / runtime deps
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
# Ghostscript is required for rendering PDF previews
		ghostscript \
# wp-cli depdencies..
        mariadb-client \
        less \
		libcurl4-gnutls-dev \
		libfreetype6-dev \
		libjpeg-dev \
		libmagickwand-dev \
		libmcrypt-dev \
		libpng-dev \
        libpq-dev  \
		libzip-dev \
	; \
	rm -rf /var/lib/apt/lists/*

RUN set -eux; \
	apt update ; \
	apt install --no-install-recommends -y \
		php5.6-bcmath \
        php5.6-curl \
		php5.6-readline \
		php5.6-exif \
		php5.6-gd \
		php5.6-imagick \
		php5.6-json \
        php5.6-mcrypt \
		php5.6-mysqli \
		php5.6-opcache \
        php5.6-pdo \
        php5.6-pgsql \
        php5.6-mysql \
		php5.6-zip \
	; \
	rm -rf /var/lib/apt/lists/*

# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN { \
		echo 'opcache.memory_consumption=128'; \
		echo 'opcache.interned_strings_buffer=8'; \
		echo 'opcache.max_accelerated_files=4000'; \
		echo 'opcache.revalidate_freq=2'; \
		echo 'opcache.fast_shutdown=1'; \
	} > $PHP_INI_DIR/conf.d/opcache-recommended.ini
# https://wordpress.org/support/article/editing-wp-config-php/#configure-error-logging

RUN { \
# https://www.php.net/manual/en/errorfunc.constants.php
# https://github.com/docker-library/wordpress/issues/420#issuecomment-517839670
		echo 'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR'; \
		echo 'display_errors = Off'; \
		echo 'display_startup_errors = Off'; \
		echo 'log_errors = On'; \
		echo 'error_log = /dev/stderr'; \
		echo 'log_errors_max_len = 1024'; \
		echo 'ignore_repeated_errors = On'; \
		echo 'ignore_repeated_source = Off'; \
		echo 'html_errors = Off'; \
	} > $PHP_INI_DIR/conf.d/error-logging.ini

RUN set -eux; \
	a2enmod rewrite expires; \
	\
# https://httpd.apache.org/docs/2.4/mod/mod_remoteip.html
	a2enmod remoteip; \
	{ \
		echo 'RemoteIPHeader X-Forwarded-For'; \
# these IP ranges are reserved for "private" use and should thus *usually* be safe inside Docker
		echo 'RemoteIPTrustedProxy 10.0.0.0/8'; \
		echo 'RemoteIPTrustedProxy 172.16.0.0/12'; \
		echo 'RemoteIPTrustedProxy 192.168.0.0/16'; \
		echo 'RemoteIPTrustedProxy 169.254.0.0/16'; \
		echo 'RemoteIPTrustedProxy 127.0.0.0/8'; \
	} > /etc/apache2/conf-available/remoteip.conf; \
	a2enconf remoteip; \
# https://github.com/docker-library/wordpress/issues/383#issuecomment-507886512
# (replace all instances of "%h" with "%a" in LogFormat)
	find /etc/apache2 -type f -name '*.conf' -exec sed -ri 's/([[:space:]]*LogFormat[[:space:]]+"[^"]*)%h([^"]*")/\1%a\2/g' '{}' +

# Turn off signatures
RUN sed -i "s/^expose_php.*/expose_php = off/" $PHP_INI_DIR/php.ini
RUN sed -i "s/^ServerTokens.*/ServerTokens Prod/" /etc/apache2/conf-enabled/security.conf
RUN sed -i "s/^ServerSignature.*/ServerSignature Off/" /etc/apache2/conf-enabled/security.conf

# Increase max upload size
RUN sed -i "s/^upload_max_filesize.*/upload_max_filesize = 50M/" $PHP_INI_DIR/php.ini
RUN sed -i "s/^post_max_size.*/post_max_size = 50M/" $PHP_INI_DIR/php.ini

# Enable Backwards Compatible options
RUN sed -i "s/^short_open_tag.*/short_open_tag = On/" $PHP_INI_DIR/php.ini

# Apache + PHP requires preforking Apache for best results
RUN a2dismod mpm_event && a2enmod mpm_prefork

# Tune down resource usage
COPY conf/mpm_prefork.conf  /etc/apache2/mods-enabled/mpm_prefork.conf

RUN curl https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp \
	&& chmod +x /usr/local/bin/wp

EXPOSE 80
CMD ["/usr/sbin/apache2ctl", "-D", "FOREGROUND"]
