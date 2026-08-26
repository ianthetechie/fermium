;;; fermium-test.el --- Tests for Fermium -*- lexical-binding: t; -*-

(require 'ert)
(require 'fermium)

(defun fermium-test--history-text ()
  "Return the rendered history region of the current room buffer."
  (buffer-substring-no-properties (point-min) (fermium-room--history-end)))

(defun fermium-test--rerendered-history ()
  "Return the text a render of the current history from scratch produces.
Comparing an incrementally updated buffer against this checks that the two
never disagree about what the history looks like, without assuming anything
about how that order was arrived at."
  (let ((messages (fermium-room--history-messages))
        (expanded fermium-room--expanded-channel-events))
    (with-temp-buffer
      (fermium-room-mode)
      (setq fermium-room--expanded-channel-events expanded)
      (fermium-room--render-history messages)
      (fermium-test--history-text))))

(defun fermium-test--rendered-keys ()
  "Return the message keys rendered in the current room buffer, in order."
  (let ((keys nil)
        (limit (fermium-room--history-end))
        (position (point-min)))
    (while (< position limit)
      (let ((key (get-text-property position 'fermium-room-message-key)))
        (when (and key (not (member key keys)))
          (push key keys)))
      (setq position (1+ position)))
    (nreverse keys)))

(defun fermium-test--window-start-line ()
  "Return the line the selected window starts on."
  (save-excursion
    (goto-char (window-start))
    (buffer-substring-no-properties (point) (line-end-position))))

(defun fermium-test--image-message (index)
  "Return a message carrying an image, named by INDEX."
  (list (cons "event_id" (format "$img%d" index))
        (cons "sender" "@bob:example.org")
        (cons "body" "photo.png")
        (cons "timestamp" (* (1+ index) 1000))
        (cons "image"
              (list (cons "source"
                          (list (cons "url" "mxc://example.org/image")))))))

(defun fermium-test--history-keys ()
  "Return the message keys in the current room's history, in order."
  (mapcar #'fermium-room--message-key (fermium-room--history-messages)))

(defun fermium-test--spec-message (spec)
  "Build a message from SPEC, a list of event id, timestamp and kind.
The body is the event id, so a case can find its own messages in the text."
  (let ((id (nth 0 spec))
        (timestamp (nth 1 spec))
        (kind (nth 2 spec)))
    (append (when (eq kind 'channel)
              (list (cons "kind" "channel_event")))
            (list (cons "event_id" id)
                  (cons "sender" "@bob:example.org")
                  (cons "body" id)
                  (cons "timestamp" timestamp)))))

(defun fermium-test--seed-room (specs)
  "Render a room in the current buffer holding the messages named by SPECS."
  (fermium-room-mode)
  (setq fermium-room--room-id "!room:example.org")
  (fermium-room--render-room
   (list (cons "room_id" "!room:example.org"))
   (mapcar #'fermium-test--spec-message specs)))

(defun fermium-test--rendered-units (thunk)
  "Call THUNK and return how many history units the room rendered as it ran.
A unit is one node of the history: a message, or a run of channel events
folded into a section.  A room updated in place renders only the units the
change touches, where one rebuilding itself renders every unit it holds."
  (let ((rendered 0))
    (cl-letf* ((printer (symbol-function 'fermium-room--insert-group))
               ((symbol-function 'fermium-room--insert-group)
                (lambda (messages)
                  (setq rendered (1+ rendered))
                  (funcall printer messages))))
      (funcall thunk))
    rendered))

(defun fermium-test--deliver (specs)
  "Deliver the messages named by SPECS to the current room, one at a time.
Return how many history units the room rendered while doing it."
  (fermium-test--rendered-units
   (lambda ()
     (dolist (spec specs)
       (fermium--handle-message-event
        (list (cons "room_id" "!room:example.org")
              (cons "message" (fermium-test--spec-message spec))))))))

(defun fermium-test--full-render (messages)
  "Return the history text a render of MESSAGES from scratch produces.
Incremental updates are correct exactly when they agree with this."
  (with-temp-buffer
    (fermium-room-mode)
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org")) messages)
    (fermium-test--history-text)))

(ert-deftest fermium-process-filter-identifies-a-failing-event ()
  (let ((fermium--process nil)
        (fermium--process-output "")
        (fermium--last-elisp-error nil))
    (cl-letf (((symbol-function 'fermium--handle-event)
               (lambda (_event)
                 (signal 'end-of-buffer nil))))
      (fermium--process-filter
       nil
       "{\"type\":\"message\",\"request_id\":9}\n"))
    (should (equal fermium--last-elisp-error
                   "helper event failed for message event (request 9): End of buffer"))))

(ert-deftest fermium-event-value-treats-json-false-as-nil ()
  (should-not (fermium--event-value
               (json-parse-string "{\"has_unread\":false}"
                                  :object-type 'alist)
               "has_unread")))

(ert-deftest fermium-loading-timer-failure-is-contained-and-recorded ()
  (let ((fermium--loading-timer (run-at-time 60 nil #'ignore))
        (fermium--last-elisp-error nil))
    (unwind-protect
        (cl-letf (((symbol-function 'fermium--animate-loading-internal)
                   (lambda ()
                     (signal 'end-of-buffer nil))))
          (fermium--animate-loading)
          (should-not fermium--loading-timer)
          (should (equal fermium--last-elisp-error
                         "loading timer failed: End of buffer")))
      (when (timerp fermium--loading-timer)
        (cancel-timer fermium--loading-timer)))))

(ert-deftest fermium-helper-environment-configures-sync-timeouts ()
  (let ((process-environment '("PATH=/bin"))
        (fermium-initial-sync-timeout 300)
        (fermium-sync-long-poll-timeout nil))
    (let ((environment (fermium--helper-environment)))
      (should (member "FERMIUM_INITIAL_SYNC_TIMEOUT=300" environment))
      (should-not (seq-some (lambda (entry)
                              (string-prefix-p "FERMIUM_SYNC_TIMEOUT=" entry))
                            environment)))
    (let ((fermium-initial-sync-timeout 600)
          (fermium-sync-long-poll-timeout 45))
      (let ((environment (fermium--helper-environment)))
        (should (member "FERMIUM_INITIAL_SYNC_TIMEOUT=600" environment))
        (should (member "FERMIUM_SYNC_TIMEOUT=45" environment))))))

(ert-deftest fermium-login-prompts-for-a-recovery-key-challenge ()
  (let (sent)
    (cl-letf (((symbol-function 'read-passwd)
               (lambda (&rest _args) "EsTj recovery key"))
              ((symbol-function 'fermium--send)
               (lambda (command payload callback)
                 (setq sent (list command payload callback)))))
      (fermium--handle-login-response
       (list (cons "type" "login_verification_required")
             (cons "request_id" 17)
             (cons "method" "recovery_key")))
      (should (equal (car sent) "login_recovery_key"))
      (should (equal (cadr sent)
                     (list (cons "login_request_id" 17)
                           (cons "recovery_key" "EsTj recovery key"))))
      (should-not (caddr sent)))))

(ert-deftest fermium-login-keeps-challenge-request-pending-for-retry ()
  (let ((fermium--pending-requests (make-hash-table :test #'eql))
        sent)
    (puthash 17 #'fermium--handle-login-response fermium--pending-requests)
    (cl-letf (((symbol-function 'read-passwd)
               (lambda (&rest _args) "recovery key"))
              ((symbol-function 'fermium--send)
               (lambda (&rest args) (setq sent args))))
      (fermium--handle-event
       (list (cons "type" "login_verification_required")
             (cons "request_id" 17)
             (cons "method" "recovery_key")))
      (should sent)
      (should (gethash 17 fermium--pending-requests)))))

(ert-deftest fermium-overview-shows-a-pending-login-with-animated-dots ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--accounts nil)
          (fermium--account nil)
          (fermium--rooms nil)
          (fermium--pending-logins
           (list (list (cons "user_id" "@alice:example.org")
                       (cons "status" "logging_in")
                       (cons "rooms" nil))))
          (fermium--loading-frame 1))
      (fermium--render-overview)
      (should (string-match-p "@alice:example.org" (buffer-string)))
      (should (string-match-p "Logging in\." (buffer-string))))))

(ert-deftest fermium-login-removes-pending-account-when-helper-fails ()
  (let ((fermium--pending-logins nil)
        (sent nil)
        (inputs (list "https://example.org" "@alice:example.org")))
    (cl-letf (((symbol-function 'fermium)
               (lambda () nil))
              ((symbol-function 'read-string)
               (lambda (&rest _args) (pop inputs)))
              ((symbol-function 'auth-source-search)
               (lambda (&rest _args) nil))
              ((symbol-function 'read-passwd)
               (lambda (&rest _args) "password"))
              ((symbol-function 'fermium--send)
               (lambda (command payload callback)
                 (setq sent (list command payload callback)))))
      (fermium-login)
      (should (equal (fermium--account-ids)
                     (list "@alice:example.org")))
      (funcall (nth 2 sent)
               (list (cons "type" "error")
                     (cons "message" "invalid password")))
      (should-not fermium--pending-logins))))

(ert-deftest fermium-overview-renders-accounts-and-rooms-at-root ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--accounts
           (list
            (list (cons "user_id" "@alice:example.org")
                  (cons "rooms"
                        (list (list (cons "room_id" "!alice:example.org")
                                    (cons "name" "Alice room")))))
            (list (cons "user_id" "@bob:example.org")
                  (cons "rooms"
                        (list (list (cons "room_id" "!bob:example.org")
                                    (cons "name" "Bob room")))))))
          (fermium--account nil)
          (fermium--rooms nil))
      (fermium--render-overview)
      (should-not (string-match-p "Accounts" (buffer-string)))
      (should (string-match-p "^▾ @alice:example.org$" (buffer-string)))
      (should (string-match-p "^▾ Rooms (1)$" (buffer-string)))
      (should (string-match-p "^• Alice room$" (buffer-string)))
      (should (string-match-p "Alice room" (buffer-string)))
      (should (string-match-p "Bob room" (buffer-string)))
      (should (fermium--overview-goto-entity
               'room "!bob:example.org" "@bob:example.org"))
      (should (equal (get-text-property (point) 'fermium-account-id)
                     "@bob:example.org")))))

(ert-deftest fermium-overview-renders-a-partial-account-while-rooms-load ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--accounts
           (list (list (cons "user_id" "@alice:example.org")
                       (cons "homeserver" "https://example.org")
                       (cons "rooms" nil)
                       (cons "rooms_loading" t))))
          (fermium--account nil)
          (fermium--rooms nil))
      (fermium--render-overview)
      (should (string-match-p "Rooms (loading)" (buffer-string)))
      (should (string-match-p "^▾ @alice:example.org$" (buffer-string)))
      (should (string-match-p "^▾ Rooms (loading)$" (buffer-string)))
      (should (string-match-p "Loading rooms" (buffer-string)))
      (should-not (string-match-p "No rooms yet" (buffer-string))))))

(ert-deftest fermium-overview-shows-initial-sync-failure-instead-of-no-rooms ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--accounts
           (list (list (cons "user_id" "@alice:example.org")
                       (cons "homeserver" "https://example.org")
                       (cons "rooms" nil)
                       (cons "rooms_loading" nil)
                       (cons "initial_sync_failed" t)
                       (cons "connection_status" "offline")
                       (cons "connection_error" "request timed out"))))
          (fermium--account nil)
          (fermium--rooms nil))
      (fermium--render-overview)
      (should (string-match-p "Rooms (initial sync failed)" (buffer-string)))
      (should (string-match-p "Initial sync failed" (buffer-string)))
      (should-not (string-match-p "No rooms yet" (buffer-string)))
      (should (string-match-p
               "initial sync failed"
               (fermium--account-status-description
                (car fermium--accounts)))))))

(ert-deftest fermium-room-updates-are-merged-into-the-account ()
  (let* ((existing-room
          (list (cons "room_id" "!room:example.org")
                (cons "latest_message"
                      (list (cons "body" "cached")))))
         (fermium--accounts
          (list (list (cons "user_id" "@alice:example.org")
                      (cons "rooms" (list existing-room)))))
        (fermium--account "@alice:example.org")
        (fermium--rooms nil))
    (fermium--handle-room-updated
     (list (cons "type" "room_updated")
           (cons "account" "@alice:example.org")
           (cons "room"
                 (list (cons "room_id" "!room:example.org")
                       (cons "name" "Example room")))))
    (should (equal (fermium--event-value
                    (car (fermium--rooms-for-account "@alice:example.org"))
                    "name")
                   "Example room"))
    (should (equal (fermium--event-value
                    (fermium--event-value
                     (car (fermium--rooms-for-account "@alice:example.org"))
                     "latest_message")
                    "body")
                   "cached"))))

(ert-deftest fermium-room-update-keeps-an-enriched-name-over-id-fallback ()
  (let* ((existing-room
          (list (cons "room_id" "!dm:example.org")
                (cons "name" "Bob")
                (cons "members" (list "Bob"))
                (cons "last_activity_timestamp" 2000)))
         (fermium--accounts
          (list (list (cons "user_id" "@alice:example.org")
                      (cons "rooms" (list existing-room)))))
        (fermium--account "@alice:example.org")
        (fermium--rooms nil))
    (fermium--handle-room-updated
     (list (cons "type" "room_updated")
           (cons "account" "@alice:example.org")
           (cons "room"
                 (list (cons "room_id" "!dm:example.org")
                       (cons "name" "!dm:example.org")
                       (cons "is_dm" t)
                       (cons "members" nil)
                       (cons "last_activity_timestamp" 0)))))
    (let ((room (car (fermium--rooms-for-account "@alice:example.org"))))
      (should (equal (fermium--event-value room "name") "Bob"))
      (should (equal (fermium--event-value room "members") (list "Bob")))
      (should (= (fermium--event-value room "last_activity_timestamp")
                 2000)))))

(ert-deftest fermium-state-refresh-keeps-enriched-room-names ()
  (let* ((room (list (cons "room_id" "!dm:example.org")
                     (cons "name" "Bob")
                     (cons "members" (list "Bob"))
                     (cons "last_activity_timestamp" 2000)
                     (cons "latest_message"
                           (list (cons "body" "latest")))))
         (account (list (cons "user_id" "@alice:example.org")
                        (cons "rooms" (list room))))
         (fermium--accounts nil)
         (fermium--account "@alice:example.org")
         (fermium--rooms nil))
    (fermium--handle-state
     (list (cons "type" "state")
           (cons "accounts" (list account))))
    (let ((refreshed-room
           (car (fermium--rooms-for-account "@alice:example.org"))))
      (should (equal (fermium--event-value refreshed-room "name") "Bob"))
      (should (equal (fermium--event-value refreshed-room "members")
                     (list "Bob")))
      (should (= (fermium--overview-room-activity-timestamp refreshed-room)
                 2000))
      (should (equal (fermium--event-value
                      (fermium--event-value refreshed-room "latest_message")
                      "body")
                     "latest")))))

(ert-deftest fermium-overview-room-order-is-deterministic-for-ties ()
  (let ((rooms
         (list (list (cons "room_id" "!z:example.org")
                     (cons "name" "Same name")
                     (cons "last_activity_timestamp" 1000))
               (list (cons "room_id" "!a:example.org")
                     (cons "name" "Same name")
                     (cons "last_activity_timestamp" 1000)))))
    (should (equal
             (mapcar (lambda (room) (fermium--event-value room "room_id"))
                     (fermium--overview-sorted-rooms rooms))
             (list "!a:example.org" "!z:example.org")))))

(ert-deftest fermium-room-removal-is-scoped-to-its-account ()
  (let ((fermium--accounts
         (list (list (cons "user_id" "@alice:example.org")
                     (cons "rooms"
                           (list (list (cons "room_id" "!room:example.org")))))
               (list (cons "user_id" "@bob:example.org")
                     (cons "rooms"
                           (list (list (cons "room_id" "!room:example.org")))))))
        (fermium--account "@alice:example.org")
        (fermium--rooms nil))
    (fermium--handle-room-removed
     (list (cons "type" "room_removed")
           (cons "account" "@alice:example.org")
           (cons "room_id" "!room:example.org")))
    (should-not (fermium--rooms-for-account "@alice:example.org"))
    (should (fermium--rooms-for-account "@bob:example.org"))))

(ert-deftest fermium-online-status-completes-initial-room-loading ()
  (let ((fermium--accounts
         (list (list (cons "user_id" "@alice:example.org")
                     (cons "rooms" nil)
                     (cons "rooms_loading" t))))
        (fermium--account nil))
    (cl-letf (((symbol-function 'message) (lambda (&rest _args) nil)))
      (fermium--handle-connection-status
       (list (cons "type" "connection_status")
             (cons "account" "@alice:example.org")
             (cons "status" "online"))))
    (should-not (fermium--event-value
                 (fermium--account-record "@alice:example.org")
                 "rooms_loading"))
    (should (equal (fermium--event-value
                    (fermium--account-record "@alice:example.org")
                    "connection_status")
                   "online"))))

(ert-deftest fermium-connection-status-heartbeats-do-not-message ()
  (let ((fermium--accounts
         (list (list (cons "user_id" "@alice:example.org")
                     (cons "rooms" nil)
                     (cons "rooms_loading" nil))))
        (messages 0))
    (cl-letf (((symbol-function 'message)
               (lambda (&rest _args) (cl-incf messages))))
      (fermium--handle-connection-status
       (list (cons "type" "connection_status")
             (cons "account" "@alice:example.org")
             (cons "status" "online")
             (cons "last_sync_timestamp" 1000)))
      (fermium--handle-connection-status
       (list (cons "type" "connection_status")
             (cons "account" "@alice:example.org")
             (cons "status" "online")
             (cons "last_sync_timestamp" 2000)))
      (should (= messages 0)))))

(ert-deftest fermium-open-room-sends-the-owning-account ()
  (let ((overview (generate-new-buffer " *Fermium multi-account overview*"))
        room
        sent)
    (unwind-protect
        (with-current-buffer overview
          (fermium-overview-mode)
          (let ((fermium--accounts
                 (list
                  (list (cons "user_id" "@alice:example.org")
                        (cons "rooms"
                              (list (list (cons "room_id" "!same:example.org")
                                          (cons "name" "Alice room")))))
                  (list (cons "user_id" "@bob:example.org")
                        (cons "rooms"
                              (list (list (cons "room_id" "!same:example.org")
                                          (cons "name" "Bob room")))))))
                (fermium--account nil)
                (fermium--rooms nil))
            (fermium--render-overview)
            (fermium--overview-goto-entity
             'room "!same:example.org" "@bob:example.org")
            (cl-letf (((symbol-function 'fermium--send)
                       (lambda (command payload _callback)
                         (setq sent (list command payload)))))
              (fermium-open-room))
            (setq room (current-buffer))
            (should (string-match-p "@bob:example.org"
                                    (buffer-name room)))
            (should (equal (car sent) "open_room"))
            (should (equal (cadr sent)
                           (list (cons "account" "@bob:example.org")
                                 (cons "room_id" "!same:example.org"))))))
      (when (buffer-live-p room)
        (kill-buffer room))
      (when (buffer-live-p overview)
        (kill-buffer overview)))))

(ert-deftest fermium-room-open-response-survives-account-state-change ()
  (let ((overview (generate-new-buffer " *Fermium room loading overview*"))
        room)
    (unwind-protect
        (with-current-buffer overview
          (fermium-overview-mode)
          (let ((fermium--accounts
                 (list
                  (list (cons "user_id" "@alice:example.org")
                        (cons "rooms"
                              (list (list (cons "room_id"
                                                "!room:example.org")
                                          (cons "name" "Example room")))))))
                (fermium--pending-logins
                 (list (list (cons "user_id" "@bob:example.org")
                             (cons "status" "logging_in")
                             (cons "rooms" nil))))
                (fermium--account "@alice:example.org")
                (fermium--rooms nil))
            (fermium--render-overview)
            (fermium--overview-goto-entity
             'room "!room:example.org" "@alice:example.org")
            (cl-letf (((symbol-function 'fermium--send)
                       (lambda (&rest _args) nil)))
              (fermium-open-room))
            (setq room (current-buffer))
            (should (string= (buffer-name room)
                             "*Fermium: Example room / @alice:example.org*"))
            ;; Bob's login finishes (or is removed) while Alice's history
            ;; request is still in flight, so the account count changes.
            (setq fermium--pending-logins nil)
            (cl-letf (((symbol-function 'fermium--send)
                       (lambda (&rest _args) nil)))
              (fermium--handle-room-opened
               (list (cons "type" "room_opened")
                     (cons "account" "@alice:example.org")
                     (cons "room"
                           (list (cons "room_id" "!room:example.org")
                                 (cons "name" "Example room")))
                     (cons "messages"
                           (list (list (cons "event_id" "$history")
                                       (cons "body" "history")
                                       (cons "timestamp" 1000)))))))
            (with-current-buffer room
              (should-not fermium-room--loading)
              (should (string-match-p "history" (buffer-string))))))
      (when (buffer-live-p room)
        (kill-buffer room))
      (when (buffer-live-p overview)
        (kill-buffer overview)))))

(ert-deftest fermium-account-menu-can-log-out-a-specific-account ()
  (let ((fermium--accounts
         (list (list (cons "user_id" "@alice:example.org")
                     (cons "rooms" nil))
               (list (cons "user_id" "@bob:example.org")
                     (cons "rooms" nil))))
        (fermium--account "@alice:example.org")
        sent)
    (cl-letf (((symbol-function 'read-char-choice)
               (lambda (&rest _args) ?o))
              ((symbol-function 'yes-or-no-p)
               (lambda (&rest _args) t))
              ((symbol-function 'fermium--send)
               (lambda (command payload callback)
                 (setq sent (list command payload callback)))))
      (fermium-account-menu "@bob:example.org")
      (should (equal (car sent) "logout"))
      (should (equal (cadr sent)
                     (list (cons "account" "@bob:example.org"))))
      (should (functionp (caddr sent))))))

(ert-deftest fermium-logout-removes-only-the-requested-account ()
  (let ((fermium--accounts
         (list (list (cons "user_id" "@alice:example.org")
                     (cons "rooms" nil))
               (list (cons "user_id" "@bob:example.org")
                     (cons "rooms" nil))))
        (fermium--account "@bob:example.org")
        (alice-room (generate-new-buffer " *Fermium alice room*"))
        (bob-room (generate-new-buffer " *Fermium bob room*")))
    (unwind-protect
        (progn
          (with-current-buffer alice-room
            (fermium-room-mode)
            (setq fermium-room--account-id "@alice:example.org"))
          (with-current-buffer bob-room
            (fermium-room-mode)
            (setq fermium-room--account-id "@bob:example.org"))
          (fermium--handle-logout
           (list (cons "type" "logout_succeeded")
                 (cons "account" "@bob:example.org")))
          (should (equal (fermium--account-ids)
                         (list "@alice:example.org")))
          (should (buffer-live-p alice-room))
          (should-not (buffer-live-p bob-room)))
      (when (buffer-live-p alice-room)
        (kill-buffer alice-room))
      (when (buffer-live-p bob-room)
        (kill-buffer bob-room)))))

(ert-deftest fermium-can-verify-an-active-device-with-a-recovery-key ()
  (let ((fermium--account "@alice:example.org")
        sent)
    (cl-letf (((symbol-function 'read-passwd)
               (lambda (&rest _args) "recovery key"))
              ((symbol-function 'completing-read)
               (lambda (prompt collection &rest _args)
                 (should (string-match-p "Account to verify" prompt))
                 (should (equal collection (list fermium--account)))
                 fermium--account))
              ((symbol-function 'fermium--send)
               (lambda (command payload callback)
                 (setq sent (list command payload callback)))))
      (fermium-verify-device)
      (should (equal (car sent) "verify_device"))
      (should (equal (cadr sent)
                     (list (cons "account" "@alice:example.org")
                           (cons "recovery_key" "recovery key"))))
      (should (functionp (caddr sent))))))

(ert-deftest fermium-device-verification-reports-success ()
  (let (reported)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq reported (apply #'format format-string args)))))
      (fermium--handle-device-verification
       (list (cons "type" "device_verified"))
       "@alice:example.org")
      (should (string-match-p "device verification complete" reported))
      (should (string-match-p "@alice:example.org" reported)))))

(ert-deftest fermium-device-verification-reports-failure ()
  (let (reported)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq reported (apply #'format format-string args)))))
      (fermium--handle-device-verification
       (list (cons "type" "error")
             (cons "message" "invalid recovery key"))
       "@alice:example.org")
      (should (string-match-p "device verification failed" reported))
      (should (string-match-p "invalid recovery key" reported)))))

(ert-deftest fermium-account-menu-offers-device-verification ()
  (let (called)
    (cl-letf (((symbol-function 'read-char-choice)
               (lambda (&rest _args) ?v))
              ((symbol-function 'fermium-verify-device)
               (lambda () (setq called t))))
      (fermium-account-menu)
      (should called))))

(ert-deftest fermium-overview-handles-json-null-latest-message ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--account "@alice:example.org")
          (fermium--rooms
           (list (list (cons "room_id" "!room:example.org")
                       (cons "name" "Empty room")
                       (cons "latest_message" :null)))))
      (should-not (fermium--event-value
                   (list (cons "latest_message" :null))
                   "latest_message"))
      (fermium--render-overview)
      (should (string-match-p "Empty room" (buffer-string))))))

(ert-deftest fermium-overview-shows-loading-state-instead-of-no-account ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--account nil)
          (fermium--rooms nil)
          (fermium--state-loading t))
      (fermium--render-overview)
      (should (string-match-p "Loading account state" (buffer-string)))
      (should-not (string-match-p "Accounts" (buffer-string)))
      (should-not (string-match-p "Not logged in" (buffer-string))))))

(ert-deftest fermium-overview-keeps-point-at-the-top-while-loading ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--account nil)
          (fermium--rooms nil)
          (fermium--state-loading t))
      (fermium--render-overview)
      (should (= (point) (point-min)))
      (fermium--render-overview)
      (should (= (point) (point-min))))))

(ert-deftest fermium-overview-modeline-statuses-aggregate-account-state ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--accounts
           (list (list (cons "user_id" "@alice:example.org")
                       (cons "connection_status" "online")
                       (cons "last_sync_timestamp" 0)
                       (cons "rooms_loading" nil)))))
      (let ((status (fermium--mode-line-status)))
        (should (equal (substring-no-properties status) " ⇅"))
        (should (string-match-p "last successful sync"
                                (get-text-property 1 'help-echo status)))))
    (let ((fermium--accounts
           (list (list (cons "user_id" "@alice:example.org")
                       (cons "connection_status" nil)
                       (cons "rooms_loading" t)))))
      (should (equal (substring-no-properties (fermium--mode-line-status))
                     " ⌛")))
    (let ((fermium--accounts
           (list (list (cons "user_id" "@alice:example.org")
                       (cons "connection_status" "offline")
                       (cons "connection_error" "network timeout")))))
      (let ((status (fermium--mode-line-status)))
        (should (equal (substring-no-properties status) " ⚠"))
        (should (string-match-p "network timeout"
                                (get-text-property 1 'help-echo status)))))))

(ert-deftest fermium-room-modeline-status-is-account-scoped ()
  (with-temp-buffer
    (fermium-room-mode)
    (setq fermium-room--account-id "@alice:example.org")
    (let ((fermium--accounts
           (list (list (cons "user_id" "@alice:example.org")
                       (cons "connection_status" "online")
                       (cons "last_sync_timestamp" 0))
                 (list (cons "user_id" "@bob:example.org")
                       (cons "connection_status" "offline")
                       (cons "connection_error" "Bob is disconnected")))))
      (should (equal (substring-no-properties (fermium--mode-line-status))
                     " ⇅"))
      (setq fermium-room--loading t)
      (should (equal (substring-no-properties (fermium--mode-line-status))
                     " ⌛"))
      (setq fermium-room--loading nil)
      (setq fermium-room--sending t)
      (should (equal (substring-no-properties (fermium--mode-line-status))
                     " ➤"))
      (setq fermium-room--sending nil)
      (setq fermium-room--send-error "message rejected")
      (let ((status (fermium--mode-line-status)))
        (should (equal (substring-no-properties status) " ⚠"))
        (should (string-match-p "message rejected"
                                (get-text-property 1 'help-echo status)))))))

(ert-deftest fermium-overview-loading-state-includes-animation-frame ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--account nil)
          (fermium--rooms nil)
          (fermium--state-loading t)
          (fermium--loading-frame 2))
      (fermium--render-overview)
      (should (string-match-p (regexp-quote "Loading account state..")
                              (buffer-string))))))

(ert-deftest fermium-overview-shows-login-help-when-no-accounts-exist ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--accounts nil)
          (fermium--account nil)
          (fermium--rooms nil)
          (fermium--state-loading nil))
      (fermium--render-overview)
      (should (equal (buffer-string)
                     "Not logged in. Press l to log in.\n")))))

(ert-deftest fermium-overview-marks-room-lines ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--account "@alice:example.org")
          (fermium--rooms
           (list (list (cons "room_id" "!room:example.org")
                       (cons "name" "Example room")
                       (cons "has_unread" t)))))
      (fermium--render-overview)
      (goto-char (point-min))
      (search-forward "Example room")
      (should (equal (get-text-property (line-beginning-position)
                                        'fermium-room-id)
                     "!room:example.org")))))

(ert-deftest fermium-overview-uses-collapsible-sections-and-hidden-help ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--account "@alice:example.org")
          (fermium--rooms
           (list (list (cons "room_id" "!room:example.org")
                       (cons "name" "Example room")
                       (cons "has_unread" nil)))))
      (fermium--render-overview)
      (should-not (string-match-p "^Fermium$" (buffer-string)))
      (should-not (string-match-p "Commands:" (buffer-string)))
      (goto-char (point-min))
      (should (equal (get-text-property (point) 'fermium-section-id)
                     'account))
      (fermium-toggle-section)
      (should (invisible-p
               (save-excursion
                 (fermium--overview-goto-property
                  'fermium-room-id "!room:example.org")
                 (point))))
      (fermium--overview-goto-property
       'fermium-section-key '(account "@alice:example.org"))
      (fermium-toggle-section)
      (fermium--overview-goto-property 'fermium-section-id 'rooms)
      (fermium-toggle-section)
      (should (invisible-p
               (save-excursion
                 (fermium--overview-goto-property
                  'fermium-room-id "!room:example.org")
                 (point)))))))

(ert-deftest fermium-overview-distinguishes-groups-from-visitable-rows ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--account "@alice:example.org")
          (fermium--rooms
           (list (list (cons "room_id" "!room:example.org")
                       (cons "name" "Example room")
                       (cons "has_unread" t)))))
      (fermium--render-overview)
      (should (string-match-p "^▾ @alice:example.org$" (buffer-string)))
      (should-not (string-match-p "^▾ Accounts$" (buffer-string)))
      (should-not (string-match-p "\\[[+-]\\]" (buffer-string)))
      (goto-char (point-min))
      (should (eq (get-text-property (point) 'fermium-overview-row-type)
                  'visitable-group))
      (search-forward "@alice:example.org")
      (should (eq (get-text-property (1- (point))
                                     'fermium-overview-row-type)
                  'visitable-group))
      (should (eq (get-text-property (1- (point)) 'face)
                  'fermium-overview-account-face))
      (should-not (get-text-property (1- (point)) 'mouse-face))
      (should-not (get-text-property (1- (point)) 'keymap))
      (should-not (get-text-property (1- (point)) 'follow-link))
      (search-forward "Example room")
      (should (eq (get-text-property (1- (point))
                                     'fermium-overview-row-type)
                  'visitable))
      (should (equal (get-text-property (line-beginning-position) 'face)
                     '(fermium-overview-unread-face
                       fermium-overview-room-face)))
      (should-not (get-text-property (line-beginning-position) 'mouse-face))
      (should-not (get-text-property (line-beginning-position) 'keymap))
      (should-not (get-text-property (line-beginning-position) 'follow-link)))))

(ert-deftest fermium-overview-sorts-rooms-and-shows-activity-preview ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--account "@alice:example.org")
          (fermium--rooms
           (list (list (cons "room_id" "!older:example.org")
                       (cons "name" "Older room")
                       (cons "last_activity_timestamp" 1000)
                       (cons "latest_message"
                             (list (cons "body" "older preview"))))
                 (list (cons "room_id" "!newer:example.org")
                       (cons "name" "Newer room")
                       (cons "last_activity_timestamp" 2000)
                       (cons "latest_message"
                             (list (cons "body" "newer preview")))))))
      (fermium--render-overview)
      (let ((newer (string-match "Newer room" (buffer-string)))
            (older (string-match "Older room" (buffer-string))))
        (should (< newer older)))
      (should (string-match-p "1970-01-01" (buffer-string)))
      (should (string-match-p "newer preview" (buffer-string))))))

(ert-deftest fermium-overview-bolds-unread-room-title-and-metadata ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--account "@alice:example.org")
          (fermium--rooms
           (list (list (cons "room_id" "!room:example.org")
                       (cons "name" "Unread room")
                       (cons "last_activity_timestamp" 2000)
                       (cons "has_unread" t)
                       (cons "latest_message"
                             (list (cons "body" "unread preview")))))))
      (fermium--render-overview)
      (goto-char (point-min))
      (search-forward "Unread room")
      (should (equal (get-text-property (1- (point)) 'face)
                     '(fermium-overview-unread-face
                       fermium-overview-room-face)))
      (should (equal (save-excursion
                       (backward-char)
                       (faces--attribute-at-point :weight))
                     'bold))
      (should (equal (save-excursion
                       (backward-char)
                       (faces--attribute-at-point :slant))
                     'italic))
      (search-forward "1970-01-01")
      (should (equal (get-text-property (1- (point)) 'face)
                     '(fermium-overview-unread-face
                       fermium-overview-room-meta-face)))
      (should (equal (save-excursion
                       (backward-char)
                       (faces--attribute-at-point :weight))
                     'bold))
      (should (equal (save-excursion
                       (backward-char)
                       (faces--attribute-at-point :slant))
                     'italic))
      (search-forward "unread preview")
      (should (equal (get-text-property (1- (point)) 'face)
                     '(fermium-overview-unread-face
                       fermium-overview-room-meta-face)))
      (should (equal (save-excursion
                       (backward-char)
                       (faces--attribute-at-point :weight))
                     'bold))
      (should (equal (save-excursion
                       (backward-char)
                       (faces--attribute-at-point :slant))
                     'italic)))))

(ert-deftest fermium-overview-keeps-read-room-metadata-normal-weight ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--account "@alice:example.org")
          (fermium--rooms
           (list (list (cons "room_id" "!room:example.org")
                       (cons "name" "Read room")
                       (cons "last_activity_timestamp" 2000)
                       (cons "has_unread" :false)
                       (cons "latest_message"
                             (list (cons "body" "read preview")))))))
      (fermium--render-overview)
      (goto-char (point-min))
      (search-forward "Read room")
      (should (equal (save-excursion
                       (backward-char)
                       (faces--attribute-at-point :weight))
                     'normal))
      (search-forward "1970-01-01")
      (should (eq (get-text-property (1- (point)) 'face)
                  'fermium-overview-room-meta-face))
      (search-forward "read preview")
      (should (eq (get-text-property (1- (point)) 'face)
                  'fermium-overview-room-meta-face)))))

(ert-deftest fermium-room-read-refreshes-the-overview ()
  (let ((overview (get-buffer-create fermium--overview-buffer))
        (room (list (cons "room_id" "!room:example.org")
                    (cons "name" "Example room")
                    (cons "has_unread" t))))
    (unwind-protect
        (let ((fermium--accounts
               (list (list (cons "user_id" "@alice:example.org")
                           (cons "rooms" (list room)))))
              (fermium--account "@alice:example.org")
              (fermium--rooms (list room)))
          (with-current-buffer overview
            (fermium-overview-mode)
            (fermium--render-overview))
          (fermium--handle-room-updated
           (list (cons "account" "@alice:example.org")
                 (cons "room"
                       (list (cons "room_id" "!room:example.org")
                             (cons "name" "Example room")
                             (cons "has_unread" nil)))))
          (fermium--handle-room-read nil)
          (with-current-buffer overview
            (goto-char (point-min))
            (search-forward "Example room")
            (should-not (equal (get-text-property (1- (point)) 'face)
                               '(fermium-overview-unread-face
                                 fermium-overview-room-face)))))
      (when (buffer-live-p overview)
        (kill-buffer overview)))))

(ert-deftest fermium-room-read-survives-fast-refresh-and-enrichment ()
  (let* ((room (list (cons "room_id" "!room:example.org")
                     (cons "name" "Example room")
                     (cons "has_unread" t)))
         (fermium--accounts
          (list (list (cons "user_id" "@alice:example.org")
                      (cons "rooms" (list room)))))
         (fermium--account "@alice:example.org")
         (fermium--rooms nil)
         (fermium--locally-read-rooms (make-hash-table :test #'equal)))
    (fermium--handle-room-read
     (list (cons "account" "@alice:example.org")
           (cons "room_id" "!room:example.org")))
    ;; Both the fast state response and the enriched update can still carry
    ;; the SDK's stale unread flag; the local read decision must win.
    (fermium--handle-state
     (list (cons "type" "state")
           (cons "accounts"
                 (list (list (cons "user_id" "@alice:example.org")
                             (cons "rooms"
                                   (list (list
                                          (cons "room_id" "!room:example.org")
                                          (cons "name" "!room:example.org")
                                          (cons "has_unread" t)))))))))
    (fermium--handle-room-updated
     (list (cons "account" "@alice:example.org")
           (cons "room"
                 (list (cons "room_id" "!room:example.org")
                       (cons "name" "Example room")
                       (cons "has_unread" t)))))
    (let ((refreshed-room
           (car (fermium--rooms-for-account "@alice:example.org"))))
      (should-not (fermium--event-value refreshed-room "has_unread")))
    ;; A new message clears the override and makes the room unread again.
    (fermium--handle-message-event
     (list (cons "account" "@alice:example.org")
           (cons "room_id" "!room:example.org")
           (cons "message"
                 (list (cons "event_id" "$new")
                       (cons "body" "new message")
                       (cons "timestamp" 3000)))))
    (should (fermium--event-value
             (car (fermium--rooms-for-account "@alice:example.org"))
             "has_unread"))))

(ert-deftest fermium-open-room-reuses-the-current-window ()
  (let ((overview (generate-new-buffer " *Fermium overview test*"))
        (room nil))
    (unwind-protect
        (with-current-buffer overview
          (fermium-overview-mode)
          (let ((fermium--account "@alice:example.org")
                (fermium--rooms
                 (list (list (cons "room_id" "!room:example.org")
                             (cons "name" "Example room")))))
            (fermium--render-overview)
            (fermium--overview-goto-property
             'fermium-room-id "!room:example.org")
            (cl-letf (((symbol-function 'fermium--send)
                       (lambda (&rest _args) nil)))
              (fermium-open-room))
            (setq room (current-buffer))
            (should (string= (buffer-name room)
                             "*Fermium: Example room / @alice:example.org*"))
            (should (string-match-p "Example room"
                                    (fermium-room--header-line)))
            (should (string-match-p "Loading history"
                                    (fermium-room--header-line)))
            (should-not (string-match-p "Example room" (buffer-string)))
            (should-not (string-match-p "Loading history" (buffer-string)))
            (should (string-match-p "Composition" (buffer-string)))
            (should (= (point) (point-max)))))
      (when (buffer-live-p room)
        (kill-buffer room))
      (when (buffer-live-p overview)
        (kill-buffer overview)))))

(ert-deftest fermium-reuses-the-current-window ()
  (let ((source (generate-new-buffer " *Fermium launch source*"))
        overview)
    (unwind-protect
        (progn
          (switch-to-buffer source)
          (let ((window (selected-window)))
            (cl-letf (((symbol-function 'fermium--ensure-process)
                       (lambda () nil))
                      ((symbol-function 'fermium--request-state)
                       (lambda () nil))
                      ((symbol-function 'pop-to-buffer)
                       (lambda (&rest _args)
                         (error "Fermium must not use pop-to-buffer"))))
              (fermium))
            (setq overview (get-buffer fermium--overview-buffer))
            (should (eq (selected-window) window))
            (should (eq (window-buffer window) overview))))
      (when (buffer-live-p overview)
        (kill-buffer overview))
      (when (buffer-live-p source)
        (kill-buffer source)))))

(ert-deftest fermium-room-overview-reuses-the-session-and-current-window ()
  (let ((source (generate-new-buffer " *Fermium room navigation source*"))
        overview
        (process-count 0)
        live-process)
    (unwind-protect
        (progn
          (switch-to-buffer source)
          (fermium-room-mode)
          (let ((window (selected-window))
                (fermium-helper-program "fermium-test-helper")
                (fermium--process nil)
                (fermium--pending-requests (make-hash-table :test #'eql)))
            (cl-letf (((symbol-function 'process-live-p)
                       (lambda (process)
                         (and process (eq process live-process))))
                      ((symbol-function 'make-process)
                       (lambda (&rest _args)
                         (setq live-process (list :process (cl-incf process-count)))
                         live-process))
                      ((symbol-function 'fermium--request-state)
                       (lambda () nil)))
              (fermium)
              (let ((first-overview (get-buffer fermium--overview-buffer)))
                (should first-overview)
                (fermium)
                (should (eq (get-buffer fermium--overview-buffer)
                            first-overview))
                (kill-buffer first-overview)
                (switch-to-buffer source)
                (fermium-room-overview)
                (setq overview (get-buffer fermium--overview-buffer))
                (should (eq (selected-window) window))
                (should (eq (window-buffer window) overview))
                (should (= process-count 1))
                (should (= 1
                           (cl-count fermium--overview-buffer
                                     (buffer-list)
                                     :key #'buffer-name
                                     :test #'equal)))))))
      (when (buffer-live-p overview)
        (kill-buffer overview))
      (when (buffer-live-p source)
        (kill-buffer source)))))

(ert-deftest fermium-room-overview-is-bound-in-room-buffers ()
  (should (eq (lookup-key fermium-room-mode-map (kbd "C-c o"))
              #'fermium-room-overview))
  (with-temp-buffer
    (fermium-room-mode)
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org")) nil)
    (goto-char (point-min))
    (should (eq (key-binding (kbd "C-c o")) #'fermium-room-overview)))
  (with-temp-buffer
    (fermium-room-mode)
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org")) nil)
    (goto-char fermium-room--input-start)
    (insert "draft")
    (should (eq (overlay-get fermium-room--composition-overlay 'keymap)
                fermium-room-mode-map))
    (should (eq (key-binding (kbd "C-c o")) #'fermium-room-overview))))

(ert-deftest fermium-open-room-preserves-existing-room-image-state ()
  (let ((overview (generate-new-buffer " *Fermium existing room overview*"))
        (room (get-buffer-create "*Fermium: !room:example.org*"))
        image)
    (unwind-protect
        (progn
          (with-current-buffer room
            (fermium-room-mode)
            (setq image (list :test-image))
            (puthash "$image"
                     (list :status 'ready
                           :data "image-data"
                           :type 'png
                           :image image)
                     fermium-room--image-states))
          (with-current-buffer overview
            (fermium-overview-mode)
            (let ((fermium--account "@alice:example.org")
                  (fermium--rooms
                   (list (list (cons "room_id" "!room:example.org")
                               (cons "name" "Example room")))))
              (fermium--render-overview)
              (fermium--overview-goto-property
               'fermium-room-id "!room:example.org")
              (cl-letf (((symbol-function 'fermium--send)
                         (lambda (&rest _args) nil)))
                (fermium-open-room))))
          (with-current-buffer room
            (should (eq (plist-get (gethash "$image" fermium-room--image-states)
                                   :image)
                        image))))
      (when (buffer-live-p room)
        (kill-buffer room))
      (when (buffer-live-p overview)
        (kill-buffer overview)))))

(ert-deftest fermium-reentering-overview-preserves-folded-sections ()
  (let ((source (generate-new-buffer " *Fermium overview reentry source*"))
        overview
        (fermium--accounts
         (list (list (cons "user_id" "@alice:example.org")
                     (cons "rooms"
                           (list (list (cons "room_id" "!room:example.org")
                                       (cons "name" "Example room")))))))
        (fermium--account nil)
        (fermium--rooms nil))
    (unwind-protect
        (progn
          (switch-to-buffer source)
          (cl-letf (((symbol-function 'fermium--ensure-process)
                     (lambda () nil))
                    ((symbol-function 'fermium--request-state)
                     (lambda () nil)))
            (fermium)
            (setq overview (get-buffer fermium--overview-buffer))
            (with-current-buffer overview
              (goto-char (point-min))
              (fermium-toggle-section)
              (should (member '(account "@alice:example.org")
                              fermium--overview-collapsed-sections)))
            (switch-to-buffer source)
            (fermium-room-overview)
            (should (eq (current-buffer) overview))
            (with-current-buffer overview
              (should (member '(account "@alice:example.org")
                              fermium--overview-collapsed-sections))
              (should (invisible-p
                       (save-excursion
                         (fermium--overview-goto-property
                          'fermium-room-id "!room:example.org")
                         (point)))))
            (switch-to-buffer source)
            (fermium)
            (with-current-buffer overview
              (should (member '(account "@alice:example.org")
                              fermium--overview-collapsed-sections)))))
      (when (buffer-live-p overview)
        (kill-buffer overview))
      (when (buffer-live-p source)
        (kill-buffer source)))))

(ert-deftest fermium-reentering-room-preserves-existing-state ()
  (let ((overview (generate-new-buffer " *Fermium room reentry overview*"))
        (room (get-buffer-create
               "*Fermium: Example room / @alice:example.org*"))
        sent)
    (unwind-protect
        (progn
          (with-current-buffer room
            (fermium-room-mode)
            (setq fermium-room--room-id "!room:example.org")
            (setq fermium-room--account-id "@alice:example.org")
            (let ((messages
                   (append
                    (list (list (cons "kind" "channel_event")
                                (cons "event_id" "$join")
                                (cons "body" "Alice joined")
                                (cons "timestamp" 1000))
                          (list (cons "kind" "channel_event")
                                (cons "event_id" "$leave")
                                (cons "body" "Bob left")
                                (cons "timestamp" 2000)))
                    (cl-loop for index from 3 to 20
                             collect (list (cons "event_id"
                                                 (format "$message-%d" index))
                                           (cons "body"
                                                 (format "message %d" index))
                                           (cons "timestamp" (* index 1000)))))))
              (fermium-room--render-room
               (list (cons "room_id" fermium-room--room-id)
                     (cons "name" "Example room"))
               messages))
            (goto-char (point-min))
            (search-forward "Channel events")
            (beginning-of-line)
            (fermium-room-toggle-channel-events)
            (goto-char fermium-room--input-start)
            (insert "draft")
            (should (= 20 (length (fermium-room--history-messages)))))
          (with-current-buffer overview
            (fermium-overview-mode)
            (let ((fermium--accounts
                   (list (list (cons "user_id" "@alice:example.org")
                               (cons "rooms"
                                     (list (list
                                            (cons "room_id"
                                                  "!room:example.org")
                                            (cons "name" "Example room")))))))
                  (fermium--account nil)
                  (fermium--rooms nil))
              (fermium--render-overview)
              (fermium--overview-goto-property
               'fermium-room-id "!room:example.org")
              (cl-letf (((symbol-function 'fermium--send)
                         (lambda (command &rest _args)
                           (push command sent))))
                (fermium-open-room)
                (should (eq (current-buffer) room)))))
          (should-not (member "open_room" sent))
          (with-current-buffer room
            (should-not fermium-room--loading)
            (should (= 20 (length (fermium-room--history-messages))))
            (should (string-match-p "message 20" (buffer-string)))
            (should (string-suffix-p
                     "draft"
                     (buffer-substring-no-properties
                      fermium-room--input-start (point-max))))
            (should (gethash "$join" fermium-room--expanded-channel-events))
            (should-not
             (invisible-p
              (save-excursion
                (goto-char (point-min))
                (search-forward "Alice joined")
                (point))))))
      (when (buffer-live-p room)
        (kill-buffer room))
      (when (buffer-live-p overview)
        (kill-buffer overview)))))

(ert-deftest fermium-overview-navigates-visible-rows-with-n-and-p ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--account "@alice:example.org")
          (fermium--rooms
           (list (list (cons "room_id" "!room:example.org")
                       (cons "name" "Example room")
                       (cons "has_unread" nil)))))
      (fermium--render-overview)
      (goto-char (point-min))
      (should (equal (fermium--overview-current-entity)
                     '(account . "@alice:example.org")))
      (fermium-next)
      (should (equal (fermium--overview-current-row)
                     '(section rooms)))
      (fermium-next)
      (should (equal (fermium--overview-current-entity)
                     '(room . "!room:example.org")))
      (fermium-previous)
      (should (equal (fermium--overview-current-row)
                     '(section rooms)))
      (fermium-previous)
      (should (equal (fermium--overview-current-entity)
                     '(account . "@alice:example.org"))))))

(ert-deftest fermium-overview-displays-dm-member-name ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--account "@alice:example.org")
          (fermium--rooms
           (list (list (cons "room_id" "!dm:example.org")
                       (cons "name" "Bob")
                       (cons "is_dm" t)
                       (cons "members" (list "Bob"))
                       (cons "has_unread" nil)))))
      (fermium--render-overview)
      (should (string-match-p "Bob" (buffer-string)))
      (should-not (string-match-p "Commands:" (buffer-string))))))

(ert-deftest fermium-room-has-writable-composition-tail ()
  (with-temp-buffer
    (fermium-room-mode)
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org"))
     (list (list (cons "sender" "@bob:example.org")
                 (cons "body" "hello")
                 (cons "timestamp" 0))))
    (goto-char (point-min))
    (search-forward "hello")
    (should (get-text-property (1- (point)) 'read-only))
    (goto-char fermium-room--input-start)
    (insert "draft")
    (should (equal (buffer-substring-no-properties
                   fermium-room--input-start (point-max))
                   "draft"))))

(ert-deftest fermium-room-suppresses-line-numbers-even-after-global-activation ()
  (with-temp-buffer
    (fermium-room-mode)
    (display-line-numbers-mode 1)
    (should-not display-line-numbers-mode)
    (should-not display-line-numbers)))

(ert-deftest fermium-room-folds-account-and-matrix-id-header-details ()
  (with-temp-buffer
    (fermium-room-mode)
    (setq fermium-room--account-id "@alice:example.org")
    (setq fermium-room--room-id "!room:example.org")
    (fermium-room--render-room
     (list (cons "room_id" fermium-room--room-id)
           (cons "name" "Example room"))
     nil)
    (should-not fermium-room--header-expanded)
    (let ((header (fermium-room--header-line)))
      (should (equal header "▸ Example room"))
      (should (eq (get-text-property 0 'fermium-room-header header)
                  t))
      (should (eq (lookup-key (get-text-property 0 'local-map header)
                            [header-line mouse-1])
                  #'fermium-room--mouse-toggle-header))
      (should (eq (lookup-key (get-text-property 0 'local-map header)
                            [header-line mouse-2])
                  #'fermium-room--mouse-toggle-header))
      (should (eq (lookup-key (get-text-property 0 'local-map header)
                            (kbd "TAB"))
                  #'fermium-room-toggle-header))
      (should (eq (get-text-property 0 'mouse-face header)
                  'highlight))
      (should (get-text-property 0 'follow-link header))
      (should-not (string-match-p "Account:" header))
      (should-not (string-match-p "Matrix ID:" header)))
    (fermium-room-toggle-header)
    (should fermium-room--header-expanded)
    (let* ((header (fermium-room--header-line))
           (account-label (string-match "Account:" header))
           (account-value (string-match "@alice:example.org" header))
           (matrix-label (string-match "Matrix ID:" header))
           (matrix-value (string-match "!room:example.org" header)))
      (should (equal header
                     "▾ Example room\n  Account: @alice:example.org\n  Matrix ID: !room:example.org"))
      (should (eq (get-text-property account-label 'face header)
                  'fermium-room-header-label-face))
      (should (eq (get-text-property account-value 'face header)
                  'fermium-room-sender-self-face))
      (should (eq (get-text-property matrix-label 'face header)
                  'fermium-room-header-label-face))
      (should (eq (get-text-property matrix-value 'face header)
                  'fermium-room-header-other-face))
      (should (get-text-property account-label 'fermium-room-header-details
                                 header))
      (should (eq (lookup-key (get-text-property 0 'local-map header)
                              [header-line mouse-2])
                  #'fermium-room--mouse-toggle-header))
      (fermium-room-toggle-header)
      (should-not fermium-room--header-expanded)
      (should (equal (fermium-room--header-line) "▸ Example room")))))

(ert-deftest fermium-room-graphical-header-is-multi-line ()
  (skip-unless (and (require 'svg nil t)
                    (image-type-available-p 'svg)))
  (let ((buffer (generate-new-buffer " *fermium-svg-header-test*")))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (fermium-room-mode)
          (setq fermium-room--room-title "Example room"
                fermium-room--account-id "@alice:example.org"
                fermium-room--room-id "!room:example.org"
                fermium-room--header-expanded t)
          (cl-letf (((symbol-function 'display-graphic-p)
                     (lambda (&optional _frame) t)))
            (let* ((header (fermium-room--header-line))
                   (display (get-text-property 0 'display header))
                   (data (plist-get (cdr display) :data)))
              (should (equal (plist-get (cdr display) :type) 'svg))
              (should (= (1- (length (split-string data "<text" t))) 3))
              (should (eq (get-text-property 0 'fermium-room-header header)
                          t)))))
      (kill-buffer buffer))))

(ert-deftest fermium-room-buffer-name-uses-the-resolved-room-title ()
  (with-temp-buffer
    (fermium-room-mode)
    (setq fermium-room--account-id "@alice:example.org")
    (setq fermium-room--room-id "!room:example.org")
    (fermium-room--render-loading-room fermium-room--room-id nil)
    (should (equal (buffer-name)
                   "*Fermium: !room:example.org / @alice:example.org*"))
    (setq fermium-room--room-title "Example room")
    (fermium-room--rename-buffer fermium-room--room-title)
    (fermium-room--update-header-title fermium-room--room-title)
    (should (equal (buffer-name)
                   "*Fermium: Example room / @alice:example.org*"))
    (should (equal (fermium-room--header-line) "▸ Example room"))
    (should-not (string-match-p "Example room" (buffer-string)))))

(ert-deftest fermium-room-seeds-latest-message-while-history-loads ()
  (with-temp-buffer
    (fermium-room-mode)
    (setq fermium-room--loading t)
    (fermium-room--render-loading-room
     "Example room"
     (list (cons "event_id" "$latest")
           (cons "sender" "@bob:example.org")
           (cons "body" "latest preview")
           (cons "timestamp" 2000)))
    (should (string-match-p "Loading history" (fermium-room--header-line)))
    (should (string-match-p "latest preview" (buffer-string)))
    (should (string-match-p "Composition" (buffer-string)))
    (goto-char fermium-room--input-start)
    (insert "draft")
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org")
           (cons "name" "Example room"))
     nil)
    (should (= 1 (how-many "latest preview" (point-min) (point-max))))
    (should (string-suffix-p "draft"
                             (buffer-substring-no-properties
                              fermium-room--input-start (point-max))))
    (should (= (point) (point-max)))))

(ert-deftest fermium-room-marks-the-visible-latest-message-read-once ()
  (save-window-excursion
    (let ((buffer (get-buffer-create " *Fermium room read test*")) sent)
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (fermium-room-mode)
            (setq fermium-room--account-id "@alice:example.org")
            (setq fermium-room--room-id "!room:example.org")
            (fermium-room--render-room
             (list (cons "room_id" fermium-room--room-id))
             (list (list (cons "event_id" "$latest")
                         (cons "sender" "@bob:example.org")
                         (cons "body" "latest")
                         (cons "timestamp" 1000))))
            (cl-letf (((symbol-function 'frame-focus-state)
                       (lambda (&optional _frame) t))
                      ((symbol-function 'fermium--send)
                       (lambda (command payload _callback)
                         (push (list command payload) sent))))
              (fermium-room--maybe-mark-latest-message-read)
              (fermium-room--maybe-mark-latest-message-read))
            (should (equal sent
                           (list
                            (list "mark_room_read"
                                  (list (cons "account" "@alice:example.org")
                                        (cons "room_id" "!room:example.org")
                                        (cons "event_id" "$latest")))))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest fermium-room-does-not-mark-without-frame-focus ()
  (save-window-excursion
    (let ((buffer (get-buffer-create " *Fermium room unfocused read test*"))
          sent)
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (fermium-room-mode)
            (setq fermium-room--account-id "@alice:example.org")
            (setq fermium-room--room-id "!room:example.org")
            (fermium-room--render-room
             (list (cons "room_id" fermium-room--room-id))
             (list (list (cons "event_id" "$latest")
                         (cons "sender" "@bob:example.org")
                         (cons "body" "latest")
                         (cons "timestamp" 1000))))
            (cl-letf (((symbol-function 'frame-focus-state)
                       (lambda (&optional _frame) nil))
                      ((symbol-function 'fermium--send)
                       (lambda (&rest args) (setq sent args))))
              (fermium-room--maybe-mark-latest-message-read))
            (should-not sent))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest fermium-room-does-not-mark-without-a-window ()
  (let (sent)
    (with-temp-buffer
      (fermium-room-mode)
      (setq fermium-room--account-id "@alice:example.org")
      (setq fermium-room--room-id "!room:example.org")
      (fermium-room--render-room
       (list (cons "room_id" fermium-room--room-id))
       (list (list (cons "event_id" "$latest")
                   (cons "sender" "@bob:example.org")
                   (cons "body" "latest")
                   (cons "timestamp" 1000))))
      (cl-letf (((symbol-function 'frame-focus-state)
                 (lambda (&optional _frame) t))
                ((symbol-function 'fermium--send)
                 (lambda (&rest args) (setq sent args))))
        (fermium-room--maybe-mark-latest-message-read)))
    (should-not sent)))

(ert-deftest fermium-room-retries-after-focus-returns ()
  (save-window-excursion
    (let ((buffer (get-buffer-create " *Fermium room focus retry test*"))
          sent)
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (fermium-room-mode)
            (setq fermium-room--account-id "@alice:example.org")
            (setq fermium-room--room-id "!room:example.org")
            (fermium-room--render-room
             (list (cons "room_id" fermium-room--room-id))
             (list (list (cons "event_id" "$latest")
                         (cons "sender" "@bob:example.org")
                         (cons "body" "latest")
                         (cons "timestamp" 1000))))
            (cl-letf (((symbol-function 'frame-focus-state)
                       (lambda (&optional _frame) t))
                      ((symbol-function 'fermium--send)
                       (lambda (&rest args) (setq sent args))))
              (fermium--after-focus-change))
            (should sent))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest fermium-room-does-not-mark-in-a-non-selected-window ()
  (save-window-excursion
    (let ((room (get-buffer-create " *Fermium room non-selected read test*"))
          (other (get-buffer-create " *Fermium room other window test*"))
          sent)
      (unwind-protect
          (progn
            (switch-to-buffer other)
            (let ((room-window (split-window-right)))
              (with-current-buffer room
                (fermium-room-mode)
                (setq fermium-room--account-id "@alice:example.org")
                (setq fermium-room--room-id "!room:example.org")
                (fermium-room--render-room
                 (list (cons "room_id" fermium-room--room-id))
                 (list (list (cons "event_id" "$latest")
                             (cons "sender" "@bob:example.org")
                             (cons "body" "latest")
                             (cons "timestamp" 1000))))
                (set-window-buffer room-window room))
              (cl-letf (((symbol-function 'frame-focus-state)
                         (lambda (&optional _frame) t))
                        ((symbol-function 'fermium--send)
                         (lambda (&rest args) (setq sent args))))
                (with-current-buffer room
                  (fermium-room--maybe-mark-latest-message-read)))
              (should-not sent)))
        (when (buffer-live-p room)
          (kill-buffer room))
        (when (buffer-live-p other)
          (kill-buffer other))))))

(ert-deftest fermium-room-loading-indicator-uses-animation-frame ()
  (with-temp-buffer
    (fermium-room-mode)
    (setq fermium-room--loading t)
    (let ((fermium--loading-frame 3))
      (fermium-room--render-loading-room "Example room" nil)
      (should (string-match-p (regexp-quote "Loading history...")
                              (fermium-room--header-line)))
      (should (= (point) (point-max)))
      (fermium-room--render-loading-indicator)
      (should (= (point) (point-max))))))

(ert-deftest fermium-room-finishing-without-loading-marker-is-safe ()
  (with-temp-buffer
    (fermium-room-mode)
    (should-not
     (condition-case error
         (progn
           (fermium-room--finish-loading)
           nil)
       (error error)))))

(ert-deftest fermium-room-merges-seeded-message-with-history-in-order ()
  (with-temp-buffer
    (fermium-room-mode)
    (setq fermium-room--loading t)
    (fermium-room--render-loading-room
     "Example room"
     (list (cons "event_id" "$latest")
           (cons "sender" "@bob:example.org")
           (cons "body" "latest")
           (cons "timestamp" 3000)))
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org")
           (cons "name" "Example room"))
     (list (list (cons "event_id" "$earliest")
                 (cons "sender" "@bob:example.org")
                 (cons "body" "earliest")
                 (cons "timestamp" 1000))
           (list (cons "event_id" "$latest")
                 (cons "sender" "@bob:example.org")
                 (cons "body" "latest")
                 (cons "timestamp" 3000))))
    (should (= 1 (how-many "latest" (point-min) (point-max))))
    (should (< (string-match "earliest" (buffer-string))
               (string-match "latest" (buffer-string))))))

(ert-deftest fermium-room-message-event-inserts-before-composition ()
  (let ((buffer (get-buffer-create "*Fermium: !room:example.org*")))
    (unwind-protect
        (with-current-buffer buffer
          (fermium-room-mode)
          (setq fermium-room--room-id "!room:example.org")
          (fermium-room--render-room
           (list (cons "room_id" "!room:example.org")) nil)
          (goto-char fermium-room--input-start)
          (insert "draft")
          (fermium--handle-message-event
           (list (cons "room_id" "!room:example.org")
                 (cons "message"
                       (list (cons "sender" "@bob:example.org")
                             (cons "body" "incoming")
                             (cons "timestamp" 0)))))
          (should (string-match-p "incoming" (buffer-string)))
          (should (< (string-match "incoming" (buffer-string))
                     (string-match "Composition" (buffer-string))))
          (should (string-suffix-p "draft"
                                   (buffer-substring-no-properties
                                    fermium-room--input-start (point-max))))
          (should (= (point) (point-max))))
      (kill-buffer buffer))))

(ert-deftest fermium-room-update-preserves-a-history-point ()
  (let ((buffer (get-buffer-create "*Fermium: !room:example.org*")))
    (unwind-protect
        (with-current-buffer buffer
          (fermium-room-mode)
          (setq fermium-room--room-id "!room:example.org")
          (fermium-room--render-room
           (list (cons "room_id" "!room:example.org"))
           (list (list (cons "event_id" "$first")
                       (cons "sender" "@bob:example.org")
                       (cons "body" "first")
                       (cons "timestamp" 1000))))
          (goto-char (point-min))
          (search-forward "first")
          (beginning-of-line)
          (fermium--handle-message-event
           (list (cons "room_id" "!room:example.org")
                 (cons "message"
                       (list (cons "event_id" "$second")
                             (cons "sender" "@bob:example.org")
                             (cons "body" "second")
                             (cons "timestamp" 500)))))
          (should (equal (get-text-property
                          (point) 'fermium-room-message-key)
                         "$first"))
          (should (string-match-p
                   "first"
                   (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position)))))
      (kill-buffer buffer))))

(ert-deftest fermium-room-update-pins-composition-scroll-to-bottom ()
  (save-window-excursion
    (let ((buffer (get-buffer-create " *Fermium room composition scroll test*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (fermium-room-mode)
            (setq fermium-room--room-id "!room:example.org")
            (fermium-room--render-room
             (list (cons "room_id" "!room:example.org"))
             (mapcar
              (lambda (number)
                (list (cons "event_id" (format "$%d" number))
                      (cons "sender" "@bob:example.org")
                      (cons "body" (format "history message %d" number))
                      (cons "timestamp" number)))
              (number-sequence 1 40)))
            (set-window-start (selected-window) (point-min))
            (redisplay)
            (goto-char (point-max))
            (fermium--handle-message-event
             (list (cons "room_id" "!room:example.org")
                   (cons "message"
                         (list (cons "event_id" "$latest")
                               (cons "sender" "@bob:example.org")
                               (cons "body" "history message latest")
                               (cons "timestamp" 41)))))
            (should (= (point) (point-max)))
            (should (> (window-start) (point-min)))
            ;; The converse: a reader is not dragged along.  With point back
            ;; in the history, a message arriving has to leave the scroll
            ;; where it is, or reading is interrupted every time the room
            ;; moves.
            (goto-char (point-min))
            (set-window-start (selected-window) (point-min))
            (redisplay)
            (let ((scroll-start (window-start)))
              (fermium--handle-message-event
               (list (cons "room_id" "!room:example.org")
                     (cons "message"
                           (list (cons "event_id" "$later")
                                 (cons "sender" "@bob:example.org")
                                 (cons "body" "history message later")
                                 (cons "timestamp" 42)))))
              (should (= (window-start) scroll-start))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest fermium-room-update-keeps-a-window-inside-a-rewritten-section ()
  (save-window-excursion
    (let ((buffer (get-buffer-create " *Fermium room section scroll test*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (fermium-room-mode)
            (setq fermium-room--room-id "!room:example.org")
            (fermium-room--render-room
             (list (cons "room_id" "!room:example.org"))
             (cl-loop for index from 1 to 60
                      collect (list (cons "kind" "channel_event")
                                    (cons "event_id" (format "$c%d" index))
                                    (cons "body" (format "event number %d" index))
                                    (cons "timestamp" (* index 1000)))))
            (goto-char (point-min))
            (search-forward "Channel events")
            (beginning-of-line)
            (fermium-room-toggle-channel-events)
            (goto-char (point-min))
            (search-forward "event number 30")
            (beginning-of-line)
            (set-window-start (selected-window) (point))
            (redisplay)
            (let ((line (fermium-test--window-start-line)))
              ;; The arriving event restates the whole run, and the window
              ;; started inside the text that replaces.  Emacs collapses a
              ;; window start there to where the replacement began, so the
              ;; reader has to be carried across by what they were reading.
              (fermium--handle-message-event
               (list (cons "room_id" "!room:example.org")
                     (cons "message"
                           (list (cons "kind" "channel_event")
                                 (cons "event_id" "$c61")
                                 (cons "body" "event number 61")
                                 (cons "timestamp" 61000)))))
              (should (equal line (fermium-test--window-start-line)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest fermium-room-toggling-the-first-section-keeps-it-protected ()
  (with-temp-buffer
    (fermium-test--seed-room '(("$join" 1000 channel) ("$hi" 2000)))
    ;; The fold arrow is the first character the section prints, so toggling
    ;; a section that opens the room rewrites `point-min' and has to make it
    ;; front-sticky again, exactly as any other edit to the first message.
    (goto-char (point-min))
    (fermium-room-toggle-channel-events)
    (should (equal (get-text-property (point-min) 'front-sticky)
                   '(read-only keymap)))
    (should (eq 'caught
                (condition-case nil
                    (progn (goto-char (point-min)) (insert "x") 'inserted)
                  (text-read-only 'caught))))))

(ert-deftest fermium-room-loading-animation-restates-every-placeholder ()
  (with-temp-buffer
    (fermium-room-mode)
    (setq fermium-room--room-id "!room:example.org")
    (dotimes (index 20)
      (puthash (format "$img%d" index) (list :status 'loading)
               fermium-room--image-states))
    (let ((fermium--loading-frame 1))
      (fermium-room--render-room
       (list (cons "room_id" "!room:example.org"))
       (cl-loop for index from 0 below 20
                collect (fermium-test--image-message index))))
    (should (= 20 (how-many "^\\.$" (point-min) (point-max))))
    ;; A longer frame grows every placeholder, and so the history under
    ;; them.  A pass bounded by a position taken before it started would
    ;; stop short and leave the last placeholders on the previous frame.
    (let ((fermium--loading-frame 3))
      (fermium-room--render-loading-images))
    (should (= 20 (how-many "^\\.\\.\\.$" (point-min) (point-max))))
    (should (= 0 (how-many "^\\.$" (point-min) (point-max))))))

(ert-deftest fermium-room-update-pins-an-inactive-composition-window ()
  (save-window-excursion
    (let ((room (get-buffer-create " *Fermium inactive composition scroll test*"))
          (other (get-buffer-create " *Fermium inactive composition other*")))
      (unwind-protect
          (progn
            (switch-to-buffer other)
            (let ((room-window (split-window-right)))
              (with-current-buffer room
                (fermium-room-mode)
                (setq fermium-room--room-id "!room:example.org")
                (fermium-room--render-room
                 (list (cons "room_id" "!room:example.org"))
                 (mapcar
                  (lambda (number)
                    (list (cons "event_id" (format "$%d" number))
                          (cons "sender" "@bob:example.org")
                          (cons "body" (format "history message %d" number))
                          (cons "timestamp" number)))
                  (number-sequence 1 40)))
                (goto-char (point-max)))
              (set-window-buffer room-window room)
              (set-window-start room-window (with-current-buffer room
                                               (point-min)))
              (set-window-point room-window (with-current-buffer room
                                               (point-max)))
              (redisplay)
              (with-current-buffer room
                (fermium--handle-message-event
                 (list (cons "room_id" "!room:example.org")
                       (cons "message"
                             (list (cons "event_id" "$latest")
                                   (cons "sender" "@bob:example.org")
                                   (cons "body" "history message latest")
                                   (cons "timestamp" 41)))))
                (should (> (window-start room-window) (point-min))))))
        (when (buffer-live-p room)
          (kill-buffer room))
        (when (buffer-live-p other)
          (kill-buffer other))))))

(ert-deftest fermium-room-update-pins-composition-after-tab-switch ()
  (require 'tab-bar)
  (save-window-excursion
    (let ((room (get-buffer-create " *Fermium tab composition scroll test*"))
          (other (get-buffer-create " *Fermium tab composition other*")))
      (unwind-protect
          (progn
            (tab-bar-mode 1)
            (switch-to-buffer room)
            (fermium-room-mode)
            (setq fermium-room--room-id "!room:example.org")
            (fermium-room--render-room
             (list (cons "room_id" "!room:example.org"))
             (mapcar
              (lambda (number)
                (list (cons "event_id" (format "$%d" number))
                      (cons "sender" "@bob:example.org")
                      (cons "body" (format "history message %d" number))
                      (cons "timestamp" number)))
              (number-sequence 1 40)))
            (goto-char (point-max))
            (set-window-start (selected-window) (point-min))
            (redisplay)
            (tab-bar-new-tab)
            (switch-to-buffer other)
            (with-current-buffer room
              (fermium--handle-message-event
               (list (cons "room_id" "!room:example.org")
                     (cons "message"
                           (list (cons "event_id" "$latest")
                                 (cons "sender" "@bob:example.org")
                                 (cons "body" "history message latest")
                                 (cons "timestamp" 41))))))
            (tab-bar-select-tab 1)
            (redisplay)
            (should (> (window-start) (point-min))))
        (tab-bar-select-tab 1)
        (when (fboundp 'tab-bar-mode)
          (tab-bar-mode -1))
        (when (buffer-live-p room)
          (kill-buffer room))
        (when (buffer-live-p other)
          (kill-buffer other))))))

(ert-deftest fermium-room-update-pins-unfocused-room-window-after-tab-switch ()
  (require 'tab-bar)
  (save-window-excursion
    (let ((room (get-buffer-create " *Fermium unfocused tab room*"))
          (other (get-buffer-create " *Fermium unfocused tab other*"))
          (second-tab (get-buffer-create " *Fermium unfocused tab second*")))
      (unwind-protect
          (progn
            (tab-bar-mode 1)
            (switch-to-buffer other)
            (let ((room-window (split-window-right)))
              (with-current-buffer room
                (fermium-room-mode)
                (setq fermium-room--room-id "!room:example.org")
                (fermium-room--render-room
                 (list (cons "room_id" "!room:example.org"))
                 (mapcar
                  (lambda (number)
                    (list (cons "event_id" (format "$%d" number))
                          (cons "sender" "@bob:example.org")
                          (cons "body" (format "history message %d" number))
                          (cons "timestamp" number)))
                  (number-sequence 1 40)))
                (goto-char (point-max)))
              (set-window-buffer room-window room)
              (set-window-point room-window (with-current-buffer room
                                               (point-max)))
              (set-window-start room-window (with-current-buffer room
                                               (point-min)))
              ;; Keep the other window selected when saving the tab.
              (select-window (get-buffer-window other)))
            (tab-bar-new-tab)
            (switch-to-buffer second-tab)
            (with-current-buffer room
              (fermium--handle-message-event
               (list (cons "room_id" "!room:example.org")
                     (cons "message"
                           (list (cons "event_id" "$latest")
                                 (cons "sender" "@bob:example.org")
                                 (cons "body" "history message latest")
                                 (cons "timestamp" 41))))))
            (tab-bar-select-tab 1)
            (redisplay)
            (let ((room-window (get-buffer-window room nil)))
              (should room-window)
              (should-not (eq room-window (selected-window)))
              (should (> (window-start room-window) (point-min)))))
        (tab-bar-select-tab 1)
        (when (fboundp 'tab-bar-mode)
          (tab-bar-mode -1))
        (when (buffer-live-p room)
          (kill-buffer room))
        (when (buffer-live-p other)
          (kill-buffer other))
        (when (buffer-live-p second-tab)
          (kill-buffer second-tab))))))

(ert-deftest fermium-room-queues-messages-while-history-loads ()
  (let ((buffer (get-buffer-create "*Fermium: !loading:example.org*")))
    (unwind-protect
        (with-current-buffer buffer
          (fermium-room-mode)
          (setq fermium-room--room-id "!loading:example.org")
          (setq fermium-room--loading t)
          (fermium-room--render-loading-room fermium-room--room-id nil)
          (fermium--handle-message-event
           (list (cons "room_id" fermium-room--room-id)
                 (cons "message"
                       (list (cons "event_id" "$queued")
                             (cons "sender" "@bob:example.org")
                             (cons "body" "queued")
                             (cons "timestamp" 0)))))
          (should (= 1 (length fermium-room--pending-messages)))
          (fermium-room--render-room
           (list (cons "room_id" fermium-room--room-id)) nil)
          (should-not fermium-room--pending-messages)
          (should (string-match-p "queued" (buffer-string))))
      (kill-buffer buffer))))

(ert-deftest fermium-room-does-not-duplicate-history-and-live-event ()
  (with-temp-buffer
    (fermium-room-mode)
    (let ((message (list (cons "event_id" "$same")
                         (cons "sender" "@bob:example.org")
                         (cons "body" "once")
                         (cons "timestamp" 0))))
      (fermium-room--render-room
       (list (cons "room_id" "!room:example.org"))
       (list message))
      (fermium--handle-message-event
       (list (cons "room_id" "!room:example.org")
             (cons "message" message)))
      (should (= 1 (how-many "once" (point-min) (point-max)))))))

(ert-deftest fermium-room-live-message-does-not-rebuild-the-history ()
  (let ((buffer (get-buffer-create "*Fermium: !room:example.org*")))
    (unwind-protect
        (with-current-buffer buffer
          (fermium-room-mode)
          (setq fermium-room--room-id "!room:example.org")
          (fermium-room--render-room
           (list (cons "room_id" "!room:example.org"))
           (list (list (cons "event_id" "$first")
                       (cons "sender" "@bob:example.org")
                       (cons "body" "first")
                       (cons "timestamp" 1000))))
          (let ((node (fermium-room--node-for-key "$first")))
            (dolist (event '(("$second" "second" 2000)
                             ("$third" "third" 3000)))
              (fermium--handle-message-event
               (list (cons "room_id" "!room:example.org")
                     (cons "message"
                           (list (cons "event_id" (nth 0 event))
                                 (cons "sender" "@bob:example.org")
                                 (cons "body" (nth 1 event))
                                 (cons "timestamp" (nth 2 event)))))))
            ;; Appending a message must not tear down and re-insert the rest
            ;; of the history: the node rendering the first message is still
            ;; the one that was rendering it.
            (should (eq node (fermium-room--node-for-key "$first"))))
          (let ((text (buffer-string)))
            (should (< (string-match "first" text)
                       (string-match "second" text)))
            (should (< (string-match "second" text)
                       (string-match "third" text))))
          ;; Repeated appends have to keep landing inside the read-only
          ;; history rather than drifting into the composition, which means
          ;; the history end marker advanced with each one.
          (dolist (key '("$second" "$third"))
            (let ((position (fermium-room--message-position key)))
              (should position)
              (should (get-text-property position 'read-only))
              (should (< position
                         (marker-position fermium-room--input-start))))))
      (kill-buffer buffer))))

(ert-deftest fermium-room-live-channel-event-joins-the-folded-section ()
  (let ((buffer (get-buffer-create "*Fermium: !room:example.org*")))
    (unwind-protect
        (with-current-buffer buffer
          (fermium-room-mode)
          (setq fermium-room--room-id "!room:example.org")
          (fermium-room--render-room
           (list (cons "room_id" "!room:example.org"))
           ;; An ordinary message ahead of the section, so a room that
           ;; rebuilt itself would render more than the section alone.
           (list (list (cons "event_id" "$hello")
                       (cons "sender" "@bob:example.org")
                       (cons "body" "hello")
                       (cons "timestamp" 500))
                 (list (cons "kind" "channel_event")
                       (cons "event_id" "$join")
                       (cons "body" "Alice joined")
                       (cons "timestamp" 1000))))
          (should (string-match-p "Channel events (1)" (buffer-string)))
          ;; Restating the one section the event joins is enough: it is the
          ;; only unit of history the room renders again.
          (should (= 1 (fermium-test--rendered-units
                        (lambda ()
                          (fermium--handle-message-event
                           (list (cons "room_id" "!room:example.org")
                                 (cons "message"
                                       (list (cons "kind" "channel_event")
                                             (cons "event_id" "$leave")
                                             (cons "body" "Bob left")
                                             (cons "timestamp" 2000)))))))))
          ;; The event folds into the section already on screen instead of
          ;; opening a second one, and that section keeps the identity of its
          ;; first event so its expansion state stays addressable.
          (should (= 1 (how-many "Channel events" (point-min) (point-max))))
          (should (string-match-p "Channel events (2)" (buffer-string)))
          (should (string-match-p "Bob left" (buffer-string)))
          (goto-char (point-min))
          (search-forward "Channel events")
          (beginning-of-line)
          (should (equal (get-text-property
                          (point) 'fermium-room-channel-events-id)
                         "$join")))
      (kill-buffer buffer))))

(ert-deftest fermium-room-live-channel-event-keeps-the-section-expanded ()
  (let ((buffer (get-buffer-create "*Fermium: !room:example.org*")))
    (unwind-protect
        (with-current-buffer buffer
          (fermium-room-mode)
          (setq fermium-room--room-id "!room:example.org")
          (fermium-room--render-room
           (list (cons "room_id" "!room:example.org"))
           (list (list (cons "kind" "channel_event")
                       (cons "event_id" "$join")
                       (cons "body" "Alice joined")
                       (cons "timestamp" 1000))))
          (goto-char (point-min))
          (search-forward "Channel events")
          (beginning-of-line)
          (fermium-room-toggle-channel-events)
          (should-not (invisible-p (save-excursion (forward-line 1) (point))))
          (fermium--handle-message-event
           (list (cons "room_id" "!room:example.org")
                 (cons "message"
                       (list (cons "kind" "channel_event")
                             (cons "event_id" "$leave")
                             (cons "body" "Bob left")
                             (cons "timestamp" 2000)))))
          (goto-char (point-min))
          (search-forward "Channel events")
          (beginning-of-line)
          (should (string-match-p "▾" (buffer-string)))
          (should-not (invisible-p (save-excursion (forward-line 1) (point)))))
      (kill-buffer buffer))))

(ert-deftest fermium-room-out-of-order-channel-event-can-open-its-run ()
  (let ((buffer (get-buffer-create "*Fermium: !room:example.org*"))
        (earliest (list (cons "kind" "channel_event")
                        (cons "event_id" "$create")
                        (cons "body" "Alice created the room")
                        (cons "timestamp" 500)))
        (joined (list (cons "kind" "channel_event")
                      (cons "event_id" "$join")
                      (cons "body" "Alice joined")
                      (cons "timestamp" 1000)))
        (left (list (cons "kind" "channel_event")
                    (cons "event_id" "$leave")
                    (cons "body" "Bob left")
                    (cons "timestamp" 3000))))
    (unwind-protect
        (with-current-buffer buffer
          (fermium-room-mode)
          (setq fermium-room--room-id "!room:example.org")
          (fermium-room--render-room
           (list (cons "room_id" "!room:example.org"))
           (list joined left))
          (fermium--handle-message-event
           (list (cons "room_id" "!room:example.org")
                 (cons "message" earliest)))
          ;; The arriving event becomes the run's first, which is what the
          ;; section is keyed on, so the section changes identity.  The
          ;; incremental path has to agree with a render from scratch.
          (should (= 1 (how-many "Channel events" (point-min) (point-max))))
          (goto-char (point-min))
          (search-forward "Channel events")
          (beginning-of-line)
          (should (equal (get-text-property
                          (point) 'fermium-room-channel-events-id)
                         "$create"))
          (should (equal (fermium-test--history-text)
                         (fermium-test--full-render
                          (list earliest joined left)))))
      (kill-buffer buffer))))

(ert-deftest fermium-room-equal-timestamps-render-in-history-order ()
  (let ((buffer (get-buffer-create "*Fermium: !room:example.org*"))
        (existing (list (cons "event_id" "$existing")
                        (cons "sender" "@bob:example.org")
                        (cons "body" "existing")
                        (cons "timestamp" 1000)))
        (tied (list (cons "event_id" "$tied")
                    (cons "sender" "@bob:example.org")
                    (cons "body" "tied")
                    (cons "timestamp" 1000))))
    (unwind-protect
        (with-current-buffer buffer
          (fermium-room-mode)
          (setq fermium-room--room-id "!room:example.org")
          (fermium-room--render-room
           (list (cons "room_id" "!room:example.org"))
           (list existing))
          (fermium--handle-message-event
           (list (cons "room_id" "!room:example.org")
                 (cons "message" tied)))
          ;; Two events can share a timestamp.  Wherever the arriving one is
          ;; placed, the buffer and the history have to agree, or the room
          ;; reshuffles the next time it is rendered in full.
          (should (equal (fermium-test--rendered-keys)
                         (fermium-test--history-keys)))
          (should (equal (fermium-test--rendered-keys)
                         '("$existing" "$tied")))
          (should (equal (fermium-test--history-text)
                         (fermium-test--rerendered-history))))
      (kill-buffer buffer))))

(ert-deftest fermium-room-message-lookup-finds-every-rendered-message ()
  (with-temp-buffer
    (let ((specs nil))
      ;; Alternate plain messages and runs of channel events, so the lookup
      ;; has to reach events folded inside a section as well as ordinary
      ;; messages standing on their own.
      (dotimes (i 40)
        (push (list (format "$m%d" i) (* (1+ i) 10)) specs)
        (push (list (format "$c%da" i) (+ (* (1+ i) 10) 1) 'channel) specs)
        (push (list (format "$c%db" i) (+ (* (1+ i) 10) 2) 'channel) specs))
      (setq specs (nreverse specs))
      (fermium-test--seed-room specs)
      (let ((previous (point-min)))
        (dolist (spec specs)
          (let ((region (fermium-room--message-region (nth 0 spec))))
            ;; Every message is found, at text that is its own, and the
            ;; regions follow the order the history is in without overlap.
            (should region)
            (should (<= previous (car region)))
            (should (< (car region) (cdr region)))
            (should (equal (get-text-property (car region)
                                              'fermium-room-message-key)
                           (nth 0 spec)))
            (setq previous (cdr region)))))
      ;; A key that is not rendered is reported missing.
      (should-not (fermium-room--message-region "$absent")))))

(defconst fermium-test--incremental-cases
  ;; label, messages the room starts with, messages delivered one at a time.
  '(("a message arriving after the last one"
     (("$a" 1000)) (("$b" 2000)))
    ("a message arriving before the first one"
     (("$b" 2000)) (("$a" 1000)))
    ("a message arriving between two messages"
     (("$a" 1000) ("$c" 3000)) (("$b" 2000)))
    ("a channel event opening a folded run"
     (("$b" 2000 channel) ("$c" 3000 channel)) (("$a" 1000 channel)))
    ("a channel event landing inside a folded run"
     (("$a" 1000 channel) ("$c" 3000 channel)) (("$b" 2000 channel)))
    ("a channel event extending a folded run"
     (("$a" 1000 channel) ("$b" 2000 channel)) (("$c" 3000 channel)))
    ("a channel event with no run to join"
     (("$a" 1000)) (("$b" 2000 channel)))
    ("a message splitting a folded run in two"
     (("$a" 1000 channel) ("$c" 3000 channel)) (("$b" 2000)))
    ("a message arriving before a folded run"
     (("$b" 2000 channel) ("$c" 3000 channel)) (("$a" 1000)))
    ("a message arriving after a folded run"
     (("$a" 1000 channel) ("$b" 2000 channel)) (("$c" 3000)))
    ("a run growing on both sides of a message"
     (("$a" 1000 channel) ("$d" 4000 channel)) (("$b" 2000) ("$c" 3000 channel)))
    ("two messages sharing a timestamp"
     (("$a" 1000)) (("$b" 1000)))
    ("two channel events sharing a timestamp"
     (("$a" 1000 channel)) (("$b" 1000 channel)))
    ("an event repeated at the same time"
     (("$a" 1000)) (("$a" 1000)))
    ("an echo correcting its own time in place"
     (("$a" 1000) ("$b" 5000)) (("$b" 4000)))
    ("an echo corrected while between two runs"
     (("$a" 1000 channel) ("$b" 2000) ("$c" 3000 channel)) (("$b" 2500)))
    ("an echo corrected out from between two runs"
     (("$a" 1000 channel) ("$b" 2000) ("$c" 3000 channel)) (("$b" 4000)))
    ("an echo corrected back past a folded run"
     (("$a" 1000 channel) ("$b" 2000) ("$c" 3000 channel)) (("$b" 500)))
    ("an echo corrected past another message"
     (("$a" 1000) ("$b" 2000) ("$c" 3000)) (("$c" 1500))))
  "Ways a message can reach a room that is already on screen.")

(ert-deftest fermium-room-incremental-updates-match-a-full-render ()
  (dolist (case fermium-test--incremental-cases)
    (let ((label (nth 0 case))
          (buffer (get-buffer-create "*Fermium: !room:example.org*")))
      (ert-info (label)
        (unwind-protect
            (with-current-buffer buffer
              (fermium-test--seed-room (nth 1 case))
              ;; Whatever arrives, the room ends up in the order the history
              ;; is in and reads exactly as a render of that history from
              ;; scratch would.
              (fermium-test--deliver (nth 2 case))
              (should (equal (fermium-test--rendered-keys)
                             (fermium-test--history-keys)))
              (should (equal (fermium-test--history-text)
                             (fermium-test--rerendered-history))))
          (kill-buffer buffer))))))

(ert-deftest fermium-room-incremental-update-renders-only-what-it-touches ()
  (dolist (case fermium-test--incremental-cases)
    (let* ((label (nth 0 case))
           ;; A tail of unrelated messages, all older than anything a case
           ;; delivers, so a room that rebuilds itself renders far more than
           ;; one that updates in place.
           (ballast (cl-loop for index from 1 to 40
                             collect (list (format "$ballast%d" index)
                                           (- (* index 10) 10000))))
           (buffer (get-buffer-create "*Fermium: !room:example.org*")))
      (ert-info (label)
        (unwind-protect
            (with-current-buffer buffer
              (fermium-test--seed-room (append ballast (nth 1 case)))
              (should (< (fermium-test--deliver (nth 2 case))
                         (length ballast))))
          (kill-buffer buffer))))))

(defconst fermium-test--incremental-point-cases
  ;; label, starting messages, delivered messages, where point is, where it
  ;; should still be.  `heading' means the folded section's heading line.
  '(("reading a message when a later one arrives"
     (("$a" 1000)) (("$b" 2000)) "$a" "$a")
    ("reading a message when an earlier one arrives"
     (("$b" 2000)) (("$a" 1000)) "$b" "$b")
    ("reading an event whose run is rewritten around it"
     (("$a" 1000 channel) ("$c" 3000 channel)) (("$b" 2000 channel)) "$c" "$c")
    ("reading a run's heading while it is rewritten"
     (("$a" 1000 channel) ("$c" 3000 channel)) (("$b" 2000 channel))
     heading heading)
    ("reading a message whose echo corrects its time"
     (("$a" 1000) ("$b" 5000)) (("$b" 4000)) "$b" "$b")
    ("reading a message whose echo moves it"
     (("$a" 1000 channel) ("$b" 2000) ("$c" 3000 channel)) (("$b" 4000))
     "$b" "$b")
    ("reading a message beside a run that is rewritten"
     (("$a" 1000 channel) ("$c" 3000 channel) ("$d" 9000))
     (("$b" 2000 channel)) "$d" "$d"))
  "Where a reader's point has to stay while a room is updated around it.")

(ert-deftest fermium-room-incremental-updates-keep-the-reader-in-place ()
  (dolist (case fermium-test--incremental-point-cases)
    (let ((label (nth 0 case))
          (target (nth 3 case))
          (expected (nth 4 case))
          (buffer (get-buffer-create "*Fermium: !room:example.org*")))
      (ert-info (label)
        (unwind-protect
            (with-current-buffer buffer
              (fermium-test--seed-room (nth 1 case))
              ;; Expand any folded section so its events are places a reader
              ;; can actually be.
              (goto-char (point-min))
              (when (search-forward "Channel events" nil t)
                (beginning-of-line)
                (fermium-room-toggle-channel-events))
              (goto-char (point-min))
              (if (eq target 'heading)
                  (progn (search-forward "Channel events")
                         (beginning-of-line))
                (search-forward target)
                (goto-char (match-beginning 0)))
              (fermium-test--deliver (nth 2 case))
              (if (eq expected 'heading)
                  (should (string-match-p
                           "Channel events"
                           (buffer-substring-no-properties
                            (line-beginning-position) (line-end-position))))
                (should (equal (get-text-property
                                (point) 'fermium-room-message-key)
                               expected))))
          (kill-buffer buffer))))))

(ert-deftest fermium-room-synced-echo-supersedes-a-locally-timed-message ()
  (let ((buffer (get-buffer-create "*Fermium: !room:example.org*"))
        (older (list (cons "event_id" "$older")
                     (cons "sender" "@bob:example.org")
                     (cons "body" "older")
                     (cons "timestamp" 1000)))
        (local (list (cons "event_id" "$sent")
                     (cons "sender" "@me:example.org")
                     (cons "body" "hello")
                     (cons "timestamp" 5000)))
        (synced (list (cons "event_id" "$sent")
                      (cons "sender" "@me:example.org")
                      (cons "body" "hello")
                      (cons "timestamp" 4000))))
    (unwind-protect
        (with-current-buffer buffer
          (fermium-room-mode)
          (setq fermium-room--room-id "!room:example.org")
          (fermium-room--render-room
           (list (cons "room_id" "!room:example.org"))
           (list older))
          ;; A sent message is shown at once, timed by the local clock, and
          ;; comes back through sync carrying the homeserver's time.
          (fermium--handle-message-event
           (list (cons "room_id" "!room:example.org") (cons "message" local)))
          (fermium--handle-message-event
           (list (cons "room_id" "!room:example.org") (cons "message" synced)))
          (should (equal (fermium-test--history-keys) '("$older" "$sent")))
          (should (= 1 (how-many "hello" (point-min) (point-max))))
          ;; The homeserver's time is the room's, so it is the one kept.
          (should (equal (mapcar (lambda (message)
                                   (fermium--event-value message "timestamp"))
                                 (fermium-room--history-messages))
                         '(1000 4000)))
          (should (equal (fermium-test--rendered-keys)
                         (fermium-test--history-keys)))
          (should (equal (fermium-test--history-text)
                         (fermium-test--rerendered-history))))
      (kill-buffer buffer))))

(ert-deftest fermium-room-replacing-the-first-message-keeps-it-protected ()
  (with-temp-buffer
    (fermium-room-mode)
    (let ((first (list (cons "event_id" "$first")
                       (cons "sender" "@bob:example.org")
                       (cons "body" "first")
                       (cons "timestamp" 1000))))
      (fermium-room--render-room
       (list (cons "room_id" "!room:example.org"))
       (list first
             (list (cons "event_id" "$second")
                   (cons "sender" "@bob:example.org")
                   (cons "body" "second")
                   (cons "timestamp" 2000))))
      (should (= (fermium-room--message-position "$first") (point-min)))
      (fermium-room--refresh-message "$first")
      ;; A `read-only' property does not stop insertion immediately before
      ;; the first character carrying it, so a rewritten first character has
      ;; to be made front-sticky again.
      (should (equal (get-text-property (point-min) 'front-sticky)
                     '(read-only keymap)))
      (should (= 1 (how-many "first" (point-min) (point-max))))
      (should (= 1 (how-many "second" (point-min) (point-max)))))))

(ert-deftest fermium-room-send-recovers-from-a-send-error ()
  (with-temp-buffer
    (fermium-room-mode)
    (setq fermium-room--room-id "!room:example.org")
    (fermium-room--render-room
     (list (cons "room_id" fermium-room--room-id)) nil)
    (goto-char fermium-room--input-start)
    (insert "draft")
    (cl-letf (((symbol-function 'fermium--send)
               (lambda (&rest _args)
                 (error "helper unavailable"))))
      (fermium-room-send))
    (should-not fermium-room--sending)
    (should-not (get-text-property fermium-room--input-start 'read-only))
    (should (equal (buffer-substring-no-properties
                    fermium-room--input-start (point-max))
                   "draft"))))

(ert-deftest fermium-room-composition-is-muted-and-locked-while-sending ()
  (with-temp-buffer
    (fermium-room-mode)
    (setq fermium-room--account-id "@alice:example.org"
          fermium-room--room-id "!room:example.org")
    (fermium-room--render-room
     (list (cons "room_id" fermium-room--room-id)) nil)
    (goto-char fermium-room--input-start)
    (insert "draft")
    (cl-letf (((symbol-function 'fermium--send)
               (lambda (&rest _args) nil)))
      (fermium-room-send))
    (should fermium-room--sending)
    (should (eq (overlay-get fermium-room--composition-overlay 'face)
                'fermium-room-composition-sending-face))
    (should (get-text-property fermium-room--input-start 'read-only))
    (should-error (insert " edited"))
    ;; The helper emits the local message before the acknowledgement.  This
    ;; re-render must not make the pending composition editable again.
    (fermium--handle-message-event
     (list (cons "account" fermium-room--account-id)
           (cons "room_id" fermium-room--room-id)
           (cons "message"
                 (list (cons "event_id" "$sent")
                       (cons "sender" fermium-room--account-id)
                       (cons "body" "draft")
                       (cons "timestamp" 0)))))
    (should fermium-room--sending)
    (should (eq (overlay-get fermium-room--composition-overlay 'face)
                'fermium-room-composition-sending-face))
    (should (get-text-property fermium-room--input-start 'read-only))
    (should-error (insert " edited"))
    (fermium--handle-message-sent
     (list (cons "account" fermium-room--account-id)
           (cons "room_id" fermium-room--room-id)))
    (should-not fermium-room--sending)
    (should-not (get-text-property fermium-room--input-start 'read-only))
    (should (eq (overlay-get fermium-room--composition-overlay 'face)
                'fermium-room-composition-face))
    (goto-char fermium-room--input-start)
    (insert "next")
    (should (equal (buffer-substring-no-properties
                    fermium-room--input-start (point-max))
                   "next"))))

(ert-deftest fermium-room-composition-unlocks-and-keeps-draft-after-send-failure ()
  (with-temp-buffer
    (fermium-room-mode)
    (setq fermium-room--account-id "@alice:example.org"
          fermium-room--room-id "!room:example.org")
    (fermium-room--render-room
     (list (cons "room_id" fermium-room--room-id)) nil)
    (goto-char fermium-room--input-start)
    (insert "draft")
    (cl-letf (((symbol-function 'fermium--send)
               (lambda (&rest _args) nil)))
      (fermium-room-send))
    (fermium--handle-send-error
     (list (cons "type" "error")
           (cons "message" "Message send timed out"))
     fermium-room--room-id
     (current-buffer))
    (should-not fermium-room--sending)
    (should (equal fermium-room--send-error "Message send timed out"))
    (should-not (get-text-property fermium-room--input-start 'read-only))
    (should (eq (overlay-get fermium-room--composition-overlay 'face)
                'fermium-room-composition-face))
    (should (equal (buffer-substring-no-properties
                    fermium-room--input-start (point-max))
                   "draft"))))

(ert-deftest fermium-room-history-is-read-only-and-composition-is-distinct ()
  (with-temp-buffer
    (fermium-room-mode)
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org"))
     (list (list (cons "sender" "@bob:example.org")
                 (cons "body" "hello")
                 (cons "timestamp" 0))))
    (should (get-text-property (point-min) 'read-only))
    (goto-char (point-min))
    (should-error (insert "edited at start"))
    (search-forward "hello")
    (should (get-text-property (1- (point)) 'read-only))
    (should-error (insert "edited"))
    (should (string-match-p "Composition" (buffer-string)))
    (goto-char fermium-room--input-start)
    (should-not (get-text-property (point) 'read-only))
    (insert "draft")
    (should (equal (buffer-substring-no-properties
                    fermium-room--input-start (point-max))
                   "draft"))))

(ert-deftest fermium-room-question-mark-is-composition-input ()
  (with-temp-buffer
    (fermium-room-mode)
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org")) nil)
    (should-not (lookup-key fermium-room-mode-map (kbd "?")))
    (goto-char (1- fermium-room--input-start))
    (should (eq (lookup-key (get-text-property (point) 'keymap) (kbd "?"))
                #'fermium-help))
    (should (eq (key-binding (kbd "?")) #'fermium-help))
    (goto-char fermium-room--input-start)
    (should (eq (key-binding (kbd "?")) #'self-insert-command))
    (insert "?")
    (should (equal (buffer-substring-no-properties
                    fermium-room--input-start (point-max))
                   "?"))))

(ert-deftest fermium-room-q-is-composition-input ()
  (with-temp-buffer
    (fermium-room-mode)
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org")) nil)
    (goto-char fermium-room--input-start)
    (should (eq (key-binding (kbd "q")) #'self-insert-command))
    (insert "q")
    (should (equal (buffer-substring-no-properties
                    fermium-room--input-start (point-max))
                   "q"))
    (goto-char (point-min))
    (should (eq (key-binding (kbd "q"))
                #'fermium-room--redirect-self-insert))))

(ert-deftest fermium-room-read-only-self-insertion-goes-to-composition ()
  (with-temp-buffer
    (fermium-room-mode)
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org")) nil)
    (goto-char (point-min))
    (let ((last-command-event ?q))
      (call-interactively (key-binding (kbd "q"))))
    (should (= (point) (point-max)))
    (should (equal (buffer-substring-no-properties
                    fermium-room--input-start (point-max))
                   "q"))))

(ert-deftest fermium-overview-q-quits-fermium ()
  (should (eq (lookup-key fermium-overview-mode-map (kbd "q"))
              #'fermium-quit)))

(ert-deftest fermium-help-selects-the-overview-transient ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((called nil))
      (cl-letf (((symbol-function 'fermium--overview-help)
                 (lambda () (setq called t)))
                ((symbol-function 'fermium--room-help)
                 (lambda () (ert-fail "room help selected"))))
        (fermium-help))
      (should called))))

(ert-deftest fermium-help-selects-the-room-transient ()
  (with-temp-buffer
    (fermium-room-mode)
    (let ((called nil))
      (cl-letf (((symbol-function 'fermium--overview-help)
                 (lambda () (ert-fail "overview help selected")))
                ((symbol-function 'fermium--room-help)
                 (lambda () (setq called t))))
        (fermium-help))
      (should called))))

(ert-deftest fermium-room-messages-expose-readable-semantic-styles ()
  (with-temp-buffer
    (fermium-room-mode)
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org"))
     (list (list (cons "sender" "@bob:example.org")
                 (cons "body" "hello")
                 (cons "timestamp" 0))))
    (let ((timestamp (format-time-string "%Y-%m-%d %H:%M"
                                         (seconds-to-time 0))))
      (should (string-match-p (regexp-quote (format "%s @bob:example.org:"
                                                    timestamp))
                              (buffer-string)))
      (should-not (string-match-p (regexp-quote (format "[%s]" timestamp))
                                  (buffer-string)))
      (let ((header (fermium-room--header-line)))
        (should (string-match-p "!room:example.org" header))
        (should (eq (get-text-property
                     (string-match "!room:example.org" header)
                     'face header)
                    'fermium-room-title-face)))
      (goto-char (point-min))
      (search-forward timestamp)
      (should (eq (get-text-property (1- (point)) 'face)
                  'fermium-room-timestamp-face))
      (should (eq (get-text-property (1- (point)) 'font-lock-face)
                  'fermium-room-timestamp-face))
      (search-forward "@bob:example.org")
      (should (eq (get-text-property (1- (point)) 'face)
                  'fermium-room-sender-face))
      (should (eq (get-text-property (1- (point)) 'font-lock-face)
                  'fermium-room-sender-face))
      (goto-char fermium-room--input-start)
      (should (eq (overlay-get fermium-room--composition-overlay 'face)
                  'fermium-room-composition-face)))))

(ert-deftest fermium-room-renders-sender-display-name-when-present ()
  (with-temp-buffer
    (fermium-room-mode)
    (setq fermium-room--account-id "@alice:example.org")
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org"))
     (list (list (cons "sender" "@bob:example.org")
                 (cons "sender_display_name" "Bob")
                 (cons "body" "hello")
                 (cons "timestamp" 0))))
    (should (string-match-p
             (regexp-quote
              (format "%s Bob: hello" (fermium-room--format-timestamp 0)))
             (buffer-string)))
    (should-not (string-match-p "@bob:example.org:" (buffer-string)))
    (goto-char (point-min))
    (search-forward "Bob")
    (should (equal (get-text-property (1- (point)) 'fermium-room-sender-id)
                   "@bob:example.org"))))

(ert-deftest fermium-room-uses-an-explicit-unknown-user-label ()
  (with-temp-buffer
    (fermium-room-mode)
    (should (equal (fermium-room--message-sender-label nil)
                   fermium-room-unknown-user-label))
    (should (equal
             (fermium-room--message-sender-label
              (list (cons "sender" "")
                    (cons "sender_display_name" "")))
             fermium-room-unknown-user-label))))

(ert-deftest fermium-room-styles-survive-font-lock-unfontification ()
  (with-temp-buffer
    (fermium-room-mode)
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org"))
     (list (list (cons "sender" "@bob:example.org")
                 (cons "body" "hello")
                 (cons "timestamp" 0))))
    (let ((inhibit-read-only t))
      (font-lock-default-unfontify-region (point-min) (point-max)))
    (goto-char (point-min))
    (search-forward "1970")
    (should (eq (get-text-property (1- (point)) 'font-lock-face)
                'fermium-room-timestamp-face))
    (search-forward "@bob:example.org")
    (should (eq (get-text-property (1- (point)) 'font-lock-face)
                'fermium-room-sender-face))))

(ert-deftest fermium-room-renders-the-current-account-as-me ()
  (with-temp-buffer
    (fermium-room-mode)
    (setq fermium-room--account-id "@alice:example.org")
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org"))
     (list (list (cons "sender" "@alice:example.org")
                 (cons "body" "hello")
                 (cons "timestamp" 0))))
    (should (string-match-p
             (regexp-quote
              (format "%s me: hello" (fermium-room--format-timestamp 0)))
             (buffer-string)))
    (should-not (string-match-p "@alice:example.org:" (buffer-string)))
    (goto-char (point-min))
    (search-forward "me")
    (should (eq (get-text-property (1- (point)) 'face)
                'fermium-room-sender-self-face))
    (should (eq (get-text-property (1- (point)) 'font-lock-face)
                'fermium-room-sender-self-face))
    (should (equal (get-text-property (1- (point))
                                     'fermium-room-sender-id)
                   "@alice:example.org"))
    (should (eq (get-text-property (1- (point))
                                   'fermium-room-sender-role)
                'self))))

(ert-deftest fermium-room-sender-role-is-relative-to-the-room-account ()
  (let ((message (list (cons "sender" "@alice:example.org")
                       (cons "body" "hello")
                       (cons "timestamp" 0)))
        (alice-buffer (generate-new-buffer " *Fermium Alice room test*"))
        (bob-buffer (generate-new-buffer " *Fermium Bob room test*")))
    (unwind-protect
        (progn
          (with-current-buffer alice-buffer
            (fermium-room-mode)
            (setq fermium-room--account-id "@alice:example.org")
            (fermium-room--render-room
             (list (cons "room_id" "!room:example.org"))
             (list message)))
          (with-current-buffer bob-buffer
            (fermium-room-mode)
            (setq fermium-room--account-id "@bob:example.org")
            (fermium-room--render-room
             (list (cons "room_id" "!room:example.org"))
             (list message)))
          (with-current-buffer alice-buffer
            (should (string-match-p " me: hello" (buffer-string)))
            (goto-char (point-min))
            (search-forward "me")
            (should (eq (get-text-property (1- (point))
                                           'fermium-room-sender-role)
                        'self)))
          (with-current-buffer bob-buffer
            (should (string-match-p " @alice:example.org: hello"
                                    (buffer-string)))
            (goto-char (point-min))
            (search-forward "@alice:example.org")
            (should (equal
                     (car (get-text-property (1- (point)) 'face))
                     (fermium-room--message-sender-color-face message)))
            (should (eq (get-text-property (1- (point))
                                           'fermium-room-sender-role)
                        'other))))
      (kill-buffer alice-buffer)
      (kill-buffer bob-buffer))))

(ert-deftest fermium-room-sender-color-is-stable-and-bounded ()
  (let ((palette fermium-room-sender-color-faces))
    (should (= (length palette) 5))
    (dolist (sender '("@alice:example.org"
                      "@bob:example.org"
                      "@carol:example.org"))
      (with-temp-buffer
        (fermium-room-mode)
        (setq fermium-room--account-id "@viewer:example.org")
        (let ((message (list (cons "sender" sender))))
          (should (memq (fermium-room--message-sender-color-face message)
                        palette))
          (should (eq (fermium-room--message-sender-color-face message)
                      (fermium-room--message-sender-color-face message))))))))

(ert-deftest fermium-room-omits-date-for-messages-from-today ()
  (let* ((now (encode-time 0 34 12 26 7 2026))
         (timestamp (* 1000 (truncate (float-time now)))))
    (should (equal (fermium-room--format-timestamp timestamp now)
                   "12:34"))
    (with-temp-buffer
      (fermium-room-mode)
      (cl-letf (((symbol-function 'current-time) (lambda () now)))
        (fermium-room--render-room
         (list (cons "room_id" "!room:example.org"))
         (list (list (cons "sender" "@bob:example.org")
                     (cons "body" "hello")
                     (cons "timestamp" timestamp)))))
      (should (string-match-p "12:34 @bob:example.org:" (buffer-string)))
      (should-not (string-match-p "2026-07-26" (buffer-string))))))

(ert-deftest fermium-faces-use-theme-derived-semantic-parents ()
  (dolist (face-and-parent
           '((fermium-room-title-face . header-line)
             (fermium-room-timestamp-face . shadow)
             (fermium-room-sender-face . font-lock-variable-name-face)
             (fermium-room-sender-self-face . fermium-room-sender-face)
             (fermium-room-composition-header-face . header-line)
             (fermium-room-channel-events-face . shadow)
             (fermium-overview-group-face . header-line)
             (fermium-overview-account-face . font-lock-variable-name-face)
             (fermium-modeline-sending-face . mode-line-emphasis)))
    (should (eq (face-attribute (car face-and-parent) :inherit nil t)
                (cdr face-and-parent))))
  (let ((old-shadow-foreground
         (face-attribute 'shadow :foreground nil t))
        (old-variable-foreground
         (face-attribute 'font-lock-variable-name-face :foreground nil t)))
    (unwind-protect
        (progn
          (set-face-attribute 'shadow nil :foreground "magenta")
          (set-face-attribute 'font-lock-variable-name-face nil
                              :foreground "cyan")
          (should (equal
                   (face-attribute 'fermium-room-timestamp-face
                                   :foreground nil t)
                   "magenta"))
          (should (equal
                   (face-attribute 'fermium-room-sender-face
                                   :foreground nil t)
                   "cyan")))
      (set-face-attribute 'shadow nil :foreground old-shadow-foreground)
      (set-face-attribute 'font-lock-variable-name-face nil
                          :foreground old-variable-foreground)))
  (should (equal (face-attribute 'fermium-room-timestamp-face :height nil t)
                 0.9))
  (should (eq (face-attribute 'fermium-room-timestamp-face :slant nil t)
              'italic))
  (should (eq (face-attribute 'fermium-room-sender-face :weight nil t)
              'bold))
  (should (eq (face-attribute 'fermium-room-sender-self-face
                              :slant nil t)
              'italic))
  (should-not (face-attribute 'fermium-room-title-face :box nil t))
  (should (eq (face-attribute 'fermium-room-composition-face :weight nil t)
              'normal))
  (should (eq (face-attribute 'fermium-room-composition-face :slant nil t)
              'normal))
  (should (eq (face-attribute 'fermium-room-composition-sending-face
                              :slant nil t)
              'italic))
  (should (equal (face-attribute 'fermium-room-composition-sending-face
                                 :height nil t)
                 0.9))
  (should-not (face-attribute 'fermium-room-composition-face
                              :underline nil t))
  (should-not (face-attribute 'fermium-room-composition-face :box nil t)))

(ert-deftest fermium-room-folds-consecutive-channel-events ()
  (with-temp-buffer
    (fermium-room-mode)
    (let ((first (list (cons "kind" "channel_event")
                       (cons "event_id" "$join")
                       (cons "body" "Alice joined")
                       (cons "timestamp" 1000)))
          (second (list (cons "kind" "channel_event")
                        (cons "event_id" "$leave")
                        (cons "body" "Bob left")
                        (cons "timestamp" 2000)))
          (message (list (cons "event_id" "$message")
                         (cons "sender" "@carol:example.org")
                         (cons "body" "hello")
                         (cons "timestamp" 3000))))
      (fermium-room--render-room
       (list (cons "room_id" "!room:example.org"))
       (list first second message))
      (should (string-match-p "Channel events (2)" (buffer-string)))
      (should (string-match-p "Alice joined" (buffer-string)))
      (goto-char (point-min))
      (search-forward "Channel events")
      (beginning-of-line)
      (should (eq (get-text-property (point)
                                    'fermium-room-channel-events-header)
                  t))
      (let ((body-position (save-excursion
                             (forward-line 1)
                             (point))))
        (should (invisible-p body-position))
        (should (equal (get-text-property
                        (point) 'fermium-room-channel-events-id)
                       "$join"))
        (should (string-match-p
                 (regexp-quote (fermium-room--format-timestamp 2000))
                 (buffer-substring-no-properties
                  (line-beginning-position) (line-end-position))))
        (fermium-room-toggle-channel-events)
        (should-not (invisible-p body-position))
        (should (string-match-p "▾" (buffer-string)))
        (fermium-room-toggle-channel-events)
        (should (invisible-p body-position))))))

(ert-deftest fermium-room-folds-a-single-channel-event ()
  (with-temp-buffer
    (fermium-room-mode)
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org"))
     (list (list (cons "kind" "channel_event")
                 (cons "event_id" "$join")
                 (cons "body" "Alice joined")
                 (cons "timestamp" 1000))))
    (should (string-match-p "Channel events (1)" (buffer-string)))
    (goto-char (point-min))
    (search-forward "Channel events")
    (beginning-of-line)
    (should (invisible-p (save-excursion
                           (forward-line 1)
                           (point))))))

(ert-deftest fermium-overview-uses-image-placeholder-for-latest-image ()
  (with-temp-buffer
    (fermium-overview-mode)
    (let ((fermium--account "@alice:example.org")
          (fermium--rooms
           (list (list (cons "room_id" "!room:example.org")
                       (cons "name" "Example room")
                       (cons "latest_message"
                             (list (cons "body" "photo.png")
                                   (cons "image"
                                         (list (cons "source"
                                                     (list (cons "url"
                                                                 "mxc://example.org/image")))))))))))
      (fermium--render-overview)
      (should (string-match-p "\\[Image\\]" (buffer-string)))
      (should-not (string-match-p "photo.png" (buffer-string))))))

(ert-deftest fermium-serializes-nested-media-source-for-helper ()
  (should (equal
           (json-serialize
            (fermium--json-value-for-send
             (list (cons "url" "mxc://example.org/image"))))
           "{\"url\":\"mxc://example.org/image\"}")))

(ert-deftest fermium-serializes-encrypted-media-source-for-helper ()
  (let* ((source
          (json-parse-string
           "{\"file\":{\"url\":\"mxc://example.org/image\",\"key\":{\"key_ops\":[\"decrypt\"]}}}"
           :object-type 'alist
           :array-type 'list))
         (encoded (json-serialize (fermium--json-value-for-send source))))
    (should (string-match-p
             "\\\"key_ops\\\":\\\[\\\"decrypt\\\"\\\]"
             encoded))))

(ert-deftest fermium-room-renders-clickable-image-placeholder ()
  (with-temp-buffer
    (fermium-room-mode)
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org"))
     (list (list (cons "event_id" "$image")
                 (cons "sender" "@bob:example.org")
                 (cons "body" "photo.png")
                 (cons "timestamp" 0)
                 (cons "image"
                       (list (cons "source"
                                   (list (cons "url"
                                               "mxc://example.org/image"))))))))
    (goto-char (point-min))
    (search-forward "[Image]")
    (should (get-text-property (1- (point)) 'fermium-room-image))
    (should (eq (lookup-key (get-text-property (1- (point)) 'keymap)
                            (kbd "RET"))
                #'fermium-room-display-image))
    (should (eq (lookup-key (get-text-property (1- (point)) 'keymap)
                            [mouse-1])
                #'fermium-room--mouse-display-image))
    (should (eq (lookup-key (get-text-property (1- (point)) 'keymap)
                            [mouse-2])
                #'fermium-room--mouse-display-image))
    (should (eq (get-text-property (1- (point)) 'face) 'button))
    (should (eq (get-text-property (1- (point)) 'font-lock-face) 'button))
    (should (get-text-property (1- (point)) 'follow-link))))

(ert-deftest fermium-room-image-loading-indicator-survives-empty-frame ()
  (with-temp-buffer
    (fermium-room-mode)
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org"))
     (list (list (cons "event_id" "$image")
                 (cons "sender" "@bob:example.org")
                 (cons "body" "photo.png")
                 (cons "timestamp" 0)
                 (cons "image"
                       (list (cons "source"
                                   (list (cons "url"
                                               "mxc://example.org/image"))))))))
    (puthash "$image" (list :status 'loading)
             fermium-room--image-states)
    (let ((fermium--loading-frame 0))
      (should (equal (fermium-room--image-loading-dots) "."))
      (fermium-room--render-history (fermium-room--history-messages))
      (goto-char (point-min))
      (let ((image-position nil))
        (while (and (not image-position) (< (point) (point-max)))
          (when (equal (get-text-property (point) 'fermium-room-image-key)
                       "$image")
            (setq image-position (point)))
          (forward-char 1))
        (should image-position)
        (should (equal (buffer-substring-no-properties
                        image-position (1+ image-position))
                       ".")))
      (setq fermium--loading-frame 2)
      (fermium-room--render-loading-images)
      (goto-char (point-min))
      (search-forward "..")
      (should (equal (get-text-property (1- (point)) 'fermium-room-image-key)
                     "$image")))))

(ert-deftest fermium-room-displays-image-after-async-download ()
  (with-temp-buffer
    (fermium-room-mode)
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org"))
     (list (list (cons "event_id" "$image")
                 (cons "sender" "@bob:example.org")
                 (cons "body" "photo.png")
                 (cons "timestamp" 0)
                 (cons "image"
                       (list (cons "source"
                                   (list (cons "url"
                                               "mxc://example.org/image"))))))))
    (goto-char (point-min))
    (search-forward "@bob:example.org:")
    (should (looking-at "\n\\[Image\\]\n"))
    (search-forward "[Image]")
    (let (callback)
      (cl-letf (((symbol-function 'fermium--send)
                 (lambda (command payload received-callback)
                   (should (equal command "download_media"))
                   (should (equal payload
                                  (list (cons "source"
                                              (list (cons "url"
                                                          "mxc://example.org/image"))))))
                   (setq callback received-callback)))
                ((symbol-function 'fermium--start-loading-animation)
                 (lambda () nil))
                ((symbol-function 'fermium--stop-loading-animation-if-idle)
                 (lambda () nil))
                ((symbol-function 'image-flush)
                 (lambda (&rest _) nil)))
        (fermium-room-display-image)
        (should (string-match-p "\\." (buffer-string)))
        (funcall callback
                 (list (cons "type" "media_downloaded")
                       (cons "data"
                             "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")))
        (goto-char (point-min))
        (let ((image-position nil))
          (while (and (not image-position) (< (point) (point-max)))
            (when (get-text-property (point) 'display)
              (setq image-position (point)))
            (forward-char 1))
          (should image-position)
          (should-not (get-text-property image-position
                                         'fermium-room-image))
          (should (eq (get-text-property image-position 'face) 'default)))
        (should (eq (plist-get (gethash "$image" fermium-room--image-states)
                               :status)
                    'ready))))))

(ert-deftest fermium-room-fits-downloaded-images-to-the-room-window ()
  (with-temp-buffer
    (fermium-room-mode)
    (let ((image-data
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
      (cl-letf (((symbol-function 'get-buffer-window)
                 (lambda (&rest _) 'room-window))
                ((symbol-function 'window-live-p)
                 (lambda (_) t))
                ((symbol-function 'window-inside-pixel-edges)
                 (lambda (_) '(0 0 640 480))))
        (let ((image (fermium-room--create-image image-data 'png)))
          (should (= (plist-get (cdr image) :scale) 1))
          (should (= (plist-get (cdr image) :max-width) 640))
          (should (= (plist-get (cdr image) :max-height) 480)))))))

(ert-deftest fermium-room-refits-images-after-window-resize ()
  (with-temp-buffer
    (fermium-room-mode)
    (let ((image-data
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
          (rendered nil))
      (puthash "$image"
               (list :status 'ready
                     :data image-data
                     :type 'png
                     :image (create-image image-data 'png t
                                          :scale 1
                                          :max-width 640
                                          :max-height 480))
               fermium-room--image-states)
      (fermium-room--render-room
       (list (cons "room_id" "!room:example.org"))
       (list (list (cons "event_id" "$image")
                   (cons "sender" "@bob:example.org")
                   (cons "body" "photo.png")
                   (cons "timestamp" 0)
                   (cons "image"
                         (list (cons "source"
                                     (list (cons "url"
                                                 "mxc://example.org/image"))))))
             (list (cons "event_id" "$text")
                   (cons "sender" "@bob:example.org")
                   (cons "body" "unrelated")
                   (cons "timestamp" 1))))
      (cl-letf (((symbol-function 'window-live-p)
                 (lambda (_) t))
                ((symbol-function 'window-inside-pixel-edges)
                 (lambda (_) '(0 0 320 200)))
                ((symbol-function 'fermium-room--render-history)
                 (lambda (&rest _) (setq rendered t)))
                ((symbol-function 'image-flush)
                 (lambda (&rest _) nil)))
        (fermium-room--refresh-image-sizes 'room-window)
        (let ((image (plist-get (gethash "$image" fermium-room--image-states)
                                :image))
              (position (text-property-not-all
                         (point-min) (point-max) 'display nil)))
          ;; Refitting replaces only the messages carrying an image, and
          ;; leaves the rest of the history in place.
          (should-not rendered)
          (should (= 1 (how-many "unrelated" (point-min) (point-max))))
          (should (= (plist-get (cdr image) :scale) 1))
          (should (= (plist-get (cdr image) :max-width) 320))
          (should (= (plist-get (cdr image) :max-height) 200))
          ;; The refitted descriptor is the one now installed in the buffer.
          ;; `insert-image' augments the descriptor it is given, so compare
          ;; the fitted dimensions rather than object identity.
          (should position)
          (should (= (plist-get (cdr (get-text-property position 'display))
                                :max-width)
                     320)))))))

(ert-deftest fermium-room-flushes-replaced-image-descriptors ()
  (with-temp-buffer
    (fermium-room-mode)
    (let* ((image-data
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
           (old-image (create-image image-data 'png t
                                    :scale 1
                                    :max-width 640
                                    :max-height 480))
           (flushed nil)
           (rendered nil))
      (puthash "$image"
               (list :status 'ready
                     :data image-data
                     :type 'png
                     :image old-image)
               fermium-room--image-states)
      (fermium-room--render-room
       (list (cons "room_id" "!room:example.org"))
       (list (list (cons "event_id" "$image")
                   (cons "sender" "@bob:example.org")
                   (cons "body" "photo.png")
                   (cons "timestamp" 0)
                   (cons "image"
                         (list (cons "source"
                                     (list (cons "url"
                                                 "mxc://example.org/image"))))))))
      (cl-letf (((symbol-function 'window-live-p)
                 (lambda (_) t))
                ((symbol-function 'window-inside-pixel-edges)
                 (lambda (_) '(0 0 320 200)))
                ((symbol-function 'fermium-room--render-history)
                 (lambda (&rest _)
                   (setq rendered t)))
                ((symbol-function 'image-flush)
                 (lambda (image &optional _frame)
                   (push image flushed))))
        (fermium-room--refresh-image-sizes 'room-window)
        (let ((new-image (plist-get (gethash "$image"
                                             fermium-room--image-states)
                                    :image)))
          (should-not rendered)
          (should (memq old-image flushed))
          (should (memq new-image flushed))
          (should (= (length flushed) 2))))
      (clrhash fermium-room--image-states))))

(ert-deftest fermium-room-flushes-images-when-buffer-is-killed ()
  (let ((buffer (generate-new-buffer " *Fermium image cleanup test*"))
        (image-data
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        (flushed nil))
    (unwind-protect
        (with-current-buffer buffer
          (fermium-room-mode)
          (let ((image (create-image image-data 'png t :scale 1)))
            (puthash "$image"
                     (list :status 'ready
                           :data image-data
                           :type 'png
                           :image image)
                     fermium-room--image-states)
            (cl-letf (((symbol-function 'image-flush)
                       (lambda (flushed-image &optional _frame)
                         (push flushed-image flushed)))
                      ((symbol-function 'cancel-timer)
                       (lambda (_) nil)))
              (kill-buffer buffer)
              (should (memq image flushed)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest fermium-room-does-not-rerender-already-fitted-images ()
  (with-temp-buffer
    (fermium-room-mode)
    (let ((image-data
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
          (rendered nil))
      (let ((image (create-image image-data 'png t
                                 :scale 1
                                 :max-width 320
                                 :max-height 200)))
        (puthash "$image"
                 (list :status 'ready
                       :data image-data
                       :type 'png
                       :image image)
                 fermium-room--image-states)
        (cl-letf (((symbol-function 'window-live-p)
                   (lambda (_) t))
                  ((symbol-function 'window-inside-pixel-edges)
                   (lambda (_) '(0 0 320 200)))
                  ((symbol-function 'fermium-room--render-history)
                   (lambda (_) (setq rendered t))))
          (fermium-room--refresh-image-sizes 'room-window)
          (should-not rendered)
          (should (eq image
                      (plist-get (gethash "$image" fermium-room--image-states)
                                 :image))))))))

(ert-deftest fermium-room-channel-event-heading-is-clickable ()
  (with-temp-buffer
    (fermium-room-mode)
    (fermium-room--render-room
     (list (cons "room_id" "!room:example.org"))
     (list (list (cons "kind" "channel_event")
                 (cons "event_id" "$join")
                 (cons "body" "Alice joined")
                 (cons "timestamp" 1000))))
    (goto-char (point-min))
    (search-forward "Channel events")
    (beginning-of-line)
    (should (eq (lookup-key (get-text-property (point) 'keymap)
                            [mouse-1])
                #'fermium-room--mouse-toggle-channel-events))
    (should (eq (lookup-key (get-text-property (point) 'keymap)
                            [mouse-2])
                #'fermium-room--mouse-toggle-channel-events))
    (should (eq (get-text-property (point) 'face)
                'fermium-room-channel-events-face))
    (should (get-text-property (point) 'follow-link))))

;;; fermium-test.el ends here
