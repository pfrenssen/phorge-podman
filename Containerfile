ARG PHP_VERSION=8.4

FROM docker.io/library/php:${PHP_VERSION}-fpm

# A tag, a branch or a commit of github.com/phorgeit/phorge and
# github.com/phorgeit/arcanist.
ARG PHORGE_REF=2026.27
ARG ARCANIST_REF=2026.27

# mariadb-client provides mysqldump, which "bin/storage dump" calls. procps
# provides ps, which Phorge uses to inspect its daemons. python3-pygments
# provides pygmentize, which Phorge calls to highlight source code. The -dev
# packages are needed to compile the gd and zip extensions.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        libfreetype-dev \
        libjpeg62-turbo-dev \
        libpng-dev \
        libzip-dev \
        mariadb-client \
        nginx \
        procps \
        python3-pygments \
        supervisor \
    && rm -rf /var/lib/apt/lists/*

RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" gd mysqli opcache pcntl zip \
    && pecl install apcu \
    && docker-php-ext-enable apcu \
    && rm -rf /tmp/pear

# "git fetch" of a single ref followed by a checkout of FETCH_HEAD accepts a
# tag, a branch and a commit alike. The directories belong to root while the
# web server and the daemons run as www-data, so git has to be told that it may
# read them.
RUN set -eu; \
    fetch() { \
        git init --quiet "$2"; \
        git -C "$2" remote add origin "https://github.com/phorgeit/$1.git"; \
        git -C "$2" fetch --quiet --depth 1 origin "$3"; \
        git -C "$2" -c advice.detachedHead=false checkout --quiet FETCH_HEAD; \
        git config --system --add safe.directory "$2"; \
    }; \
    fetch arcanist /opt/phorge/arcanist "${ARCANIST_REF}"; \
    fetch phorge /opt/phorge/phorge "${PHORGE_REF}"

RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
    && rm /etc/nginx/sites-enabled/default \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log \
    && install -d -o www-data -g www-data /var/lib/phorge/files

COPY container/php.ini /usr/local/etc/php/conf.d/phorge.ini
COPY container/nginx.conf /etc/nginx/conf.d/phorge.conf
COPY container/supervisord.conf /etc/supervisor/supervisord.conf
COPY --chmod=755 \
    container/entrypoint.sh \
    container/healthcheck.sh \
    container/phd.sh \
    /usr/local/bin/

WORKDIR /opt/phorge/phorge
EXPOSE 80
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
