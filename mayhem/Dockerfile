# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form, PREFERRED) — builds ON TOP of the org C/C++ base
# image (ghcr.io/savantenvs/base). The base already provides debian + clang/llvm +
# libFuzzer/afl++ + the identities + the build-contract ENV, so this only adds the
# per-commit build (built on top of the prebuilt base, rather than building the toolchain in-image).
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mytag .

# The org base, pinned to a fixed DATE-tagged base (YYYYMMDD; shared by all integrations
# minted against it). Use the current dated tag; pin by digest in production: ...base@sha256:<digest>.
FROM ghcr.io/savantenvs/base:20261023

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an
# empty value breaks clang ("must be a non-negative decimal integer") both here and for
# any in-image rebuild. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# To change it for a build (e.g. ASan-only, or add MSan): --build-arg SANITIZER_FLAGS="...".
# Declare it WITHOUT a default (no '='): an undefaulted ARG lets the base ENV flow through to
# build.sh when not passed, and an explicit --build-arg overrides it. (An empty default — `=` —
# would instead shadow the base ENV and silently wipe the sanitizers.)
ARG SANITIZER_FLAGS
# Coverage (optional, off by default): instrument the TEST build to measure how much of the project
# the suite exercises — --build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping".
# Empty by default (no effect on the normal oracle build); build.sh appends it to the test build only.
ARG COVERAGE_FLAGS=
# Build parallelism (optional). build.sh falls back to nproc when unset: --build-arg MAYHEM_JOBS=8
ARG MAYHEM_JOBS=

# The engine sources the harnesses compile include git submodules, which a plain checkout
# (and so the build context) does not carry: tracy (header-only with tracing off), streflop
# (headers; the unit-test build uses its plain-libm mode), fmt (built from src/ by build.sh for the
# replay reader), nowide (headers) and pr-downloader (tools/pr-downloader, which carries the 7-Zip C
# SDK, src/lib/7z, that rts/System/CRC.cpp wraps). Each is fetched once at the commits
# upstream pins them to (git ls-tree HEAD rts/lib tools/pr-downloader) and checked by sha256, into
# /opt/toolchains/deps (SPEC §6.2 item 19), so build.sh runs offline.
USER root
ARG TRACY_REV=5d542dc09f3d9378d005092a4ad446bd405f819a
ARG TRACY_SHA256=ab47dbd7c7f1364015f0fb2e5afe767bb86997783bbfdd6cb6d366b47f0a94ac
ARG STREFLOP_REV=570f86fb616a20179914aa7fc9645e683a3f5b4d
ARG STREFLOP_SHA256=0a0b2f9eb3a635b0b880c0616c11bce073b2fbb1d93e64ec6146a43dcafa9fd6
ARG FMT_REV=407c905e45ad75fc29bf0f9bb7c5c2fd3475976f
ARG FMT_SHA256=2bc1fe4a5b6d5d6a614239b4ca1d520e66e152a02d3d262684d26dfd6ab3438a
ARG NOWIDE_REV=de3bb558ebe3dd6d22a03b4beb92fbe05470ca1c
ARG NOWIDE_SHA256=586bf8c63eb1d9f63c6d7fb717fe854568c00d9eb64bdb3b7ebb0158cf4bff8e
ARG PRD_REV=185cfba7fda4dc683acec8b2ecbd15838d3022f5
ARG PRD_SHA256=5d3b2dbc8b1570478be1cebf05dfc96f20baaca8a91051493151c383f24cf816
RUN set -e; fetch() { \
      d="/opt/toolchains/deps/$1-$(echo "$3" | cut -c1-7)"; mkdir -p "$d/src"; \
      curl -fsSL -o /tmp/dep.tgz "https://github.com/$2/archive/$3.tar.gz"; \
      echo "$4  /tmp/dep.tgz" | sha256sum -c -; \
      tar -xzf /tmp/dep.tgz --strip-components=1 -C "$d/src"; rm -f /tmp/dep.tgz; chmod -R a+rX,go-w "$d"; }; \
    fetch tracy wolfpld/tracy "$TRACY_REV" "$TRACY_SHA256"; \
    fetch streflop RecoilEngine/streflop "$STREFLOP_REV" "$STREFLOP_SHA256"; \
    fetch fmt fmtlib/fmt "$FMT_REV" "$FMT_SHA256"; \
    fetch nowide boostorg/nowide "$NOWIDE_REV" "$NOWIDE_SHA256"; \
    fetch pr-downloader beyond-all-reason/pr-downloader "$PRD_REV" "$PRD_SHA256"
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git
# history) is copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Anything a Dockerfile step materializes into the tree (downloaded fixtures, generated headers,
# vendored deps) MUST be committed or (re)created by build.sh: rlenv's patch grader runs
# `git clean -ffdX` before every graded build, so a gitignored, untracked file is gone by then and
# every honest patch scores zero (SPEC §6.2 item 16; verify-repo.sh checks it).
#
# OPTIONAL compile-cache pre-fill (SPEC §6.2 item 18). Bases minted with /opt/mayhem/ccache/prefill
# run the build under rlenv's pinned ccache, so the patch grader's first (otherwise cold) rebuild is
# warm — this is what keeps large C/C++ targets inside the build time limit. Older bases fall back to
# the plain build; a missing or stale pre-fill only costs a cold cache. Never enable ccache in
# build.sh or via ENV/PATH, and keep the compiler resolving by name (CC=clang) or nothing is cached.
RUN if [ -x /opt/mayhem/ccache/prefill ]; then /opt/mayhem/ccache/prefill bash mayhem/build.sh; \
    else bash mayhem/build.sh; fi

# Run the project's functional tests at build time IF the repo ships them (mayhem/test.sh is
# optional — omit it only when the repo has no tests meaningful for RL). A failing suite fails the
# image build, so the commit image is guaranteed to build AND pass its own tests.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
