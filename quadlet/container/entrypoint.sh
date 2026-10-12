#!/bin/sh
# Entry point of the Phorge container. It runs as root inside the container:
# it writes the configuration, brings the database schema up to date and then
# starts supervisord, which runs nginx, php-fpm and the daemons. With rootless
# podman, root inside the container is the user who started the container, not
# root on the host.
set -eu

cd /opt/phorge/phorge

# The database container can be reported as started before the server accepts
# connections. "ping" succeeds as soon as the server answers, also without
# valid credentials.
until mariadb-admin --host=db --skip-ssl --silent ping; do
    echo "Waiting for the database server on host db."
    sleep 2
done

# The configuration is written at every start, so that it always follows the
# settings of the container unit. "bin/config set" stores the values in
# conf/local/local.json.
bin/config set mysql.host db
bin/config set mysql.user phorge
# --stdin keeps the password out of the process list. It reads all of the
# input, so the newline at the end of the file has to be removed.
tr -d '\n' < /run/secrets/db_password | bin/config set mysql.pass --stdin
bin/config set phabricator.base-uri "$PHORGE_BASE_URI"
bin/config set phabricator.timezone "$PHORGE_TIMEZONE"
bin/config set storage.local-disk.path /var/lib/phorge/files
# The image contains pygmentize.
bin/config set pygments.enabled true

# Phorge runs support/preamble.php at the start of every request. It is the
# place Phorge provides for settings that depend on a reverse proxy (see
# "Configuring a Preamble Script" in the Phorge documentation).
echo '<?php' > support/preamble.php

# The container serves HTTP only. A base URI with "https" therefore means that
# a reverse proxy in front of the container ends the TLS connection. Phorge
# then has to treat every request as HTTPS.
case "$PHORGE_BASE_URI" in
    https://*)
        echo "\$_SERVER['HTTPS'] = true;" >> support/preamble.php
        ;;
esac

# Behind a reverse proxy every request comes from the address of the proxy.
# Phorge then takes the address of the client from the X-Forwarded-For header,
# skipping the entries that the trusted proxies added.
case "$PHORGE_TRUSTED_PROXIES" in
    0)
        ;;
    [1-9]|[1-9][0-9])
        echo "preamble_trust_x_forwarded_for_header($PHORGE_TRUSTED_PROXIES);" \
            >> support/preamble.php
        ;;
    *)
        echo "PHORGE_TRUSTED_PROXIES must be a number from 0 to 99." >&2
        exit 1
        ;;
esac

# A new volume belongs to root when the container engine does not copy the
# owner of the directory in the image.
chown www-data:www-data /var/lib/phorge/files

# Creates the databases on the first start and applies the schema changes of a
# newer Phorge version on later starts.
bin/storage upgrade --force

exec supervisord --nodaemon --configuration /etc/supervisor/supervisord.conf
