# Fermium

Fermium is an Emacs Matrix client. Emacs Lisp provides the UI and glue; the
Rust workspace provides the heavier client logic and helper process.

## Repository layout

- `fermium.el`: Emacs Lisp client
- `test/`: Emacs ERT tests
- `rust/fermium-core`: shared Rust types and logic
- `rust/fermium-helper`: Rust helper process and Matrix SDK integration
- `fermium.allium`: A specification of the observable behavior using the [Allium](https://juxt.github.io/allium/) language.

## Common commands

- `just build` — build the Rust helper
- `just test` — run the Emacs and Rust test suites
- `cargo fmt --all -- --check` — check Rust formatting
- `cargo clippy --workspace --all-targets` — run Rust lint checks

## Guidelines

- Keep changes focused and preserve the existing Emacs Lisp/Rust boundary.
- Add or update tests for behavioral changes.
- Follow Rust 2024 idioms and keep Rust code safe; this workspace forbids
  `unsafe` code and enables Clippy's pedantic lints as warnings.
- Prefer clear, small functions and explicit error handling. Avoid panics in
  normal application paths.
- Observable behavior should be specified by [Allium](https://juxt.github.io/allium/).
  If you are making changes that would require spec changes,
  ensure that the Allium skill and CLI tool are available, or prompt the user to do so.
- Run the relevant formatter, tests, and lint checks before handing off work.
  Prefer using the `just` recipes rather that manual invocations,
  since the recipes avoid common pitfalls like stale `.elc` files.
