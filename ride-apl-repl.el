;;; ride-apl-repl.el --- RIDE session buffer -*- lexical-binding: t; -*-


;;; Commentary:
;; Plain special-purpose REPL buffer (AD-8, no comint).  Layout:
;; [output][prompt][input..(point-max)], tracked by two markers and
;; mutated only through the helpers here.  All rendering is driven by
;; effects registered with the session effect interpreter; user actions
;; enter the reducer as synthetic (:input ...) / (:interrupt ...) events.

;;; Code:

(require 'ring)
(require 'ride-apl-conn)

(defcustom ride-apl-repl-max-size (* 2 1024 1024)
  "Character cap for the session buffer; nil means unbounded (AD-22)."
  :type '(choice natnum (const nil)) :group 'ride-apl)

(defcustom ride-apl-repl-history-size 100
  "Entries kept in the per-session input history ring."
  :type 'natnum :group 'ride-apl)

(defface ride-apl-face-output '((t :inherit default))
  "Session output." :group 'ride-apl)
(defface ride-apl-face-error '((t :inherit error))
  "APL error messages and stderr-ish output." :group 'ride-apl)
(defface ride-apl-face-echoed-input '((t :inherit font-lock-keyword-face))
  "Input echoed back by the interpreter." :group 'ride-apl)
(defface ride-apl-face-quad-output '((t :inherit font-lock-string-face))
  "Quad and quote-quad output." :group 'ride-apl)
(defface ride-apl-face-prompt '((t :inherit minibuffer-prompt))
  "Prompt region." :group 'ride-apl)

(defvar-local ride-apl-repl--conn nil)
(defvar-local ride-apl-repl--prompt-start nil)
(defvar-local ride-apl-repl--input-start nil)
(defvar-local ride-apl-repl--history nil)
(defvar-local ride-apl-repl--history-pos nil)

(defvar ride-apl-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ride-apl-repl-send-input)
    (define-key map (kbd "C-<return>") #'newline)
    (define-key map (kbd "C-c C-c") #'ride-apl-repl-interrupt-weak)
    (define-key map (kbd "C-c C-k") #'ride-apl-repl-interrupt-strong)
    (define-key map (kbd "M-p") #'ride-apl-repl-history-previous)
    (define-key map (kbd "M-n") #'ride-apl-repl-history-next)
    (define-key map (kbd "C-c C-e") #'ride-apl-edit-at-point)
    map))

(declare-function ride-apl-edit-at-point "ride-apl-edit")

(define-derived-mode ride-apl-repl-mode fundamental-mode "RIDE-REPL"
  "Session buffer for a RIDE connection."
  (setq-local scroll-conservatively 101))

(defun ride-apl-repl-attach (conn)
  "Create and wire the REPL buffer for CONN; return the buffer."
  (with-current-buffer (get-buffer-create (ride-apl-repl--buffer-name conn))
    (ride-apl-repl-mode)
    (setq ride-apl-repl--conn conn)
    (setq ride-apl-repl--prompt-start (point-min-marker))
    (setq ride-apl-repl--input-start (point-min-marker))
    (setq ride-apl-repl--history (make-ring ride-apl-repl-history-size))
    (setq buffer-read-only t)
    (setf (ride-apl-conn-repl-buffer conn) (current-buffer))
    (current-buffer)))

(defun ride-apl-repl--buffer-name (conn)
  (format "*ride-apl-repl:%s:%s*" (ride-apl-conn-host conn) (ride-apl-conn-port conn)))

;;; Effect handlers.

(defun ride-apl-repl--handle-display-batch (conn args)
  (ride-apl-repl--with-buffer conn
    (lambda ()
      (let ((inhibit-read-only t)
            (follow (>= (point) (marker-position ride-apl-repl--prompt-start))))
        (save-excursion
          (goto-char ride-apl-repl--prompt-start)
          (let ((start (point)))
            (dolist (entry (car args))
              (insert (ride-apl-repl--fontify (car entry) (cadr entry))))
            (ride-apl-repl--advance-markers (- (point) start) start)))
        (ride-apl-repl--truncate)
        (when follow (goto-char (point-max)))))))

(defun ride-apl-repl--handle-set-prompt (conn args)
  (ride-apl-repl--with-buffer conn
    (lambda ()
      (let ((inhibit-read-only t)
            (type (car args)))
        (save-excursion
          (delete-region ride-apl-repl--prompt-start ride-apl-repl--input-start)
          (goto-char ride-apl-repl--prompt-start)
          (insert (propertize (ride-apl-repl--prompt-string type)
                              'face 'ride-apl-face-prompt
                              'read-only t
                              'front-sticky t
                              'rear-nonsticky t))
          (set-marker ride-apl-repl--input-start (point)))
        (setq buffer-read-only (eql type 0))
        (setq mode-name (if (eql type 0) "RIDE-REPL:busy" "RIDE-REPL"))
        (goto-char (point-max))))))

(defun ride-apl-repl--handle-focus (conn _args)
  (when (buffer-live-p (ride-apl-conn-repl-buffer conn))
    (display-buffer (ride-apl-conn-repl-buffer conn))))

(defun ride-apl-repl--on-session-died (conn reason detail)
  (ride-apl-repl--with-buffer conn
    (lambda ()
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (propertize (format "\n--- session died: %s %s ---\n"
                                    reason (or detail ""))
                            'face 'ride-apl-face-error))
        (setq buffer-read-only t)
        (setq mode-name "RIDE-REPL:dead")))))

(defun ride-apl-repl--handle-show-dialog (conn args)
  (pcase-let ((`(,kind ,dialog) args))
    (run-at-time 0 nil #'ride-apl-repl--prompt-dialog conn kind dialog)))

(defun ride-apl-repl--prompt-dialog (conn kind dialog)
  (let ((token (alist-get 'token dialog)))
    (ride-apl-session--dispatch
     conn (list :dialog-reply kind token
                (condition-case nil
                    (ride-apl-repl--read-dialog kind dialog)
                  (quit (if (eq kind :string) nil -1)))))))

(defun ride-apl-repl--read-dialog (kind dialog)
  (pcase kind
    (:string (read-string (ride-apl-repl--dialog-prompt dialog)
                          (or (alist-get 'initialValue dialog)
                              (alist-get 'defaultValue dialog))))
    (_ (let ((choices (ride-apl-repl--dialog-choices kind dialog)))
         (cdr (assoc (completing-read (ride-apl-repl--dialog-prompt dialog)
                                      choices nil t)
                     choices))))))

(defun ride-apl-repl--dialog-choices (kind dialog)
  "Alist of (LABEL . REPLY-INDEX) for an :options or :task DIALOG.
Task buttonText entries reply as 100+i per the protocol."
  (append (seq-map-indexed (lambda (label i) (cons label i))
                           (alist-get 'options dialog))
          (when (eq kind :task)
            (seq-map-indexed (lambda (label i) (cons label (+ 100 i)))
                             (alist-get 'buttonText dialog)))))

(defun ride-apl-repl--dialog-prompt (dialog)
  (format "%s%s: "
          (or (alist-get 'title dialog) "Dyalog")
          (if (alist-get 'text dialog)
              (concat " — " (alist-get 'text dialog))
            "")))

(ride-apl-session-register-effect :show-dialog #'ride-apl-repl--handle-show-dialog)
(ride-apl-session-register-effect :display-output-batch #'ride-apl-repl--handle-display-batch)
(ride-apl-session-register-effect :set-prompt #'ride-apl-repl--handle-set-prompt)
(ride-apl-session-register-effect :focus-repl #'ride-apl-repl--handle-focus)
(add-hook 'ride-apl-session-died-hook #'ride-apl-repl--on-session-died)

;;; Rendering helpers.

(defun ride-apl-repl--with-buffer (conn thunk)
  (let ((buffer (ride-apl-conn-repl-buffer conn)))
    (if (buffer-live-p buffer)
        (with-current-buffer buffer (funcall thunk))
      (message "ride-apl debug: REPL output for dead buffer dropped"))))

(defun ride-apl-repl--advance-markers (length start)
  (when (= (marker-position ride-apl-repl--prompt-start) start)
    (set-marker ride-apl-repl--prompt-start (+ start length)))
  (set-marker ride-apl-repl--input-start
              (+ (marker-position ride-apl-repl--input-start) length)))

(defun ride-apl-repl--fontify (text type)
  (propertize text
              'face (ride-apl-repl--face-for type)
              'read-only t
              'front-sticky t
              'rear-nonsticky t))

(defun ride-apl-repl--face-for (type)
  (pcase type
    ((or 3 5) 'ride-apl-face-error)
    ((or 11 14) 'ride-apl-face-echoed-input)
    ((or 7 8) 'ride-apl-face-quad-output)
    (_ 'ride-apl-face-output)))

(defun ride-apl-repl--prompt-string (type)
  (pcase type
    ((or 1 5) "      ")
    (2 "⎕:    ")
    (3 "∇:    ")
    (4 "⍞:    ")
    (_ "")))

(defun ride-apl-repl--truncate ()
  (when (and ride-apl-repl-max-size
             (> (buffer-size) ride-apl-repl-max-size))
    (let ((inhibit-read-only t)
          (cut (min (marker-position ride-apl-repl--prompt-start)
                    (save-excursion
                      (goto-char (- (point-max) ride-apl-repl-max-size))
                      (line-beginning-position 2)))))
      (delete-region (point-min) cut))))

;;; Commands.

(defun ride-apl-repl-send-input ()
  "Submit the input region to the interpreter."
  (interactive)
  (let ((text (buffer-substring-no-properties ride-apl-repl--input-start (point-max))))
    (delete-region ride-apl-repl--input-start (point-max))
    (when (string-match-p "[^ \t\n]" text)
      (ring-insert ride-apl-repl--history text))
    (setq ride-apl-repl--history-pos nil)
    (ride-apl-session--dispatch ride-apl-repl--conn
                            (list :input (split-string text "\n")))))

(defun ride-apl-repl-interrupt-weak ()
  "Send a weak interrupt, bypassing the pending-line queue."
  (interactive)
  (ride-apl-session--dispatch ride-apl-repl--conn '(:interrupt :weak)))

(defun ride-apl-repl-interrupt-strong ()
  "Send a strong interrupt, bypassing the pending-line queue."
  (interactive)
  (ride-apl-session--dispatch ride-apl-repl--conn '(:interrupt :strong)))

(defun ride-apl-repl-history-previous ()
  "Replace the input region with the previous history entry."
  (interactive)
  (ride-apl-repl--history-move 1))

(defun ride-apl-repl-history-next ()
  "Replace the input region with the next history entry."
  (interactive)
  (ride-apl-repl--history-move -1))

(defun ride-apl-repl--history-move (delta)
  (when (ring-empty-p ride-apl-repl--history)
    (user-error "ride-apl: no input history"))
  (setq ride-apl-repl--history-pos
        (mod (+ (or ride-apl-repl--history-pos (if (> delta 0) -1 0)) delta)
             (ring-length ride-apl-repl--history)))
  (delete-region ride-apl-repl--input-start (point-max))
  (goto-char (point-max))
  (insert (ring-ref ride-apl-repl--history ride-apl-repl--history-pos)))

(defun ride-apl-set-width ()
  "Send the current REPL window width to the interpreter as ⎕PW."
  (interactive)
  (let* ((conn (or ride-apl-repl--conn (ride-apl-current-conn)))
         (window (get-buffer-window (ride-apl-conn-repl-buffer conn))))
    (ride-apl-session--dispatch
     conn (list :set-pw (if window (- (window-width window) 1) 80)))))

(provide 'ride-apl-repl)
;;; ride-apl-repl.el ends here
