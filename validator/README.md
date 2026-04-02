# TeamDB Validator

CLI validator for TeamDB YAML/CSV manifests based on JSON schemas in `.schema/`.

## What it validates

- `metadata.yaml` / `metadata.yml` files against `.schema/metadata.schema.json`
- `members.csv` files against `.schema/members.table.schema.json`

Files are discovered recursively under `teams/` by default.

## Usage

From the `validator/` directory:

```bash
dart run bin/validator.dart --root ..
```

Options:

- `--root <path>`: repository root containing `.schema/` (auto-detected if omitted)
- `--teams-dir <path>`: teams folder relative to root (default: `teams`)
- `--include-template`: also validate files under `.template/`
- `-h`, `--help`: print help