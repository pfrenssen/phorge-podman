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

- `phorge` runs the [image](#image) `ghcr.io/pfrenssen/phorge`, which this
  repository builds from `quadlet/Containerfile`. It holds the source of Phorge
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
- access to `ghcr.io` and `docker.io`, from which the first start downloads the
  images of Phorge and MariaDB

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

| Setting | Default |
|---|---|
| `PublishPort` | `127.0.0.1:8080:80` |
| `PHORGE_BASE_URI` | `http://phorge.localhost:8080/` |
| `PHORGE_TIMEZONE` | `UTC` |
| `PHORGE_TRUSTED_PROXIES` | `0` |

`PublishPort` is the address and the port on the host. `PHORGE_BASE_URI` is the
address for browsers, and `PHORGE_TIMEZONE` the default time zone.
`PHORGE_TRUSTED_PROXIES` is the number of [reverse proxies](#reverse-proxy) in
front of the container.

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

The default of `PublishPort` accepts connections from the local machine only.
Keep it that way until the administrator account exists: the first visitor of a
new instance creates that account.

### Reverse proxy

The container serves HTTP only. To reach Phorge over HTTPS, put a reverse proxy
that ends the TLS connection in front of the port of `PublishPort`, and set
`PHORGE_BASE_URI` to the `https` address of the proxy. With such an address the
container treats every request as HTTPS. The proxy has to pass on the `Host`
header of the request.

Behind a proxy, every request reaches Phorge from the address of the proxy.
Phorge then records that address in its logs, and counts the failed logins of
all users together. To give Phorge the address of the client, let the proxy add
it to the `X-Forwarded-For` header, and set `PHORGE_TRUSTED_PROXIES` to the
number of proxies that do so, `1` for a single proxy. For nginx:

```nginx
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```

Phorge takes the entry of the header that the first of these proxies added, and
ignores the entries before it, which the client can choose freely. Set the
number only when the port of `PublishPort` cannot be reached without passing the
proxies. A client that connects to the port directly can put any address in the
header.

## Image

The workflows of this repository build the image of `phorge` and publish it as
`ghcr.io/pfrenssen/phorge`, with two tags:

- The full hash of the commit of `master` it was built from, such as
  `ghcr.io/pfrenssen/phorge:ff02add79da4d1fbce9f318a7b53de516d519a5d`. Every
  image is kept, so the image of an earlier commit can be run again.
- `latest`, the image of the newest commit. `quadlet/phorge.container` uses this
  tag.

`quadlet/Containerfile` pins three inputs of the image:

| Pin | Value |
|---|---|
| `FROM` | `docker.io/library/php:8.4-fpm` with the digest of one image |
| `PHORGE_REF` | a commit of `phorgeit/phorge` at GitHub |
| `ARCANIST_REF` | a commit of `phorgeit/arcanist` at GitHub |

Two workflows in `.github/workflows/` publish images:

- `push.yml` builds each commit that is pushed to `master` and publishes its
  image. A pull request is built and not published.
- `follow-stable.yml` runs once a day. It reads the heads of the `stable`
  branches of Phorge and Arcanist and the digest of the current `php:8.4-fpm`
  image. When one of them moved, it writes them into the `Containerfile`, builds
  the image, commits the change to `master` as `github-actions[bot]` and
  publishes the image of that commit. A failed build leaves `master` unchanged.
  The workflow can also be started by hand, on its page under "Actions" of the
  repository.

The pins follow the `stable` branches and not the release tags. Phorge tags two
or three releases a year, named after the year and the week, such as `2026.27`,
and publishes no point releases. Fixes between two releases, security fixes
included, are committed to `stable` only and get no tag. The upgrade guide of
Phorge requires Phorge and Arcanist to be upgraded together, so each commit of
the workflow holds the heads of both branches at the time of the run.

The pins are commits and not branch names. A build with an unchanged branch name
reuses the cached layer of the `git fetch` step and does not fetch new code.

Every start of `phorge` runs `bin/storage upgrade`, which brings the database
schema to the version of the image. `bin/storage` has no downgrade, so an image
of an earlier commit cannot be run on a database that a newer image upgraded.
The way back is the dump that is written before an
[update](#update-of-the-image).

GitHub disables a scheduled workflow of a public repository after 60 days
without activity in the repository. The base image changes every few weeks, and
each change is a commit of `follow-stable.yml`. A disabled workflow is enabled
again on its page under "Actions".

## Start

Before the first start, download the image of Phorge. systemd gives the start of
`phorge` 420 seconds, which the first start needs for the database schema; a
download during the start would count towards them.

```bash
podman pull ghcr.io/pfrenssen/phorge:latest
```

Start Phorge:

```bash
systemctl --user restart phorge
```

The command starts what is not running: it creates the network and the volumes,
starts `phorge-db`, waits until the database accepts connections and then starts
`phorge`. It returns when Phorge answers requests. The first start downloads the
MariaDB image and creates the database schema, which takes several minutes.
Later starts use the downloaded images.

Follow the progress in a second terminal:

```bash
journalctl --user -f -u phorge-db -u phorge
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

## Update of the image

podman downloads the image of `phorge` at the first start only; later starts use
the local copy. To run the newest image, download it again:

```bash
podman pull ghcr.io/pfrenssen/phorge:latest
```

The next start of `phorge` upgrades the database schema, which cannot be undone.
Before it, write a dump of the database while the old container runs. The file
holds all data of Phorge, in plain text.

```bash
podman exec phorge bin/storage dump | gzip > phorge-before-update.sql.gz
```

Start Phorge on the new image. The old container stops, and the new one runs
`bin/storage upgrade` before it answers requests.

```bash
systemctl --user restart phorge
```

To go back to the previous image, the dump has to be loaded into a new
`phorge-db` volume before that image starts.

`quadlet/phorge.container` sets no `AutoUpdate=`. `podman auto-update` would
start a new image without a dump, and when that start fails it would start the
previous image again, on a schema that the new image may have upgraded.

## Update of the files

After a change to a file in `quadlet/`, for example when a newer commit of this
repository is checked out, install the files again and start Phorge again.

```bash
podman quadlet install --replace --application=phorge quadlet
```

```bash
systemctl --user restart phorge
```

## Local build

To build the image on your machine instead of downloading it, such as to test a
change of the `Containerfile`, let `phorge` use the image of
`quadlet/phorge.build`. Create the file
`~/.config/containers/systemd/phorge.container.d/build.conf`:

```ini
[Container]
Image=phorge.build
```

Then run `systemctl --user daemon-reload` and [start](#start) Phorge again. Each
start of `phorge` now runs `podman build` first, as the unit `phorge-build`, and
builds `localhost/phorge:latest`; unchanged steps come from the cache. Remove
the file to return to the published image.

To build other commits of Phorge and Arcanist than those of the `Containerfile`,
create the file `~/.config/containers/systemd/phorge.build.d/versions.conf`, for
example:

```ini
[Build]
BuildArg=PHORGE_REF=7d2dd8899c3b31bfd7a61d8e0de94b9b9a675615
BuildArg=ARCANIST_REF=922ffd9dd8233e29e269bc28c19931a39a0ef46d
```

`PHORGE_REF` and `ARCANIST_REF` also accept a tag or a branch. A branch is
fetched at the first build only, as described under [Image](#image). Change both
together, because Phorge and Arcanist have to be upgraded together.

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
podman rmi ghcr.io/pfrenssen/phorge
```

After a [local build](#local-build), also remove the built image:

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
