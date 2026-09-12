;;; ride-apl.el --- Dyalog APL client via the RIDE protocol -*- lexical-binding: t; -*-

;; Author: TODO-your-name <TODO-your@email>
;; Maintainer: TODO-your-name <TODO-your@email>
;; URL: https://example.com/TODO-repo-url
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: languages, apl
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Entry-point commands.  Start an interpreter with
;;   RIDE_INIT=SERVE:127.0.0.1:4502 dyalog
;; then M-x ride-apl-connect.

;;; Code:

(require 'ride-apl-session)
(require 'ride-apl-repl)
(require 'ride-apl-edit)
(require 'ride-apl-tracer)
(require 'ride-apl-eldoc)
(require 'ride-apl-eval)

(defcustom ride-apl-default-host "127.0.0.1"
  "Default host offered by `ride-apl-connect'."
  :type 'string :group 'ride-apl)

(defcustom ride-apl-default-port 4502
  "Default port offered by `ride-apl-connect'."
  :type 'natnum :group 'ride-apl)

(defcustom ride-apl-confirm-remote-connect t
  "Ask before connecting to a non-loopback host.
RIDE is unauthenticated plaintext TCP; prefer an SSH tunnel."
  :type 'boolean :group 'ride-apl)

;;;###autoload
(defun ride-apl-connect (host port)
  "Connect to a Dyalog interpreter listening at HOST:PORT."
  (interactive
   (list (read-string (format "Host (default %s): " ride-apl-default-host)
                      nil nil ride-apl-default-host)
         (read-number "Port: " ride-apl-default-port)))
  (when (ride-apl--refused-remote-p host)
    (user-error "ride-apl: connection refused by user"))
  (let ((conn (ride-apl-session-open host port)))
    (pop-to-buffer (ride-apl-repl-attach conn))
    (message "ride-apl: connecting to %s:%s..." host port)
    conn))

(defun ride-apl-trace (line)
  "Trace LINE: run it with the tracer open on the first call."
  (interactive
   (list (read-string "Trace: "
                      (if (use-region-p)
                          (buffer-substring-no-properties (region-beginning)
                                                          (region-end))
                        (thing-at-point 'line t)))))
  (let ((conn (ride-apl-current-conn)))
    (unless conn (user-error "ride-apl: no session"))
    (ride-apl-session--dispatch conn
                            (list :trace-line (string-trim-right line "
")))))

(defun ride-apl-pop-to-repl ()
  "Select the current session's REPL buffer."
  (interactive)
  (let ((conn (ride-apl-current-conn)))
    (unless (and conn (buffer-live-p (ride-apl-conn-repl-buffer conn)))
      (user-error "ride-apl: no session"))
    (pop-to-buffer (ride-apl-conn-repl-buffer conn))))

(defun ride-apl-transcript-save (file &optional conn)
  "Export CONN's protocol log as an AD-18 fixture to FILE.
CONN defaults to the current connection.  Review fixtures recorded
against real workspaces before committing."
  (interactive "FSave transcript to: ")
  (let ((conn (or conn (ride-apl-current-conn)))
        (print-length nil)
        (print-level nil))
    (unless conn (user-error "ride-apl: no session"))
    (with-temp-file file
      (insert ";; -*- mode: lisp-data -*-\n")
      (insert (format ";; RIDE transcript, %s:%s, saved %s\n"
                      (ride-apl-conn-host conn) (ride-apl-conn-port conn)
                      (format-time-string "%F %T")))
      (dolist (entry (ride-apl-session-transcript conn))
        (prin1 entry (current-buffer))
        (insert "\n")))
    (message "ride-apl: transcript saved to %s" file)))

(defun ride-apl-disconnect ()
  "Disconnect the current RIDE session."
  (interactive)
  (let ((conn (ride-apl-current-conn)))
    (unless conn (user-error "ride-apl: no session"))
    (ride-apl-session-close conn)))

(defun ride-apl--refused-remote-p (host)
  (and ride-apl-confirm-remote-connect
       (not (member host '("127.0.0.1" "localhost" "::1")))
       (not (y-or-n-p (format "Connect to remote host %s over plaintext TCP? "
                              host)))))

(provide 'ride-apl)
;;; ride-apl.el ends here
