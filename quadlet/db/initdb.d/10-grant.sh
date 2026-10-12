# The entry point of the MariaDB image reads this file once, when it
# initialises an empty data directory. The file must not be executable: the
# entry point then includes it in its own shell, which provides
# docker_process_sql and MARIADB_USER.
#
# Phorge keeps its data in many databases whose names start with
# "phabricator_", and creates them itself. The application user gets all
# privileges on databases with that prefix and none on other databases.
docker_process_sql --database=mysql <<EOSQL
GRANT ALL PRIVILEGES ON \`phabricator\\_%\`.* TO '${MARIADB_USER}'@'%';
EOSQL
