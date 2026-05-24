# codex-eval-private (DO NOT GIVE TO AGENTS)

Hidden test harness for the `codex-impl` task. Lives **outside** the impl directory so candidate agents can never see it.

## Layout

```
codex-eval-private/
├── README.md          # this file
├── run_eval.sh        # harness — points PYTHONPATH at a candidate dir
└── tests/
    └── test_core.py   # the hidden test suite (~6800 lines)
```

## Usage

```bash
./run_eval.sh /path/to/candidate
```

The candidate dir must contain a Python package named `codex/` (i.e. `/path/to/candidate/codex/__init__.py`) implementing the API documented in `codex-impl/SPEC.md` and `codex-impl/API_SURFACE.md`.

The harness prepends the candidate dir to `PYTHONPATH`, then runs:

```bash
python -m unittest discover -v -s tests -t .
```

## Truth source

The hidden tests are the ground truth. `SPEC.md` and `API_SURFACE.md` in the eval dir describe the API surface the tests rely on, but they are derived from the tests — if the spec and the test disagree, the test wins.

## Updating

When you modify the reference implementation (in `swarm/_release/codex-py/`), copy `tests/test_core.py` back into here, and re-derive `API_SURFACE.md` for the eval dir if any public-API signatures changed.