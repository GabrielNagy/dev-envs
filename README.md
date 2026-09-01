# dev-env

Run a project's branches on a box and browse them over HTTPS, so a change can be
clicked through in a real browser rather than only asserted about in tests.

An environment is created on demand for one branch, bundling a git worktree, a
database (postgres by default, MariaDB/MySQL on request), a loopback port and a
systemd user unit. Caddy terminates TLS in front through one wildcard
certificate for the machine's base domain.

```
dev-env up <branch>     # create an environment
dev-env list            # what is recorded, and where it answers (alias: ls)
dev-env creds [target]  # basic-auth credentials
dev-env logs [target] -f  # follow the log
dev-env down <id>       # tear one environment down by its immutable ID
dev-env down --all      # tear every active or inactive environment down
```

A target is an immutable environment ID or an exact branch in the current
project. Run from inside an environment's worktree, commands taking `[target]`
and `down` infer the environment from the current directory when it is omitted.

Environments are served at `https://<id>-<project>.<base domain>`, plus one
hostname per subdomain the project declares — by default `app`, folded into the
leftmost label as `https://app-<id>-<project>.<base domain>`. The ID is a random
8-character lowercase alphanumeric string:

```sh
dev-env up dev-env-support   # e.g. https://epxrnilj-sample.example.com
```

The same immutable ID is shown by `up` and `list` and accepted by explicit
teardown, so teardown never depends on a branch name or the caller's current
project. The ID, port, URL and password stay fixed while the environment record
exists, including across restarts and inactive periods. `down` ends that
lifetime; bringing the same branch up later creates a new environment with a
new ID and may choose a new port, URL and password. The project's `public`
setting, or an `up --public`/`up --private` override, only changes basic auth.

Only one environment may exist per project and exact branch. Generated
artifacts use the descriptive key `<project>--<branch slug>--<id>`, including
systemd units such as
`dev-env@sample--worktree-silver-cloud-2a0f--epxrnilj.service`. The concise ID is
the URL component and command-line selector.

Lifecycle commands for different environments may run concurrently. Commands
that target the same repository and branch exclude one another; `setup`,
`warm`, and `down --all` are machine-wide and run only when no targeted
lifecycle operation is active. Updates to shared Git metadata and Caddy routing
are serialized briefly without holding up the rest of each operation.

## Setting up a machine

Needs a database server (postgres, MySQL or MariaDB), Caddy, and one
`*.<base domain>` wildcard DNS record pointing at the box.

```sh
dev-env setup     # writes ~/.config/dev-envs/config.json, then re-run to write the Caddy config
```

`setup` detects the public address, writes `/etc/caddy/Caddyfile` (via sudo) and
installs the `dev-env@.service` systemd user template. Enable lingering so
environments survive logout: `loginctl enable-linger $USER`.

`~/.config/dev-envs/config.json` is machine-local — see `config.example.json`.
Environment IDs are unbounded in number, so one certificate per hostname would
grow issuance without limit; every project is instead served under one shared
`*.<base domain>` wildcard certificate obtained through DNS-01.
`acme_dns_provider` (for example, `route53`) is therefore required, and the
provider's module and credentials must be available to Caddy. Check the modules
in the installed Caddy build with `caddy list-modules | grep '^dns\.providers\.'`.
`base_domain` is a setup-time choice. When it changes, `dev-env setup` applies
it automatically if no environments exist. If environments are recorded, run
`dev-env down --all` and then `dev-env setup`.

## Existing worktrees

`up` does not need a branch of its own. If the branch is already checked out —
by an agent, or by hand, anywhere on disk — that checkout is the one served:

```sh
dev-env up feature-x                          # finds and adopts an existing checkout
dev-env up feature-x --worktree ~/some/path   # or point at one explicitly
```

When no checkout exists, `up` creates a worktree from the local branch or from
`origin/<branch>`. When the branch is new, it starts from the currently checked
out branch by default; `--base` selects a different base ref.

`down` removes a worktree only when `dev-env` created it. If that worktree has
uncommitted changes, teardown stops before removing anything and requires an
explicit choice: `--force` discards the changes, while `--keep-worktree`
preserves the checkout. An adopted worktree is never removed:

| `up` recorded | `down` does |
| --- | --- |
| it created a clean worktree | removes it, unless `--keep-worktree` |
| it created a dirty worktree | requires `--force` to remove or `--keep-worktree` to preserve |
| it adopted the worktree | never removes it; no flag overrides this |

The `up` summary marks an adopted worktree.

## Setting up a project

```sh
cd ~/projects/thing && dev-env init
```

That writes a `.dev-env.json` describing how to build an environment: the
commands to install dependencies, load the schema, migrate and serve, plus any
untracked files a worktree needs. Nothing in this tool is specific to a project
or a framework — the defaults `init` writes just happen to suit Rails.

Project configuration can instead remain machine-local under `projects` in
`~/.config/dev-envs/config.json`, keyed by the primary checkout's repository
root (`~` is expanded):

