;;; ride-apl-test-common.el --- Shared test helpers -*- lexical-binding: t; -*-

(require 'ride-apl-repl)
(require 'ride-apl-conn)
(require 'ride-apl-test-server)

(defun ride-apl-test--fold (state messages)
  "Fold MESSAGES through the reducer; return (FINAL-STATE . ALL-EFFECTS)."
  (let (effects)
    (dolist (message messages)
      (pcase-let ((`(,next . ,step-effects) (ride-apl-session-step state message)))
        (setq state next)
        (setq effects (append effects step-effects))))
    (cons state effects)))

(defun ride-apl-test--connected-session ()
  (car (ride-apl-test--fold (car (ride-apl-session-init))
                        '(("SupportedProtocols" . "2")
                          ("UsingProtocol" . "2")
                          ("ReplyIdentify" . ((apiVersion . 1) (version . "20.0")))))))

(defun ride-apl-test--effect-types (effects)
  (mapcar #'car effects))

(defun ride-apl-test--wait-for (predicate &optional timeout)
  (let ((deadline (+ (float-time) (or timeout 3))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall predicate)))

(defun ride-apl-e2e--start ()
  "Fake repl server + attached REPL buffer; return (SERVER CONN BUFFER)."
  (let* ((server+port (ride-apl-testsrv-start 'repl))
         (conn (ride-apl-session-open "127.0.0.1" (cdr server+port)))
         (buffer (ride-apl-repl-attach conn)))
    (list (car server+port) conn buffer)))

(defun ride-apl-e2e--stop (server conn)
  (ride-apl-transport-close (ride-apl-conn-process conn))
  (delete-process server)
  (when (buffer-live-p (ride-apl-conn-repl-buffer conn))
    (kill-buffer (ride-apl-conn-repl-buffer conn)))
  (pcase-dolist (`(,_ . ,buffer) (ride-apl-conn-edit-buffers conn))
    (when (buffer-live-p buffer)
      (let ((ride-apl-edit--killing-by-effect t))
        (kill-buffer buffer))))
  (setq ride-apl--conns nil))

(defmacro ride-apl-e2e--with-repl (conn-var buffer-var &rest body)
  (declare (indent 2))
  `(pcase-let ((`(,server ,,conn-var ,,buffer-var) (ride-apl-e2e--start)))
     (unwind-protect (progn ,@body)
       (ride-apl-e2e--stop server ,conn-var))))

(defun ride-apl-e2e--ready-p (conn)
  (let ((state (ride-apl-conn-state conn)))
    (and (eq (ride-apl-session-conn-state state) 'connected)
         (eq (ride-apl-session-log-state state) 'done)
         (> (ride-apl-session-prompt-type state) 0))))

(defun ride-apl-e2e--type-and-send (buffer text)
  (with-current-buffer buffer
    (goto-char (point-max))
    (insert text)
    (ride-apl-repl-send-input)))

(provide 'ride-apl-test-common)
;;; ride-apl-test-common.el ends here
