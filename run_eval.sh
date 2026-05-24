#!/usr/bin/env bash
# Hidden eval harness. Designed to leak as little information as possible
# about its own location to the candidate process.
#
# Mitigations:
#   - The test file is copied to a freshly-created random tmpdir before
#     unittest sees it. sys.path / tracebacks / inspect.getfile() then only
#     reveal the throwaway tmpdir, never the private dir.
#   - Bytecode writes disabled (PYTHONDONTWRITEBYTECODE=1) so no __pycache__
#     gets seeded next to the test or inside the candidate dir.
#   - The tmpdir is mode 0700 and removed on exit (success, failure, or
#     interrupt).
#   - We don't export any env var that names the private dir.
#
# Residual risks (require OS-level isolation to fully close):
#   - The candidate process, if it can run `ps` / read /proc/<pid>/cmdline,
#     can see the tmpdir path the harness passed to `python -m unittest`,
#     and from there read the copied test file (same uid).
#   - True protection = run the unittest process as a different uid (sudo -u),
#     or inside a container / chroot.
#
# Usage:
#   ./run_eval.sh <candidate_dir> [extra unittest args...]

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <candidate_dir> [extra unittest args...]" >&2
  exit 2
fi

CANDIDATE_DIR="$(cd "$1" && pwd)"
shift
if [[ ! -d "${CANDIDATE_DIR}/codex" ]]; then
  echo "error: ${CANDIDATE_DIR}/codex/ not found" >&2
  exit 2
fi

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
PRIVATE_TESTS="${HARNESS_DIR}/tests/test_core.py"
if [[ ! -f "${PRIVATE_TESTS}" ]]; then
  echo "error: ${PRIVATE_TESTS} not found" >&2
  exit 2
fi

# Upstream tree (allowed to be visible — it's public eval material).
# Default to the upstream copy that ships with this private harness so the
# eval is self-contained. Override with CODEX_IMPL_PUBLIC_DIR if you want to
# point at the public codex-impl/upstream tree instead.
if [[ -n "${CODEX_IMPL_PUBLIC_DIR:-}" ]]; then
  PUBLIC_UPSTREAM="${CODEX_IMPL_PUBLIC_DIR}/upstream/openai-codex"
else
  PUBLIC_UPSTREAM="${HARNESS_DIR}/upstream/openai-codex"
fi

# Create a throwaway sandbox the candidate cannot easily attribute back to us.
WORK_ROOT="$(mktemp -d -t ce-XXXXXXXX)"
chmod 700 "${WORK_ROOT}"
trap 'rm -rf "${WORK_ROOT}"' EXIT INT TERM

TESTS_DIR="${WORK_ROOT}/tests"
mkdir -p "${TESTS_DIR}"
cp "${PRIVATE_TESTS}" "${TESTS_DIR}/test_core.py"
touch "${TESTS_DIR}/__init__.py"

# Scrub any env var that could leak the private location. Only export the
# generically-named upstream pointer.
unset CODEX_IMPL_PUBLIC_DIR
unset CODEX_IMPL_UPSTREAM
export CODEX_UPSTREAM_DIR="${PUBLIC_UPSTREAM}"

# Disable .pyc writes so no __pycache__ gets seeded.
export PYTHONDONTWRITEBYTECODE=1

# Run with the candidate dir as cwd (so `os.getcwd()` resolves the candidate's
# codex/ package). From the test runner process's perspective the test lives
# under ${WORK_ROOT}, not the private dir.
cd "${CANDIDATE_DIR}"

# Prefer pytest + xdist when both are available: run non-PTY tests in parallel
# (one worker per CPU) and the PTY tests serially in a separate pass. The PTY
# tests open real pseudo-terminals and use timing-sensitive `read_until(...)`
# polling; running >3 of them in parallel reliably starves them out and they
# fail spuriously. Splitting like this maximizes total throughput without
# making the PTY tests flaky.
PYTEST_TEST_PATH="${TESTS_DIR}/test_core.py"
if python3 -c "import pytest, xdist" >/dev/null 2>&1; then
    PYTEST_COMMON=(
        --no-header
        --tb=short
        -q
        -p no:cacheprovider
        -p no:warnings
        --rootdir "${WORK_ROOT}"
    )
    # No retries: keep eval results deterministic. On a broken candidate,
    # retrying a failing test just doubles the timeout cost; on a reference
    # candidate, the one or two parallel-flakes we've seen are easier to spot
    # by re-running the whole eval than by silently hiding them.
    echo "==== parallel pass (non-PTY tests) ===="
    set +e
    python3 -m pytest "${PYTEST_COMMON[@]}" \
        -n auto \
        -k 'not test_cli_ and not test_exec_command_' \
        "${PYTEST_TEST_PATH}" "$@"
    rc_parallel=$?
    echo
    echo "==== low-concurrency pass (PTY tests, n=2) ===="
    # PTY tests are timing-sensitive (real pty + read_until polling). 2 workers
    # is the highest we can run without spurious read timeouts under load.
    python3 -m pytest "${PYTEST_COMMON[@]}" \
        -n 2 \
        -k 'test_cli_ or test_exec_command_' \
        "${PYTEST_TEST_PATH}" "$@"
    rc_serial=$?
    if [[ $rc_parallel -ne 0 || $rc_serial -ne 0 ]]; then
        exit 1
    fi
    exit 0
fi

# Fallback when pytest+xdist isn't installed: plain unittest, serial.
exec python3 -m unittest discover -v -s "${TESTS_DIR}" -t "${WORK_ROOT}" "$@"