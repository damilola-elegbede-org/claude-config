# Test discovery

## Priority order

1. **README.md** — sections like "Testing", "Running Tests", "Development"; extract commands from
   code blocks. A project that documents its test command means it; prefer it over inference.
2. **Package manager config** — the test script it declares.
3. **Framework config files** — `pytest.ini`, `jest.config.js`, `vitest.config.*`, `.rspec`.
4. **File patterns** — infer the framework from test file naming.
5. **Common fallbacks** — try the ecosystem's standard command.

## Per-language

| Language      | Configs                                        | Commands                              | Patterns                          |
| ------------- | ---------------------------------------------- | ------------------------------------- | --------------------------------- |
| JS/TS         | `package.json`, `jest.config.js`, `vitest.config.ts` | `npm test`, `yarn test`, `pnpm test`, `npm run test:unit` | `*.test.js`, `*.spec.js`, `__tests__/` |
| Python        | `pytest.ini`, `pyproject.toml`, `setup.py`, `tox.ini` | `pytest`, `python -m pytest`, `tox` | `test_*.py`, `*_test.py`, `tests/` |
| Go            | `go.mod`                                       | `go test ./...`                       | `*_test.go`                       |
| Rust          | `Cargo.toml`                                   | `cargo test`                          | `tests/`                          |
| Ruby          | `Gemfile`, `.rspec`                            | `bundle exec rspec`, `rake test`      | `*_spec.rb`, `spec/`              |
| Java          | `pom.xml`, `build.gradle`                      | `mvn test`, `gradle test`, `./gradlew test` | `*Test.java`, `src/test/`    |
| .NET          | `*.csproj`                                     | `dotnet test`                         | —                                 |

Run with the test environment set where the ecosystem expects it (e.g. `NODE_ENV=test`).

## Coverage flags

- Jest / Vitest: `--coverage`
- pytest: `--cov=src`
- Go: `-cover`
- Rust: `--coverage` (needs `llvm-cov`)

## When several test commands exist

Unit, integration, and e2e scripts are different jobs with different runtimes. List what you found and
ask which to run rather than picking the broadest one silently.

## Common failure modes

These are environment problems, not test failures — say so rather than reporting the suite as broken:

- `Cannot find module '<framework>'` → dependencies aren't installed; `npm install` / `yarn install`.
- Database connection refused → test database isn't running, or env vars/test config are missing.
- No command discoverable at all → report what you searched (README, package config, test files, test
  config) and offer `--create` or `--framework <name>`.

## Create mode

Deploy `test-engineer` to generate the structure — this is the one part of this skill that delegates.
Detect the language and pick the conventional framework for it, generate test files plus config, wire
the test script into the package manifest, install the dependencies, then run the generated tests and
report real coverage. Generated tests that haven't been run are not a test suite.
