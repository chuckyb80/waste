#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# session-start.sh — make `make check` and the serve suite runnable in a
# fresh Claude Code on the web container.
#
# WASTE itself has no third-party runtime deps (CLAUDE.md is explicit about
# that), and serve/ + tests/serve are stdlib-only Python. So there is no
# package manifest to install from — what a fresh container is actually
# missing is the *toolchain*: a C compiler + make (build-essential) and uv
# (the Python reference checks run through `uv run --with torch
# --no-project`; torch itself is never installed here — see step below).
# This hook makes sure those exist, then pre-builds the library and test
# binaries so the first `make`/`make test`/`tests/run.sh` a session runs is
# a no-op or near-no-op instead of a multi-minute compile — the container
# is cached after this hook completes, so paying the build cost here means
# every later turn in the session sees it already paid.
#
# Only meaningful on the web: a local checkout already has its toolchain.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

set -uo pipefail
cd "$CLAUDE_PROJECT_DIR"

# ---------------------------------------------------------------- compiler --
# build-essential gives us cc/gcc + make. Guarded on `cc` being resolvable
# at all, per the Makefile's own comment on CC0/TRIPLE: a missing compiler
# must fail loudly, not be silently reinterpreted as another platform.
if ! command -v cc >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
  echo "installing build-essential (cc/make not found)"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends build-essential
  else
    echo "no apt-get available — cannot install a C toolchain" >&2
  fi
fi

# ------------------------------------------------------------------- uv ----
# Only the *.py reference checkers (tools/kimi_ref.py, kda_ref.py, ...) and
# tests/run.sh's optional differential steps need uv; `make`, `make test`,
# `make check` on the synthetic container and `make serve-check` do not.
# Installed the same way CI does it (the official installer, not a
# distro package), so behavior matches the workflow this hook is meant to
# mirror.
if ! command -v uv >/dev/null 2>&1; then
  echo "installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
fi
# uv installs to ~/.local/bin; make sure both this hook and the rest of the
# session can find it.
export PATH="$HOME/.local/bin:$PATH"
if [ -n "${CLAUDE_ENV_FILE:-}" ] && ! grep -q '.local/bin' "$CLAUDE_ENV_FILE" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$CLAUDE_ENV_FILE"
fi

# ------------------------------------------------------- pre-build & cache --
# `make` and `make test` are deliberately separate targets (a stale test
# binary is one of the two failure modes tests/run.sh exists to catch), so
# build both — this is exactly what tests/run.sh does first anyway. Building
# now, before the session's first turn, means that work lands in the cached
# container instead of blocking the first `make check`.
echo "building libwaste + waste CLI + test binaries"
make -s
make -s test

# A synthetic container is what every check that needs a model falls back
# to (tools/make_test_container.py — a few MB of deterministic noise in the
# real container format). Real K3/Kimi-Linear weights are never fetched
# here: the smallest real container is 19 GB, and CLAUDE.md is explicit
# that WASTE_REF_MODEL should point at a real conversion, not something
# this hook can fabricate. Building the synthetic one now means
# tests/run.sh's own synthetic-container step is a cache hit.
echo "building synthetic test container"
python3 tools/make_test_container.py /tmp/warm-tiny.waste >/dev/null 2>&1 || true

echo "session-start.sh: done"
