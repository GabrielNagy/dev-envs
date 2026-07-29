# dev-env

Run a project's branches on a box and browse them over HTTPS, so a change can be
clicked through in a real browser rather than only asserted about in tests.

An environment is one slot in a per-project pool, bundling a git worktree, a
postgres database, a loopback port and a systemd user unit. Caddy terminates TLS
in front and fetches a Let's Encrypt certificate per hostname.

```
dev-env up <branch>     # claim a free slot
dev-env list            # what is running, and which slots are free
dev-env creds [slot]    # basic-auth credentials
dev-env logs <slot> -f  # follow the log
dev-env down <slot>     # tear down and free the slot
```

Environments are served at `https://dev<N>.<project>.<base domain>` and
`https://app.dev<N>.<project>.<base domain>`.

## Setting up a machine

Needs postgres, Caddy, and a wildcard DNS record pointing at the box.

```sh
dev-env setup     # writes config.json, then re-run to write the Caddy config
```

`setup` detects the public address, writes `/etc/caddy/Caddyfile` (via sudo) and
installs the `dev-env@.service` systemd user template. Enable lingering so
environments survive logout: `loginctl enable-linger $USER`.

`config.json` is machine-local and gitignored — see `config.example.json`.

## Setting up a project

```sh
cd ~/projects/thing && dev-env init
```

That writes a `.dev-env.json` describing how to build an environment: the
commands to install dependencies, load the schema, migrate and serve, plus any
untracked files a worktree needs. Nothing in this tool is specific to a project
or a framework — the defaults `init` writes just happen to suit Rails.

Keys, all optional except `commands.server`:

| Key | Purpose |
| --- | --- |
| `name` | Hostname component; defaults to the repository directory name |
| `commands` | `install`, `schema`, `migrate`, `server` |
| `env` | Environment variables for those commands and the service |
| `after_restore` | Commands to run after a dump is restored |
| `link_from_root` | Globs symlinked from the primary checkout into each worktree, for gitignored files such as credential keys |
| `worktree_files` | Untracked files written into each worktree, optionally guarded by `unless_file_contains` |
| `pool_size`, `seed`, `worktree_root` | Override the defaults |

`${DOMAIN}`, `${DOMAIN_RE}`, `${PORT}`, `${DATABASE}`, `${DATABASE_URL}`,
`${SLOT}`, `${PROJECT}`, `${WORKTREE}` and `${TLD_LENGTH}` are interpolated.

## Seed data

`dev-env up` restores `~/dev-envs/dumps/<project>-seed.pdump` if present, and
starts from a bare schema otherwise. `dev-env seed <slot>` rebuilds an existing
environment's database from it.

## Why a fixed pool

Caddy issues one certificate per hostname, and Let's Encrypt caps new
certificates per registered domain per week. Reusing a small pool of slots means
those hostnames are issued once and thereafter only renewed, and renewals do not
count against that cap. Freeing a slot leaves a placeholder Caddy site behind so
renewal continues while it is idle.

Basic-auth passwords are per slot and persist across teardown, so credentials
saved in a browser keep working when a slot is reused.
