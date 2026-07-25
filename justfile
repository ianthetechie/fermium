# Show the available development recipes.
help:
    @just --list

# Build the development Rust helper.
build:
    cargo build

# Build the Rust helper in release mode.
build-release:
    cargo build --release

# Build, then reload all root-level Elisp files in the running Emacs server.
dev-reload: build
    @emacsclient --eval "(progn (dolist (file (directory-files \"{{ justfile_directory() }}\" t)) (when (string-suffix-p \".el\" file) (load-file file))) \"ok\")"
