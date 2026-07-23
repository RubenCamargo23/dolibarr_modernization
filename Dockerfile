FROM php:8.2-apache-bookworm

ENV PHP_INI_DATE_TIMEZONE='UTC'
ENV PHP_INI_MEMORY_LIMIT=256M

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        libfreetype6-dev \
        libjpeg62-turbo-dev \
        libjpeg62-turbo \
        libpng-dev \
        libldap2-dev \
        libxml2-dev \
        libzip-dev \
        zlib1g-dev \
        libicu-dev \
        g++ \
        default-mysql-client \
        unzip \
        curl \
        libpq-dev \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) calendar intl mysqli pdo_mysql pgsql gd soap zip \
    && docker-php-ext-configure ldap \
    && docker-php-ext-install -j$(nproc) ldap && \
    mv ${PHP_INI_DIR}/php.ini-production ${PHP_INI_DIR}/php.ini && \
    { \
        echo "date.timezone = ${PHP_INI_DATE_TIMEZONE}"; \
        echo "memory_limit = ${PHP_INI_MEMORY_LIMIT}"; \
    } > ${PHP_INI_DIR}/conf.d/dolibarr-php.ini

WORKDIR /var/www/html

COPY htdocs /var/www/html

RUN mkdir -p /var/www/documents \
    && chown -R www-data:www-data /var/www/html /var/www/documents \
    && find /var/www/html/conf -maxdepth 1 -type f -delete

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80
ENTRYPOINT ["entrypoint.sh"]