```json
{
  "projects": {
    "~/projects/thing": {
      "name": "thing",
      "commands": {
        "server": "bin/rails server -b 127.0.0.1 -p ${PORT}"
      }
    }
  }
}
```

The value accepts the same keys as `.dev-env.json` and applies from the primary
checkout and all of its worktrees. A `.dev-env.json` in the current or primary
checkout takes precedence as a complete project configuration; the two sources
are not merged. Commands still run from the environment's worktree, so a helper
kept outside the repository should be referenced by absolute path.

Keys, all optional except `commands.server`:

| Key | Purpose |
| --- | --- |
| `name` | Project component appended to each environment ID in its hostname; defaults to the repository directory name |
| `public` | Set `true` to disable basic auth by default; defaults to `false` |
| `subdomains` | Hostnames to serve, and which sit behind basic auth |
| `commands` | `install`, `schema`, `migrate`, `server` |
| `process_manager` | Set to `overmind` when `commands.server` delegates to Overmind |
| `database` | Engine and connection: `adapter`, `host`, `port`, `user`, `extra` |
| `env` | Environment variables for those commands and the service |
| `after_down` | Commands run by `down` after the service stops, before anything is removed |
| `summary` | Labelled commands whose output becomes a row of the `up` summary |
| `worktree_files` | Untracked files written into each worktree |
| `install_cache` | Seed an install directory from the last successful install with matching key files |
| `seed_template` | Seed each environment by cloning a template database |

`${DOMAIN}`, `${DOMAIN_RE}`, `${PORT}`, `${DATABASE}`, `${DATABASE_URL}`,
`${BRANCH}`, `${PROJECT}`, `${WORKTREE}` and `${TLD_LENGTH}` are interpolated, as
are `${<SUB>_DOMAIN}` and `${<SUB>_DOMAIN_RE}` for each declared subdomain — an
`mcp` subdomain gives `${MCP_DOMAIN}` and `${MCP_DOMAIN_RE}`.

### Install cache

A fresh worktree can start from an independent copy of a previous successful
install instead of materialising every dependency from the package manager's
cache again:

```json
"install_cache": {
  "directory": "node_modules",
  "key_files": [
    "package.json",
    "packages/*/package.json",
    "yarn.lock",
    ".yarnrc",
    "mise.toml"
  ]
}
```

Before `commands.install`, dev-env restores `directory` only when it is absent
and every `key_files` path or glob has the same contents. The install command
itself is part of the cache key and always runs afterward, so Yarn, npm or any
other installer remains responsible for validating the result. After a
successful command, dev-env atomically saves the directory for the next
worktree. A failed install is never cached.

The snapshot is an ordinary recursive copy, not a symlink or hardlink, so one
worktree cannot change another. Each repository keeps only its latest snapshot
under `${XDG_CACHE_HOME:-~/.cache}/dev-envs/installs`; set `DEV_ENV_CACHE_DIR`
to override the parent directory. List every manifest, lockfile, package-manager
configuration and checked-in runtime-version file that can change the installed
directory. Missing optional key files are included in the fingerprint, and
globs allow workspace manifests to participate.

`summary` puts a project's own line into the block `up` prints at the end,
where it can be read rather than scrolled back to:

```json
"summary": {
  "Login": "bin/rails runner 'puts %Q(https://#{ENV.fetch(%q(DOMAIN))}/admin?lt=#{User.first.auto_login_token})'"
}
```

```
  Database   dev_env_thing_4001_pkliinp6  (port 4001)
  Login      https://pkliinp6-thing.example.com/admin?lt=1dscvkm5xha5hbp9d8xd
```

Each command runs once the environment answers, in its worktree and with the
variables its service runs with, and the last line it prints becomes the value.
Keep labels to ten characters, the width the fixed rows are padded to. The
environment is already up by then, so a command that fails or prints nothing
costs its row and a warning, not the `up`. Every command is one more thing
between the service starting and the summary appearing: a hook that boots the
application again is seconds the summary sits silent, and those seconds fall
outside the reported total.

`after_down` is for resources dev-env does not track — a paired worktree in a
second repository, say. Hooks run in the environment's worktree with its saved
variables, after the service stops and before the database, worktree and state
are removed, so they can still inspect everything. `DEV_ENV_KEEP_WORKTREE` and
`DEV_ENV_KEEP_DATABASE` are set to `true`/`false` reflecting `--keep-worktree`
and `--keep-database`, so hooks can honor the same intent. A failing hook
prints a warning and `down` continues; teardown never aborts halfway.

`"process_manager": "overmind"` installs Overmind's shutdown handling only for
that environment's systemd unit. Set it even when `commands.server` invokes a
wrapper; dev-env does not inspect arbitrary shell or script contents.

## Subdomains

Every environment answers on the bare hostname and an `app-`-prefixed hostname
unless the project says otherwise. `subdomains` replaces that list, and decides
which hostnames sit behind basic auth:

