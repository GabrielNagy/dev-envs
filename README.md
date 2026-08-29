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

Private environments are served at `https://dev<N>.<project>.<base domain>`,
plus one hostname per subdomain the project declares — by default `app.`, so
`https://app.dev<N>.<project>.<base domain>`. `up --public` uses a persistent
randomized alias in place of `dev<N>` and disables basic auth.

## Setting up a machine

Needs postgres, Caddy, and a wildcard DNS record pointing at the box.

```sh
dev-env setup     # writes config.json, then re-run to write the Caddy config
```

`setup` detects the public address, writes `/etc/caddy/Caddyfile` (via sudo) and
installs the `dev-env@.service` systemd user template. Enable lingering so
environments survive logout: `loginctl enable-linger $USER`.

`config.json` is machine-local and gitignored — see `config.example.json`.
By default Caddy's automatic HTTPS obtains one certificate per exact hostname.
Set `acme_dns_provider` (for example, `route53`) to use one wildcard certificate
per project through DNS-01; the provider's credentials must be available to Caddy.
Certificate mode is a setup-time choice, as is `base_domain` when using wildcards;
tear down environments and remove their managed Caddy sites before changing either.

## Existing worktrees

`up` does not need a branch of its own. If the branch is already checked out —
by an agent, or by hand, anywhere on disk — that checkout is the one served:

```sh
dev-env up feature-x                          # finds and adopts an existing checkout
dev-env up feature-x --worktree ~/some/path   # or point at one explicitly
```

Otherwise `up` creates a worktree as before, from the local branch, from
`origin/<branch>`, or from `--base` when the branch is new.

`down` removes a worktree only when `dev-env` created it. `git worktree remove
--force` discards uncommitted work and cannot be undone, so removal needs
positive evidence of ownership rather than the absence of a reason to stop:

| `up` recorded | `down` does |
| --- | --- |
| it created the worktree | removes it, unless `--keep-worktree` |
| it adopted the worktree | never removes it; no flag overrides this |
| nothing — the environment predates ownership tracking | leaves it, unless `--remove-worktree` |

That last row matters because older versions silently adopted a worktree already
sitting at the default path, which is exactly where agents put theirs. Such an
environment cannot prove the checkout is its own, so it leaves it behind and says
so. Use `--remove-worktree` once you have checked.

The `up` summary marks an adopted worktree.

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
| `subdomains` | Hostnames to serve, and which sit behind basic auth |
| `commands` | `install`, `schema`, `migrate`, `server` |
| `env` | Environment variables for those commands and the service |
| `after_restore` | Commands to run after a dump is restored |
| `link_from_root` | Globs symlinked from the primary checkout into each worktree, for gitignored files such as credential keys |
| `worktree_files` | Untracked files written into each worktree, optionally guarded by `unless_file_contains` |
| `pool_size`, `seed`, `worktree_root` | Override the defaults |

`${DOMAIN}`, `${DOMAIN_RE}`, `${PORT}`, `${DATABASE}`, `${DATABASE_URL}`,
`${SLOT}`, `${PROJECT}`, `${WORKTREE}` and `${TLD_LENGTH}` are interpolated, as
are `${<SUB>_DOMAIN}` and `${<SUB>_DOMAIN_RE}` for each declared subdomain — an
`mcp` subdomain gives `${MCP_DOMAIN}` and `${MCP_DOMAIN_RE}`.

## Subdomains

Every environment answers on the bare hostname and on `app.` unless the project
says otherwise. `subdomains` replaces that list, and decides which hostnames sit
behind basic auth:

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

`dev-env up --public` still overrides the lot and serves every hostname open.

Caddy cannot vary basic auth between hostnames inside one site block, so guarded
and open hostnames are routed separately. With wildcard certificates, subdomain
labels are folded into the leftmost label (`dev1-app.project.example.com`) so
the certificate covers them. Adding a subdomain to a project whose environments
are already up takes effect on `dev-env warm`.

## Seed data

`dev-env up` restores `~/dev-envs/dumps/<project>-seed.pdump` if present, and
starts from a bare schema otherwise. `dev-env seed <slot>` rebuilds an existing
environment's database from it.

## Why a fixed pool

By default Caddy issues one certificate per hostname, and Let's Encrypt caps new
certificates per registered domain per week. Reusing a small pool of slots means
those hostnames are issued once and thereafter only renewed. A configured
wildcard certificate covers the whole project instead. Freeing a slot leaves a
placeholder Caddy site behind so renewal continues while it is idle.

Basic-auth passwords are per slot and persist across teardown, so credentials
saved in a browser keep working when a slot is reused.
