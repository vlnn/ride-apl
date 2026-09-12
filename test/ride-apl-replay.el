;;; ride-apl-replay.el --- Transcript fixture replay driver -*- lexical-binding: t; -*-

;;; Commentary:
;; AD-18 infrastructure, usable from tests and interactively.  A fixture
;; is an elisp-readable file of plists:
;;   (:dir :in|:out :t FLOAT-SECONDS :raw BASE64)   pre-handshake entries
;;   (:dir :in|:out :t FLOAT-SECONDS :msg PARSED)   framed entries
;;   (:dir :event :t FLOAT-SECONDS :msg EVENT)      synthetic reducer events
;; The :event kind extends AD-18 so user actions (:input, :interrupt)
;; and timers replay deterministically.
;; Replay feeds :in entries through the reducer from a fresh session and
;; collects everything needed for assertions: the accumulated effect
;; log, the payloads we would send, the payloads the fixture says were
;; sent, and a curated projection of final state.  Never assert full
;; state equality (AD-18).

;;; Code:

(require 'ride-apl-session)
(require 'ride-apl-proto)

(defun ride-apl-replay-load (file)
  "Read FILE; return the list of transcript entries."
  (with-temp-buffer
    (insert-file-contents file)
    (let (entries entry)
      (while (setq entry (condition-case nil
                             (read (current-buffer))
                           (end-of-file nil)))
        (push entry entries))
      (nreverse entries))))

(defun ride-apl-replay-run (entries)
  "Replay ENTRIES from a fresh session.
Return a plist: :state FINAL-STATE, :effects ALL-EFFECTS (including
the init effects), :sent (payload strings from :send effects), and
:recorded-out (payload strings the fixture recorded as sent)."
  (pcase-let ((`(,state . ,effects) (ride-apl-session-init)))
    (dolist (entry entries)
      (when (memq (plist-get entry :dir) '(:in :event))
        (pcase-let ((`(,next . ,step-effects)
                     (ride-apl-session-step state (ride-apl-replay-entry-message entry))))
          (setq state next)
          (setq effects (append effects step-effects)))))
    (list :state state
          :effects effects
          :sent (mapcar #'cadr (ride-apl-replay-effects-of effects '(:send)))
          :recorded-out (mapcar #'ride-apl-replay-entry-payload
                                (seq-filter (lambda (e) (eq (plist-get e :dir) :out))
                                            entries)))))

(defun ride-apl-replay-entry-message (entry)
  "Parsed (NAME . ARGS) message for ENTRY."
  (let ((msg (plist-get entry :msg)))
    (or msg (ride-apl-proto-parse (ride-apl-replay--raw-payload entry)))))

(defun ride-apl-replay-entry-payload (entry)
  "Wire payload string for ENTRY."
  (let ((msg (plist-get entry :msg)))
    (if msg
        (ride-apl-proto-serialize (car msg) (cdr msg))
      (ride-apl-replay--raw-payload entry))))

(defun ride-apl-replay--raw-payload (entry)
  (decode-coding-string (base64-decode-string (plist-get entry :raw)) 'utf-8))

(defun ride-apl-replay-effects-of (effects types)
  "EFFECTS filtered to the allowlist TYPES."
  (seq-filter (lambda (effect) (memq (car effect) types)) effects))

(defun ride-apl-replay-state-projection (state)
  "Curated final-state projection for fixture assertions (AD-18)."
  (list :conn-state (ride-apl-session-conn-state state)
        :prompt-type (ride-apl-session-prompt-type state)
        :log-state (ride-apl-session-log-state state)
        :windows (mapcar #'car (ride-apl-session-windows state))))

(provide 'ride-apl-replay)
;;; ride-apl-replay.el ends here
