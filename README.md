# dev-env

Run a project's branches on a box and browse them over HTTPS, so a change can be
clicked through in a real browser rather than only asserted about in tests.

An environment is created on demand for one branch, bundling a git worktree, a
postgres database, a loopback port and a systemd user unit. Caddy terminates TLS
in front through one wildcard certificate per project.

```
dev-env up <branch>     # create an environment
dev-env list            # what is recorded, and where it answers
dev-env creds [branch]  # basic-auth credentials
dev-env logs [branch] -f  # follow the log
dev-env exec [branch] -c "bin/rails db:migrate:status"  # run one command in its context
dev-env activate [branch]  # open a shell in its worktree + env; exit to leave
dev-env down <branch>   # tear the environment down
```

Run from inside an environment's worktree, every command taking `[branch]`
infers it from the current directory, so the argument can be omitted.

Environments are served at `https://<identifier>.<project>.<base domain>`,
plus one hostname per subdomain the project declares — by default `app`, folded
into the leftmost label as `https://app-<identifier>.<project>.<base domain>`.
The identifier is a random eight-character label, or one chosen with
`up --id <label>` (a lowercase DNS label of at most eight characters, rejected
if invalid or already used by another environment of the same project):

```sh
dev-env up dev-env-support                 # e.g. https://pkliinp6.sample.example.com
dev-env up dev-env-support --id pkliinp6   # a stable, recognizable hostname
```

The identifier, port, URL and password stay fixed while the environment record
exists, including across restarts and inactive periods. `down` ends that
lifetime; bringing the same branch up later creates a new environment and may
choose a new identifier, port, URL and password. `up --public` only disables
basic auth; the hostname is chosen the same way.

Only one environment may exist per project and exact branch. Internally each
environment is keyed as `<project>--<branch slug>--<port>`; the port keeps
branches whose slugs collide (`feature/foo`, `feature-foo`) distinct, and names
the systemd unit, state files, Caddy route and database unambiguously.

## Setting up a machine

Needs postgres, Caddy, and a wildcard DNS record pointing at the box.

```sh
dev-env setup     # writes config.json, then re-run to write the Caddy config
```

`setup` detects the public address, writes `/etc/caddy/Caddyfile` (via sudo) and
installs the `dev-env@.service` systemd user template. Enable lingering so
environments survive logout: `loginctl enable-linger $USER`.

`config.json` is machine-local and gitignored — see `config.example.json`.
Hostname identifiers are unbounded, so one certificate per hostname would grow
issuance without limit; each project is instead served under one wildcard
certificate obtained through DNS-01. `acme_dns_provider` (for example,
`route53`) is therefore required, and the provider's credentials must be
available to Caddy. `base_domain` is a setup-time choice; tear down
environments and remove their managed Caddy sites before changing it.

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
| `process_manager` | Set to `overmind` when `commands.server` delegates to Overmind |
| `env` | Environment variables for those commands and the service |
| `after_restore` | Commands to run after a dump is restored |
| `after_down` | Commands run by `down` after the service stops, before anything is removed |
| `link_from_root` | Globs symlinked from the primary checkout into each worktree, for gitignored files such as credential keys |
| `worktree_files` | Untracked files written into each worktree, optionally guarded by `unless_file_contains` |
| `seed`, `worktree_root` | Override the defaults |

`${DOMAIN}`, `${DOMAIN_RE}`, `${PORT}`, `${DATABASE}`, `${DATABASE_URL}`,
`${BRANCH}`, `${PROJECT}`, `${WORKTREE}` and `${TLD_LENGTH}` are interpolated, as
are `${<SUB>_DOMAIN}` and `${<SUB>_DOMAIN_RE}` for each declared subdomain — an
`mcp` subdomain gives `${MCP_DOMAIN}` and `${MCP_DOMAIN_RE}`.

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
and open hostnames are routed separately. Subdomain labels are folded into the
wildcard-covered leftmost label (`app-pkliinp6.project.example.com`) so the
project's certificate covers them. Adding a subdomain to a project whose
environments are already up takes effect on `dev-env warm`.

## Seed data

`dev-env up` restores `~/dev-envs/dumps/<project>-seed.pdump` if present, and
starts from a bare schema otherwise. `dev-env seed <branch>` rebuilds an
existing environment's database from it.

## Certificates and capacity

Let's Encrypt caps new certificates per registered domain per week, and
randomized hostnames would each need one, so per-hostname issuance cannot work.
Each project instead holds a single wildcard certificate for
`*.<project>.<base domain>`, obtained through DNS-01, under which environments
come and go freely: creating one adds a route, removing one deletes it, and
neither touches issuance. Practical capacity is bounded by `port_range` and
machine resources, not by a configured environment count.

Basic-auth passwords live exactly as long as their environment record: created
on `up`, stable across restarts, removed on `down`.

## Migrating from the fixed-pool version

There is no legacy-state detection or migration; the cut is clean:

1. Use the old version to tear down each `devN` environment, passing
   `--keep-worktree` where its checkout must remain.
2. Remove old parked and exact-host managed Caddy files, old slot state and old
   slot secrets.
3. Configure wildcard DNS, Caddy's DNS provider module and provider credentials.
4. Remove `pool_size` from `config.json` and rerun `dev-env setup`.
5. Bring each desired branch up again — preserved worktrees are adopted
   automatically — supplying `--id` only when a chosen hostname is wanted.

## Development

`bin/dev-env` is a thin entry point; the implementation lives in `lib/dev_env/`,
one class per responsibility. Run the tests with `rake test`.
