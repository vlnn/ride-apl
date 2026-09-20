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

(require 'ride-apl-conn)
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

(defcustom ride-apl-program "dyalog"
  "Interpreter executable run by `ride-apl-start'."
  :type 'string :group 'ride-apl)

(defcustom ride-apl-program-args nil
  "Extra arguments `ride-apl-start' passes to `ride-apl-program'."
  :type '(repeat string) :group 'ride-apl)

(defcustom ride-apl-program-environment '("DYALOG_LINEEDITOR_MODE=1")
  "Extra \"VAR=VALUE\" entries for the spawned interpreter's environment.
Entries shadow inherited variables of the same name; RIDE_INIT is
always set by `ride-apl-start' itself.  The default enables Dyalog's
multi-line session input, without which a dfn evaluated line by line
dies with an unpaired-brace SYNTAX ERROR."
  :type '(repeat string) :group 'ride-apl)

(defcustom ride-apl-spawn-timeout 10
  "Seconds `ride-apl-start' waits for the interpreter to serve RIDE."
  :type 'number :group 'ride-apl)

(defcustom ride-apl-spawn-retry-interval 0.15
  "Seconds between connection attempts to a spawned interpreter."
  :type 'number :group 'ride-apl)

;;;###autoload
(defun ride-apl-start (&optional command)
  "Spawn a Dyalog interpreter and connect to it.
Run `ride-apl-program' with `ride-apl-program-args', told via
RIDE_INIT to serve RIDE on a free loopback port, and connect as soon
as it accepts.  With a prefix argument, prompt for the exact COMMAND
line instead.  Return the interpreter process."
  (interactive
   (list (when current-prefix-arg
           (read-shell-command "Interpreter command: "
                               (combine-and-quote-strings
                                (cons ride-apl-program ride-apl-program-args))))))
  (let* ((port (ride-apl-spawn--free-port))
         (process (ride-apl-spawn--launch (ride-apl-spawn--command command) port)))
    (message "ride-apl: started %s; waiting for RIDE on port %s..."
             (car (process-command process)) port)
    (ride-apl-spawn--connect-when-ready process "127.0.0.1" port
                                    (+ (float-time) ride-apl-spawn-timeout))
    process))

(defun ride-apl-spawn--command (command)
  "Argv for the interpreter: COMMAND when given, else the customized one."
  (if command
      (split-string-shell-command command)
    (cons ride-apl-program ride-apl-program-args)))

(defun ride-apl-spawn--free-port ()
  "A currently free loopback TCP port, courtesy of the kernel."
  (let ((probe (make-network-process :name "ride-apl-port-probe" :server t
                                     :host "127.0.0.1" :service t :noquery t)))
    (unwind-protect (process-contact probe :service)
      (delete-process probe))))

(defun ride-apl-spawn--environment (port)
  "`process-environment' telling the interpreter to serve RIDE on PORT.
RIDE_INIT comes first, then `ride-apl-program-environment', then the
inherited environment; `getenv' takes the first match, so earlier
entries shadow later ones."
  (cons (format "RIDE_INIT=SERVE:127.0.0.1:%s" port)
        (append ride-apl-program-environment process-environment)))

(defun ride-apl-spawn--launch (argv port)
  "Start ARGV with RIDE_INIT set to serve PORT; return the process."
  (let ((process-environment (ride-apl-spawn--environment port)))
    (make-process :name "ride-apl-interpreter"
                  :buffer (generate-new-buffer "*ride-apl-interpreter*")
                  :command argv
                  :noquery t)))

(defun ride-apl-spawn--connect-when-ready (process host port deadline)
  "Connect to HOST:PORT once PROCESS serves it, retrying until DEADLINE."
  (cond
   ((not (process-live-p process))
    (user-error "ride-apl: interpreter exited before serving RIDE (see %s)"
                (buffer-name (process-buffer process))))
   ((ride-apl-spawn--try-connect host port))
   ((> (float-time) deadline)
    (interrupt-process process)
    (user-error "ride-apl: interpreter did not serve RIDE within %s s"
                ride-apl-spawn-timeout))
   (t (run-at-time ride-apl-spawn-retry-interval nil
                   #'ride-apl-spawn--connect-when-ready
                   process host port deadline))))

(defun ride-apl-spawn--try-connect (host port)
  "Attempt one connection to HOST:PORT; nil when nothing listens yet."
  (condition-case nil
      (ride-apl-connect host port)
    (file-error nil)))

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
