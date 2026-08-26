;;; fermium.el --- Matrix client for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:

;; Fermium is a small Emacs front-end for a Rust Matrix SDK helper.  The
;; helper is deliberately one child process per Emacs session and communicates
;; over its inherited stdin/stdout pipes.

;;; Code:

(require 'auth-source)
(require 'button)
(require 'cl-lib)
(require 'ewoc)
(require 'json)
(require 'image)
(require 'svg nil t)
(require 'seq)
(require 'subr-x)
(require 'transient)
(require 'url-parse)

(defgroup fermium nil
  "Matrix client for Emacs."
  :group 'applications)

(defcustom fermium-helper-program nil
  "Path to the Fermium Rust helper executable.

When nil, use the development helper under this package's workspace."
  :type 'file
  :group 'fermium)

(defcustom fermium-initial-sync-timeout 300
  "Maximum number of seconds allowed for an initial Matrix sync.

This setting is read when the Rust helper process starts.  It is deliberately
longer than the normal sync long-poll because some homeservers take a while to
construct the first complete response."
  :type 'natnum
  :group 'fermium)

(defcustom fermium-sync-long-poll-timeout nil
  "Maximum number of seconds a Matrix sync long-poll may wait.

When nil, use the Matrix SDK default.  This setting is read when the Rust
helper process starts."
  :type '(choice (const :tag "Matrix SDK default" nil)
                 (natnum :tag "Seconds"))
  :group 'fermium)

(defcustom fermium-auth-source-port "matrix"
  "Auth-source port/service used for Matrix credentials."
  :type 'string
  :group 'fermium)

(defun fermium--helper-environment ()
  "Return the environment for the helper process."
  (let ((environment
         (cl-remove-if
          (lambda (entry)
            (or (string-prefix-p "FERMIUM_INITIAL_SYNC_TIMEOUT=" entry)
                (string-prefix-p "FERMIUM_SYNC_TIMEOUT=" entry)))
          process-environment)))
    (push (format "FERMIUM_INITIAL_SYNC_TIMEOUT=%d"
                  fermium-initial-sync-timeout)
          environment)
    (when fermium-sync-long-poll-timeout
      (push (format "FERMIUM_SYNC_TIMEOUT=%d"
                    fermium-sync-long-poll-timeout)
            environment))
    environment))

(defconst fermium-room-unknown-user-label "<UNKNOWN USER>"
  "Label used when a message has neither a display name nor a sender ID.")

(defface fermium-room-title-face
  '((t (:inherit header-line :weight bold :height 1.2 :box nil)))
  "Face used for a room's title."
  :group 'fermium)

(defface fermium-room-header-marker-face
  '((t (:inherit shadow :weight bold :height 1.2)))
  "Face used for a room header's disclosure marker."
  :group 'fermium)

(defface fermium-room-header-label-face
  '((t (:weight bold)))
  "Face used for labels in a room header's metadata."
  :group 'fermium)

(defface fermium-room-header-other-face
  '((t (:inherit font-lock-constant-face)))
  "Face used for non-account values in a room header."
  :group 'fermium)

(defface fermium-room-timestamp-face
  '((t (:inherit shadow
        :height 0.9
        :slant italic)))
  "Face used for message timestamps."
  :group 'fermium)

(defface fermium-room-sender-face
  '((t (:inherit font-lock-variable-name-face :weight bold)))
  "Face used for message senders."
  :group 'fermium)

(defface fermium-room-sender-self-face
  '((t (:inherit fermium-room-sender-face :slant italic)))
  "Face used for the current account's message senders."
  :group 'fermium)

(defface fermium-room-sender-color-0-face
  '((((class color) (background light)) (:foreground "#005f87"))
    (((class color) (background dark)) (:foreground "#5fafff"))
    (t (:inherit fermium-room-sender-face)))
  "First palette face used for other message senders."
  :group 'fermium)

(defface fermium-room-sender-color-1-face
  '((((class color) (background light)) (:foreground "#006b4f"))
    (((class color) (background dark)) (:foreground "#65c18c"))
    (t (:inherit fermium-room-sender-face)))
  "Second palette face used for other message senders."
  :group 'fermium)

(defface fermium-room-sender-color-2-face
  '((((class color) (background light)) (:foreground "#9e2a2b"))
    (((class color) (background dark)) (:foreground "#ff7b72"))
    (t (:inherit fermium-room-sender-face)))
  "Third palette face used for other message senders."
  :group 'fermium)

(defface fermium-room-sender-color-3-face
  '((((class color) (background light)) (:foreground "#5e4b8a"))
    (((class color) (background dark)) (:foreground "#c8a6ff"))
    (t (:inherit fermium-room-sender-face)))
  "Fourth palette face used for other message senders."
  :group 'fermium)

(defface fermium-room-sender-color-4-face
  '((((class color) (background light)) (:foreground "#8a4b08"))
    (((class color) (background dark)) (:foreground "#ffb86b"))
    (t (:inherit fermium-room-sender-face)))
  "Fifth palette face used for other message senders."
  :group 'fermium)

(defcustom fermium-room-sender-color-faces
  '(fermium-room-sender-color-0-face
    fermium-room-sender-color-1-face
    fermium-room-sender-color-2-face
    fermium-room-sender-color-3-face
    fermium-room-sender-color-4-face)
  "Faces used to distinguish other message senders.

Fermium assigns a sender to a stable face from this list based on the
sender's canonical Matrix user ID.  Set this to nil to disable sender
coloring, or replace it with a custom list of faces."
  :type '(repeat face)
  :group 'fermium)

(defface fermium-room-composition-header-face
  '((t (:inherit header-line :weight bold)))
  "Face used for the composition area's heading."
  :group 'fermium)

(defface fermium-room-composition-face
  '((t (:inherit default
        :weight normal
        :slant normal
        :underline nil
        :box nil)))
  "Face used for text in the composition area."
  :group 'fermium)

(defface fermium-room-composition-sending-face
  '((t (:inherit fermium-room-timestamp-face)))
  "Face used for composition text while its message is being sent."
  :group 'fermium)

(defface fermium-room-channel-events-face
  '((t (:inherit shadow :weight bold)))
  "Face used for collapsed channel-event headings."
  :group 'fermium)

(defface fermium-overview-group-face
  '((t (:inherit header-line :weight bold)))
  "Face used for overview rows that only group other rows."
  :group 'fermium)

(defface fermium-overview-account-face
  '((t (:inherit font-lock-variable-name-face :weight bold)))
  "Face used for visitable account rows in the overview."
  :group 'fermium)

(defface fermium-overview-room-face
  '((t (:inherit default)))
  "Face used for visitable room rows in the overview."
  :group 'fermium)

(defface fermium-overview-unread-face
  '((t (:weight bold :slant italic)))
  "Face used for rooms with unread messages."
  :group 'fermium)

(defface fermium-overview-marker-face
  '((t (:inherit shadow)))
  "Face used for overview disclosure and item markers."
  :group 'fermium)

(defface fermium-overview-room-meta-face
  '((t (:inherit shadow)))
  "Face used for room timestamps and message previews."
  :group 'fermium)

(defface fermium-modeline-error-face
  '((t (:inherit error :weight bold)))
  "Face used for Fermium modeline errors."
  :group 'fermium)

(defface fermium-modeline-loading-face
  '((t (:inherit warning :weight bold)))
  "Face used for Fermium modeline loading indicators."
  :group 'fermium)

(defface fermium-modeline-sending-face
  '((t (:inherit mode-line-emphasis :weight bold)))
  "Face used for Fermium modeline sending indicators."
  :group 'fermium)

(defface fermium-modeline-connected-face
  '((t (:inherit success :weight bold)))
  "Face used for Fermium modeline connected indicators."
  :group 'fermium)

(defconst fermium--overview-buffer "*Fermium*")

(defvar fermium--process nil)
(defvar fermium--process-output "")
(defvar fermium--request-counter 0)
(defvar fermium--pending-requests (make-hash-table :test #'eql))
(defvar fermium--stopping nil)
(defvar fermium--accounts nil)
(defvar fermium--pending-logins nil)
(defvar fermium--rooms nil)
(defvar fermium--account nil)
(defvar fermium--locally-read-rooms (make-hash-table :test #'equal))
(defvar fermium--focus-change-hook-installed nil)
(defvar fermium--state-loading nil)
(defconst fermium--loading-frames '("" "." ".." "..."))
(defvar fermium--loading-frame 0)
(defvar fermium--loading-timer nil)
(defvar fermium--handling-event-type nil)
(defvar fermium--handling-event-request-id nil)
(defvar fermium--last-elisp-error nil)
(defvar fermium--last-buffer-action nil)

(defvar-local fermium--overview-collapsed-sections nil)

(defvar-local fermium-room--ewoc nil
  "The `ewoc' rendering this room's history, or nil before it is rendered.

A node's data is the list of messages it renders as one unit: a single
ordinary message, or a run of consecutive channel events folded into one
section.  The node list is this room's history -- there is no second copy
of it to keep in step.")

(defvar-local fermium-room--resizing-images nil)
(defvar-local fermium-room--image-resize-timer nil)
(defvar-local fermium-room--send-error nil)
(defvar-local fermium-room--sending nil)
(defvar-local fermium-room--header-expanded nil)
(defvar-local fermium-room--header-image-cache-key nil)
(defvar-local fermium-room--header-image-cache nil)
(defvar-local fermium-room--nodes nil
  "Hash mapping a message key to the ewoc node that renders it.
Every message of a folded run maps to the one node holding the run.")
(defvar-local fermium-room--read-message-key nil)
(defvar-local fermium-room--last-point-in-composition nil)

(defun fermium-room--disable-line-numbers ()
  "Keep line numbers disabled in the current room buffer."
  (setq-local display-line-numbers nil)
  (when (and (boundp 'display-line-numbers-mode)
             display-line-numbers-mode)
    (display-line-numbers-mode -1)))

(defvar fermium-overview-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "l") #'fermium-login)
    (define-key map (kbd "a") #'fermium-account-menu)
    (define-key map (kbd "g") #'fermium-refresh)
    (define-key map (kbd "n") #'fermium-next)
    (define-key map (kbd "p") #'fermium-previous)
    (define-key map (kbd "TAB") #'fermium-toggle-section)
    (define-key map (kbd "?") #'fermium-help)
    (define-key map (kbd "RET") #'fermium-overview-visit)
    (define-key map (kbd "q") #'fermium-quit)
    map))

(defvar fermium-overview--toggle-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map fermium-overview-mode-map)
    (define-key map [mouse-1] #'fermium-overview--mouse-toggle-section)
    (define-key map [mouse-2] #'fermium-overview--mouse-toggle-section)
    map)
  "Keymap used by clickable overview section headings.")

(defvar fermium-room-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c o") #'fermium-room-overview)
    (define-key map (kbd "C-c C-c") #'fermium-room-send)
    (define-key map (kbd "C-c C-k") #'fermium-room-clear-input)
    (define-key map (kbd "TAB") #'fermium-room-toggle-header-or-channel-events)
    (define-key map [mouse-2]
                #'fermium-room--mouse-toggle-header-or-yank)
    map))

(defvar fermium-room--read-only-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c o") #'fermium-room-overview)
    (define-key map (kbd "?") #'fermium-help)
    (define-key map (kbd "TAB") #'fermium-room-toggle-header-or-channel-events)
    (define-key map [remap self-insert-command]
                #'fermium-room--redirect-self-insert)
    map)
  "Keymap used by the read-only part of a room buffer.")

(defvar fermium-room--header-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map fermium-room--read-only-map)
    (define-key map (kbd "TAB") #'fermium-room-toggle-header)
    (define-key map [header-line down-mouse-1] #'ignore)
    (define-key map [header-line mouse-1] #'fermium-room--mouse-toggle-header)
    (define-key map [header-line mouse-2] #'fermium-room--mouse-toggle-header)
    map)
  "Keymap used by room headers that show folded metadata.")

(defvar fermium-room--channel-events-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map fermium-room--read-only-map)
    (define-key map [mouse-1] #'fermium-room--mouse-toggle-channel-events)
    (define-key map [mouse-2] #'fermium-room--mouse-toggle-channel-events)
    map)
  "Keymap used by visible collapsed channel-event headings.")

(defvar fermium-room--image-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map fermium-room--read-only-map)
    (define-key map (kbd "RET") #'fermium-room-display-image)
    (define-key map [mouse-1] #'fermium-room--mouse-display-image)
    (define-key map [mouse-2] #'fermium-room--mouse-display-image)
    map)
  "Keymap used by image placeholders in room buffers.")

(define-derived-mode fermium-overview-mode special-mode "Fermium-Overview"
  "Major mode for the Fermium account and room overview."
  (setq-local truncate-lines t)
  (setq-local buffer-invisibility-spec '(fermium))
  (setq-local mode-line-process
              '(:eval (fermium--mode-line-status))))

(define-derived-mode fermium-room-mode text-mode "Fermium-Room"
  "Major mode for a Fermium room conversation."
  (setq-local indent-tabs-mode nil)
  (setq-local fermium-room--ewoc nil)
  (setq-local fermium-room--input-start nil)
  (setq-local fermium-room--room-id nil)
  (setq-local fermium-room--account-id nil)
  (setq-local fermium-room--sending nil)
  (setq-local fermium-room--send-error nil)
  (setq-local fermium-room--read-message-key nil)
  (setq-local fermium-room--last-point-in-composition nil)
  (setq-local fermium-room--loading nil)
  (setq-local fermium-room--pending-messages nil)
  (setq-local fermium-room--seed-message nil)
  (setq-local fermium-room--room-title nil)
  (setq-local fermium-room--header-expanded nil)
  (setq-local fermium-room--header-image-cache-key nil)
  (setq-local fermium-room--header-image-cache nil)
  (setq-local fermium-room--expanded-channel-events
              (make-hash-table :test #'equal))
  (setq-local fermium-room--image-states (make-hash-table :test #'equal))
  (setq-local fermium-room--resizing-images nil)
  (setq-local fermium-room--image-resize-timer nil)
  (setq-local fermium-room--nodes (make-hash-table :test #'equal))
  (setq-local fermium-room--composition-overlay nil)
  (setq-local buffer-invisibility-spec '(fermium))
  (setq-local header-line-format '((:eval (fermium-room--header-line))))
  (require 'display-line-numbers nil t)
  (when (boundp 'display-line-numbers)
    (setq-local display-line-numbers nil))
  (when (fboundp 'display-line-numbers-mode)
    (add-hook 'display-line-numbers-mode-hook
              #'fermium-room--disable-line-numbers nil t)
    (fermium-room--disable-line-numbers))
  (setq-local mode-line-process
              '(:eval (fermium--mode-line-status)))
  (add-hook 'after-change-functions
            #'fermium-room--composition-after-change nil t)
  (add-hook 'window-state-change-functions
            #'fermium-room--window-state-changed nil t)
  (add-hook 'window-selection-change-functions
            #'fermium-room--window-selection-changed nil t)
  (add-hook 'window-scroll-functions
            #'fermium-room--window-scrolled nil t)
  (add-hook 'post-command-hook
            #'fermium-room--remember-point-position nil t)
  (add-hook 'post-command-hook
            #'fermium-room--maybe-mark-latest-message-read nil t)
  (add-hook 'kill-buffer-hook
            #'fermium-room--cleanup-images nil t))

(defun fermium--default-helper-program ()
  (expand-file-name
   "target/debug/fermium-helper"
   (file-name-directory (or load-file-name buffer-file-name))))

(defun fermium--helper-program ()
  (or fermium-helper-program (fermium--default-helper-program)))

(defun fermium--report-elisp-error (where error &optional event-type request-id)
  "Record and report an Elisp ERROR raised while handling WHERE."
  (let ((event-type (or event-type fermium--handling-event-type))
        (request-id (or request-id fermium--handling-event-request-id)))
    (let ((description
           (format
            "%s failed%s%s%s: %s"
            where
            (if event-type
                (format " for %s event" event-type)
              "")
            (if request-id
                (format " (request %s)" request-id)
              "")
            (if (derived-mode-p 'fermium-room-mode)
                (format " in buffer %s" (buffer-name))
              "")
            (error-message-string error))))
      (setq fermium--last-elisp-error description)
      (message "Fermium: %s" description))))

(defun fermium--close-buffer (buffer reason)
  "Close BUFFER and record REASON for the diagnostic log."
  (when (buffer-live-p buffer)
    (setq fermium--last-buffer-action
          (list :action 'kill
                :buffer (buffer-name buffer)
                :reason reason
                :time (current-time-string)))
    (message "Fermium: closing buffer %s (%s)"
             (buffer-name buffer) reason)
    (kill-buffer buffer)))

(defun fermium--reset-room-send-state ()
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'fermium-room-mode)
          (setq fermium-room--sending nil)
          (fermium-room--finish-loading)
          (when (hash-table-p fermium-room--image-states)
            (fermium-room--flush-image-states)
            (clrhash fermium-room--image-states))
          (fermium-room--set-input-read-only nil))))))

(defun fermium--loading-dots ()
  (nth (mod fermium--loading-frame (length fermium--loading-frames))
       fermium--loading-frames))

(defun fermium--loading-active-p ()
  (or fermium--state-loading
      fermium--pending-logins
      (seq-some
       (lambda (buffer)
         (and (buffer-live-p buffer)
              (with-current-buffer buffer
                (and (derived-mode-p 'fermium-room-mode)
                     (or fermium-room--loading
                         (fermium-room--image-loading-p))))))
       (buffer-list))))

(defun fermium--start-loading-animation ()
  (unless fermium--loading-timer
    (setq fermium--loading-timer
          (run-at-time 0 0.4 #'fermium--animate-loading))))

(defun fermium--stop-loading-animation-if-idle ()
  (unless (fermium--loading-active-p)
    (when fermium--loading-timer
      (cancel-timer fermium--loading-timer)
      (setq fermium--loading-timer nil))))

(defun fermium--animate-loading ()
  (condition-case-unless-debug error
      (fermium--animate-loading-internal)
    (error
     (fermium--report-elisp-error "loading timer" error)
     (when fermium--loading-timer
       (cancel-timer fermium--loading-timer)
       (setq fermium--loading-timer nil)))))

(defun fermium--animate-loading-internal ()
  (if (not (fermium--loading-active-p))
      (fermium--stop-loading-animation-if-idle)
    (setq fermium--loading-frame
          (mod (1+ fermium--loading-frame)
               (length fermium--loading-frames)))
    (when (and (or fermium--state-loading fermium--pending-logins)
               (get-buffer fermium--overview-buffer))
      (with-current-buffer fermium--overview-buffer
        (fermium--render-overview)))
    (dolist (buffer (buffer-list))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (and (derived-mode-p 'fermium-room-mode)
                     fermium-room--loading)
            (fermium-room--render-loading-indicator))
          (when (derived-mode-p 'fermium-room-mode)
            (fermium-room--render-loading-images)))))))

(defun fermium--ensure-process ()
  (unless (process-live-p fermium--process)
    (when fermium--process
      (setq fermium--process nil)
      (setq fermium--process-output "")
      (clrhash fermium--pending-requests)
      (fermium--reset-room-send-state))
    (setq fermium--stopping nil)
    (setq fermium--process-output "")
    (let ((process-environment (fermium--helper-environment)))
      (setq fermium--process
            (make-process
             :name "fermium-helper"
             :command (list (fermium--helper-program))
             :connection-type 'pipe
             :coding 'utf-8
             :noquery t
             :filter #'fermium--process-filter
             :sentinel #'fermium--process-sentinel)))))

(defun fermium--process-filter (process output)
  (when (eq process fermium--process)
    (setq fermium--process-output (concat fermium--process-output output))
    (let ((lines (split-string fermium--process-output "\n")))
      (setq fermium--process-output (car (last lines)))
      (dolist (line (butlast lines))
        (unless (string-empty-p line)
          (condition-case-unless-debug error
              (let* ((event
                      (json-parse-string line :object-type 'alist
                                         :array-type 'list))
                     (event-type (fermium--event-value event "type"))
                     (request-id (fermium--event-value event "request_id")))
                (condition-case-unless-debug error
                    (let ((fermium--handling-event-type event-type)
                          (fermium--handling-event-request-id request-id))
                      (fermium--handle-event event))
                  (error
                   (fermium--report-elisp-error
                    "helper event" error event-type request-id))))
            (json-parse-error
             (message "Fermium: invalid helper event: %s"
                      (error-message-string error)))))))))

(defun fermium--process-sentinel (process event)
  (when (eq process fermium--process)
    (setq fermium--process nil)
    (setq fermium--process-output "")
    (clrhash fermium--pending-requests)
    (clrhash fermium--locally-read-rooms)
    (setq fermium--state-loading nil)
    (fermium--reset-room-send-state)
    (unless fermium--stopping
      (dolist (account fermium--accounts)
        (setf (alist-get "connection_status" account nil nil #'string=)
              "offline"
              (alist-get "connection_error" account nil nil #'string=)
              (format "helper stopped: %s" (string-trim event))))
      (fermium--force-mode-line-update))
    (fermium--stop-loading-animation-if-idle)
    (unless (or fermium--stopping
                (string-match-p "finished\\|exited" event))
      (message "Fermium helper stopped: %s" (string-trim event)))))

(defun fermium--send (command payload callback)
  (fermium--ensure-process)
  (let ((request-id (cl-incf fermium--request-counter)))
    (when callback
      (puthash request-id callback fermium--pending-requests))
    (condition-case error
        (process-send-string
         fermium--process
         (concat
          (json-serialize
           (mapcar (lambda (pair)
                     (cons (intern (car pair))
                           (fermium--json-value-for-send (cdr pair))))
                   (append (list (cons "command" command)
                                 (cons "request_id" request-id))
                           payload)))
          "\n"))
      (error
       (remhash request-id fermium--pending-requests)
       (signal (car error) (cdr error))))
    request-id))

(defun fermium--json-value-for-send (value)
  "Convert nested alists in VALUE to objects accepted by `json-serialize'."
  (cond
   ((and (listp value)
         (consp (car value))
         (or (stringp (caar value)) (symbolp (caar value))))
    (mapcar
     (lambda (pair)
       (cons (if (stringp (car pair))
                 (intern (car pair))
               (car pair))
             (fermium--json-value-for-send (cdr pair))))
     value))
   ((listp value)
    ;; `json-serialize' interprets a proper list as an object.  JSON arrays
    ;; arrive from `json-parse-string' as lists, so make them vectors before
    ;; serialization (notably media keys contain ["decrypt"]).
    (vconcat (mapcar #'fermium--json-value-for-send value)))
   (t value)))

(defun fermium--event-value (event key)
  "Read KEY from an event alist, treating JSON null and false as nil."
  (when (listp event)
    (let ((value (alist-get key event nil nil #'string=)))
      (unless (memq value '(:null :false))
        value))))

(defun fermium--account-record-id (account)
  "Return the user ID in ACCOUNT summary ACCOUNT."
  (fermium--event-value account "user_id"))

(defun fermium--room-state-key (account-id room-id)
  "Return the local state key for ROOM-ID belonging to ACCOUNT-ID."
  (cons account-id room-id))

(defun fermium--room-locally-read-p (account-id room-id)
  "Return non-nil when Fermium has locally accepted ROOM-ID as read."
  (and account-id room-id
       (gethash (fermium--room-state-key account-id room-id)
                fermium--locally-read-rooms)))

(defun fermium--mark-room-locally-read (account-id room-id)
  "Remember that ROOM-ID for ACCOUNT-ID was just marked read."
  (when (and account-id room-id)
    (puthash (fermium--room-state-key account-id room-id) t
             fermium--locally-read-rooms)))

(defun fermium--clear-room-locally-read (account-id room-id)
  "Forget the local read override for ROOM-ID belonging to ACCOUNT-ID."
  (when (and account-id room-id)
    (remhash (fermium--room-state-key account-id room-id)
             fermium--locally-read-rooms)))

(defun fermium--clear-account-locally-read (account-id)
  "Forget all local read overrides belonging to ACCOUNT-ID."
  (when account-id
    (let (keys)
      (maphash
       (lambda (key _value)
         (when (equal (car key) account-id)
           (push key keys)))
       fermium--locally-read-rooms)
      (dolist (key keys)
        (remhash key fermium--locally-read-rooms)))))

(defun fermium--pending-login-p (account)
  "Return non-nil when ACCOUNT represents an in-progress login."
  (equal (fermium--event-value account "status") "logging_in"))

(defun fermium--pending-login-record (account-id)
  "Return the pending login record for ACCOUNT-ID, if any."
  (seq-find (lambda (account)
              (equal account-id (fermium--account-record-id account)))
            fermium--pending-logins))

(defun fermium--render-overview-if-live ()
  "Render the overview when its buffer exists."
  (when-let ((buffer (get-buffer fermium--overview-buffer)))
    (with-current-buffer buffer
      (fermium--render-overview))))

(defun fermium--add-pending-login (account-id)
  "Show ACCOUNT-ID as an account whose login is in progress."
  (setq fermium--pending-logins
        (cons (list (cons "user_id" account-id)
                    (cons "status" "logging_in")
                    (cons "rooms" nil))
              (cl-remove-if
               (lambda (account)
                 (equal account-id (fermium--account-record-id account)))
               fermium--pending-logins)))
  (fermium--start-loading-animation)
  (fermium--render-overview-if-live))

(defun fermium--remove-pending-login (account-id)
  "Remove the pending login identified by ACCOUNT-ID."
  (when account-id
    (setq fermium--pending-logins
          (cl-remove-if
           (lambda (account)
             (equal account-id (fermium--account-record-id account)))
           fermium--pending-logins))
    (fermium--render-overview-if-live)
    (fermium--stop-loading-animation-if-idle)))

(defun fermium--account-records ()
  "Return the known account summaries.

The single-account variables are retained as a small compatibility shim for
older callers and for the empty-state UI tests; helper state uses
`fermium--accounts'."
  (append (or fermium--accounts
              (and fermium--account
                   (list (list (cons "user_id" fermium--account)
                               (cons "rooms" fermium--rooms)))))
          fermium--pending-logins))

(defun fermium--account-record (account-id)
  "Return the summary for ACCOUNT-ID, if it is known."
  (seq-find (lambda (account)
              (equal account-id (fermium--account-record-id account)))
            (fermium--account-records)))

(defun fermium--ensure-account-status-fields (account)
  "Ensure ACCOUNT has fields used to track connection status."
  (dolist (key '("connection_status" "last_sync_timestamp"
                 "connection_error" "initial_sync_failed"))
    (unless (assoc key account)
      (setq account (cons (cons key nil) account))))
  account)

(defun fermium--timestamp-number (timestamp)
  "Return TIMESTAMP as a number, or nil when it is not a timestamp."
  (cond
   ((numberp timestamp) timestamp)
   ((stringp timestamp) (string-to-number timestamp))
   (t nil)))

(defun fermium--format-sync-timestamp (timestamp)
  "Format sync TIMESTAMP, which is milliseconds since the Unix epoch."
  (when-let ((timestamp (fermium--timestamp-number timestamp)))
    (format-time-string
     "%Y-%m-%d %H:%M:%S"
     (seconds-to-time (/ timestamp 1000.0)))))

(defun fermium--account-connection-error-p (account)
  "Return non-nil when ACCOUNT has a connection error or is offline."
  (or (fermium--event-value account "connection_error")
      (equal (fermium--event-value account "connection_status") "offline")))

(defun fermium--account-status-description (account)
  "Describe the current connection status of ACCOUNT."
  (let ((account-id (fermium--account-record-id account))
        (status (fermium--event-value account "connection_status"))
        (error (fermium--event-value account "connection_error"))
        (timestamp (fermium--format-sync-timestamp
                    (fermium--event-value account "last_sync_timestamp"))))
    (cond
     ((fermium--event-value account "initial_sync_failed")
      (format "%s: initial sync failed%s"
              account-id
              (if error (format ": %s" error) "")))
     (error (format "%s: %s" account-id error))
     ((equal status "offline")
      (format "%s: offline" account-id))
     ((equal status "online")
      (format "%s: last successful sync %s"
              account-id (or timestamp "unknown")))
     ((fermium--event-value account "rooms_loading")
      (format "%s: initial sync in progress" account-id))
     (t (format "%s: connection status unknown" account-id)))))

(defun fermium--overview-mode-line-status-data ()
  "Return the aggregate modeline status data for the overview."
  (let* ((accounts (fermium--account-records))
         (problem-accounts
          (seq-filter #'fermium--account-connection-error-p accounts))
         (loading-accounts
          (seq-filter
           (lambda (account)
             (fermium--event-value account "rooms_loading"))
           accounts)))
    (cond
     (problem-accounts
      (list :icon "⚠"
            :face 'fermium-modeline-error-face
            :help-echo
            (concat "Fermium: "
                    (mapconcat #'fermium--account-status-description
                               problem-accounts "; "))))
     ((or fermium--state-loading fermium--pending-logins loading-accounts)
      (list :icon "⌛"
            :face 'fermium-modeline-loading-face
            :help-echo
            (cond
             (fermium--state-loading
              "Fermium: loading account state...")
             (fermium--pending-logins
              (format "Fermium: logging in: %s"
                      (string-join
                       (mapcar #'fermium--account-record-id
                               fermium--pending-logins)
                       ", ")))
             (t
              (format "Fermium: initial sync in progress for %s"
                      (string-join
                       (mapcar #'fermium--account-record-id
                               loading-accounts)
                       ", "))))))
     ((and accounts
           (not (seq-some
                 (lambda (account)
                   (not (equal (fermium--event-value
                                account "connection_status") "online")))
                 accounts)))
      (list :icon "⇅"
            :face 'fermium-modeline-connected-face
            :help-echo
            (concat "Fermium: "
                    (mapconcat #'fermium--account-status-description
                               accounts "; ")))))))

(defun fermium-room--mode-line-status-data ()
  "Return the modeline status data for the current room buffer."
  (let* ((account (fermium--account-record fermium-room--account-id))
         (account-status (and account
                              (fermium--event-value
                               account "connection_status")))
         (account-error (and account
                             (fermium--event-value
                              account "connection_error")))
         (timestamp (and account
                         (fermium--format-sync-timestamp
                          (fermium--event-value
                           account "last_sync_timestamp")))))
    (cond
     (fermium-room--send-error
      (list :icon "⚠"
            :face 'fermium-modeline-error-face
            :help-echo (format "Fermium: message send failed: %s"
                               fermium-room--send-error)))
     ((or (equal account-status "offline") account-error)
      (list :icon "⚠"
            :face 'fermium-modeline-error-face
            :help-echo
            (format "Fermium: %s offline%s"
                    fermium-room--account-id
                    (if account-error
                        (format ": %s" account-error)
                      ""))))
     (fermium-room--sending
      (list :icon "➤"
            :face 'fermium-modeline-sending-face
            :help-echo "Fermium: sending message..."))
     (fermium-room--loading
      (list :icon "⌛"
            :face 'fermium-modeline-loading-face
            :help-echo "Fermium: loading room history..."))
     ((equal account-status "online")
      (list :icon "⇅"
            :face 'fermium-modeline-connected-face
            :help-echo
            (format "Fermium: last successful sync %s"
                    (or timestamp "unknown")))))))

(defun fermium--mode-line-status ()
  "Return the current Fermium modeline status segment."
  (let ((status
         (cond
          ((derived-mode-p 'fermium-room-mode)
           (fermium-room--mode-line-status-data))
          ((derived-mode-p 'fermium-overview-mode)
           (fermium--overview-mode-line-status-data)))))
    (when status
      (propertize
       (concat " " (plist-get status :icon))
       'face (plist-get status :face)
       'mouse-face 'mode-line-highlight
       'help-echo (plist-get status :help-echo)))))

(defun fermium--force-mode-line-update (&optional account-id)
  "Refresh Fermium modelines, optionally scoped to ACCOUNT-ID."
  (dolist (buffer (buffer-list))
    (when (and (buffer-live-p buffer)
               (with-current-buffer buffer
                 (or (derived-mode-p 'fermium-overview-mode)
                     (and (derived-mode-p 'fermium-room-mode)
                          (or (null account-id)
                              (equal account-id fermium-room--account-id))))))
      (with-current-buffer buffer
        (force-mode-line-update t)))))

(defun fermium--account-ids ()
  "Return the IDs of all known accounts."
  (delq nil (mapcar #'fermium--account-record-id
                    (fermium--account-records))))

(defun fermium--rooms-for-account (account-id)
  "Return the room summaries belonging to ACCOUNT-ID."
  (let ((account (fermium--account-record account-id)))
    (if account
        (fermium--event-value account "rooms")
      (and (equal account-id fermium--account) fermium--rooms))))

(defun fermium--set-selected-account (account-id)
  "Keep the legacy selected-account variables aligned with ACCOUNT-ID."
  (setq fermium--account account-id)
  (setq fermium--rooms (fermium--rooms-for-account account-id)))

(defun fermium--multi-account-p ()
  "Return non-nil when more than one account is known."
  (> (length (fermium--account-records)) 1))

(defun fermium--room-buffer-name (room-id &optional account-id room-title)
  "Return the buffer name for ROOM-ID and ACCOUNT-ID.

ROOM-TITLE is the user-facing room name.  Keep ROOM-ID as the fallback so
buffers can still be created while a room's name is being resolved."
  (format "*Fermium: %s%s*"
          (or room-title room-id)
          (if account-id
              (format " / %s" account-id)
            "")))

(defun fermium--terminal-event-p (type)
  (member type '("login_succeeded" "logout_succeeded" "state" "room_opened"
                 "media_downloaded" "message_sent" "room_read" "device_verified"
                 "error")))

(defun fermium--handle-event (event)
  (let* ((type (fermium--event-value event "type"))
         (request-id (fermium--event-value event "request_id"))
         (callback (and request-id
                        (gethash request-id fermium--pending-requests))))
    (when callback
      (unwind-protect
          (funcall callback event)
        (when (fermium--terminal-event-p type)
          (remhash request-id fermium--pending-requests))))
    (pcase type
      ("login_succeeded" (fermium--handle-login event))
      ("account_available" (fermium--handle-account-available event))
      ("state" (fermium--handle-state event))
      ("room_opened" (fermium--handle-room-opened event))
      ("room_updated" (fermium--handle-room-updated event))
      ("room_removed" (fermium--handle-room-removed event))
      ("message" (fermium--handle-message-event event))
      ("message_pending" (fermium--handle-message-pending event))
      ("message_sent" (fermium--handle-message-sent event))
      ("room_read" (fermium--handle-room-read event))
      ("logout_succeeded" (fermium--handle-logout event))
      ("error" (message "Fermium: %s"
                        (fermium--event-value event "message")))
      ("connection_status" (fermium--handle-connection-status event)))))

(defun fermium--open-overview ()
  "Open the canonical Fermium overview in the current window."
  (let ((new-process (not (process-live-p fermium--process))))
    (fermium--ensure-process)
    (when new-process
      (fermium--request-state))
    (let ((buffer (get-buffer-create fermium--overview-buffer)))
      (with-current-buffer buffer
        (unless (derived-mode-p 'fermium-overview-mode)
          (fermium-overview-mode))
        (fermium--render-overview))
      (switch-to-buffer buffer)
      buffer)))

(defun fermium ()
  "Open the Fermium overview buffer."
  (interactive)
  (fermium--open-overview))

(defun fermium-room-overview ()
  "Return from the current room to the Fermium overview."
  (interactive)
  (fermium--open-overview))

(defun fermium-login ()
  "Log in to a Matrix homeserver using auth-source credentials."
  (interactive)
  (let* ((homeserver (read-string "Homeserver URL: " "https://matrix.org"))
         (username (read-string "Matrix user ID: "))
         (host (url-host (url-generic-parse-url homeserver)))
         (auth (auth-source-search :host host
                                   :port fermium-auth-source-port
                                   :user username
                                   :max 1))
         (password (or (plist-get (car auth) :secret)
                       (read-passwd (format "Password for %s: " username)))))
    (fermium)
    (fermium--add-pending-login username)
    (message "Fermium: logging in as %s" username)
    (condition-case error
        (fermium--send
         "login"
         (list (cons "homeserver" homeserver)
               (cons "username" username)
               (cons "password" (if (functionp password)
                                    (funcall password)
                                  password)))
         (lambda (event)
           (fermium--handle-login-response event username)))
      (error
       (fermium--remove-pending-login username)
       (message "Fermium: could not start login for %s: %s"
                username
                (error-message-string error))))))

(defun fermium--handle-login-response (event &optional pending-account)
  "Handle a response or continuation request for a login EVENT."
  (pcase (fermium--event-value event "type")
    ("login_succeeded"
     (fermium--remove-pending-login pending-account)
     (message "Fermium: login complete"))
    ("device_verified"
     (message "Fermium: device verification complete"))
    ("login_verification_required"
     (if (equal (fermium--event-value event "method") "recovery_key")
         (fermium--prompt-for-recovery-key event)
       (progn
         (message "Fermium: login requires unsupported device verification: %s"
                  (fermium--event-value event "method"))
         (fermium--remove-pending-login pending-account))))
    (_
     (fermium--remove-pending-login pending-account)
     (message "Fermium: login failed: %s"
              (fermium--event-value event "message")))))

(defun fermium--prompt-for-recovery-key (event)
  "Prompt for the recovery key requested by login EVENT."
  (let ((recovery-key (fermium--read-recovery-key)))
    (cond
     ((or (null recovery-key) (string-empty-p recovery-key))
      (message "Fermium: recovery key is required to finish login"))
     (t
      (condition-case error
          (fermium--send
           "login_recovery_key"
           (list (cons "login_request_id"
                       (fermium--event-value event "request_id"))
                 (cons "recovery_key" recovery-key))
           nil)
        (error
         (message "Fermium: could not submit recovery key: %s"
                  (error-message-string error))))))))

(defun fermium--read-recovery-key ()
  "Read a recovery key without retaining it in the minibuffer history."
  (condition-case nil
      (read-passwd "Recovery key for device verification: ")
    (quit nil)))

(defun fermium-verify-device (&optional selected-account)
  "Verify a logged-in Matrix device with its account recovery key."
  (interactive)
  (if (not (fermium--account-ids))
      (message "Fermium: no logged-in account to verify")
    (when-let ((account (or selected-account (fermium--select-account "verify"))))
      (let ((recovery-key (fermium--read-recovery-key)))
        (if (or (null recovery-key) (string-empty-p recovery-key))
            (message "Fermium: recovery key is required to verify %s"
                     account)
          (condition-case error
              (fermium--send
               "verify_device"
               (list (cons "account" account)
                     (cons "recovery_key" recovery-key))
               (lambda (event)
                 (fermium--handle-device-verification event account)))
            (error
             (message "Fermium: could not submit recovery key: %s"
                      (error-message-string error)))))))))

(defun fermium--select-account (&optional action)
  "Prompt for an account for ACTION."
  (let ((prompt (format "Account to %s: " (or action "use")))
        (accounts (fermium--account-ids)))
    (completing-read prompt
                     accounts
                     nil
                     t
                     nil
                     nil
                     (or (and (member fermium--account accounts)
                              fermium--account)
                         (car accounts)))))

(defun fermium--handle-device-verification (event account)
  "Report the result of verifying ACCOUNT from helper EVENT."
  (if (equal (fermium--event-value event "type") "device_verified")
      (message "Fermium: device verification complete for %s" account)
    (message "Fermium: device verification failed for %s: %s"
             account
             (fermium--event-value event "message"))))

(defun fermium-account-menu (&optional selected-account)
  "Show actions for SELECTED-ACCOUNT, or the account at point."
  (interactive)
  (let ((account (or selected-account
                     (get-text-property (point) 'fermium-account-id)
                     fermium--account)))
    (if (and account (fermium--pending-login-record account))
        (message "Fermium: login for %s is still in progress" account)
      (pcase (read-char-choice
              "Fermium account: [l]ogin [v]erify [o]logout [q]uit "
              '(?l ?v ?o ?q))
        (?l (call-interactively #'fermium-login))
        (?v (if account
                (fermium-verify-device account)
              (fermium-verify-device)))
        (?o (if account
                (fermium-logout account)
              (fermium-logout)))
        (?q (fermium-quit))))))

(defun fermium-logout (&optional selected-account)
  "Log out of SELECTED-ACCOUNT, or prompt for an account."
  (interactive)
  (let ((account (or selected-account
                     (and (fermium--account-ids)
                          (fermium--select-account "log out")))))
    (cond
     ((not account)
      (message "Fermium: no logged-in account to log out"))
     ((not (yes-or-no-p (format "Log out of %s? " account))) nil)
     (t
      (message "Fermium: logging out of %s" account)
      (condition-case error
          (fermium--send
           "logout"
           (list (cons "account" account))
           #'fermium--handle-logout-response)
        (error
         (message "Fermium: could not log out of %s: %s"
                  account
                  (error-message-string error))))))))

(defun fermium--handle-logout-response (event)
  "Report the result of a logout request EVENT."
  (if (equal (fermium--event-value event "type") "logout_succeeded")
      (message "Fermium: logout complete for %s"
               (fermium--event-value event "account"))
    (message "Fermium: logout failed: %s"
             (fermium--event-value event "message"))))

(defun fermium-overview-visit ()
  "Visit the account or room at point."
  (interactive)
  (pcase (fermium--overview-current-entity)
    (`(account . ,_) (fermium-account-menu))
    (`(room . ,_) (fermium-open-room))
    (_ (message "Fermium: no visitable item at point"))))

(defun fermium-overview--mouse-toggle-section (event)
  "Move to EVENT and toggle the overview section there."
  (interactive "e")
  (mouse-set-point event)
  (fermium-toggle-section))

(defun fermium-refresh ()
  "Refresh the overview state from the Rust helper."
  (interactive)
  (fermium--request-state))

(defun fermium--request-state ()
  "Request current account and room state from the Rust helper."
  (setq fermium--state-loading t)
  (fermium--start-loading-animation)
  (when-let ((buffer (get-buffer fermium--overview-buffer)))
    (with-current-buffer buffer
      (fermium--render-overview)))
  (condition-case error
      (fermium--send
       "list_state"
       nil
       (lambda (event)
         (setq fermium--state-loading nil)
         (if (equal (fermium--event-value event "type") "state")
             (message "Fermium: refreshed")
           (message "Fermium: refresh failed: %s"
                    (fermium--event-value event "message")))
         (when-let ((buffer (get-buffer fermium--overview-buffer)))
           (with-current-buffer buffer
             (fermium--render-overview)))
         (fermium--stop-loading-animation-if-idle)))
    (error
     (setq fermium--state-loading nil)
     (fermium--stop-loading-animation-if-idle)
     (signal (car error) (cdr error)))))

(defun fermium--upsert-account-summary (account)
  "Add or replace ACCOUNT in the known account summaries."
  (let ((account-id (fermium--account-record-id account)))
    (when account-id
      (setq fermium--accounts
            (cons account
                  (cl-remove-if
                   (lambda (existing)
                     (equal account-id (fermium--account-record-id existing)))
                   fermium--accounts)))
      (unless fermium--account
        (fermium--set-selected-account account-id)))))

(defun fermium--handle-account-available (event)
  "Add a restored account before its initial room sync completes."
  (when-let ((account (fermium--event-value event "account")))
    (fermium--upsert-account-summary account)
    (when-let ((buffer (get-buffer fermium--overview-buffer)))
      (with-current-buffer buffer
        (fermium--render-overview)))))

(defun fermium--handle-connection-status (event)
  "Update the connection and initial-loading state for EVENT's account."
  (let* ((account-id (fermium--event-value event "account"))
         (status (fermium--event-value event "status"))
         (last-sync (fermium--event-value event "last_sync_timestamp"))
         (connection-error (fermium--event-value event "error"))
         (previous-status nil)
         (previous-rooms-loading nil))
    (setq fermium--accounts
          (mapcar #'fermium--ensure-account-status-fields
                  fermium--accounts))
    (when-let ((account (fermium--account-record account-id)))
      (setq previous-status
            (fermium--event-value account "connection_status"))
      (setq previous-rooms-loading
            (fermium--event-value account "rooms_loading"))
      (setf (alist-get "connection_status" account nil nil #'string=) status)
      (when (or (assoc "last_sync_timestamp" event)
                (equal status "online"))
        (when last-sync
          (setf (alist-get "last_sync_timestamp" account nil nil #'string=)
                last-sync)))
      (when (or (assoc "error" event) (equal status "online"))
        (setf (alist-get "connection_error" account nil nil #'string=)
              (unless (equal status "online") connection-error)))
      (when (or (assoc "initial_sync_failed" event)
                (equal status "online"))
        (setf (alist-get "initial_sync_failed" account nil nil #'string=)
              (and (not (equal status "online"))
                   (fermium--event-value event "initial_sync_failed"))))
      (when (member status '("online" "offline"))
        (setf (alist-get "rooms_loading" account nil nil #'string=) nil)))
    (fermium--force-mode-line-update account-id)
    (when (or (not (equal previous-status status))
              (not (equal previous-rooms-loading
                          (when-let ((account (fermium--account-record
                                               account-id)))
                            (fermium--event-value account "rooms_loading")))))
      (when-let ((buffer (get-buffer fermium--overview-buffer)))
        (with-current-buffer buffer
          (fermium--render-overview))))))

(defun fermium-quit ()
  "Stop the helper and close Fermium buffers."
  (interactive)
  (setq fermium--stopping t)
  (when (process-live-p fermium--process)
    (fermium--send "quit" nil nil)
    (delete-process fermium--process))
  (setq fermium--process nil)
  (setq fermium--process-output "")
  (clrhash fermium--pending-requests)
  (setq fermium--accounts nil)
  (setq fermium--pending-logins nil)
  (setq fermium--account nil)
  (setq fermium--rooms nil)
  (clrhash fermium--locally-read-rooms)
  (setq fermium--state-loading nil)
  (when fermium--loading-timer
    (cancel-timer fermium--loading-timer)
    (setq fermium--loading-timer nil))
  (dolist (buffer (seq-filter
                   (lambda (buffer)
                     (string-prefix-p "*Fermium" (buffer-name buffer)))
                   (buffer-list)))
    (fermium--close-buffer buffer "quit")))

(defun fermium--overview-section-collapsed-p (section)
  (member section fermium--overview-collapsed-sections))

(defun fermium--overview-section-marker (section &optional section-key)
  (if (fermium--overview-section-collapsed-p (or section-key section))
      "▸"
    "▾"))

(defun fermium--overview-entity-face (kind)
  (pcase kind
    ('account 'fermium-overview-account-face)
    ('room 'fermium-overview-room-face)
    (_ 'default)))

(defun fermium--overview-insert-section
    (section title body indent entity &optional section-key)
  (let* ((section-key (or section-key section))
         (header-start (point))
         (collapsed (fermium--overview-section-collapsed-p section-key)))
    (insert indent (fermium--overview-section-marker section section-key) " ")
    (let ((title-start (point)))
      (insert title "\n")
      (add-text-properties
       title-start (point)
       (list 'face (if entity
                       (fermium--overview-entity-face (nth 0 entity))
                     'fermium-overview-group-face))))
    (add-text-properties
     header-start (point)
     (list 'fermium-overview-row-type (if entity
                                          'visitable-group
                                        'group)
           'fermium-overview-group t
           'fermium-section section
           'fermium-section-id section
           'fermium-section-key section-key))
    (unless entity
      (add-text-properties
       header-start (point)
       (list 'keymap fermium-overview--toggle-map
             'follow-link t
             'help-echo "TAB toggles this group")))
    (when entity
      (add-text-properties
       header-start (point)
       (list 'fermium-entity (nth 0 entity)
             'fermium-entity-id (nth 1 entity)
             'fermium-account-id (nth 1 entity))))
    (add-text-properties
     (+ header-start (length indent))
     (+ header-start (length indent)
        (length (fermium--overview-section-marker section section-key)))
     '(face fermium-overview-marker-face))
    (let ((body-start (point)))
      (funcall body)
      (when collapsed
        (add-text-properties body-start (point) '(invisible fermium))))))

(defun fermium--overview-room-activity-timestamp (room)
  (max (or (fermium--event-value room "last_activity_timestamp") 0)
       (or (fermium--event-value (fermium--event-value room "latest_message")
                                 "timestamp")
           0)))

(defun fermium--overview-room-message (room)
  (fermium--event-value room "latest_message"))

(defun fermium--overview-room-display-width ()
  (or (when-let ((window (get-buffer-window (current-buffer))))
        (window-body-width window))
      80))

(defun fermium--overview-format-room-timestamp (timestamp)
  (when (and (numberp timestamp) (> timestamp 0))
    (let ((time (seconds-to-time (/ timestamp 1000.0))))
      (if (string= (format-time-string "%Y-%m-%d" time)
                   (format-time-string "%Y-%m-%d"))
          (format-time-string "%H:%M" time)
        (format-time-string "%Y-%m-%d" time)))))

(defun fermium--overview-room-sort< (left right)
  (let ((left-timestamp (fermium--overview-room-activity-timestamp left))
        (right-timestamp (fermium--overview-room-activity-timestamp right))
        (left-name (or (fermium--event-value left "name") ""))
        (right-name (or (fermium--event-value right "name") ""))
        (left-id (or (fermium--event-value left "room_id") ""))
        (right-id (or (fermium--event-value right "room_id") "")))
    (cond
     ((/= left-timestamp right-timestamp)
      (> left-timestamp right-timestamp))
     ((not (equal left-name right-name))
      (string-lessp left-name right-name))
     (t
      (string-lessp left-id right-id)))))

(defun fermium--overview-sorted-rooms (&optional rooms)
  (sort (copy-sequence (or rooms fermium--rooms))
        #'fermium--overview-room-sort<))

(defun fermium--overview-insert-room (room &optional account-id)
  (let* ((room-id (fermium--event-value room "room_id"))
         (name (or (fermium--event-value room "name") room-id))
         (message (fermium--overview-room-message room))
         (preview (replace-regexp-in-string
                   "[[:space:]]+" " "
                   (string-trim
                    (if (fermium--event-value message "image")
                        "[Image]"
                      (or (fermium--event-value message "body") "")))))
         (timestamp
          (fermium--overview-format-room-timestamp
           (fermium--overview-room-activity-timestamp room)))
         (width (fermium--overview-room-display-width))
         (name-width (max 8 (min 32 (/ width 3))))
         (display-name (truncate-string-to-width name name-width nil nil "…"))
         (prefix-width (+ (string-width "• ")
                          (string-width display-name)
                          (if timestamp (+ 2 (string-width timestamp)) 0)))
         (preview-width (max 0 (- width prefix-width
                                  (if (string-empty-p preview) 0 2))))
         (display-preview (truncate-string-to-width
                           preview preview-width nil nil "…"))
         (unread (fermium--event-value room "has_unread"))
         (start (point))
         (timestamp-start nil)
         (timestamp-end nil)
         (preview-start nil)
         (preview-end nil))
    (insert "• " display-name)
    (when timestamp
      (insert "  ")
      (setq timestamp-start (point))
      (insert timestamp)
      (setq timestamp-end (point)))
    (unless (string-empty-p display-preview)
      (insert "  ")
      (setq preview-start (point))
      (insert display-preview)
      (setq preview-end (point)))
    (insert "\n")
    (add-text-properties
     start (point)
     (list 'fermium-overview-row-type 'visitable
           'fermium-entity 'room
           'fermium-entity-id room-id
           'fermium-room-id room-id
           'fermium-account-id account-id
           'face (if unread
                     '(fermium-overview-unread-face
                       fermium-overview-room-face)
                   'fermium-overview-room-face)))
    (when timestamp-start
      (add-text-properties timestamp-start timestamp-end
                           (list 'face
                                 (if unread
                                     '(fermium-overview-unread-face
                                       fermium-overview-room-meta-face)
                                   'fermium-overview-room-meta-face))))
    (when preview-start
      (add-text-properties preview-start preview-end
                           (list 'face
                                 (if unread
                                     '(fermium-overview-unread-face
                                       fermium-overview-room-meta-face)
                                   'fermium-overview-room-meta-face))))))

(defun fermium--overview-visible-rows ()
  (let (rows)
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (let ((kind (get-text-property (point) 'fermium-entity))
              (id (get-text-property (point) 'fermium-entity-id))
              (section (get-text-property (point) 'fermium-section-id)))
          (when (and (not (invisible-p (point)))
                     (or (and kind id) section))
            (push (list (point)
                        (if (and kind id)
                            (list kind id
                                  (get-text-property
                                   (point) 'fermium-account-id))
                          (list 'section section
                                (or (get-text-property
                                     (point) 'fermium-section-key)
                                    section))))
                  rows)))
        (forward-line 1)))
    (nreverse rows)))

(defun fermium--overview-current-row ()
  (let ((kind (fermium--overview-property-at-point 'fermium-entity))
        (id (fermium--overview-property-at-point 'fermium-entity-id))
        (section (fermium--overview-current-section)))
    (cond
     ((and kind id) (list 'entity kind id))
     (section (list 'section section)))))

(defun fermium--overview-property-at-point (property)
  (or (get-text-property (point) property)
      (and (> (point) (line-beginning-position))
           (get-text-property (1- (point)) property))))

(defun fermium--overview-current-entity ()
  (let ((kind (fermium--overview-property-at-point 'fermium-entity))
        (id (fermium--overview-property-at-point 'fermium-entity-id)))
    (and kind id (cons kind id))))

(defun fermium--overview-current-section ()
  (fermium--overview-property-at-point 'fermium-section-id))

(defun fermium--overview-current-section-key ()
  (or (fermium--overview-property-at-point 'fermium-section-key)
      (fermium--overview-current-section)))

(defun fermium--overview-current-entity-key ()
  (let ((entity (fermium--overview-current-entity)))
    (and entity
         (list (car entity)
               (cdr entity)
               (fermium--overview-property-at-point 'fermium-account-id)))))

(defun fermium--overview-goto-property (property value)
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found) (< (point) (point-max)))
      (when (equal (get-text-property (point) property) value)
        (setq found t))
      (unless found
        (forward-line 1)))
    found))

(defun fermium--overview-goto-entity (kind id &optional account-id)
  "Move to entity KIND and ID, optionally scoped to ACCOUNT-ID."
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found) (< (point) (point-max)))
      (when (and (eq (get-text-property (point) 'fermium-entity) kind)
                 (equal (get-text-property (point) 'fermium-entity-id) id)
                 (or (null account-id)
                     (equal (get-text-property (point) 'fermium-account-id)
                            account-id)))
        (setq found t))
      (unless found
        (forward-line 1)))
    found))

(defun fermium--overview-visible-entities ()
  (let (entities)
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (let ((kind (get-text-property (point) 'fermium-entity))
              (id (get-text-property (point) 'fermium-entity-id)))
          (when (and kind id (not (invisible-p (point))))
            (push (list (point) kind id) entities)))
        (forward-line 1)))
    (nreverse entities)))

(defun fermium--overview-move (step)
  (let* ((rows (fermium--overview-visible-rows))
         (current (or (fermium--overview-current-entity-key)
                      (list 'section
                            (fermium--overview-current-section)
                            (fermium--overview-current-section-key))))
         (index (and current
                     (cl-position-if
                      (lambda (row)
                        (equal current (nth 1 row)))
                      rows)))
         (target-index (if index (+ index step) (if (> step 0) 0 (1- (length rows)))))
         (target (and (>= target-index 0)
                      (< target-index (length rows))
                      (nth target-index rows))))
    (if target
        (progn
          (goto-char (car target))
          (beginning-of-line))
      (message "Fermium: no %s row" (if (> step 0) "next" "previous")))))

(defun fermium-next ()
  "Move to the next visible overview row."
  (interactive)
  (fermium--overview-move 1))

(defun fermium-previous ()
  "Move to the previous visible overview row."
  (interactive)
  (fermium--overview-move -1))

(defun fermium-toggle-section ()
  "Collapse or expand the section at point."
  (interactive)
  (let ((section (fermium--overview-current-section))
        (section-key (fermium--overview-current-section-key)))
    (if (not section)
        (message "Fermium: no section at point")
      (if (fermium--overview-section-collapsed-p section-key)
          (setq fermium--overview-collapsed-sections
                (delete section-key fermium--overview-collapsed-sections))
        (push section-key fermium--overview-collapsed-sections))
      (fermium--render-overview))))

(transient-define-prefix fermium--overview-help ()
  "Fermium overview commands."
  ["Navigation"
   ("n" "next overview row" fermium-next)
   ("p" "previous overview row" fermium-previous)
   ("TAB" "collapse or expand group" fermium-toggle-section)
   ("RET" "visit item at point" fermium-overview-visit)]
  ["Account"
   ("l" "log in" fermium-login)
   ("a" "account actions" fermium-account-menu)
   ("g" "refresh" fermium-refresh)
   ("q" "quit Fermium" fermium-quit)])

(transient-define-prefix fermium--room-help ()
  "Fermium room commands."
  ["Room"
   ("C-c o" "return to the overview" fermium-room-overview)
   ("TAB" "collapse or expand header or channel events"
    fermium-room-toggle-header-or-channel-events)
   ("C-c C-c" "send the message" fermium-room-send)
   ("C-c C-k" "clear the composition" fermium-room-clear-input)])

(defun fermium-help ()
  "Show Fermium's key bindings in a temporary command popup."
  (interactive)
  (if (derived-mode-p 'fermium-room-mode)
      (fermium--room-help)
    (fermium--overview-help)))

(defun fermium--overview-insert-rooms-section
    (account-id &optional rooms rooms-loading initial-sync-failed)
  (let ((rooms (if account-id
                   (or rooms (fermium--rooms-for-account account-id))
                 (or rooms fermium--rooms))))
    (fermium--overview-insert-section
     'rooms
     (cond
      (initial-sync-failed "Rooms (initial sync failed)")
      (rooms-loading "Rooms (loading)")
      (t (format "Rooms (%d)" (length rooms))))
     (lambda ()
       (cond
        (initial-sync-failed
         (insert "Initial sync failed. Press g to retry.\n")
         (dolist (room (fermium--overview-sorted-rooms rooms))
           (fermium--overview-insert-room room account-id)))
        (rooms
         (dolist (room (fermium--overview-sorted-rooms rooms))
           (fermium--overview-insert-room room account-id)))
        (rooms-loading
         (insert "Loading rooms...\n"))
        (t
         (insert "No rooms yet.\n"))))
     ""
     nil
     (and account-id (list 'rooms account-id)))))

(defun fermium--render-overview ()
  (let* ((inhibit-read-only t)
         (point-position (point))
         (accounts (fermium--account-records))
         (point-entity (fermium--overview-current-entity))
         (point-entity-account
          (fermium--overview-property-at-point 'fermium-account-id))
         (point-section (fermium--overview-current-section))
         (point-section-key
          (fermium--overview-property-at-point 'fermium-section-key)))
    (erase-buffer)
    (cond
     (accounts
      (dolist (account accounts)
        (let ((account-id (fermium--account-record-id account))
              (rooms (fermium--event-value account "rooms")))
          (fermium--overview-insert-section
           'account
           account-id
           (lambda ()
             (if (fermium--pending-login-p account)
                 (insert (format "Logging in%s\n"
                                 (fermium--loading-dots)))
               (fermium--overview-insert-rooms-section
                account-id rooms
                (fermium--event-value account "rooms_loading")
                (fermium--event-value account "initial_sync_failed"))))
           ""
           (list 'account account-id nil)
           (list 'account account-id)))))
     (fermium--state-loading
      (insert (format "Loading account state%s\n"
                      (fermium--loading-dots))))
     (t
      (insert "Not logged in. Press l to log in.\n")))
    (cond
     (point-entity
      (fermium--overview-goto-entity
       (car point-entity) (cdr point-entity) point-entity-account))
     (point-section-key
      (fermium--overview-goto-property 'fermium-section-key point-section-key))
     (point-section
      (fermium--overview-goto-property 'fermium-section-id point-section))
     ;; Loading and empty-state lines do not have overview row properties.
     ;; Keep the old point in that case instead of leaving it at the end of
     ;; the newly inserted buffer.
     (t
      (goto-char (min point-position (point-max)))))))

(defun fermium--handle-login (event)
  (setq fermium--state-loading nil)
  (fermium--stop-loading-animation-if-idle)
  (let* ((account-id (fermium--event-value event "user_id"))
         (account (list (cons "user_id" account-id)
                        (cons "homeserver"
                              (fermium--event-value event "homeserver"))
                        (cons "rooms" (fermium--event-value event "rooms"))
                        (cons "rooms_loading"
                              (if (assoc "rooms_loading" event)
                                  (fermium--event-value event "rooms_loading")
                                t))
                        (cons "initial_sync_failed"
                              (fermium--event-value event
                                                    "initial_sync_failed"))
                        (cons "connection_status"
                              (fermium--event-value event
                                                    "connection_status"))
                        (cons "last_sync_timestamp"
                              (fermium--event-value event
                                                    "last_sync_timestamp"))
                        (cons "connection_error"
                              (fermium--event-value event
                                                    "connection_error")))))
    (fermium--remove-pending-login account-id)
    (fermium--upsert-account-summary account)
    (fermium--set-selected-account account-id))
  (when-let ((buffer (get-buffer fermium--overview-buffer)))
    (with-current-buffer buffer
      (fermium--render-overview))))

(defun fermium--handle-state (event)
  (setq fermium--state-loading nil)
  (fermium--stop-loading-animation-if-idle)
  (let ((accounts (fermium--event-value event "accounts"))
        (previous-account fermium--account))
    ;; The SDK can briefly report the pre-receipt unread state when the fast
    ;; snapshot is reloaded.  Keep the locally accepted read state until a
    ;; new message arrives.
    (setq fermium--accounts
          (fermium--apply-local-read-state
           (mapcar #'fermium--ensure-account-status-fields accounts)))
    (setq fermium--account nil)
    (setq fermium--rooms nil)
    (let ((account-ids (fermium--account-ids)))
      (fermium--set-selected-account
       (or (and (member previous-account account-ids) previous-account)
           (car account-ids)))))
  (when-let ((buffer (get-buffer fermium--overview-buffer)))
    (with-current-buffer buffer
      (fermium--render-overview))))

(defun fermium--handle-logout (event)
  "Remove the account named by successful logout EVENT from the UI."
  (let ((account-id (fermium--event-value event "account")))
    (fermium--clear-account-locally-read account-id)
    (setq fermium--accounts
          (cl-remove-if
           (lambda (account)
             (equal account-id (fermium--account-record-id account)))
           fermium--accounts))
    (when (equal account-id fermium--account)
      (setq fermium--account nil)
      (setq fermium--rooms nil)
      (fermium--set-selected-account (car (fermium--account-ids))))
    (dolist (buffer (buffer-list))
      (when (and (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (and (derived-mode-p 'fermium-room-mode)
                        (equal fermium-room--account-id account-id))))
        (fermium--close-buffer buffer "logout")))
    (when-let ((buffer (get-buffer fermium--overview-buffer)))
      (with-current-buffer buffer
        (fermium--render-overview)))))

(defun fermium-open-room ()
  "Open the room at point."
  (interactive)
  (let ((room-id (get-text-property (point) 'fermium-room-id))
        (account-id (get-text-property (point) 'fermium-account-id)))
    (if (not room-id)
        (message "Fermium: no room at point")
      (let* ((room (fermium--room-summary-by-id room-id account-id))
             (room-name (or (fermium--event-value room "name") room-id))
             (latest-message (fermium--event-value room "latest_message"))
             (buffer (or (fermium--room-by-id room-id account-id)
                         (get-buffer-create
                          (fermium--room-buffer-name room-id account-id
                                                     room-name))))
             (room-buffer-already-live
              (with-current-buffer buffer
                (derived-mode-p 'fermium-room-mode))))
        (with-current-buffer buffer
          (if room-buffer-already-live
              (progn
                ;; Re-entering a live room activates its existing view.  Do
                ;; not replace its history with another bounded snapshot.
                (setq fermium-room--room-id room-id)
                (setq fermium-room--account-id account-id)
                (setq fermium-room--room-title room-name)
                (fermium-room--rename-buffer room-name)
                (fermium-room--update-header-title room-name))
            (fermium-room-mode)
            (setq fermium-room--room-id room-id)
            (setq fermium-room--account-id account-id)
            (setq fermium-room--read-message-key nil)
            (setq fermium-room--loading t)
            (setq fermium-room--pending-messages nil)
            (fermium-room--render-loading-room room-name latest-message)))
        (switch-to-buffer buffer)
        (if room-buffer-already-live
            (fermium-room--maybe-mark-latest-message-read)
          (fermium--start-loading-animation)
          (condition-case error
              (fermium--send
               "open_room"
               (list (cons "account" account-id)
                     (cons "room_id" room-id))
               (lambda (event)
                 (when (equal (fermium--event-value event "type")
                              "error")
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (fermium-room--finish-loading)))
                   (fermium--stop-loading-animation-if-idle)
                   (message "Fermium: could not open room: %s"
                            (fermium--event-value event "message")))))
            (error
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (fermium-room--finish-loading)))
             (fermium--stop-loading-animation-if-idle)
             (message "Fermium: could not open room: %s"
                      (error-message-string error)))))))))

(defun fermium--handle-room-opened (event)
  (let* ((room (fermium--event-value event "room"))
         (room-id (fermium--event-value room "room_id"))
         (account-id (fermium--event-value event "account"))
         (buffer (fermium--room-by-id room-id account-id)))
    (when room-id
      (fermium--upsert-room-summary room account-id))
    (when buffer
      (with-current-buffer buffer
        (fermium-room--render-room
         room (fermium--event-value event "messages"))
        (fermium-room--maybe-mark-latest-message-read)))))

(defun fermium--handle-room-updated (event)
  "Merge an incremental room summary into the owning account."
  (fermium--upsert-room-summary
   (fermium--event-value event "room")
   (fermium--event-value event "account")))

(defun fermium--handle-room-read (event)
  "Refresh the overview after a room's read marker has been accepted."
  (let ((account-id (fermium--event-value event "account"))
        (room-id (fermium--event-value event "room_id")))
    (fermium--mark-room-locally-read account-id room-id)
    ;; Reapply the override to the current summary in case the read response
    ;; arrived without a preceding room_updated event.
    (when (and account-id room-id)
      (fermium--upsert-room-summary
       (list (cons "room_id" room-id)
             (cons "has_unread" nil))
       account-id)))
  (when-let ((overview (get-buffer fermium--overview-buffer)))
    (with-current-buffer overview
      (fermium--render-overview))))

(defun fermium--handle-room-removed (event)
  "Remove a room that is no longer joined for EVENT's account."
  (let ((account-id (fermium--event-value event "account"))
        (room-id (fermium--event-value event "room_id")))
    (when (and account-id room-id)
      (fermium--clear-room-locally-read account-id room-id)
      (when-let ((account (fermium--account-record account-id)))
        (setf (alist-get "rooms" account nil nil #'string=)
              (cl-remove-if
               (lambda (room)
                 (equal room-id (fermium--event-value room "room_id")))
               (fermium--event-value account "rooms")))
        (when (equal account-id fermium--account)
          (setq fermium--rooms (fermium--event-value account "rooms"))))
      (when-let ((overview (get-buffer fermium--overview-buffer)))
        (with-current-buffer overview
          (fermium--render-overview))))))

(defun fermium--merge-room-summary (existing room)
  "Merge lazily enriched fields from EXISTING into incremental ROOM."
  (if (not existing)
      room
    (let* ((room-id (fermium--event-value room "room_id"))
           (incoming-name (fermium--event-value room "name"))
           (existing-name (fermium--event-value existing "name"))
           (merged (copy-tree room)))
      (dolist (key '("latest_message" "members"))
        (when (and (null (fermium--event-value merged key))
                   (fermium--event-value existing key))
          (setf (alist-get key merged nil nil #'string=)
                (fermium--event-value existing key))))
      (let ((incoming-activity
             (fermium--event-value merged "last_activity_timestamp"))
            (existing-activity
             (fermium--event-value existing "last_activity_timestamp")))
        (when (and (numberp existing-activity)
                   (> existing-activity 0)
                   (or (not (numberp incoming-activity))
                       (< incoming-activity existing-activity)))
          (setf (alist-get "last_activity_timestamp" merged nil nil #'string=)
                existing-activity)))
      ;; Fast room updates cannot resolve names that require asynchronous
      ;; enrichment, such as the other member of a DM.  Do not replace an
      ;; already-resolved name with the room ID fallback.
      (when (and existing-name
                 (not (equal existing-name room-id))
                 (or (null incoming-name)
                     (equal incoming-name room-id)))
        (setf (alist-get "name" merged nil nil #'string=) existing-name))
      merged)))

(defun fermium--apply-local-read-state (accounts)
  "Apply local read overrides to the room summaries in ACCOUNTS."
  (mapcar
   (lambda (account)
     (let* ((account-id (fermium--account-record-id account))
            (merged (copy-tree account)))
       (setf (alist-get "rooms" merged nil nil #'string=)
             (mapcar
              (lambda (room)
                (if (fermium--room-locally-read-p
                     account-id (fermium--event-value room "room_id"))
                    (let ((read-room (copy-tree room)))
                      (setf (alist-get "has_unread" read-room nil nil #'string=)
                            nil)
                      read-room)
                  room))
              (fermium--event-value account "rooms")))
       merged))
   accounts))

(defun fermium--upsert-room-summary (room &optional account-id)
  (let* ((room-id (fermium--event-value room "room_id"))
         (existing (seq-find
                    (lambda (candidate)
                      (equal room-id
                             (fermium--event-value candidate "room_id")))
                    (if account-id
                        (fermium--rooms-for-account account-id)
                      fermium--rooms)))
         (room (fermium--merge-room-summary existing room)))
    (when room-id
      (when (fermium--room-locally-read-p account-id room-id)
        (setf (alist-get "has_unread" room nil nil #'string=) nil))
      (if account-id
          (when-let ((account (fermium--account-record account-id)))
            (setf (alist-get "rooms" account nil nil #'string=)
                  (cons room
                        (cl-remove-if
                         (lambda (existing)
                           (equal room-id
                                  (fermium--event-value existing "room_id")))
                         (fermium--event-value account "rooms"))))
            (when (equal account-id fermium--account)
              (setq fermium--rooms (fermium--event-value account "rooms"))))
        (setq fermium--rooms
              (cons room
                    (cl-remove-if
                     (lambda (existing)
                       (equal room-id (fermium--event-value existing "room_id")))
                     fermium--rooms))))
      (when-let ((buffer (fermium--room-by-id room-id account-id)))
        (with-current-buffer buffer
          (when (derived-mode-p 'fermium-room-mode)
            (let ((title (or (fermium--event-value room "name") room-id)))
              (setq fermium-room--room-title title)
              (fermium-room--rename-buffer title)
              (fermium-room--update-header-title title)))))
      (when-let ((overview (get-buffer fermium--overview-buffer)))
        (with-current-buffer overview
          (fermium--render-overview))))))

(defun fermium--room-summary-by-id (room-id &optional account-id)
  "Return the known room summary for ROOM-ID, if any."
  (seq-find (lambda (room)
              (equal room-id (fermium--event-value room "room_id")))
            (if account-id
                (fermium--rooms-for-account account-id)
              fermium--rooms)))

(defun fermium-room--rename-buffer (title)
  "Rename the current room buffer to TITLE when its account is known."
  (when fermium-room--account-id
    (let ((name (fermium--room-buffer-name fermium-room--room-id
                                           fermium-room--account-id
                                           title)))
      (unless (equal name (buffer-name))
        (rename-buffer name t)))))

(defun fermium-room--header-line-text ()
  "Return the textual form of the fixed room header."
  (let* ((marker (if fermium-room--header-expanded "▾" "▸"))
         (title (or fermium-room--room-title ""))
         (line (concat marker " " title))
         (marker-end (length marker))
         (title-start (+ marker-end 1))
         (title-end (length line))
         details-start
         details-end
         account-label-start
         account-label-end
         account-value-start
         account-value-end
         matrix-label-start
         matrix-label-end
         matrix-value-start
         matrix-value-end
         loading-start
         loading-end)
    (when fermium-room--header-expanded
      (setq details-start (length line))
      (when fermium-room--account-id
        (setq line (concat line "\n  Account: " fermium-room--account-id)
              account-label-start (+ details-start 3)
              account-label-end (+ account-label-start (length "Account:"))
              account-value-start (+ account-label-end 1)
              account-value-end (length line)))
      (when fermium-room--room-id
        (let ((prefix-start (length line)))
          (setq line (concat line "\n  Matrix ID: " fermium-room--room-id)
                matrix-label-start (+ prefix-start 3)
                matrix-label-end (+ matrix-label-start (length "Matrix ID:"))
                matrix-value-start (+ matrix-label-end 1)
                matrix-value-end (length line))))
      (setq details-end (length line)))
    (when fermium-room--loading
      (setq loading-start (length line)
            line (concat line "\n  Loading history" (fermium--loading-dots))
            loading-end (length line)))
    (add-text-properties marker-end title-start
                         '(fermium-room-header-marker t)
                         line)
    (add-text-properties title-start title-end
                         '(fermium-room-header-title t)
                         line)
    (fermium-room--add-face-properties-to-string
     marker-end title-start 'fermium-room-header-marker-face line)
    (fermium-room--add-face-properties-to-string
     title-start title-end 'fermium-room-title-face line)
    (when (and details-start details-end)
      (add-text-properties details-start details-end
                           '(fermium-room-header-details t)
                           line)
      (when (and account-label-start account-label-end)
        (fermium-room--add-face-properties-to-string
         account-label-start account-label-end
         'fermium-room-header-label-face line))
      (when (and account-value-start account-value-end)
        (fermium-room--add-face-properties-to-string
         account-value-start account-value-end
         'fermium-room-sender-self-face line))
      (when (and matrix-label-start matrix-label-end)
        (fermium-room--add-face-properties-to-string
         matrix-label-start matrix-label-end
         'fermium-room-header-label-face line))
      (when (and matrix-value-start matrix-value-end)
        (fermium-room--add-face-properties-to-string
         matrix-value-start matrix-value-end
         'fermium-room-header-other-face line)))
    (when (and loading-start loading-end)
      (fermium-room--add-face-properties-to-string
       loading-start loading-end 'fermium-room-timestamp-face line))
    line))

(defun fermium-room--header-svg-face-color (face)
  "Return the effective foreground color for FACE as an SVG color."
  (let ((color (face-attribute face :foreground nil t)))
    (if (and (stringp color)
             (not (string-empty-p color))
             (not (member color '("unspecified" "unspecified-fg"
                                  "unspecified-bg"))))
        color
      (let ((default-color (face-attribute 'default :foreground nil t)))
        (if (and (stringp default-color)
                 (not (member default-color '("unspecified"
                                              "unspecified-fg"
                                              "unspecified-bg"))))
            default-color
          "black")))))

(defun fermium-room--header-svg-image (text window)
  "Return a multi-line SVG image for TEXT in WINDOW, when supported."
  (when (and (window-live-p window)
             (display-graphic-p (window-frame window))
             (image-type-available-p 'svg)
             (require 'svg nil t))
    (let* ((lines (split-string (substring-no-properties text) "\n"))
           (width (max 1 (window-pixel-width window)))
           (frame (window-frame window))
           (line-height (max 1 (frame-char-height frame)))
           (font (face-attribute 'default :font nil t))
           (font-size (or (and (fontp font) (font-get font :size))
                          line-height))
           (font-family (let ((family (face-attribute 'default :family nil t)))
                          (if (and (stringp family)
                                   (not (string-empty-p family))
                                   (not (equal family "unspecified")))
                              family
                            "sans-serif")))
           (height (* line-height (max 1 (length lines))))
           (cache-key (list text width line-height font-size font-family
                            (frame-parameter frame 'background-mode)))
           (svg (or (and (equal cache-key fermium-room--header-image-cache-key)
                         fermium-room--header-image-cache)
                    (let ((image (svg-create width height)))
                      (cl-loop for line in lines
                               for row from 0
                               for face = (cond
                                           ((zerop row)
                                            'fermium-room-title-face)
                                           ((string-match-p "Loading history" line)
                                            'fermium-room-timestamp-face)
                                           (t 'default))
                               do (svg-text
                                   image line
                                   :x 6
                                   :y (+ (* row line-height) font-size)
                                   :font-size font-size
                                   :font-family font-family
                                   :font-weight
                                   (if (eq (face-attribute face :weight nil t)
                                           'bold)
                                       "bold" "normal")
                                   :font-style
                                   (if (eq (face-attribute face :slant nil t)
                                           'italic)
                                       "italic" "normal")
                                   :fill (fermium-room--header-svg-face-color face)))
                      (setq fermium-room--header-image-cache-key cache-key)
                      (with-temp-buffer
                        (svg-insert-image image)
                        (setq fermium-room--header-image-cache
                              (buffer-string)))))))
      svg)))

(defun fermium-room--decorate-header-string (header)
  "Add the common interaction properties to HEADER."
  (add-text-properties
   0 (length header)
   (list 'read-only t
         'local-map fermium-room--header-map
         'fermium-room-header t
         'mouse-face 'highlight
         'follow-link t
         'help-echo "Click or TAB to expand or fold room header")
   header)
  header)

(defun fermium-room--header-line ()
  "Return the fixed room header, using a graphical multi-line image when able."
  (let* ((text (fermium-room--header-line-text))
         (window (get-buffer-window (current-buffer) t))
         (image (fermium-room--header-svg-image text window)))
    (fermium-room--decorate-header-string (or image text))))

(defun fermium-room--update-header-title (title)
  "Update the fixed room header title to TITLE."
  (setq fermium-room--room-title title)
  (force-mode-line-update t))

(defun fermium-room--render-header (title)
  "Reset rendered room content and update its fixed header."
  (setq fermium-room--room-title title)
  (when (and (overlayp fermium-room--composition-overlay)
             (overlay-buffer fermium-room--composition-overlay))
    (delete-overlay fermium-room--composition-overlay))
  (setq fermium-room--composition-overlay nil)
  (setq fermium-room--ewoc nil)
  (setq fermium-room--input-start nil)
  (setq fermium-room--nodes (make-hash-table :test #'equal))
  (let ((inhibit-read-only t))
    (erase-buffer))
  (force-mode-line-update t))

(defun fermium-room-toggle-header ()
  "Collapse or expand the room header's account and Matrix ID details."
  (interactive)
  (if (not (derived-mode-p 'fermium-room-mode))
      (message "Fermium: no room header here")
    (setq fermium-room--header-expanded
          (not fermium-room--header-expanded))
    (force-mode-line-update t)))

(defun fermium-room-toggle-header-or-channel-events ()
  "Toggle the header at point, or the channel events section at point."
  (interactive)
  (if (or (get-text-property (point) 'fermium-room-header)
          (get-text-property (max (point-min) (1- (point)))
                             'fermium-room-header))
      (fermium-room-toggle-header)
    (if (fermium-room--channel-events-id-at-point)
        (fermium-room-toggle-channel-events)
      (fermium-room-toggle-header))))

(defun fermium-room--render-loading-indicator ()
  "Render the animated history-loading indicator in the room header."
  (force-mode-line-update t))

(defun fermium-room--clear-loading-indicator ()
  "Remove the history-loading indicator from the room header."
  (force-mode-line-update t))

(defun fermium-room--finish-loading ()
  "Finish or cancel the current room history load."
  (setq fermium-room--loading nil)
  (setq fermium-room--pending-messages nil)
  (setq fermium-room--seed-message nil)
  (fermium-room--clear-loading-indicator)
  (force-mode-line-update t))

(defun fermium-room--render-loading-room (title latest-message)
  "Render TITLE and the known LATEST-MESSAGE while history loads."
  (setq fermium-room--room-title title)
  (fermium-room--rename-buffer title)
  (let ((inhibit-read-only t))
    (fermium-room--render-header title)
    (fermium-room--build-history (and latest-message (list latest-message)))
    (fermium-room--render-composition nil))
  (setq fermium-room--seed-message latest-message)
  (force-mode-line-update t))

(defun fermium-room--render-room (room messages)
  (let ((pending-messages fermium-room--pending-messages)
        (seed-message fermium-room--seed-message)
        (draft (and fermium-room--input-start
                    (buffer-substring-no-properties
                     fermium-room--input-start (point-max)))))
    (setq fermium-room--loading nil)
    (when-let ((room-id (fermium--event-value room "room_id")))
      (setq fermium-room--room-id room-id))
    (setq fermium-room--room-title
          (or (fermium--event-value room "name")
              (fermium--event-value room "room_id")))
    (fermium-room--rename-buffer fermium-room--room-title)
    (setq fermium-room--seed-message nil)
    (setq fermium-room--pending-messages nil)
    (fermium-room--render-history
     (append messages
             (when seed-message (list seed-message))
             (nreverse pending-messages))
     draft)
    (force-mode-line-update t)
    (fermium--stop-loading-animation-if-idle)))

(defun fermium-room--point-in-composition-p ()
  "Return non-nil when point is inside the room's writable composition."
  (and fermium-room--input-start
       (>= (point) (marker-position fermium-room--input-start))))

(defun fermium-room--pin-window-to-bottom (window)
  "Pin WINDOW displaying the current room buffer to its last line."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer)))
    ;; `recenter' understands visual lines, wrapping, images, and the
    ;; window's actual height.  Temporarily selecting WINDOW also makes this
    ;; work for an inactive room window; setting a character-based start
    ;; calculated with `vertical-motion' can otherwise be only approximate.
    ;; Suppress selection hooks while doing that temporary selection: an
    ;; inactive room must not be treated as newly selected or marked read.
    (let ((window-selection-change-functions nil))
      (with-selected-window window
        (goto-char (point-max))
        (recenter -1)))))

(defun fermium-room--repin-composition-windows ()
  "Pin every window showing this room back to the composition tail.
Unlike a full re-render, a bounded history edit leaves the composition and
the user's point inside it intact, so point is restored afterwards."
  (save-excursion
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (fermium-room--pin-window-to-bottom window))))

(defun fermium-room--render-history (messages &optional draft)
  "Render MESSAGES as this room's history, preserving DRAFT in the composition."
  (fermium-room--edit-history
   (lambda ()
     (fermium-room--render-header fermium-room--room-title)
     (fermium-room--build-history messages)
     (fermium-room--render-composition draft))))

;;; What `ewoc.el' does not expose, kept here rather than spread about.

(defun fermium-ewoc--end (ewoc)
  "Return the end of EWOC's content."
  (marker-position (ewoc-location (ewoc--footer ewoc))))

(defun fermium-ewoc--delete (ewoc node)
  "Delete NODE from EWOC, whose text may be read-only.
Alone among the ewoc mutators, `ewoc-delete' does not allow for that."
  (let ((inhibit-read-only t))
    (ewoc-delete ewoc node)))

;;; The history ewoc.  The composition sits below its footer, and so
;;; outside it, which is what keeps a node change away from the input.

(defun fermium-room--group-messages (messages)
  "Split MESSAGES into the units the history renders, in order.
Consecutive channel events fold into a single section, so they render as
one unit; every other message renders on its own."
  (let ((groups nil)
        (run nil))
    (dolist (message messages)
      (if (fermium-room--channel-event-p message)
          (push message run)
        (when run
          (push (nreverse run) groups)
          (setq run nil))
        (push (list message) groups)))
    (when run (push (nreverse run) groups))
    (nreverse groups)))

(defun fermium-room--insert-group (messages)
  "Insert MESSAGES as one rendered unit of the history.
This is the history ewoc's pretty-printer."
  (if (fermium-room--channel-event-p (car messages))
      (fermium-room--insert-channel-events messages)
    (fermium-room--insert-message (car messages))))

(defun fermium-room--build-history (messages)
  "Create the history ewoc at point holding MESSAGES."
  (setq fermium-room--nodes (make-hash-table :test #'equal))
  ;; No separator: the pretty-printer emits its own newlines.
  (setq fermium-room--ewoc
        (ewoc-create #'fermium-room--insert-group nil nil t))
  (dolist (group (fermium-room--group-messages
                  (fermium-room--merge-messages messages)))
    (fermium-room--enter-group nil group))
  (goto-char (point-max)))

(defun fermium-room--history-end ()
  "Return the end of the rendered history."
  (if fermium-room--ewoc
      (fermium-ewoc--end fermium-room--ewoc)
    (point-max)))

(defun fermium-room--history-messages ()
  "Return the messages in this room's history, in order."
  (when fermium-room--ewoc
    (mapcan #'copy-sequence
            (ewoc-collect fermium-room--ewoc #'identity))))

(defun fermium-room--latest-message ()
  "Return the last message in this room's history."
  (when-let ((node (and fermium-room--ewoc
                        (ewoc-nth fermium-room--ewoc -1))))
    (car (last (ewoc-data node)))))

(defun fermium-room--node-channel-p (node)
  "Return non-nil when NODE renders a folded run of channel events."
  (fermium-room--channel-event-p (car (ewoc-data node))))

(defun fermium-room--node-first-time (node)
  "Return the time of the first message NODE renders."
  (fermium-room--message-timestamp (car (ewoc-data node))))

(defun fermium-room--node-last-time (node)
  "Return the time of the last message NODE renders."
  (fermium-room--message-timestamp (car (last (ewoc-data node)))))

(defun fermium-room--node-end (node)
  "Return the end of NODE's rendered text."
  (if-let ((next (ewoc-next fermium-room--ewoc node)))
      (marker-position (ewoc-location next))
    (fermium-room--history-end)))

(defun fermium-room--node-for-key (key)
  "Return the node rendering the message KEY, if it is shown."
  (and fermium-room--nodes (gethash key fermium-room--nodes)))

(defun fermium-room--node-message (node key)
  "Return the message KEY names among those NODE renders."
  (seq-find (lambda (message)
              (equal key (fermium-room--message-key message)))
            (ewoc-data node)))

;; The three below are the only writers of `fermium-room--nodes', so the
;; index cannot drift from what is on screen.

(defun fermium-room--enter-group (before messages)
  "Render MESSAGES as a new node before BEFORE, or last when BEFORE is nil."
  (let ((node (if before
                  (ewoc-enter-before fermium-room--ewoc before messages)
                (ewoc-enter-last fermium-room--ewoc messages))))
    (dolist (message messages)
      (puthash (fermium-room--message-key message) node fermium-room--nodes))
    node))

(defun fermium-room--delete-node (node)
  "Take NODE out of the history."
  (dolist (message (ewoc-data node))
    (remhash (fermium-room--message-key message) fermium-room--nodes))
  (fermium-ewoc--delete fermium-room--ewoc node))

(defun fermium-room--set-node-messages (node messages)
  "Make NODE render MESSAGES instead of what it renders now."
  (dolist (message (ewoc-data node))
    (remhash (fermium-room--message-key message) fermium-room--nodes))
  (setf (ewoc-data node) messages)
  (dolist (message messages)
    (puthash (fermium-room--message-key message) node fermium-room--nodes))
  (ewoc-invalidate fermium-room--ewoc node))

(defun fermium-room--message-region (key)
  "Return the rendered region of the message KEY as a cons of start and end.
Return nil when KEY is not rendered.  A folded section holds several events
under one node, so the search runs inside that node alone."
  (when-let ((node (fermium-room--node-for-key key)))
    (let ((limit (fermium-room--node-end node))
          (position (marker-position (ewoc-location node))))
      (while (and (< position limit)
                  (not (equal key (get-text-property
                                   position 'fermium-room-message-key))))
        (setq position (next-single-property-change
                        position 'fermium-room-message-key nil limit)))
      (when (< position limit)
        (cons position
              (next-single-property-change
               position 'fermium-room-message-key nil limit))))))

(defun fermium-room--message-position (key)
  "Return the start of the rendered message identified by KEY."
  (car (fermium-room--message-region key)))

(defun fermium-room--point-anchor ()
  "Return what point is reading in the history, or nil when it reads nothing.
The value is the key of what point is on, the offset into that key's text,
and whether the key names a folded section rather than a message.  Text
rewritten under point can end up a different length, or a different message
altogether, so a reader's place is held by what they are reading."
  (if-let* ((key (fermium-room--message-key-at-point))
            (region (fermium-room--message-region key)))
      (list key (- (point) (car region)) nil)
    ;; A section's heading carries no message key.  The section is named by
    ;; its first event, and that key does name the node.
    (when-let* ((id (fermium-room--channel-events-id-at-point))
                (node (fermium-room--node-for-key id)))
      (list id (- (point) (marker-position (ewoc-location node))) t))))

(defun fermium-room--anchor-at (position)
  "Return an anchor for what POSITION reads in the history.
Somewhere that reads nothing -- the header, a separator -- anchors on the
position itself, which is the best a rebuilt room can offer it."
  (save-excursion
    (goto-char position)
    (or (fermium-room--point-anchor) position)))

(defun fermium-room--anchor-position (anchor)
  "Return where ANCHOR reads now, or nil when its text is no longer shown."
  (if (numberp anchor)
      (min anchor (point-max))
    (let* ((key (nth 0 anchor))
           (node (fermium-room--node-for-key key))
           (region (cond
                    ((null node) nil)
                    ((nth 2 anchor)
                     (cons (marker-position (ewoc-location node))
                           (fermium-room--node-end node)))
                    (t (fermium-room--message-region key)))))
      (when region
        (min (+ (car region) (nth 1 anchor)) (cdr region))))))

(defun fermium-room--goto-anchor (anchor)
  "Put point back where ANCHOR was reading, when that text is still shown."
  (when-let ((position (fermium-room--anchor-position anchor)))
    (goto-char position)
    t))

(defun fermium-room--window-anchors ()
  "Return anchors for the scroll and point of each window showing this room.
The selected window shares the buffer's point, which is anchored on its
own, so only the other windows need their point remembered."
  (mapcar (lambda (window)
            (list window
                  (fermium-room--anchor-at (window-start window))
                  (unless (eq window (selected-window))
                    (fermium-room--anchor-at (window-point window)))))
          (get-buffer-window-list (current-buffer) nil t)))

(defun fermium-room--restore-window-anchors (anchors)
  "Put each window back on the text its ANCHORS name."
  (pcase-dolist (`(,window ,start ,held-point) anchors)
    (when (and (window-live-p window)
               (eq (window-buffer window) (current-buffer)))
      (when-let* ((position (and held-point
                                 (fermium-room--anchor-position held-point))))
        (unless (= position (window-point window))
          (set-window-point window position)))
      (when-let ((position (fermium-room--anchor-position start)))
        (unless (= position (window-start window))
          (set-window-start window position))))))

(defun fermium-room--edit-history (edit)
  "Call EDIT, which changes the rendered history, and keep the room usable.

Emacs carries markers, point and window starts along with the text after a
bounded edit, but collapses whatever sat inside the text it replaced.  So a
reader is held by what they are reading rather than by a position, whether
that reader is point or a window."
  (let* ((in-composition (fermium-room--point-in-composition-p))
         (anchor (unless in-composition (fermium-room--anchor-at (point))))
         (windows (unless in-composition (fermium-room--window-anchors)))
         (inhibit-read-only t)
         ;; The composition overlay is re-established by whoever renders the
         ;; composition; a history edit never reaches it.
         (inhibit-modification-hooks t)
         ;; Rendering installs image display properties.  Those are derived
         ;; UI state, not edits the user should have to undo.
         (buffer-undo-list t))
    ;; Keep the user's logical point zone independent of any window Emacs may
    ;; later choose while restoring a tab, exactly as a full render does.
    (setq fermium-room--last-point-in-composition in-composition)
    (prog1 (funcall edit)
      (fermium-room--protect-first-character)
      (when anchor (fermium-room--goto-anchor anchor))
      (if in-composition
          ;; Growing the history above a composition would otherwise push it
          ;; off the bottom of the window.
          (fermium-room--repin-composition-windows)
        (fermium-room--restore-window-anchors windows)))))

(defun fermium-room--node-ends-after-p (node timestamp)
  "Return non-nil when NODE renders a message later than TIMESTAMP."
  (> (fermium-room--node-last-time node) timestamp))

(defun fermium-room--placement-node (timestamp)
  "Return the first node of the history that ends after TIMESTAMP.
Return nil when every node ends at or before it.

The search starts from whichever end TIMESTAMP lies nearer: messages arrive
at the newest end and history pages in at the oldest, so neither may cost a
walk over everything in between."
  (let ((first (ewoc-nth fermium-room--ewoc 0))
        (last (ewoc-nth fermium-room--ewoc -1)))
    (when first
      (if (< (- timestamp (fermium-room--node-first-time first))
             (- (fermium-room--node-last-time last) timestamp))
          (let ((node first))
            (while (and node
                        (not (fermium-room--node-ends-after-p node timestamp)))
              (setq node (ewoc-next fermium-room--ewoc node)))
            node)
        (let ((node last)
              (found nil))
          (while (and node (fermium-room--node-ends-after-p node timestamp))
            (setq found node)
            (setq node (ewoc-prev fermium-room--ewoc node)))
          found)))))

(defun fermium-room--placement (timestamp)
  "Return where a message timed TIMESTAMP belongs, as a node and an index.
The index is how many of that node's messages precede it; a nil node means
after the whole history.  Messages sharing a timestamp keep arrival order,
newest last.  This is the one place the order of the history is decided."
  (let ((node (fermium-room--placement-node timestamp)))
    (cons node
          (if (or (null node)
                  (> (fermium-room--node-first-time node) timestamp))
              0
            ;; The message lands inside a folded run, which it splits in two.
            (seq-count
             (lambda (message)
               (<= (fermium-room--message-timestamp message) timestamp))
             (ewoc-data node))))))

(defun fermium-room--regroups-p (message node index previous)
  "Return non-nil when MESSAGE changes the grouping of the nodes around it.
NODE and INDEX are its placement and PREVIOUS is the node before NODE.  A
channel event joins whichever run it lands against; an ordinary message
disturbs a run only by landing inside it, which splits it in two."
  (if (fermium-room--channel-event-p message)
      (or (and previous (fermium-room--node-channel-p previous))
          (and node (fermium-room--node-channel-p node)))
    (> index 0)))

(defun fermium-room--place-message (message)
  "Render MESSAGE in this room's history, in order."
  (let* ((placement (fermium-room--placement
                     (fermium-room--message-timestamp message)))
         (node (car placement))
         (index (cdr placement))
         (previous (if node
                       (ewoc-prev fermium-room--ewoc node)
                     (ewoc-nth fermium-room--ewoc -1))))
    (if (not (fermium-room--regroups-p message node index previous))
        (fermium-room--enter-group node (list message))
      ;; Rather than decide whether MESSAGE joins a run or splits one, splice
      ;; it into the nodes it touches and group those again as a render from
      ;; scratch would.
      (let* ((join-previous (and previous
                                 (= index 0)
                                 (fermium-room--node-channel-p previous)))
             (data (and node (ewoc-data node)))
             (messages (append (and join-previous (ewoc-data previous))
                               (seq-take data index)
                               (list message)
                               (seq-drop data index)))
             (after (and node (ewoc-next fermium-room--ewoc node))))
        (when join-previous (fermium-room--delete-node previous))
        (when node (fermium-room--delete-node node))
        (dolist (group (fermium-room--group-messages messages))
          (fermium-room--enter-group after group))))))

(defun fermium-room--unplace-message (key)
  "Take the message KEY out of the rendered history.
That makes its neighbours adjacent, so channel-event runs either side of it
become one section and are rendered again as one."
  (when-let ((node (fermium-room--node-for-key key)))
    (let ((rest (seq-remove
                 (lambda (message)
                   (equal key (fermium-room--message-key message)))
                 (ewoc-data node))))
      (if rest
          ;; KEY was one of a folded run, which simply loses it.
          (fermium-room--set-node-messages node rest)
        (let ((previous (ewoc-prev fermium-room--ewoc node))
              (next (ewoc-next fermium-room--ewoc node)))
          (if (not (and previous next
                        (fermium-room--node-channel-p previous)
                        (fermium-room--node-channel-p next)))
              (fermium-room--delete-node node)
            (let ((messages (append (ewoc-data previous) (ewoc-data next)))
                  (after (ewoc-next fermium-room--ewoc next)))
              (fermium-room--delete-node previous)
              (fermium-room--delete-node node)
              (fermium-room--delete-node next)
              (dolist (group (fermium-room--group-messages messages))
                (fermium-room--enter-group after group)))))))
    t))

(defun fermium-room--message-visible-in-window-p (key window)
  "Return non-nil when the end of message KEY is visible in WINDOW."
  (when-let ((region (fermium-room--message-region key)))
    (and (<= (window-start window) (car region))
         (<= (1- (cdr region)) (window-end window t)))))

(defun fermium-room--selected-focused-window ()
  "Return the selected, focused window when it displays this room buffer."
  (let ((window (selected-window)))
    (when (and (window-live-p window)
               (eq (window-frame window) (selected-frame))
               (eq (window-buffer window) (current-buffer))
               (eq (frame-focus-state (window-frame window)) t))
      window)))

(defun fermium-room--latest-message-visible-p (key)
  "Return non-nil when the rendered latest message KEY is on screen."
  (when-let ((window (fermium-room--selected-focused-window)))
    (fermium-room--message-visible-in-window-p key window)))

(defun fermium-room--maybe-mark-latest-message-read ()
  "Mark the latest visible room message as read, if it has not been marked."
  (when (and (derived-mode-p 'fermium-room-mode)
             (not fermium-room--loading)
             fermium-room--account-id
             fermium-room--room-id)
    (let* ((message (fermium-room--latest-message))
           (event-id (and message
                          (fermium--event-value message "event_id")))
           (buffer (current-buffer)))
      (when (and event-id
                 (not (equal event-id fermium-room--read-message-key))
                 (fermium-room--latest-message-visible-p event-id))
        (setq fermium-room--read-message-key event-id)
        (condition-case error
            (fermium--send
             "mark_room_read"
             (list (cons "account" fermium-room--account-id)
                   (cons "room_id" fermium-room--room-id)
                   (cons "event_id" event-id))
             (lambda (event)
               (when (and (equal (fermium--event-value event "type") "error")
                          (buffer-live-p buffer))
                 (with-current-buffer buffer
                   (when (equal fermium-room--read-message-key event-id)
                     (setq fermium-room--read-message-key nil))))))
          (error
           (setq fermium-room--read-message-key nil)
           (message "Fermium: could not mark room as read: %s"
                    (error-message-string error))))))))

(defun fermium-room--window-selection-changed (window)
  "Retry marking the latest message when WINDOW is selected or deselected."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer)))
    (fermium-room--remember-point-position)
    (fermium-room--maybe-mark-latest-message-read)))

(defun fermium-room--window-scrolled (window _start)
  "Retry marking the latest message after WINDOW has been scrolled."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer)))
    (fermium-room--maybe-mark-latest-message-read)))

(defun fermium--after-focus-change ()
  "Retry marking a room when the selected Emacs frame gains focus."
  (let ((window (selected-window)))
    (when (and (window-live-p window)
               (buffer-live-p (window-buffer window)))
      (with-current-buffer (window-buffer window)
        (when (derived-mode-p 'fermium-room-mode)
          (fermium-room--maybe-mark-latest-message-read))))))

(unless fermium--focus-change-hook-installed
  ;; `focus-in-hook' is obsolete in recent Emacsen.  The replacement is a
  ;; function variable, so install a single global observer and let the room
  ;; predicate decide whether the selected window is eligible.
  (add-function :after after-focus-change-function
                #'fermium--after-focus-change)
  (setq fermium--focus-change-hook-installed t))

(defun fermium-room--remember-point-position ()
  "Remember whether the room's latest logical point was in composition."
  (when (derived-mode-p 'fermium-room-mode)
    (setq fermium-room--last-point-in-composition
          (fermium-room--point-in-composition-p))))

(defun fermium-room--tab-post-select (&rest _tabs)
  "Pin visible room windows after restoring an Emacs tab."
  (dolist (window (window-list nil 'nomini))
    (let ((buffer (window-buffer window)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (and (derived-mode-p 'fermium-room-mode)
                     fermium-room--last-point-in-composition)
            (fermium-room--pin-window-to-bottom window)))))))

(with-eval-after-load 'tab-bar
  (add-hook 'tab-bar-tab-post-select-functions
            #'fermium-room--tab-post-select))

(defun fermium-room--message-key-at-point ()
  "Return the message key at point, if point is in a rendered message."
  (or (get-text-property (point) 'fermium-room-message-key)
      (get-text-property (max (point-min) (1- (point)))
                         'fermium-room-message-key)))

(defun fermium-room--render-composition (draft)
  "Render the writable composition tail, preserving DRAFT when supplied.
The composition is inserted after the history ewoc's footer, so it lies
outside the ewoc and no node change can reach it."
  (fermium-room--insert-read-only "\n")
  (let ((start (point)))
    (fermium-room--insert-read-only
     "Composition  C-c C-c to send, C-c C-k to clear\n")
    (fermium-room--add-face-properties
     start (point) 'fermium-room-composition-header-face))
  (add-text-properties
   (1- (point)) (point)
   '(rear-nonsticky (read-only keymap face)))
  (setq fermium-room--input-start (copy-marker (point)))
  (when draft
    (insert draft))
  (fermium-room--ensure-composition-overlay)
  ;; A message event can cause the history to be rendered again before the
  ;; matching message-sent event arrives.  Preserve the in-flight state on
  ;; the newly rendered composition in that interval.
  (fermium-room--set-input-read-only fermium-room--sending)
  (fermium-room--protect-first-character)
  (goto-char (point-max)))

(defun fermium-room--protect-first-character ()
  "Keep the room's first history character from accepting insertions.
A `read-only' text property does not protect insertion immediately before
the first character carrying it, so make that character front-sticky.  Any
edit that can replace the first character has to reapply this."
  (when (< (point-min) (point-max))
    (let ((inhibit-read-only t))
      (add-text-properties
       (point-min) (1+ (point-min))
       '(front-sticky (read-only keymap))))))

(defun fermium-room--insert-read-only (text)
  "Insert TEXT into the room's read-only history zone."
  (let ((start (point)))
    (insert text)
    (add-text-properties
     start (point)
     `(read-only t
       keymap ,fermium-room--read-only-map))))

(defun fermium-room--ensure-composition-overlay ()
  (when fermium-room--input-start
    (unless (and (overlayp fermium-room--composition-overlay)
                 (overlay-buffer fermium-room--composition-overlay))
      (setq fermium-room--composition-overlay
            (make-overlay fermium-room--input-start (point-max)
                          (current-buffer) nil t)))
    (overlay-put fermium-room--composition-overlay
                 'face (if fermium-room--sending
                           'fermium-room-composition-sending-face
                         'fermium-room-composition-face))
    (overlay-put fermium-room--composition-overlay
                 'keymap fermium-room-mode-map)
    (move-overlay fermium-room--composition-overlay
                  fermium-room--input-start (point-max))))

(defun fermium-room--composition-after-change (&rest _)
  (fermium-room--ensure-composition-overlay))

(defun fermium-room--redirect-self-insert (count)
  "Insert typed text at the end of the room composition.

This is used by the read-only area's keymap, so typing while point is in
history moves point to the writable composition instead of attempting to
modify history."
  (interactive "p")
  (when fermium-room--input-start
    (goto-char (point-max))
    (self-insert-command count)))

(defun fermium-room--add-face-properties (start end face)
  "Apply FACE to the room text between START and END.

Keep both face properties: `face' is used when Font Lock is disabled, while
`font-lock-face' prevents Font Lock from removing the styling in a room
buffer, which derives from `text-mode'."
  (add-text-properties start end (list 'face face 'font-lock-face face)))

(defun fermium-room--add-face-properties-to-string (start end face string)
  "Apply FACE to STRING between START and END.

This is the string counterpart to `fermium-room--add-face-properties', used
for the text returned by the fixed room header's mode-line formatter."
  (add-text-properties start end (list 'face face 'font-lock-face face)
                       string))

(defun fermium-room--message-sender-id (message)
  "Return the canonical sender ID for MESSAGE."
  (fermium--event-value message "sender"))

(defun fermium-room--message-sender-role (message)
  "Return MESSAGE's sender role relative to the current room buffer."
  (if (and fermium-room--account-id
           (equal (fermium-room--message-sender-id message)
                  fermium-room--account-id))
      'self
    'other))

(defun fermium-room--message-sender-label (message)
  "Return the display label for MESSAGE's sender."
  (if (eq (fermium-room--message-sender-role message) 'self)
      "me"
    (or (let ((display-name (fermium--event-value message
                                                  "sender_display_name")))
          (and (stringp display-name)
               (not (string-empty-p display-name))
               display-name))
        (let ((sender-id (fermium-room--message-sender-id message)))
          (and (stringp sender-id)
               (not (string-empty-p sender-id))
               sender-id))
        fermium-room-unknown-user-label)))

(defun fermium-room--message-sender-color-face (message)
  "Return the stable palette face for MESSAGE's other sender."
  (let ((sender-id (fermium-room--message-sender-id message)))
    (when (and fermium-room--account-id
               sender-id
               (eq (fermium-room--message-sender-role message) 'other)
               fermium-room-sender-color-faces)
      (nth (mod (string-to-number (substring (md5 sender-id) 0 8) 16)
                (length fermium-room-sender-color-faces))
           fermium-room-sender-color-faces))))

(defun fermium-room--message-sender-face (message)
  "Return the face for MESSAGE's sender role."
  (if (eq (fermium-room--message-sender-role message) 'self)
      'fermium-room-sender-self-face
    (let ((color-face (fermium-room--message-sender-color-face message)))
      (if color-face
          (list color-face 'fermium-room-sender-face)
        'fermium-room-sender-face))))

(defun fermium-room--message-key (message)
  (or (fermium--event-value message "event_id")
      (list (fermium--event-value message "sender")
            (fermium--event-value message "body")
            (fermium--event-value message "timestamp"))))

(defun fermium-room--image-loading-p ()
  "Return non-nil when an image in the current room is being fetched."
  (let ((loading nil))
    (when (hash-table-p fermium-room--image-states)
      (maphash
       (lambda (_key state)
         (when (eq (plist-get state :status) 'loading)
           (setq loading t)))
       fermium-room--image-states))
    loading))

(defun fermium-room--image-loading-dots ()
  "Return a non-empty loading indicator for an image."
  (let ((dots (fermium--loading-dots)))
    (if (string-empty-p dots) "." dots)))

(defun fermium-room--image-key-at-point ()
  (or (get-text-property (point) 'fermium-room-image-key)
      (get-text-property (max (point-min) (1- (point)))
                         'fermium-room-image-key)))

(defun fermium-room--image-source-at-point ()
  (or (get-text-property (point) 'fermium-room-image-source)
      (get-text-property (max (point-min) (1- (point)))
                         'fermium-room-image-source)))

(defun fermium-room--flush-image (image)
  "Remove IMAGE from Emacs's native image cache when it is a descriptor."
  (when (and (fboundp 'image-flush)
             (consp image)
             (eq (car image) 'image))
    ;; `image-flush' is important for temporary, data-backed images.  Without
    ;; it, every resize leaves another native image in the cache until the
    ;; global eviction timer runs, even though the descriptor is no longer in
    ;; the buffer.
    (image-flush image)))

(defun fermium-room--flush-image-states ()
  "Flush all image descriptors retained by the current room state."
  (when (hash-table-p fermium-room--image-states)
    (maphash
     (lambda (_key state)
       (fermium-room--flush-image (plist-get state :image)))
     fermium-room--image-states)))

(defun fermium-room--image-fit-size (&optional window)
  "Return the pixel bounds for fitting an image in WINDOW.

When WINDOW is nil, use the first window displaying the current buffer.  A
nil result means that the buffer is not currently displayed in a live window.
The returned value is a cons cell of maximum width and maximum height, based
on the inside edges of WINDOW."
  (let ((window (or window (get-buffer-window (current-buffer) t))))
    (when (window-live-p window)
      (let ((edges (window-inside-pixel-edges window)))
        (when (and (numberp (nth 0 edges))
                   (numberp (nth 1 edges))
                   (numberp (nth 2 edges))
                   (numberp (nth 3 edges)))
          (let ((width (- (nth 2 edges) (nth 0 edges)))
                (height (- (nth 3 edges) (nth 1 edges))))
            (when (and (> width 0) (> height 0))
              (cons width height))))))))

(defun fermium-room--create-image (data type &optional window)
  "Create an image from DATA and TYPE, fitting it in WINDOW when possible."
  (let ((size (fermium-room--image-fit-size window)))
    (apply #'create-image data type t :scale 1
           (if size
               (list :max-width (car size)
                     :max-height (cdr size))
             nil))))

(defun fermium-room--image-fits-size-p (image size)
  "Return non-nil when IMAGE already has the fitting descriptor for SIZE."
  (and (consp image)
       (eq (car image) 'image)
       (equal (plist-get (cdr image) :scale) 1)
       (equal (plist-get (cdr image) :max-width) (car size))
       (equal (plist-get (cdr image) :max-height) (cdr size))))

(defun fermium-room--refresh-image-sizes (window)
  "Refit ready images whose descriptors do not match WINDOW's dimensions."
  (when (and (derived-mode-p 'fermium-room-mode)
             (not fermium-room--resizing-images))
    (let ((size (fermium-room--image-fit-size window)))
      (when size
        (let ((changed-keys nil)
              (old-images nil))
          (maphash
           (lambda (key state)
             (when (and (eq (plist-get state :status) 'ready)
                        (stringp (plist-get state :data))
                        (plist-get state :type))
               (unless (fermium-room--image-fits-size-p
                        (plist-get state :image) size)
                 (let ((old-image (plist-get state :image))
                       (new-image
                        (fermium-room--create-image
                         (plist-get state :data)
                         (plist-get state :type)
                         window)))
                   (push old-image old-images)
                   ;; Match `image-mode': discard any stale native data for
                   ;; the descriptor before putting it into display text.
                   (fermium-room--flush-image new-image)
                   (puthash key (plist-put state :image new-image)
                            fermium-room--image-states))
                 (push key changed-keys))))
           fermium-room--image-states)
          (unwind-protect
              (when changed-keys
                ;; Only the messages carrying a refitted image need new
                ;; display properties; the rest of the history is untouched.
                (let ((fermium-room--resizing-images t))
                  (fermium-room--refresh-messages changed-keys)))
            ;; The old descriptors are no longer installed after the render.
            ;; Flush them now instead of retaining their native backing data
            ;; for `image-cache-eviction-delay' seconds.
            (mapc #'fermium-room--flush-image old-images)))))))

(defun fermium-room--cancel-image-resize-timer ()
  "Cancel a pending room image resize."
  (when (timerp fermium-room--image-resize-timer)
    (cancel-timer fermium-room--image-resize-timer)
    (setq fermium-room--image-resize-timer nil)))

(defun fermium-room--cleanup-images ()
  "Release room image resources when the buffer is being killed."
  (fermium-room--cancel-image-resize-timer)
  (fermium-room--flush-image-states))

(defun fermium-room--refresh-image-sizes-in-buffer (buffer window)
  "Refresh room images in BUFFER for WINDOW after an idle delay."
  (when (and (buffer-live-p buffer)
             (window-live-p window))
    (with-current-buffer buffer
      (setq fermium-room--image-resize-timer nil)
      (condition-case-unless-debug error
          (when (and (derived-mode-p 'fermium-room-mode)
                     (eq (window-buffer window) buffer))
            (fermium-room--refresh-image-sizes window))
        (error
         (fermium--report-elisp-error "image resize timer" error))))))

(defun fermium-room--window-state-changed (window)
  "Refit room images after WINDOW is resized or otherwise changed."
  (when (window-live-p window)
    (let ((buffer (window-buffer window)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (derived-mode-p 'fermium-room-mode)
            (fermium-room--cancel-image-resize-timer)
            (setq fermium-room--image-resize-timer
                  (run-with-idle-timer
                   0 nil #'fermium-room--refresh-image-sizes-in-buffer
                   buffer window))
            (fermium-room--maybe-mark-latest-message-read)))))))

(defun fermium-room--mouse-toggle-channel-events (event)
  "Move to EVENT and toggle the channel-event section there."
  (interactive "e")
  (mouse-set-point event)
  (fermium-room-toggle-channel-events))

(defun fermium-room--mouse-toggle-header (event)
  "Toggle the fixed room header in response to EVENT."
  (interactive "e")
  (ignore event)
  (fermium-room-toggle-header))

(defun fermium-room--mouse-toggle-header-or-yank (event)
  "Toggle the room header on a middle-click, otherwise paste at point.

The fallback preserves Emacs's normal middle-click behavior while ensuring
that a header click cannot fall through to PRIMARY-selection insertion."
  (interactive "e")
  (mouse-set-point event)
  (if (or (get-text-property (point) 'fermium-room-header)
          (get-text-property (max (point-min) (1- (point)))
                             'fermium-room-header))
      (fermium-room-toggle-header)
    (mouse-yank-at-click event)))

(defun fermium-room--mouse-display-image (event)
  "Move to EVENT and start displaying the image there."
  (interactive "e")
  (mouse-set-point event)
  (fermium-room-display-image))

(defun fermium-room--render-loading-images ()
  "Restate the placeholders of images the room is still fetching."
  (let ((keys nil))
    (maphash (lambda (key state)
               (when (eq (plist-get state :status) 'loading)
                 (push key keys)))
             fermium-room--image-states)
    (fermium-room--refresh-messages keys)))

(defun fermium-room--render-image-error (key message)
  (when-let ((state (gethash key fermium-room--image-states)))
    (fermium-room--flush-image (plist-get state :image)))
  (remhash key fermium-room--image-states)
  (fermium-room--refresh-message key)
  (fermium--stop-loading-animation-if-idle)
  (message "Fermium: could not display image: %s" message))

(defun fermium-room--handle-image-download (buffer key event)
  "Handle a downloaded image EVENT for BUFFER and message KEY."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (equal (fermium--event-value event "type") "error")
          (fermium-room--render-image-error
           key (fermium--event-value event "message"))
        (condition-case error
            (let* ((encoded (fermium--event-value event "data"))
                   (data (base64-decode-string encoded))
                   (type (image-type-from-data data))
                   (image (and type (fermium-room--create-image data type))))
              (if (not image)
                  (fermium-room--render-image-error
                   key "Emacs does not support this image format")
                ;; Match `image-mode': discard stale native data before the
                ;; descriptor is installed in display text.
                (fermium-room--flush-image image)
                (when-let ((old-state (gethash key fermium-room--image-states)))
                  (fermium-room--flush-image (plist-get old-state :image)))
                (puthash key
                         (list :status 'ready
                               :data data
                               :type type
                               :image image)
                         fermium-room--image-states)
                (fermium-room--refresh-message key)
                (fermium--stop-loading-animation-if-idle)))
          (error
           (fermium-room--render-image-error
            key (error-message-string error))))))))

(defun fermium-room-display-image ()
  "Fetch and display the image at point in the current room."
  (interactive)
  (let* ((key (fermium-room--image-key-at-point))
         (source (fermium-room--image-source-at-point)))
    (cond
     ((not key) (message "Fermium: no image at point"))
     ((not source) (message "Fermium: image has no media source"))
     ((memq (plist-get (gethash key fermium-room--image-states) :status)
            '(loading ready))
      nil)
     (t
      (let ((buffer (current-buffer)))
        (puthash key (list :status 'loading)
                 fermium-room--image-states)
        (fermium-room--refresh-message key)
        (fermium--start-loading-animation)
        (condition-case error
            (fermium--send
             "download_media"
             (append (when fermium-room--account-id
                       (list (cons "account" fermium-room--account-id)))
                     (list (cons "source" source)))
             (lambda (event)
               (fermium-room--handle-image-download buffer key event)))
          (error
           (fermium-room--render-image-error
            key (error-message-string error)))))))))

(defun fermium-room--message-timestamp (message)
  (let ((timestamp (fermium--event-value message "timestamp")))
    (cond
     ((numberp timestamp) timestamp)
     ((stringp timestamp) (string-to-number timestamp))
     (t 0))))

(defun fermium-room--format-timestamp (timestamp &optional now)
  "Format message TIMESTAMP, omitting the date when it is today.

TIMESTAMP is milliseconds since the Unix epoch.  When supplied, NOW is the
time against which today is determined; it is useful for callers that need a
stable reference time."
  (let* ((time (seconds-to-time (/ timestamp 1000.0)))
         (today (format-time-string "%Y-%m-%d" (or now (current-time)))))
    (format-time-string
     (if (string= (format-time-string "%Y-%m-%d" time) today)
         "%H:%M"
       "%Y-%m-%d %H:%M")
     time)))

(defun fermium-room--sorted-messages (messages)
  (sort (copy-sequence messages)
        (lambda (left right)
          (< (fermium-room--message-timestamp left)
             (fermium-room--message-timestamp right)))))

(defun fermium-room--merge-messages (messages)
  "Sort MESSAGES chronologically and remove duplicate event IDs."
  (let ((seen (make-hash-table :test #'equal))
        merged)
    (dolist (message (fermium-room--sorted-messages messages))
      (let ((key (fermium-room--message-key message)))
        (unless (gethash key seen)
          (puthash key t seen)
          (push message merged))))
    (nreverse merged)))

(defun fermium-room--channel-event-p (message)
  "Return non-nil when MESSAGE is a room state or membership event."
  (equal (fermium--event-value message "kind") "channel_event"))

(defun fermium-room--insert-channel-events (events)
  "Insert a collapsed section containing consecutive channel EVENTS."
  (let* ((first (car events))
         (last (car (last events)))
         (group-id (or (fermium--event-value first "event_id")
                       (fermium-room--message-key first)))
         (expanded (gethash group-id fermium-room--expanded-channel-events))
         (header-start (point))
         (timestamp-start (point)))
    (insert (if expanded "▾" "▸") " "
            (fermium-room--format-timestamp
             (fermium-room--message-timestamp last))
            " Channel events (" (number-to-string (length events)) ")\n")
    (fermium-room--add-face-properties
     timestamp-start (point)
     'fermium-room-channel-events-face)
    (add-text-properties
     header-start (point)
     `(read-only t
       keymap ,fermium-room--channel-events-map
       fermium-room-channel-events-id ,group-id
       fermium-room-channel-events-header t
       mouse-face highlight
       follow-link t
       help-echo "Click or TAB to expand channel events"))
    (let ((body-start (point)))
      (dolist (event events)
        (let ((event-start (point)))
          (insert "  ")
          (fermium-room--insert-message event)
          (add-text-properties
           event-start (point)
           `(read-only t
             keymap ,fermium-room--read-only-map
             fermium-room-channel-events-id ,group-id))))
      (add-text-properties
       body-start (point)
       `(fermium-room-channel-events-id ,group-id
         fermium-room-channel-events-body t))
      (unless expanded
        (add-text-properties body-start (point) '(invisible fermium))))))

(defun fermium-room--channel-events-id-at-point ()
  (or (get-text-property (point) 'fermium-room-channel-events-id)
      (get-text-property (max (point-min) (1- (point)))
                         'fermium-room-channel-events-id)))

(defun fermium-room-toggle-channel-events ()
  "Collapse or expand the channel-event section at point."
  (interactive)
  (let ((group-id (fermium-room--channel-events-id-at-point)))
    (if (not (and group-id (fermium-room--node-for-key group-id)))
        (message "Fermium: no channel-event section at point")
      ;; Heading and body are one node, so the section restates itself from
      ;; the flag alone.
      (puthash group-id
               (not (gethash group-id fermium-room--expanded-channel-events))
               fermium-room--expanded-channel-events)
      (fermium-room--refresh-message group-id))))

(defun fermium-room--insert-message (message)
  (let* ((start (point))
         (timestamp-start (point))
         (sender-start nil)
         (body-start nil)
         (timestamp-value (fermium-room--message-timestamp message))
         (timestamp nil)
         (body-end nil)
         (sender-id (fermium-room--message-sender-id message))
         (sender-role (fermium-room--message-sender-role message))
         (sender-label (fermium-room--message-sender-label message))
         (sender-face (fermium-room--message-sender-face message))
         (image (fermium--event-value message "image"))
         (image-key (and image (fermium-room--message-key message)))
         (image-source (and image
                            (fermium--event-value image "source")))
         (image-state (and image-key
                           (gethash image-key fermium-room--image-states))))
    (setq timestamp
          (fermium-room--format-timestamp timestamp-value))
    (insert timestamp)
    (fermium-room--add-face-properties
     timestamp-start (point) 'fermium-room-timestamp-face)
    (if (fermium-room--channel-event-p message)
        (insert " ")
      (insert " ")
      (setq sender-start (point))
      (insert sender-label)
      (fermium-room--add-face-properties sender-start (point) sender-face)
      (add-text-properties
       sender-start (point)
       `(fermium-room-sender-id ,sender-id
         fermium-room-sender-role ,sender-role))
      (insert ":")
      (unless image
        (insert " ")))
    (if image
        (progn
          (insert "\n")
          (setq body-start (point))
          (if (eq (plist-get image-state :status) 'ready)
              ;; Keep the display image separate from its sender line and
              ;; don't leave an alt-text placeholder or link styling behind.
              (insert-image (plist-get image-state :image) " ")
            (insert (if (eq (plist-get image-state :status) 'loading)
                        (fermium-room--image-loading-dots)
                      "[Image]"))))
      (setq body-start (point))
      (insert (or (fermium--event-value message "body") "")))
    (setq body-end (point))
    (insert "\n")
    (fermium-room--add-face-properties body-start (point) 'default)
    (add-text-properties
     start (point)
     `(read-only t
       keymap ,fermium-room--read-only-map
       fermium-room-message-key ,(fermium-room--message-key message)
       fermium-room--message-timestamp ,timestamp-value))
    (when (and image
               (not (eq (plist-get image-state :status) 'ready)))
      (fermium-room--add-face-properties body-start body-end 'button)
      (add-text-properties
       body-start body-end
       `(fermium-room-image t
         fermium-room-image-key ,image-key
         fermium-room-image-source ,image-source
         mouse-face highlight
         follow-link t
         help-echo "RET or click to display image"
         keymap ,fermium-room--image-map)))))

(defun fermium-room--refresh-messages (keys)
  "Re-render the messages KEYS where they are shown, in one edit."
  (let ((nodes nil))
    (dolist (key keys)
      (when-let ((node (fermium-room--node-for-key key)))
        (cl-pushnew node nodes)))
    (when nodes
      (fermium-room--edit-history
       (lambda () (apply #'ewoc-invalidate fermium-room--ewoc nodes))))))

(defun fermium-room--refresh-message (key)
  "Re-render the message KEY where it is shown."
  (fermium-room--refresh-messages (list key)))

(defun fermium-room--add-live-message (message)
  "Add MESSAGE to this room's history and show it.

A message the client has sent is shown as soon as the homeserver accepts
it, timed by the local clock, and arrives again through the next sync
carrying `origin_server_ts'.  The homeserver's time is the room's, so the
later report of an event supersedes the shown copy wherever the two
disagree; where they agree there is nothing to redo."
  (when fermium-room--ewoc
    (let* ((key (fermium-room--message-key message))
           (node (fermium-room--node-for-key key))
           (superseded (and node (fermium-room--node-message node key))))
      (unless (and superseded
                   (= (fermium-room--message-timestamp superseded)
                      (fermium-room--message-timestamp message)))
        (fermium-room--edit-history
         (lambda ()
           (when superseded (fermium-room--unplace-message key))
           (fermium-room--place-message message)))))))

(defun fermium--room-by-id (room-id &optional account-id)
  (or (get-buffer (fermium--room-buffer-name room-id account-id))
      (when-let ((room (fermium--room-summary-by-id room-id account-id)))
        (get-buffer
         (fermium--room-buffer-name
          room-id account-id (fermium--event-value room "name"))))
      ;; Buffers created before room names were resolved used the account and
      ;; room ID order.  Find them while they are being upgraded in place.
      (and account-id
           (get-buffer (format "*Fermium: %s / %s*" account-id room-id)))
      (seq-find
       (lambda (buffer)
         (and (buffer-live-p buffer)
              (with-current-buffer buffer
                (and (derived-mode-p 'fermium-room-mode)
                     (equal fermium-room--room-id room-id)
                     (or (null account-id)
                         (equal fermium-room--account-id account-id))))))
       (buffer-list))
      ;; Keep already-open single-account buffers discoverable while the
      ;; account list is being refreshed, without confusing two accounts that
      ;; happen to share a room ID.
      (when-let ((buffer (get-buffer (format "*Fermium: %s*" room-id))))
        (when (or (not account-id)
                  (not (fermium--multi-account-p))
                  (with-current-buffer buffer
                    (equal fermium-room--account-id account-id)))
          buffer))))

(defun fermium--update-room-summary-from-message
    (room-id message &optional account-id)
  (let ((updated nil)
        (timestamp (or (fermium--event-value message "timestamp") 0)))
    (dolist (room (if account-id
                      (fermium--rooms-for-account account-id)
                    fermium--rooms)
                  updated)
      (when (equal room-id (fermium--event-value room "room_id"))
        (let ((current-timestamp
               (max (or (fermium--event-value room "last_activity_timestamp") 0)
                    (or (fermium--event-value
                         (fermium--event-value room "latest_message") "timestamp")
                        0))))
          (when (>= timestamp current-timestamp)
            (setf (alist-get "latest_message" room nil nil #'string=) message)))
        (setf (alist-get "last_activity_timestamp" room nil nil #'string=)
              (max timestamp
                   (or (fermium--event-value room "last_activity_timestamp") 0)))
        (setf (alist-get "has_unread" room nil nil #'string=) t)
        (setq updated t)))))

(defun fermium--handle-message-event (event)
  (let* ((account-id (fermium--event-value event "account"))
         (room-id (fermium--event-value event "room_id"))
         (message (fermium--event-value event "message"))
         (buffer (fermium--room-by-id room-id account-id)))
    (fermium--clear-room-locally-read account-id room-id)
    (when (and room-id message
               (fermium--update-room-summary-from-message
                room-id message account-id))
      (when-let ((overview (get-buffer fermium--overview-buffer)))
        (with-current-buffer overview
          (fermium--render-overview))))
    (when (and room-id message buffer (buffer-live-p buffer))
      (with-current-buffer buffer
        (if (and fermium-room--ewoc
                 (not fermium-room--loading))
            (progn
              (fermium-room--add-live-message message)
              (fermium-room--maybe-mark-latest-message-read))
          (push message fermium-room--pending-messages))))))

(defun fermium--handle-message-pending (event)
  (when-let ((buffer
              (fermium--room-by-id
               (fermium--event-value event "room_id")
               (fermium--event-value event "account"))))
    (with-current-buffer buffer
      (setq fermium-room--send-error nil)
      (setq fermium-room--sending t)
      (fermium-room--set-input-read-only t)
      (force-mode-line-update t))))

(defun fermium--handle-message-sent (event)
  (when-let ((buffer
              (fermium--room-by-id
               (fermium--event-value event "room_id")
               (fermium--event-value event "account"))))
    (with-current-buffer buffer
      (setq fermium-room--sending nil)
      (setq fermium-room--send-error nil)
      (when fermium-room--input-start
        (let ((inhibit-read-only t))
          (delete-region fermium-room--input-start (point-max))))
      (fermium-room--set-input-read-only nil)
      (force-mode-line-update t)
      (message "Fermium: message sent"))))

(defun fermium-room--set-input-read-only (read-only)
  "Set whether the composition is locked and update its visual state."
  (when fermium-room--input-start
    (let ((inhibit-read-only t))
      (if read-only
          (add-text-properties
           fermium-room--input-start (point-max)
           '(read-only t))
        (remove-text-properties
         fermium-room--input-start (point-max)
         '(read-only)))))
  (when (overlayp fermium-room--composition-overlay)
    (overlay-put fermium-room--composition-overlay
                 'face (if read-only
                           'fermium-room-composition-sending-face
                         'fermium-room-composition-face))))

(defun fermium-room-send ()
  "Send the text in the room's writable tail."
  (interactive)
  (if (or fermium-room--sending (not fermium-room--input-start))
      (message "Fermium: message is already being sent")
    (let ((body (string-trim
                 (buffer-substring-no-properties
                  fermium-room--input-start (point-max)))))
      (if (string-empty-p body)
          (message "Fermium: message is empty")
        (let ((room-id fermium-room--room-id)
              (room-buffer (current-buffer)))
          (setq fermium-room--send-error nil)
          (setq fermium-room--sending t)
          (fermium-room--set-input-read-only t)
          (force-mode-line-update t)
          (condition-case error
              (fermium--send
               "send_message"
               (list (cons "account" fermium-room--account-id)
                     (cons "room_id" room-id)
                     (cons "body" body))
               (lambda (event)
                 (fermium--handle-send-error
                  event room-id room-buffer)))
            (error
             (setq fermium-room--sending nil)
             (setq fermium-room--send-error (error-message-string error))
             (fermium-room--set-input-read-only nil)
             (force-mode-line-update t)
             (message "Fermium: could not send message: %s"
                      (error-message-string error)))))))))

(defun fermium--handle-send-error
    (event &optional room-id room-buffer account-id)
  (when (equal (fermium--event-value event "type") "error")
    (let ((buffer (or room-buffer
                      (fermium--room-by-id
                       (or room-id
                           (fermium--event-value event "room_id"))
                       (or account-id
                           (fermium--event-value event "account"))))))
      (when (and buffer (buffer-live-p buffer))
        (with-current-buffer buffer
          (setq fermium-room--sending nil)
          (setq fermium-room--send-error
                (fermium--event-value event "message"))
          (fermium-room--set-input-read-only nil)
          (force-mode-line-update t)))
      (message "Fermium: %s" (fermium--event-value event "message")))))

(defun fermium-room-clear-input ()
  "Clear the writable tail of the current room buffer."
  (interactive)
  (when (and fermium-room--input-start (not fermium-room--sending))
    (let ((inhibit-read-only t))
      (delete-region fermium-room--input-start (point-max)))))

(defun fermium-room-quit ()
  "Close the current room buffer."
  (interactive)
  (kill-this-buffer))

(provide 'fermium)

;;; fermium.el ends here
