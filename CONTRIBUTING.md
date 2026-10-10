# Contributing

## Development setup

Needs Docker, Kind, Helm, and `kubectl`.

```bash
make kind-up
make install-kanister
make minio
make demo-app
make apply-blueprints
```

## Branch naming

- `feat/<short-name>`
- `fix/<short-name>`
- `chore/<short-name>`
- `docs/<short-name>`
- `ci/<short-name>`

## Commits

Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`, `test:`, `ci:`.

## Tests

```bash
make ci                 # offline repository checks
make shellcheck
make recovery-drill     # PROTECT → VALIDATE → RESTORE → PROVE (Kind)
make failure-drill SCENARIO=corrupt-artifact
```

## Pull requests

Open against `main`. CI must be green. Squash merge preferred.

Checklist:

- [ ] `make ci` passes
- [ ] Recovery Contract drills still produce PROVED / UNPROVED correctly
- [ ] Branch naming follows convention
- [ ] Conventional commits
- [ ] Blueprint / script changes documented
