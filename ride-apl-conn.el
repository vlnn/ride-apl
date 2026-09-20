;;; ride-apl-conn.el --- RIDE connection shell -*- lexical-binding: t; -*-


;;; Commentary:
;; Imperative shell around the pure reducer in ride-apl-session.el
;; (AD-2): the live connection object, the dispatcher that feeds
;; messages through `ride-apl-session-step', the effect interpreter with
;; its handler registry (AD-16), lifecycle timers (AD-17), and the
;; protocol log / AD-18 transcript.

;;; Code:

(require 'cl-lib)
(require 'ride-apl-session)
(require 'ride-apl-transport)

(defcustom ride-apl-handshake-timeout 5
  "Seconds allowed for the handshake and for the Identify reply (AD-17)."
  :type 'number :group 'ride-apl)

(defcustom ride-apl-log-timeout 3
  "Seconds to wait for ReplyGetLog before rendering live output (M2)."
  :type 'number :group 'ride-apl)

(cl-defstruct (ride-apl-conn (:constructor ride-apl-conn--make))
  process state timer host port death-reason repl-buffer
  (edit-buffers nil) (log nil) (start-time (float-time))
  (tip-token 0) (tip-callback nil))

(defvar ride-apl-session--effect-handlers (make-hash-table :test 'eq)
  "Effect symbol -> (lambda (conn args)); UI layers register here.")

(defvar ride-apl-session-died-hook nil
  "Run with (CONN REASON DETAIL) after core teardown.")

(defun ride-apl-session-register-effect (symbol handler)
  (puthash symbol handler ride-apl-session--effect-handlers))

(defvar ride-apl--conns nil)

(defun ride-apl-session-open (host port)
  "Connect to HOST:PORT; return the live connection object."
  (let* ((conn (ride-apl-conn--make :host host :port port))
         (process (ride-apl-transport-connect
                   host port
                   (lambda (payload) (ride-apl-session--on-payload conn payload))
                   (lambda (reason) (ride-apl-session--on-close conn reason)))))
    (setf (ride-apl-conn-process conn) process)
    (push conn ride-apl--conns)
    (pcase-let ((`(,state . ,effects) (ride-apl-session-init)))
      (setf (ride-apl-conn-state conn) state)
      (ride-apl-session--arm-timer conn)
      (ride-apl-session--execute conn effects))
    conn))

(defun ride-apl-session-close (conn)
  "Politely disconnect CONN."
  (when (process-live-p (ride-apl-conn-process conn))
    (ignore-errors
      (ride-apl-session--execute
       conn (list (list :send (ride-apl-proto-disconnect "goodbye")))))
    (ride-apl-transport-close (ride-apl-conn-process conn))))

(defun ride-apl-value-tip (conn line pos callback)
  "Ask CONN for a value tip at 0-based column POS of LINE.
CALLBACK receives the ValueTip args alist.  Only the most recent
request per connection is answered; superseded callbacks are dropped."
  (let ((token (cl-incf (ride-apl-conn-tip-token conn))))
    (setf (ride-apl-conn-tip-callback conn) (cons token callback))
    (ride-apl-session--dispatch conn (list :value-tip 0 token line pos))))

