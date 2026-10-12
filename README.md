# Phorge in podman

Container files for running [Phorge](https://phorge.it/) with rootless podman
under systemd. They start an empty Phorge instance with a MariaDB database.
Repository hosting, SSH access, outgoing mail and the notification server
(Aphlict) are not set up.

The directory `quadlet/` holds Quadlet files: descriptions of containers,
volumes, a network and an image build, from which podman generates systemd
units. systemd then starts the containers in order, restarts one that fails and
starts them at boot. This needs podman on a Linux machine with systemd; the
files do not work with Docker.

Two containers are started:

- `phorge` is built from `quadlet/Containerfile`. It holds the source of Phorge
  and Arcanist, and runs nginx, php-fpm and the Phorge daemons under
  supervisord.
- `phorge-db` runs the MariaDB image of Docker Hub.

The data is kept in two named volumes: `phorge-db` for the database and
`phorge-files` for the files that users upload. The containers share the network
`phorge`.

## Requirements

- podman with the `podman quadlet` commands, set up for rootless use. The files
  were tested with podman 6.1.
- systemd with a user instance, which every login session has
- `openssl`, to generate the passwords

## Passwords

The database needs two passwords: one for the user `phorge`, which Phorge logs
in with, and one for the MariaDB user `root`. Each is a podman secret, which
podman mounts as a file in the containers. Create both once, before the first
start.

```bash
openssl rand -hex 32 | podman secret create phorge-db-password -
```

```bash
openssl rand -hex 32 | podman secret create phorge-db-root-password -
```

podman stores both passwords without encryption, in a file in its storage
directory that only your user can read. The password of `phorge` is also written
in plain text to `conf/local/local.json` inside the `phorge` container.

MariaDB reads the passwords only when it initialises an empty `phorge-db`
volume. Replacing a secret afterwards does not change the password in the
database, and Phorge can then no longer log in.

## Installation

Run this once, in the root of the repository. It copies the content of
`quadlet/` to `~/.config/containers/systemd/phorge/` and lets systemd generate
the units.

```bash
podman quadlet install --application=phorge quadlet
```

The units cannot be enabled or disabled with `systemctl enable`. `phorge` is
started at every start of your systemd user instance, because
`quadlet/phorge.container` contains `WantedBy=default.target`.

## Settings

The container has three settings, each with a default.

| Setting | Default |
|---|---|
| `PublishPort` | `127.0.0.1:8080:80` |
| `PHORGE_BASE_URI` | `http://phorge.localhost:8080/` |
| `PHORGE_TIMEZONE` | `UTC` |

`PublishPort` is the address and the port on the host. `PHORGE_BASE_URI` is the
address for browsers, and `PHORGE_TIMEZONE` the default time zone.

Settings are changed in a file of your own, which systemd merges with the
installed `phorge.container`. The installed files stay unchanged, so a later
installation does not overwrite the settings. Create the directory and copy the
example, once:

```bash
mkdir -p ~/.config/containers/systemd/phorge.container.d
```

```bash
cp settings.conf.example ~/.config/containers/systemd/phorge.container.d/settings.conf
```

Edit the copy, and after every change let systemd read it:

```bash
systemctl --user daemon-reload
```

A running container keeps its old settings until it is [started again](#start).

Phorge compares the host name of each request with that of `PHORGE_BASE_URI`,
and refuses a host name without a dot, so `localhost` alone does not work. Names
that end in `.localhost` resolve to the local machine in current browsers and
with systemd-resolved.

The container serves HTTP only. To reach Phorge over HTTPS, put a reverse proxy
that ends the TLS connection in front of the port of `PublishPort`, and set
`PHORGE_BASE_URI` to the `https` address of the proxy. With such an address the
container treats every request as HTTPS. The proxy has to pass on the `Host`
header of the request.

The default of `PublishPort` accepts connections from the local machine only.
Keep it that way until the administrator account exists: the first visitor of a
new instance creates that account.

## Versions

The versions are build arguments of the `Containerfile`: `PHP_VERSION`,
`PHORGE_REF` and `ARCANIST_REF`. The last two accept a tag, a branch or a commit
of the repositories `phorgeit/phorge` and `phorgeit/arcanist` at GitHub. The
defaults are in the `Containerfile`.

To build other versions, create the file
`~/.config/containers/systemd/phorge.build.d/versions.conf` with one line for
each argument to change, for example:

```ini
[Build]
BuildArg=PHORGE_REF=master
BuildArg=ARCANIST_REF=master
```

Then run `systemctl --user daemon-reload` and [start](#start) Phorge again.

## Start

```bash
systemctl --user restart phorge
```

The command starts what is not running: it builds the image, creates the network
and the volumes, starts `phorge-db`, waits until the database accepts
connections and then starts `phorge`. It returns when Phorge answers requests.
The first start downloads the MariaDB image, builds the Phorge image and creates
the database schema, which takes several minutes. Later starts build the image
from the cache.

Follow the progress in a second terminal:

```bash
journalctl --user -f -u phorge-build -u phorge-db -u phorge
```

The lines "Retrying database connection" at the start of the output of `phorge`
are expected in a new container: the first `bin/config set` commands run before
the address and the password of the database are stored.

At every start the container writes the settings to the Phorge configuration and
runs `bin/storage upgrade`. A setting that is changed with `bin/config set`
inside the container is lost at the next start, because systemd creates the
container again each time; settings that are changed on the configuration pages
of Phorge are stored in the database and are kept.

systemd gives `phorge` 420 seconds to answer requests. After that it stops the
container and starts it again, also when `bin/storage upgrade` is still running.
When an upgrade of a large database needs more time, add a section `[Service]`
with a higher `TimeoutStartSec` to `settings.conf`.

## Start at boot

Your systemd user instance, and with it Phorge, starts at your first login and
stops when your last session ends. This command starts the user instance at boot
and keeps it running after you log out. Run it once.

```bash
loginctl enable-linger
```

## First login

Open the address of `PHORGE_BASE_URI` in a browser. Phorge asks for the user
name, the real name and the email address of the administrator account, and logs
you in. It does not ask for a password: a new instance has no login method yet.
Before you log out, open the application "Auth" and add an authentication
provider, for example "Username/Password".

If you are logged out while no provider works, this command prints a link that
logs you in once. Replace `USERNAME` with the user name of the account.

```bash
podman exec phorge bin/auth recover USERNAME
```

## Processes and daemons

Inside the `phorge` container, supervisord and the main processes of nginx and
php-fpm run as root. The processes that handle requests and the Phorge daemons
run as `www-data`. With rootless podman, root inside a container is the user who
started the container, not root on the host.

A Phorge daemon that has nothing to do ends, and is started again later. The
process list of the container therefore often shows only the process that
supervises the daemons, `php ./phd-daemon`. This command shows what the daemons
did:

```bash
podman exec phorge bin/phd log
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
systemctl --user stop phorge phorge-db
```

systemd removes the two containers. The volumes are kept, so the next start
continues with the same data.

## Update of the files

After a change to a file in `quadlet/`, for example when a newer commit of this
repository is checked out, install the files again and start Phorge again.

```bash
podman quadlet install --replace --application=phorge quadlet
```

```bash
systemctl --user restart phorge
```

## Removal

Stop every unit first. Besides the containers, this ends the units that created
the network and the volumes, which systemd otherwise keeps until you log out.

```bash
systemctl --user stop 'phorge*'
```

Remove the installed files:

```bash
podman quadlet rm --recursive phorge
```

Your settings in `~/.config/containers/systemd/phorge.container.d/` and
`~/.config/containers/systemd/phorge.build.d/` are not removed by this command.

The next command deletes the database and all uploaded files.

```bash
podman volume rm phorge-db phorge-files
```

Remove the network, the passwords and the image:

```bash
podman network rm phorge
```

```bash
podman secret rm phorge-db-password phorge-db-root-password
```

```bash
podman rmi localhost/phorge
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