```json
"subdomains": {
  "":    { "auth": true },
  "app": { "auth": true },
  "mcp": { "auth": false }
}
```

`""` is the bare hostname, `auth` defaults to `true`, and a bare `true` or
`false` is shorthand for the flag on its own. An endpoint authenticating its own
callers — an MCP server presenting a bearer token, a webhook receiver — wants
`"auth": false`, since a basic-auth prompt in front of it turns every request
into a 401 the client cannot answer.

A top-level `"public": true` serves every hostname without basic auth by
default. It defaults to `false`; `dev-env up --public` and `dev-env up --private`
override the project setting for one new environment. The choice is recorded on
`up`, so existing environments keep their current access until recreated.

Caddy cannot vary basic auth between hostnames inside one site block, so guarded
and open hostnames are routed separately. Subdomain labels are folded into the
wildcard-covered leftmost label (`app-pkliinp6-project.example.com`) so the
shared base-domain certificate covers them. Adding a subdomain to a project whose
environments are already up takes effect on `dev-env warm`.

## Databases

Each environment gets one postgres database by default, created on `up` and
dropped on `down`. A project on MariaDB or MySQL declares it:

```json
"database": {
  "adapter": "mysql",
  "user": "sample_dev",
  "extra": ["${DATABASE}_data_science"]
}
```

`adapter` is `postgres` (the default) or `mysql` (alias `mariadb`). The adapter
decides how databases are created, dropped and cloned, and what the default
`${DATABASE_URL}` looks like — `postgresql:///…` or `mysql2://…`; a project
wanting other query options overrides `DATABASE_URL` in `env`. The MySQL client
connects over TCP to `host` (default `127.0.0.1`) and `port` (default `3306`)
as `user` when given, so create/drop reach the same server the URL names.

`extra` lists additional databases the environment owns, interpolated like
commands — `${DATABASE}` is the primary's name. They are created by `up`,
recreated by `seed` and dropped by `down` together with the primary, so a
project needing a second database does not have to create it in `install` and
clean it up by hand.

The adapter and the database list are recorded in the environment's state at
`up`, so `down` works outside the repository and is unaffected by later
project configuration edits.

## Seed data

Without a seed template, `up` starts each environment from a bare schema
through `commands.schema`. A project can instead keep one seeded database on
the server and have `up` clone it:

```json
"seed_template": {
  "build": "bin/rails 'db:dump:import[lightweight]'",
  "max_age": "1d"
}
```

`build` is the project's own command for filling a database, run in the
environment's worktree. Both `${DATABASE}` and `${DATABASE_URL}` name the
template rather than the environment, and so do `DATABASE` and `DATABASE_URL`
in the command's own environment, so a command that reads `DATABASE_URL` for
itself needs no change. Whatever the project already knows about fetching and
loading its seed data stays where it is; dev-env only decides when to ask.

The template is rebuilt when it is missing, when it is older than `max_age`
(`30m`, `12h`, `1d`; one day by default), or when the `build` command changes.
A build that fails leaves the template marked unusable rather than leaving the
previous build to vouch for what the failure loaded, so the next `up` rebuilds
it. `database` names it, defaulting to `dev_env_<project>_template`; it is
machine-local state like the install cache, so `down` leaves it alone.

Rebuilding drops the template first, so dev-env refuses to touch a database of
that name the current project has no record of building on that database
server. Ownership and locking follow the adapter, server endpoint and database
name, so changing servers or using the same name from another repository fails
closed. Point `database` somewhere else, or drop it yourself, if that happens.

One lock covers building and cloning together, so concurrent `up` commands
build the template once and then clone it one after another.

Each engine clones the way it can. Postgres copies the database itself through
`CREATE DATABASE ... TEMPLATE`. MySQL and MariaDB have no equivalent, so the
adapter loads the template's schema and then copies its rows with
`INSERT ... SELECT` across several clients at once — the rows never leave the
server, which is what makes it faster than replaying a dump. Against a 1.5GB
template that took around 10 seconds where the dump took 75. Views are copied
as definitions rather than inserted into, and triggers are installed once the
rows are in, so a trigger does not fire for every row the clone copies.

`dev-env seed <target>` rebuilds an existing environment's databases the same
way, and `up --no-seed` skips the template and loads `commands.schema` instead.

## Certificates and capacity

Let's Encrypt caps new certificates per registered domain per week, and
randomized hostnames would each need one, so per-hostname issuance cannot work.
The machine instead holds a single wildcard certificate for `*.<base domain>`,
obtained through DNS-01, under which every project's environments come and go
freely: creating one adds a route, removing one deletes it, and neither touches
issuance. Practical capacity is bounded by `port_range` and machine resources,
not by a configured environment count.

Basic-auth passwords live exactly as long as their environment record: created
on `up`, stable across restarts, removed on `down`.

## Development

`bin/dev-env` is a thin entry point; the implementation lives in `lib/dev_env/`,
one class per responsibility. Run the tests with `rake test`.
