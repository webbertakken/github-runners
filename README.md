# github-runners

Self-hosted GitHub Actions runners in a container, for any repository: one public image,
`ghcr.io/webbertakken/github-runner`, and a Compose template to run a few of them on your own
server. Jobs run on your hardware; the image is built on GitHub-hosted runners.

## The image

`image/Dockerfile` has two stages. CI publishes the last one, `e2e`, tagged with the commit and
`latest` ([images.yml](.github/workflows/images.yml)): on every change to `image/`, and weekly
without the layer cache, so it takes Ubuntu's security updates.

**`base`**

- [`ghcr.io/actions/actions-runner`](https://github.com/actions/runner), pinned by digest (Ubuntu
  24.04). The runner updates itself between images.
- The entrypoint: registration, state and cache handling (below).
- `libatomic1`, which Node 26's official Linux binary needs.
- `gh`, `git`, `curl`, `jq`, `ca-certificates`, `lsof`, `procps`, `unzip`, `xz-utils` and `zstd`.
- The action archive cache, with the archives of `actions/checkout`, `jdx/mise-action` and
  `actions/upload-artifact`.
- No Node and no mise: jobs install their tools from their own `mise.toml` with
  [`jdx/mise-action`](https://github.com/jdx/mise-action), into `MISE_DATA_DIR=/cache/mise`.

**`e2e`** (published) is `base` plus:

- Playwright's system libraries for Chromium. The browser itself comes per job from the checkout's
  Playwright, into `PLAYWRIGHT_BROWSERS_PATH=/cache/ms-playwright`.
- A headless JRE (OpenJDK 21) for the Firebase emulators.
- The standalone Firebase CLI.

Every download pins a version and checks its sha256. The image holds no secret.

### The cache volume

Everything a job downloads lands on `/cache`, so a runner fetches it once, not per job:

| Path                                | What                                       |
| ----------------------------------- | ------------------------------------------ |
| `/cache/mise`                       | mise and every tool it installs            |
| `/cache/toolcache`                  | the Actions tool cache (`setup-*` actions) |
| `/cache/yarn`, `/cache/yarn-global` | Yarn's caches                              |
| `/cache/ms-playwright`              | Playwright's browsers                      |
| `/cache/action-archives`            | action archives (below)                    |

It only ever speeds jobs up: deleting it is safe.

### Action archives

The runner downloads each action a job uses from `codeload.github.com` in "Set up job", which
answers a busy address HTTP 429 and fails the job. It takes `<owner>_<repo>/<sha>.tar.gz` from
`/cache/action-archives` instead (`ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE`), filled three ways:

1. **The image** carries the archives in [`image/actions.txt`](image/actions.txt) and copies them to
   the cache at start, overwriting none.
2. **Your repository's list**: the pins your workflows use, `owner/repo@full-commit` per line
   ([`templates/actions.txt`](templates/actions.txt)), mounted at `/etc/github-runner/actions.txt`.
   Each start downloads the ones the cache lacks, through the API's tarball route, which is not
   throttled like codeload. A failure is logged, never fatal.
3. **The job-completed hook** archives any action a job fetched that the cache lacks, so a new pin
   is downloaded once.

The archive is keyed by the commit, so pin actions by full SHA. A repository can keep its list equal
to its workflows' pins with a test.

## Use it in a repository

1. Copy [`templates/`](templates/) to a folder on the server: `compose.yaml`, `actions.txt`, and
   `runner.env.example` once per runner as `runner-<n>.env`.
2. In `compose.yaml`, replace `OWNER/REPO`, the names, the host paths and the limits. Each runner
   has its own state and cache folders: create them, owned by uid 1001.

   ```bash
   mkdir -p /srv/OWNER-REPO-runner-1/{state,cache}
   chown -R 1001:1001 /srv/OWNER-REPO-runner-1
   chmod 700 /srv/OWNER-REPO-runner-1/state
   ```

3. Give each runner labels. Workflows pick runners by label
   (`runs-on: [self-hosted, linux, x64, e2e]`), so runners that must never wait on each other, such
   as deploys and test suites, get labels of their own.
4. Register: the repository's Settings, Actions, Runners, **New self-hosted runner**. Copy only the
   token, valid for one hour, into that runner's env file without it reaching the shell history:

   ```bash
   install -m 600 /dev/null runner-1.env
   read -rsp 'Token: ' token && printf 'RUNNER_TOKEN=%s\n' "$token" > runner-1.env; unset token; echo
   ```

5. Start, and watch for `Registered` and `Listening for jobs`:

   ```bash
   docker compose pull && docker compose up -d && docker logs -f OWNER-REPO-runner-1
   ```

6. Delete the env file: the token is spent, and the registration lives in the state folder.

A runner offline for 14 days is removed by GitHub: empty its state folder and register again.

### Settings

| Variable                | Required    | Meaning                                         |
| ----------------------- | ----------- | ----------------------------------------------- |
| `RUNNER_REPOSITORY_URL` | yes         | `https://github.com/<owner>/<repo>`             |
| `RUNNER_NAME`           | yes         | the runner's name in the repository's list      |
| `RUNNER_LABELS`         | no          | comma-separated, beside `self-hosted,linux,x64` |
| `RUNNER_TOKEN`          | first start | the registration token                          |

The entrypoint refuses to start, saying why, when a required setting is missing, a volume is not
writable by uid 1001, there is neither a registration nor a token, or the state holds a registration
for another repository.

## Update

`docker compose up -d` pulls the newest image first (`pull_policy: always`); a restart never changes
it. Wait until the runners are idle (Settings, Actions, Runners): recreating a runner ends the job
it holds. Then:

```bash
docker compose pull && docker compose up -d
```

The registrations in the state folders are kept. To hold or roll back a version, pin its commit tag
(`ghcr.io/webbertakken/github-runner:<commit>`) instead of `latest`.

### A new Node major

Jobs install Node themselves, but Node's official binary can need a system library the image lacks:
Node 26 needs `libatomic1`. When a repository moves to a new Node major, publish an image with what
it needs and pull it on the server **before** the change merges, or every job fails installing Node
with an error such as `libatomic.so.1: cannot open shared object file`. Check a running runner:

```bash
docker exec <runner> bash -c 'ldconfig -p | grep libatomic.so.1; printenv MISE_DATA_DIR'
```

## Develop

```bash
docker buildx build --load --target e2e -t github-runner:try image
docker run --rm -e RUNNER_REPOSITORY_URL=https://github.com/OWNER/REPO -e RUNNER_NAME=try \
  -v /runner-state -v /cache github-runner:try
```

The second command stops with "not registered yet and no RUNNER_TOKEN": the entrypoint works.

### Publishing the lighter `base` stage

Only `e2e` is published. Should a runner ever need nothing but `base`, add a second
`docker/build-push-action` step to `images.yml` with `target: base` and its own package name (for
example `ghcr.io/webbertakken/github-runner-base`), then make that package public as well.

## Licence

[MIT](LICENSE)
