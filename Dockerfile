# SPDX-License-Identifier: Apache-2.0
# Defaults match versions.env. scripts/check_pins.sh fails when they drift.

ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.13.7@sha256:96f40d3904aad8d0bd010539001d36c8e2188b981e1334471a90c4a1d93bb490
ARG UV_VERSION=0.13.7
ARG PYTHON_VERSION=3.12.16
ARG RUST_VERSION=1.96.0
ARG RUSTUP_VERSION=1.28.2
ARG RUSTUP_SHA256=20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c
ARG GO_VERSION=1.26.10
ARG GO_SHA256=ccfe7ae822d2c2f41f4fe7c956199967a4dac22d0ee0d2b2bfdb440aab3b20c5
ARG CARGO_BUILD_JOBS=1
ARG AWSCLI_VERSION=2.40.1
ARG AWSCLI_SHA256=fddb097a8ea197dc9beed9e4426ef99aded612a52df64581e079b6e8817e1d24
ARG JUST_VERSION=1.59.0
ARG JUST_SHA256=409044617b6f06517c1035e55ca38c8c856ff8b650e41bc2aa1ef82d5903a23e
ARG TERRAFORM_VERSION=1.9.8
ARG TERRAFORM_SHA256=186e0145f5e5f2eb97cbd785bc78f21bae4ef15119349f6ad4fa535b83b10df8
ARG DBT_REPO=https://github.com/aoelvp94/dbt.git
ARG DBT_BRANCH=local/athena-combined
ARG DBT_SPEC=aoelvp94/dbt/local/athena-combined
ARG DBT_SHA=e7d7bdc6c659399606965545b8e8f90c9c41dde5
ARG DRIVER_REPO=https://github.com/dbt-labs/athena.git
ARG DRIVER_SHA=b147c187872fa8b21d8fa3ab0c56d33d9b19d28f
ARG DRIVER_PRS="20 19 22"
ARG DRIVER_PR_20_SHA=0df20751ea9c509596af181bca9a5b0479e55fa0
ARG DRIVER_PR_19_SHA=0be3f7a8da7da54aa24abd2e73bff769c9eaef28
ARG DRIVER_PR_22_SHA=3acd21d33126d067302b1516b43dc78d36b1e06d

FROM ${UV_IMAGE} AS uvbin

FROM ${DEBIAN_IMAGE} AS build

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ARG DEBIAN_IMAGE
ARG UV_IMAGE
ARG UV_VERSION
ARG PYTHON_VERSION
ARG RUST_VERSION
ARG RUSTUP_VERSION
ARG RUSTUP_SHA256
ARG GO_VERSION
ARG GO_SHA256
ARG CARGO_BUILD_JOBS
ARG AWSCLI_VERSION
ARG JUST_VERSION
ARG TERRAFORM_VERSION
ARG DBT_REPO
ARG DBT_BRANCH
ARG DBT_SPEC
ARG DBT_SHA
ARG DRIVER_REPO
ARG DRIVER_SHA
ARG DRIVER_PRS
ARG DRIVER_PR_20_SHA
ARG DRIVER_PR_19_SHA
ARG DRIVER_PR_22_SHA