(defun ride-apl-session--handle-tip-reply (conn args)
  (pcase-let ((`(,reply) args))
    (pcase (ride-apl-conn-tip-callback conn)
      (`(,token . ,callback)
       (when (eql token (alist-get 'token reply))
         (setf (ride-apl-conn-tip-callback conn) nil)
         (funcall callback reply))))))

(ride-apl-session-register-effect :value-tip-reply #'ride-apl-session--handle-tip-reply)

(defun ride-apl--apl-quote (string)
  "Escape STRING for inclusion in an APL character literal."
  (replace-regexp-in-string "'" "''" string))

(defun ride-apl-current-conn ()
  "Most recently opened live connection, else most recent, else nil."
  (or (seq-find (lambda (c) (process-live-p (ride-apl-conn-process c)))
                ride-apl--conns)
      (car ride-apl--conns)))

(defun ride-apl-session--on-payload (conn payload)
  (ride-apl-session--log conn "<-" payload)
  (condition-case err
      (ride-apl-session--dispatch conn (ride-apl-proto-parse payload))
    (ride-apl-proto-bad-message
     (message "ride-apl: unparseable payload: %S" (cdr err)))))

(defun ride-apl-session--on-close (conn reason)
  (ride-apl-session--dispatch conn (list :closed reason)))

(defun ride-apl-session--dispatch (conn message)
  (when (keywordp (car message))
    (ride-apl-session--log-event conn message))
  (let ((before (ride-apl-session-conn-state (ride-apl-conn-state conn))))
    (pcase-let ((`(,state . ,effects)
                 (ride-apl-session-step (ride-apl-conn-state conn) message)))
      (setf (ride-apl-conn-state conn) state)
      (ride-apl-session--manage-timer conn before (ride-apl-session-conn-state state))
      (when (and (ride-apl-conn-timer conn)
                 (eq (ride-apl-session-conn-state state) 'connected)
                 (eq (ride-apl-session-log-state state) 'done))
        (ride-apl-session--cancel-timer conn))
      (ride-apl-session--execute conn effects))))

(defun ride-apl-session--manage-timer (conn before after)
  (unless (eq before after)
    (ride-apl-session--cancel-timer conn)
    (pcase after
      ('identifying (ride-apl-session--arm-timer conn))
      ('connected (setf (ride-apl-conn-timer conn)
                        (run-at-time ride-apl-log-timeout nil
                                     #'ride-apl-session--dispatch conn
                                     '(:log-timeout)))))))

(defun ride-apl-session--arm-timer (conn)
  (setf (ride-apl-conn-timer conn)
        (run-at-time ride-apl-handshake-timeout nil
                     #'ride-apl-session--dispatch conn '(:timeout))))

(defun ride-apl-session--cancel-timer (conn)
  (when (ride-apl-conn-timer conn)
    (cancel-timer (ride-apl-conn-timer conn))
    (setf (ride-apl-conn-timer conn) nil)))

(defun ride-apl-session--execute (conn effects)
  (dolist (effect (ride-apl-session--batch-display effects))
    (pcase effect
      (`(:send ,payload)
       (ride-apl-session--log conn "->" payload)
       (ride-apl-transport-send (ride-apl-conn-process conn) payload))
      (`(:notify ,level ,text)
       (message "ride-apl %s: %s" level text))
      (`(:session-died ,reason . ,detail)
       (ride-apl-session--on-died conn reason (car detail)))
      (`(,symbol . ,args)
       (let ((handler (gethash symbol ride-apl-session--effect-handlers)))
         (unless handler (error "ride-apl: unknown effect: %S" effect))
         (funcall handler conn args))))))

(defun ride-apl-session--batch-display (effects)
  "Coalesce runs of :display-output in EFFECTS into batches (AD-22)."
  (let (result run)
    (dolist (effect effects)
      (if (eq (car effect) :display-output)
          (push (cdr effect) run)
        (when run
          (push (list :display-output-batch (nreverse run)) result)
          (setq run nil))
        (push effect result)))
    (when run (push (list :display-output-batch (nreverse run)) result))
    (nreverse result)))

(defun ride-apl-session--on-died (conn reason detail)
  (setf (ride-apl-conn-death-reason conn) (cons reason detail))
  (ride-apl-session--cancel-timer conn)
  (ride-apl-transport-close (ride-apl-conn-process conn))
  (ride-apl-session--log conn "--" (format "session died: %s %s" reason
                                       (or detail "")))
  (message "ride-apl: session %s:%s died: %s%s"
           (ride-apl-conn-host conn) (ride-apl-conn-port conn) reason
           (if detail (format " (%s)" detail) ""))
  (run-hook-with-args 'ride-apl-session-died-hook conn reason detail))

(defun ride-apl-session--log (conn direction payload)
  (ride-apl-session--log-transcript conn direction payload)
  (with-current-buffer (ride-apl-session--log-buffer conn)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (format-time-string "%T.%3N ") direction " " payload "\n"))))

(defun ride-apl-session--log-transcript (conn direction payload)
  (let ((dir (pcase direction ("->" :out) ("<-" :in))))
    (when dir
      (push (ride-apl-session--transcript-entry
             dir (- (float-time) (ride-apl-conn-start-time conn)) payload)
            (ride-apl-conn-log conn)))))

(defun ride-apl-session--transcript-entry (dir elapsed payload)
  "AD-18 fixture entry for DIR/PAYLOAD: JSON as :msg, anything else as :raw."
  (if (and (string-prefix-p "[" payload)
           (ignore-errors (ride-apl-proto-parse payload)))
      (list :dir dir :t elapsed :msg (ride-apl-proto-parse payload))
    (list :dir dir :t elapsed
          :raw (base64-encode-string
                (encode-coding-string payload 'utf-8) t))))

(defun ride-apl-session--log-event (conn message)
  "Record a synthetic reducer event on CONN so replays are deterministic."
  (push (list :dir :event
              :t (- (float-time) (ride-apl-conn-start-time conn))
              :msg message)
        (ride-apl-conn-log conn))
  (with-current-buffer (ride-apl-session--log-buffer conn)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (format-time-string "%T.%3N ") "== " (format "%S" message) "\n"))))

(defun ride-apl-session-transcript (conn)
  "Chronological AD-18 transcript entries for CONN."
  (reverse (ride-apl-conn-log conn)))

(defun ride-apl-session--log-buffer (conn)
  (let ((name (format "*ride-apl-log:%s:%s*"
                      (ride-apl-conn-host conn) (ride-apl-conn-port conn))))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (special-mode)
          (current-buffer)))))

(provide 'ride-apl-conn)
;;; ride-apl-conn.el ends here
