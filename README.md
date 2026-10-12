# Phorge in podman

Container files for running [Phorge](https://phorge.it/) with rootless podman
and `podman-compose`. They start an empty Phorge instance with a MariaDB
database. Repository hosting, SSH access, outgoing mail and the notification
server (Aphlict) are not set up.

Two containers are started:

- `phorge` is built from the `Containerfile`. It holds the source of Phorge and
  Arcanist, and runs nginx, php-fpm and the Phorge daemons under supervisord.
- `db` runs the MariaDB image of Docker Hub.

The data is kept in two named volumes: `db` for the database and `files` for the
files that users upload.

Only `podman-compose` has been tested. The compose file uses no podman-specific
keys, but it has not been run with `docker compose`.

## Requirements

- podman, set up for rootless use
- podman-compose 1.6.0 or newer
- `openssl`, to generate the passwords

## Passwords

The database needs two passwords: one for the user `phorge`, which Phorge logs
in with, and one for the MariaDB user `root`. Each is read from a file in
`secrets/`. Create both files once, before the first start.

```bash
(umask 077; openssl rand -hex 32 > secrets/db_password)
```

```bash
(umask 077; openssl rand -hex 32 > secrets/db_root_password)
```

The passwords are stored in plain text in these two files, which only your user
can read and which git ignores. The password of `phorge` is also written in
plain text to `conf/local/local.json` inside the `phorge` container.

MariaDB reads the files only when it initialises an empty `db` volume. Changing
a file afterwards does not change the password in the database, and Phorge can
then no longer log in.

## Settings

The compose file has three settings, each with a default.

| Variable | Default | Meaning |
|---|---|---|
| `PHORGE_LISTEN` | `127.0.0.1:8080` | Address and port on the host |
| `PHORGE_BASE_URI` | `http://phorge.localhost:8080/` | Address for browsers |
| `PHORGE_TIMEZONE` | `UTC` | Default time zone |

To change a setting, copy `.env.example` to `.env` and edit it, or set the
variable in the environment of the `podman-compose` command.

Phorge compares the host name and the port of each request with
`PHORGE_BASE_URI` and refuses a host name without a dot, so `localhost` alone
does not work. Names that end in `.localhost` resolve to the local machine in
current browsers and with systemd-resolved.

The default of `PHORGE_LISTEN` accepts connections from the local machine only.
Keep it that way until the administrator account exists: the first visitor of a
new instance creates that account.

The versions are build arguments of the `Containerfile`: `PHP_VERSION`,
`PHORGE_REF` and `ARCANIST_REF`. The last two accept a tag, a branch or a commit
of the repositories `phorgeit/phorge` and `phorgeit/arcanist` at GitHub.

## Build

Build the image once, and again after a change to the `Containerfile` or to a
file in `container/`.

```bash
podman-compose build
```

## Start

```bash
podman-compose up -d
```

The first start creates the database schema, which takes about a minute. Follow
the progress in the log of the container:

```bash
podman-compose logs -f phorge
```

Phorge is ready when the log shows that supervisord has started `nginx`,
`php-fpm` and `phd`. The lines "Retrying database connection" at the top of the
log are expected in a new container: the first `bin/config set` commands run
before the address and the password of the database are stored.

At every start the container writes the settings to the Phorge configuration and
runs `bin/storage upgrade`. A setting that is changed with `bin/config set`
inside the container is lost when the container is created again; settings that
are changed on the configuration pages of Phorge are stored in the database and
are kept.

## First login

Open the address of `PHORGE_BASE_URI` in a browser. Phorge asks for the user
name, the real name and the email address of the administrator account, and logs
you in. It does not ask for a password: a new instance has no login method yet.
Before you log out, open the application "Auth" and add an authentication
provider, for example "Username/Password".

If you are logged out while no provider works, this command prints a link that
logs you in once. Replace `USERNAME` with the user name of the account.

```bash
podman-compose exec phorge bin/auth recover USERNAME
```

## Remaining setup issues

Phorge lists the problems it finds in its configuration on the page
`/config/issue/`. A new instance shows four. They depend on how the instance is
used, so the image does not resolve them.

- "No Authentication Providers Configured": see [First login](#first-login).
- "Mailers Not Configured": Phorge cannot send mail until the setting
  `cluster.mailers` describes a mail server.
- "Missing Repository Local Path": the directory `/var/repo/` does not exist,
  because repository hosting is not set up. It would also need a volume for that
  directory.
- "Alternate File Domain Not Configured": Phorge advises to serve uploaded files
  from a second host name, which has to exist in your DNS first.

## Stop

```bash
podman-compose down
```

The volumes are kept, so the next `podman-compose up -d` continues with the same
data.

## Removal

This deletes the database and all uploaded files.

```bash
podman-compose down -v
```

## Prior work

Phorge has no official container image. These community projects were compared
before this setup was written:

- [zengxs/phorge-docker](https://github.com/zengxs/phorge-docker)
- [dongrote/phorge.it-docker-compose](https://github.com/dongrote/phorge.it-docker-compose)
- [dynamist/phabfive](https://github.com/dynamist/phabfive)
- [niteria/phorge-nix](https://github.com/niteria/phorge-nix)

## Licence

Apache License 2.0, the licence of Phorge. See [LICENSE](LICENSE).
