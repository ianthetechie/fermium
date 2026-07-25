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

## Credentials

Fermium uses Emacs's [auth-source](https://www.gnu.org/software/emacs/manual/html_mono/auth.html)
only to look up the password for a login.
If no matching auth-source entry is found, Fermium prompts for the password instead.

The auth-source backend itself may persist your password; that is separate from Fermium.
For example, an encrypted `~/.authinfo.gpg` entry can look like this
(the `port` value matches `fermium-auth-source-port`, whose default is `matrix`):

``` text
machine matrix.org login @alice:matrix.org password YOUR_PASSWORD port matrix
```


## Logging in

The l command logs in from the overview using credentials resolved through
Emacs's auth-source; RET opens a joined room; C-c C-c sends the text in the
writable tail of a room buffer.  Press ? in the overview or a room to see the
available commands.


## Why the name?

It's an element... get it?
