# Fermium

A Matrix client for Emacs.
UI and glue via elisp, with the heavy lifting by the Rust Matrix SDK.

The Rust Matrix SDK interaction happens via a child process (max of one per Emacs session).
It uses NDJSON over inherited stdin/stdout pipes.
This is reasonably secure from other processes on the machine, but of course you should trust other elisp in your environment.
Data storage is handled by the [Rust Matrix SDK](https://github.com/matrix-org/matrix-rust-sdk).

## Getting started

## Building the helper

This project requires a small Rust helper.

``` shell
cargo build
```

## Emacs configuration

If you have it pre-built:

``` emacs-lisp
(add-to-list 'load-path "/path/to/fermium-el")
(require 'fermium)
(global-set-key (kbd "C-c f") #'fermium)
```

For development, you can also more easily just run this:

``` shell
just dev-reload
```


## Logging in

The `l` command adds an account from the overview.
If you have credentials in `auth-source`, these will be used.
Otherwise, it will just prompt for them.
Authentication from here, and storage of session tokens,
is delegated to the official Rust Matrix SDK.

If the account has Matrix recovery enabled,
Fermium prompts for the recovery key after password login.
The key is used only in memory to restore the account's cross-signing secrets and verify the new device;
it is not persisted anywhere.
The recovery key also automatically marks yoru session as verified.

Each account and its Rooms group appears at the overview root.
You can press `?` in the overview to access help.
You can navigate between items with `n` and `p`,
and fold/unfold sections with `TAB`.
`RET` on a room opens a room buffer where you can view and compose messages.
In a room, `C-c o` returns to the overview in the same window.

### Sync timeouts

`fermium-initial-sync-timeout` controls how long Fermium waits for the first
Matrix sync and defaults to 300 seconds. `fermium-sync-long-poll-timeout`
controls subsequent sync long-polls; it defaults to `nil`, which uses the
Matrix SDK default. Both options are available through
`M-x customize-group RET fermium` and are read when the helper process starts.

## Themes and face customization

Fermium uses named faces that inherit from Emacs's standard theme-aware faces;
it does not require a Fermium-specific color palette. The room title, sender,
timestamp, overview rows, message metadata, and modeline statuses can be
customized with `M-x customize-group RET fermium` or by configuring the
corresponding `fermium-*` faces directly.

## Known gaps

- Pagination/backfill of history beyond 10 events when opening a room buffer
- Room management of any sort (creating, joining, leaving, ...)
- First-class support for spaces (the rooms you are joined will still show though!)
- Emoji verification
- Markdown rendering
- Image uploads
- While image display is supported, sizing and interaction with scrolling could use some help

## Why the name?

It's an element... get it?
