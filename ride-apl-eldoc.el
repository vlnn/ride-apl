;;; ride-apl-eldoc.el --- Eldoc via RIDE value tips -*- lexical-binding: t; -*-


;;; Commentary:
;; An async member of `eldoc-documentation-functions' that asks the
;; connected interpreter for a GetValueTip about the name at point.
;; When a session is live it claims eldoc, so live workspace values win
;; over static documentation (e.g. gnu-apl-mode's); with no session it
;; returns nil and other providers take over.  Requires the Emacs 28+
;; eldoc API; on older eldoc the setup is a no-op.

;;; Code:

(require 'eldoc)
(require 'ride-apl-session)
(require 'ride-apl-repl)

(defun ride-apl-eldoc-function (callback &rest _)
  "Document the position at point from the live session, asynchronously.
Return non-nil when a request was issued (CALLBACK will be called),
nil when there is no usable session or nothing at point."
  (let ((conn (ride-apl-current-conn)))
    (pcase (and (ride-apl-eldoc--usable-p conn) (ride-apl-eldoc--context))
      (`(,line . ,pos)
       (ride-apl-value-tip conn line pos
                       (lambda (reply)
                         (funcall callback (ride-apl-eldoc--format reply))))
       t))))

(defun ride-apl-eldoc-setup ()
  "Make RIDE the first eldoc provider in this buffer.
A buffer-local legacy `eldoc-documentation-function' would shadow the
new hook entirely, so it is demoted to an ordinary hook member first."
  (when (boundp 'eldoc-documentation-functions)
    (ride-apl-eldoc--demote-legacy-function)
    (add-hook 'eldoc-documentation-functions #'ride-apl-eldoc-function -90 t)
    (eldoc-mode 1)))

(defun ride-apl-eldoc-teardown ()
  "Stop consulting RIDE for eldoc in this buffer."
  (when (boundp 'eldoc-documentation-functions)
    (remove-hook 'eldoc-documentation-functions #'ride-apl-eldoc-function t)))

(add-hook 'ride-apl-repl-mode-hook #'ride-apl-eldoc-setup)

(defun ride-apl-eldoc--demote-legacy-function ()
  (when (and (local-variable-p 'eldoc-documentation-function)
             (functionp eldoc-documentation-function)
             (not (eq eldoc-documentation-function
                      'eldoc-documentation-default)))
    (let ((legacy eldoc-documentation-function))
      (add-hook 'eldoc-documentation-functions
                (lambda (_callback &rest _) (funcall legacy))
                50 t))
    (kill-local-variable 'eldoc-documentation-function)))

(defun ride-apl-eldoc--usable-p (conn)
  (and conn
       (process-live-p (ride-apl-conn-process conn))
       (eq (ride-apl-session-conn-state (ride-apl-conn-state conn)) 'connected)))

(defun ride-apl-eldoc--context ()
  "Return (LINE . POS) for the value tip at point, else nil.
In the REPL the line is the input region; elsewhere the current line."
  (pcase-let ((`(,start . ,end) (ride-apl-eldoc--line-bounds)))
    (let ((line (buffer-substring-no-properties start end))
          (pos (- (point) start)))
      (when (and (<= 0 pos (length line))
                 (string-match-p "[^ \t]" line))
        (cons line pos)))))

(defun ride-apl-eldoc--line-bounds ()
  (if (derived-mode-p 'ride-apl-repl-mode)
      (cons (marker-position ride-apl-repl--input-start) (point-max))
    (cons (line-beginning-position) (line-end-position))))

(defun ride-apl-eldoc--format (reply)
  (let ((tip (alist-get 'tip reply)))
    (when (and tip (not (seq-every-p #'string-empty-p tip)))
      (string-trim-right (string-join tip "\n")))))

(provide 'ride-apl-eldoc)
;;; ride-apl-eldoc.el ends here