ENV RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    PATH="/opt/cargo/bin:/usr/local/go/bin:${PATH}" \
    GOPATH=/go \
    GOCACHE=/root/.cache/go-build \
    CGO_ENABLED=1 \
    E2E_REQUIRE_TOOLCHAIN=1 \
    GIT_TERMINAL_PROMPT=0 \
    GIT_AUTHOR_DATE=2026-11-12T00:00:00Z \
    GIT_COMMITTER_DATE=2026-11-12T00:00:00Z \
    GIT_AUTHOR_NAME=dbt-v2-athena-e2e \
    GIT_AUTHOR_EMAIL=aoelvp94@gmail.com \
    GIT_COMMITTER_NAME=dbt-v2-athena-e2e \
    GIT_COMMITTER_EMAIL=aoelvp94@gmail.com \
    UV_PYTHON_INSTALL_DIR=/opt/uv-python \
    UV_LINK_MODE=copy \
    CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS}

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      git \
      build-essential \
      pkg-config \
      libssl-dev \
      cmake \
      zlib1g-dev \
      clang \
      libclang-dev \
      protobuf-compiler \
 && rm -rf /var/lib/apt/lists/*

COPY --from=uvbin /uv /uvx /usr/local/bin/

RUN uv --version | grep -q "^uv ${UV_VERSION} "

RUN curl -fsSL -o /tmp/rustup-init \
      "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/x86_64-unknown-linux-gnu/rustup-init" \
 && echo "${RUSTUP_SHA256}  /tmp/rustup-init" | sha256sum -c - \
 && chmod +x /tmp/rustup-init \
 && /tmp/rustup-init -y --default-toolchain "${RUST_VERSION}" --profile minimal --no-modify-path \
 && rm /tmp/rustup-init \
 && rustup component add rustfmt clippy \
 && rustc --version | grep -q "^rustc ${RUST_VERSION} "

RUN curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
 && echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c - \
 && rm -rf /usr/local/go \
 && tar -C /usr/local -xzf /tmp/go.tgz \
 && rm /tmp/go.tgz \
 && go version | grep -q "go${GO_VERSION} "

WORKDIR /src

COPY pyproject.toml uv.lock .python-version ./
RUN uv python install "${PYTHON_VERSION}" \
 && uv sync --frozen --project /src \
 && uv run --frozen --project /src python --version | grep -q "^Python ${PYTHON_VERSION}$"

COPY . .
RUN git config --global --add safe.directory '*' \
 && env -u DBT_BRANCH scripts/build_dbt.sh \
      --merge-only \
      --cache-dir /src/.cache/dbt-v2-athena-e2e \
      --branch "${DBT_SPEC}" \
      --expect-commit "${DBT_SHA}" \
      --driver-prs "${DRIVER_PRS}" \
      --expect-driver-main "${DRIVER_SHA}" \
      --expect-driver-pr "20:${DRIVER_PR_20_SHA}" \
      --expect-driver-pr "19:${DRIVER_PR_19_SHA}" \
      --expect-driver-pr "22:${DRIVER_PR_22_SHA}"

RUN --mount=type=cache,target=/opt/cargo/registry,sharing=locked \
    --mount=type=cache,target=/opt/cargo/git,sharing=locked \
    --mount=type=cache,target=/src/.cache/dbt-v2-athena-e2e/dbt-src/target,sharing=locked \
    --mount=type=cache,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,target=/root/.cache/go-build,sharing=locked \
    env -u DBT_BRANCH scripts/build_dbt.sh \
      --cache-dir /src/.cache/dbt-v2-athena-e2e \
      --branch "${DBT_SPEC}" \
      --expect-commit "${DBT_SHA}" \
      --driver-prs "${DRIVER_PRS}" \
      --expect-driver-main "${DRIVER_SHA}" \
      --expect-driver-pr "20:${DRIVER_PR_20_SHA}" \
      --expect-driver-pr "19:${DRIVER_PR_19_SHA}" \
      --expect-driver-pr "22:${DRIVER_PR_22_SHA}"

RUN bash scripts/write_build_info.sh /src/BUILD_INFO.json /src/build/merge-report.json

FROM ${DEBIAN_IMAGE} AS runtime

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ARG DEBIAN_IMAGE
ARG UV_IMAGE
ARG UV_VERSION
ARG PYTHON_VERSION
ARG RUST_VERSION
ARG RUSTUP_VERSION
ARG GO_VERSION
ARG CARGO_BUILD_JOBS
ARG AWSCLI_VERSION
ARG AWSCLI_SHA256
ARG JUST_VERSION
ARG JUST_SHA256
ARG TERRAFORM_VERSION
ARG TERRAFORM_SHA256
ARG DBT_REPO
ARG DBT_BRANCH
ARG DBT_SPEC
ARG DBT_SHA
ARG DRIVER_REPO
ARG DRIVER_SHA
ARG DRIVER_PRS
ARG DRIVER_PR_20_SHA
ARG DRIVER_PR_19_SHA
ARG DRIVER_PR_22_SHA

LABEL org.opencontainers.image.title="dbt-v2-athena-e2e" \
      org.opencontainers.image.source="https://github.com/aoelvp94/dbt-v2-athena-e2e" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.description="Pinned dbt v2 Athena end-to-end harness" \
      e2e.dbt.repo="${DBT_REPO}" \
      e2e.dbt.branch="${DBT_BRANCH}" \
      e2e.dbt.sha="${DBT_SHA}" \
      e2e.driver.repo="${DRIVER_REPO}" \
      e2e.driver.sha="${DRIVER_SHA}" \
      e2e.driver.pr20="${DRIVER_PR_20_SHA}" \
      e2e.driver.pr19="${DRIVER_PR_19_SHA}" \
      e2e.driver.pr22="${DRIVER_PR_22_SHA}" \
      e2e.rust="${RUST_VERSION}" \
      e2e.go="${GO_VERSION}" \
      e2e.uv="${UV_VERSION}" \
      e2e.python="${PYTHON_VERSION}" \
      e2e.awscli="${AWSCLI_VERSION}" \
      e2e.terraform="${TERRAFORM_VERSION}" \
      e2e.just="${JUST_VERSION}" \
      e2e.debian="${DEBIAN_IMAGE}" \
      e2e.uv.image="${UV_IMAGE}"

ENV PATH="/opt/e2e/.cache/dbt-v2-athena-e2e/dist:${PATH}" \
    UV_PYTHON_INSTALL_DIR=/opt/uv-python \
    UV_LINK_MODE=copy \
    UV_CACHE_DIR=/tmp/uv-cache \
    HOME=/tmp/e2e-home \
    DBT_ALLOW_EXPERIMENTAL_ADAPTERS=true \
    DBT_SEND_ANONYMOUS_USAGE_STATS=false

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      git \
      jq \
      less \
      unzip \
 && rm -rf /var/lib/apt/lists/*

COPY --from=uvbin /uv /uvx /usr/local/bin/

RUN uv --version | grep -q "^uv ${UV_VERSION} " \
 && curl -fsSL -o /tmp/awscli.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" \
 && echo "${AWSCLI_SHA256}  /tmp/awscli.zip" | sha256sum -c - \
 && unzip -q /tmp/awscli.zip -d /tmp \
 && /tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli \
 && rm -rf /tmp/aws /tmp/awscli.zip \
 && curl -fsSL -o /tmp/just.tgz "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
 && echo "${JUST_SHA256}  /tmp/just.tgz" | sha256sum -c - \
 && tar -C /usr/local/bin -xzf /tmp/just.tgz just \
 && rm /tmp/just.tgz \
 && curl -fsSL -o /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
 && echo "${TERRAFORM_SHA256}  /tmp/terraform.zip" | sha256sum -c - \
 && unzip -q -o -d /usr/local/bin /tmp/terraform.zip \
 && rm /tmp/terraform.zip \
 && chmod 755 /usr/local/bin/just /usr/local/bin/terraform

WORKDIR /opt/e2e

COPY pyproject.toml uv.lock .python-version ./
RUN uv python install "${PYTHON_VERSION}" \
 && uv sync --frozen --project /opt/e2e

COPY . .
COPY --from=build /src/.cache/dbt-v2-athena-e2e/dist /opt/e2e/.cache/dbt-v2-athena-e2e/dist
COPY --from=build /src/BUILD_INFO.json /opt/e2e/BUILD_INFO.json

RUN mkdir -p /opt/e2e/results /opt/e2e/infra/.state /opt/e2e/build /tmp/e2e-home /tmp/uv-cache \
 && chmod -R a+rX /opt/e2e /opt/uv-python /usr/local/bin/uv /usr/local/bin/uvx \
 && chmod -R a+rwX /opt/e2e/project /opt/e2e/results /opt/e2e/infra /opt/e2e/build /opt/e2e/.venv /tmp/e2e-home /tmp/uv-cache \
 && chmod 755 /opt/e2e/scripts/*.sh /opt/e2e/infra/*.sh \
 && bash scripts/write_build_info.sh --apt /opt/e2e/BUILD_INFO.json \
 && chmod a+r /opt/e2e/BUILD_INFO.json

ENTRYPOINT ["/opt/e2e/scripts/container_entrypoint.sh"]
CMD ["just", "--list"]
