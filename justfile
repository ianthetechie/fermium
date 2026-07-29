# Show the available development recipes.
help:
    @just --list

# Run the Emacs ERT test suite.
test:
    emacs -Q --batch --eval '(setq load-prefer-newer t)' -L . -L test -l ./fermium.el -l test/fermium-test.el -f ert-run-tests-batch-and-exit
    cargo nextest run --no-fail-fast

# Build the development Rust helper.
build:
    cargo build

# Build the Rust helper in release mode.
build-release:
    cargo build --release

# Build, then reload all root-level Elisp files in the running Emacs server.
dev-reload: build
    @emacs -Q --batch -L "{{ justfile_directory() }}" --eval '(byte-compile-file (expand-file-name "fermium.el"))'
    @emacsclient --eval "(progn (let ((load-prefer-newer t)) (dolist (file (directory-files \"{{ justfile_directory() }}\" t)) (when (string-suffix-p \".el\" file) (load-file file)))) \"ok\")"
