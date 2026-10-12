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

# The container serves HTTP only. A base URI with "https" therefore means that
# a reverse proxy in front of the container ends the TLS connection. Phorge
# then has to treat every request as HTTPS, and support/preamble.php is the
# place it provides for that (see "Configuring a Preamble Script" in the Phorge
# documentation).
case "$PHORGE_BASE_URI" in
    https://*)
        cat > support/preamble.php <<'EOF'
<?php

$_SERVER['HTTPS'] = true;
EOF
        ;;
esac

# A new volume belongs to root when the container engine does not copy the
# owner of the directory in the image.
chown www-data:www-data /var/lib/phorge/files

# Creates the databases on the first start and applies the schema changes of a
# newer Phorge version on later starts.
bin/storage upgrade --force

exec supervisord --nodaemon --configuration /etc/supervisor/supervisord.conf
