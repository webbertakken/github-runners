# syntax=docker/dockerfile:1
# github-runner: a self-hosted GitHub Actions runner for any repository, in a container. Node, Yarn
# and every other project tool come per job from the checkout's own mise.toml, installed into the
# cache (MISE_DATA_DIR). It holds no secret. See README.md.
#
# Two stages; the last, e2e, is what CI publishes as ghcr.io/webbertakken/github-runner.
#   base  the runner, its entrypoint and registration, libatomic1 (Node 26), gh and the action
#         archive cache; jobs install mise with jdx/mise-action, into MISE_DATA_DIR on the cache
#   e2e   base plus what browser and emulator tests need: Playwright's system libraries for
#         Chromium, a headless JRE and the standalone Firebase CLI

FROM ghcr.io/actions/actions-runner:2.338.1@sha256:e275409999c37162649aa050ca573f03eab2eabcb3a1e7fcc47548de6b4f9690 AS base

# renovate: datasource=github-releases depName=cli/cli
ARG GH_VERSION=2.103.2
ARG GH_SHA256=62ccf747115ddc61237efffdde66a3c8f70ba249433dc64f70801089b59c59c8

# 0 is root; 1001 is the base image's runner user, as which jobs run.
USER 0
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# The weekly rebuild takes Ubuntu's security updates (upgrade). git for actions/checkout; jq for the
# entrypoint; lsof and procps to inspect a job's processes; unzip, xz-utils and zstd for the archives
# jdx/mise-action, mise and jobs unpack; libatomic1, which Node 26's official Linux binary links.
# hadolint ignore=DL3005,DL3008
RUN apt-get update \
  && apt-get upgrade -y --no-install-recommends \
  && apt-get install -y --no-install-recommends \
    ca-certificates curl git jq lsof procps unzip xz-utils zstd libatomic1 \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/gh.tar.gz \
    "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
  && echo "${GH_SHA256}  /tmp/gh.tar.gz" | sha256sum -c - \
  && tar -xzf /tmp/gh.tar.gz -C /tmp \
  && install -m 755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
  && rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_amd64"

# The volumes' mount points, owned by the runner user, so a Docker volume starts out writable by it.
RUN mkdir -p /runner-state /cache && chown 1001:1001 /runner-state /cache && chmod 700 /runner-state

COPY --chmod=755 entrypoint.sh /usr/local/bin/github-runner-entrypoint
COPY --chmod=755 action-archives.sh /usr/local/bin/github-runner-action-archives
COPY --chmod=755 keep-action-archives.sh /usr/local/bin/github-runner-keep-action-archives

# The archives of the generic actions most workflows pin (actions.txt), so "Set up job" downloads none
# from codeload.github.com, which answers a busy address HTTP 429. A repository's own actions come
# from its list at start (ACTION_ARCHIVES) or from the job-completed hook. A GitHub token, when the
# build has one, lifts the anonymous API rate limit: a BuildKit secret, mounted for this step only.
COPY actions.txt /opt/action-archives.txt
RUN --mount=type=secret,id=github_token,required=false \
  GITHUB_TOKEN_FILE=/run/secrets/github_token \
  github-runner-action-archives seed /opt/action-archives.txt /opt/action-archives

# Docker's /etc/hosts maps localhost to ::1 and 127.0.0.1: Node then listens on ::1 (a dev server)
# but connects to 127.0.0.1 (fetch, net), and a job's local servers never answer. IPv4 first gives
# localhost one address.
ENV NODE_OPTIONS=--dns-result-order=ipv4first

# The runner's debug trace stays in _diag; docker logs shows the entrypoint and the runner's summary.
ENV ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=0

# Everything a job downloads lands on the /cache volume, so it is fetched once per runner, not per
# job: mise (jdx/mise-action) with the tools it installs, the Actions tool cache (setup-* actions),
# Yarn's caches, and the action archives the runner would otherwise download in "Set up job".
ENV MISE_DATA_DIR=/cache/mise \
    RUNNER_TOOL_CACHE=/cache/toolcache \
    AGENT_TOOLSDIRECTORY=/cache/toolcache \
    YARN_CACHE_FOLDER=/cache/yarn \
    YARN_GLOBAL_FOLDER=/cache/yarn-global \
    ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE=/cache/action-archives \
    ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/local/bin/github-runner-keep-action-archives \
    ACTION_ARCHIVES=/etc/github-runner/actions.txt \
    RUNNER_STATE=/runner-state

USER 1001
WORKDIR /home/runner
ENTRYPOINT ["/usr/local/bin/github-runner-entrypoint"]

FROM base AS e2e

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Only to install Chromium's system libraries at build time (`playwright install-deps`); removed after.
# renovate: datasource=node-version depName=node
ARG BUILD_NODE_VERSION=26.12.1
ARG BUILD_NODE_SHA256=6170b2d474e1c626f43cff3adc118df9fe3b573258a4fc3d850c8dbc6b079bbd
# A newer Playwright that needs other system libraries means a new image with this raised.
# renovate: datasource=npm depName=playwright
ARG PLAYWRIGHT_VERSION=1.64.1
# renovate: datasource=github-releases depName=firebase/firebase-tools
ARG FIREBASE_TOOLS_VERSION=15.34.1
ARG FIREBASE_TOOLS_SHA256=39150511323536d08fa8604c232db10da2b2421ce2c36f3913d5650a6fbe6e58

USER 0

# A headless JRE for the Firebase emulators.
# hadolint ignore=DL3008
RUN apt-get update \
  && apt-get install -y --no-install-recommends openjdk-21-jre-headless \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/node.tar.xz \
    "https://nodejs.org/dist/v${BUILD_NODE_VERSION}/node-v${BUILD_NODE_VERSION}-linux-x64.tar.xz" \
  && echo "${BUILD_NODE_SHA256}  /tmp/node.tar.xz" | sha256sum -c - \
  && mkdir /tmp/node && tar -xJf /tmp/node.tar.xz -C /tmp/node --strip-components=1 \
  && PATH="/tmp/node/bin:${PATH}" npx --yes "playwright@${PLAYWRIGHT_VERSION}" install-deps chromium \
  && rm -rf /tmp/node /tmp/node.tar.xz /root/.npm /var/lib/apt/lists/*

RUN curl -fsSL -o /usr/local/bin/firebase \
    "https://github.com/firebase/firebase-tools/releases/download/v${FIREBASE_TOOLS_VERSION}/firebase-tools-linux" \
  && echo "${FIREBASE_TOOLS_SHA256}  /usr/local/bin/firebase" | sha256sum -c - \
  && chmod 755 /usr/local/bin/firebase

# The browsers a job's Playwright installs land on the cache too.
ENV PLAYWRIGHT_BROWSERS_PATH=/cache/ms-playwright \
    FIREBASE_CLI_DISABLE_UPDATE_CHECK=true

USER 1001
