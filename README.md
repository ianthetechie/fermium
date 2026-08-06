# Fermium

A Matrix client for Emacs.
UI and glue via elisp, with the heavy lifting by the Rust Matrix SDK.

The Rust Matrix SDK interaction happens via a child process (max of one per Emacs session).
It uses NDJSON over inherited stdin/stdout pipes (no possibility of socket snooping,
but it is NOT protected from malicious elisp in your environment!).

## Getting started

## Building the helper

This project requires a small Rust helper.

``` shell
cargo build
```

## Emacs configuration

``` emacs-lisp
(add-to-list 'load-path "/path/to/fermium-el")
(require 'fermium)
(global-set-key (kbd "C-c f") #'fermium)
```

## Themes and face customization

Fermium uses named faces that inherit from Emacs's standard theme-aware faces;
it does not require a Fermium-specific color palette. The room title, sender,
timestamp, overview rows, message metadata, and modeline statuses can be
customized with `M-x customize-group RET fermium` or by configuring the
corresponding `fermium-*` faces directly.

## Credentials

During account setup, Fermium prompts for your homeserver and credentials.
It _can_ use Emacs's [auth-source](https://www.gnu.org/software/emacs/manual/html_mono/auth.html)
to look up your password (if you've added it),
otherwise it prompts.

After a successful login, the helper persists all Matrix sessions and separate
SDK state for each account under the platform's application data directory so a
new helper process can restore them without prompting again.
The session file contains access tokens and is created with user-only permissions.
The password is passed to the Rust helper in memory for the login request and is never written by Fermium.

``` text
machine matrix.org login @alice:matrix.org password YOUR_PASSWORD port matrix
```

Refer to  [Emacs's authentication guide](https://www.gnu.org/software/emacs/manual/html_node/emacs/Authentication.html)
for `~/.authinfo.gpg` and `auth-sources` setup.
The [auth-source manual's Secret Service](https://www.gnu.org/software/emacs/manual/html_node/auth/Secret-Service-API.html)
and [pass](https://www.gnu.org/software/emacs/manual/html_node/auth/The-Unix-password-store.html)
sections cover those backends.

If the account has Matrix recovery enabled,
Fermium prompts for the recovery key after password login.
The key is used in memory to restore the account's cross-signing secrets and verify the new device;
it is **not** persisted anywhere.

## Logging in

The l command adds an account from the overview using credentials resolved
through Emacs's auth-source. Each account and its Rooms group appears at the
overview root. RET on an account opens its account actions, where o logs out
that specific account. RET on a room opens a joined room; C-c C-c sends the
text in the writable tail of a room buffer. Press ? in the overview or in the read-only
part of a room buffer to show the context-specific commands in a temporary
Magit-style popup; ? remains available for typing in the composition area.
Image messages show a [Image] placeholder until RET or mouse-2 is used on it.

## Known gaps

History pagination, room creation/leaving, spaces, emoji verification,
Markdown rendering, and richer account actions are not yet implemented.

## Why the name?

It's an element... get it?
