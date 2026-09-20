;;; ride-apl-edit.el --- RIDE editor windows -*- lexical-binding: t; -*-


;;; Commentary:
;; Editor window UI (AD-11: the interpreter owns windows; we send Edit
;; and react to OpenWindow/UpdateWindow/CloseWindow).  All 0-based
;; protocol coordinates are converted to buffer positions here and
;; nowhere else (AD-19).  Buffers may be killed by the user at any
;; time; the window table survives and buffer-facing effects for
;; missing buffers degrade to debug notifications (AD-20).  On
;; UpdateWindow over local modifications the interpreter wins: local
;; text goes to the kill ring with a warning (AD-21).

;;; Code:

(require 'ride-apl-conn)
(require 'xref)

(declare-function dyalog-mode "dyalog-mode")

(defvar-local ride-apl-edit--conn nil)
(defvar-local ride-apl-edit--win-id nil)
(defvar ride-apl-edit--killing-by-effect nil)
(defvar ride-apl-edit-render-functions nil
  "Run in the window buffer after rendering, with the window record.")

(defvar ride-apl-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'ride-apl-edit-save)
    (define-key map (kbd "C-c C-q") #'kill-current-buffer)
    map))

(define-minor-mode ride-apl-edit-mode
  "Minor mode wiring a buffer to a RIDE editor window."
  :lighter " RIDE-Edit"
  (if ride-apl-edit-mode
      (add-hook 'kill-buffer-hook #'ride-apl-edit--on-kill nil t)
    (remove-hook 'kill-buffer-hook #'ride-apl-edit--on-kill t)))

;;;###autoload
(defun ride-apl-edit (name)
  "Ask the interpreter to open an editor window for NAME."
  (interactive (list (read-string "Edit name: " (thing-at-point 'symbol t))))
  (let ((conn (ride-apl-current-conn)))
    (unless conn (user-error "ride-apl: no session"))
    (ride-apl-session--dispatch conn
                            (list :edit name 0 (ride-apl-edit--unsaved conn)))))

(defun ride-apl-edit-at-point ()
  "Ask the interpreter to edit the name at point, RIDE-style:
the whole current line plus the cursor position within it."
  (interactive)
  (let ((conn (or ride-apl-edit--conn (ride-apl-current-conn))))
    (unless conn (user-error "ride-apl: no session"))
    (ride-apl-session--dispatch
     conn (list :edit
                (buffer-substring-no-properties (line-beginning-position)
                                                (line-end-position))
                (- (point) (line-beginning-position))
                (ride-apl-edit--unsaved conn)))))

(defun ride-apl-goto-definition (name)
  "Jump to NAME's definition, letting the interpreter resolve it.
Pushes the xref marker stack so \\[xref-go-back] returns.  Linked
names land in their file (AD-24 redirect); file-less ones in a
`*ride-apl-edit:*' buffer."
  (interactive (list (or (thing-at-point 'symbol t)
                         (read-string "Definition of: "))))
  (let ((conn (or ride-apl-edit--conn (ride-apl-current-conn))))
    (unless conn (user-error "ride-apl: no session"))
    (xref-push-marker-stack)
    (ride-apl-session--dispatch conn
                            (list :edit name 0 (ride-apl-edit--unsaved conn)))))

(defun ride-apl-close-all-windows ()
  "Ask the interpreter to close every editor and tracer window."
  (interactive)
  (let ((conn (or ride-apl-edit--conn (ride-apl-current-conn))))
    (unless conn (user-error "ride-apl: no session"))
    (ride-apl-session--dispatch conn '(:close-all-windows))))

(defun ride-apl-edit-save ()
  "Send the buffer contents to the interpreter as SaveChanges."
  (interactive)
  (ride-apl-session--dispatch
   ride-apl-edit--conn
   (list :save-window ride-apl-edit--win-id
         (split-string (buffer-substring-no-properties (point-min) (point-max))
                       "\n")
         (ride-apl-edit--current-stops))))

(defun ride-apl-edit--current-stops ()
  (plist-get (ride-apl-edit--record ride-apl-edit--conn ride-apl-edit--win-id) :stop))

(defun ride-apl-edit--unsaved (conn)
  "Alist of (WIN-ID . TEXT) for modified editor buffers (AD-21 mitigation)."
  (let (unsaved)
    (pcase-dolist (`(,id . ,buffer) (ride-apl-conn-edit-buffers conn))
      (when (and (buffer-live-p buffer) (buffer-modified-p buffer))
        (push (cons id (with-current-buffer buffer
                         (buffer-substring-no-properties (point-min) (point-max))))
              unsaved)))
    (nreverse unsaved)))

;;; Effect handlers.

(defcustom ride-apl-edit-visit-files t
  "When non-nil, windows backed by a readable file open the file itself.
The protocol window is released via the normal close handshake;
tracer windows always use protocol buffers (AD-24)."
  :type 'boolean :group 'ride-apl)

(defun ride-apl-edit--handle-open (conn args)
  (let ((record (car args)))
    (if (ride-apl-edit--visit-instead-p record)
        (run-at-time 0 nil #'ride-apl-edit--visit-file conn record)
      (ride-apl-edit--open-protocol-buffer conn record))))

(defun ride-apl-edit--visit-instead-p (record)
  (and ride-apl-edit-visit-files
       (not (plist-get record :tracer))
       (let ((file (plist-get record :filename)))
         (and (stringp file)
              (not (string-empty-p file))
              (file-readable-p file)))))

(defun ride-apl-edit--visit-file (conn record)
  "AD-24: the file is the source of truth; release the protocol window."
  (pop-to-buffer (find-file-noselect (plist-get record :filename)))
  (widen)
  (goto-char (point-min))
  (forward-line (or (plist-get record :current-row) 0))
  (when (ride-apl-edit--stale-p record)
    (message "ride-apl warn: workspace copy of %s differs from %s; M-x ride-apl-link-resync?"
             (plist-get record :name)
             (file-name-nondirectory (plist-get record :filename))))
  (ride-apl-session--dispatch
   conn (list :close-window-request (plist-get record :id))))

(defun ride-apl-edit--stale-p (record)
  "Non-nil when RECORD's text differs from the current buffer's content."
  (not (equal (ride-apl-edit--trimmed-lines
               (split-string (buffer-substring-no-properties
                              (point-min) (point-max))
                             "\n"))
              (ride-apl-edit--trimmed-lines
               (append (plist-get record :text) nil)))))

(defun ride-apl-edit--trimmed-lines (lines)
  (if (equal (last lines) '("")) (butlast lines) lines))

(defun ride-apl-edit--open-protocol-buffer (conn record)
  (let* ((id (plist-get record :id))
         (buffer (get-buffer-create (ride-apl-edit--buffer-name record))))
    (setf (alist-get id (ride-apl-conn-edit-buffers conn)) buffer)
    (with-current-buffer buffer
      (ride-apl-edit--ensure-major-mode)
      (setq ride-apl-edit--conn conn)
      (setq ride-apl-edit--win-id id)
      (ride-apl-edit-mode 1)
      (ride-apl-edit--render record))
    (display-buffer buffer)))

(defun ride-apl-edit--handle-update (conn args)
  (pcase-let ((`(,id ,record) args))
    (let ((buffer (alist-get id (ride-apl-conn-edit-buffers conn))))
      (cond
       ((not (buffer-live-p buffer))
        (message "ride-apl debug: UpdateWindow for missing buffer %s" id))
       (t (with-current-buffer buffer
            (when (buffer-modified-p)
              (kill-new (buffer-substring-no-properties (point-min) (point-max)))
              (message "ride-apl warn: local edits to %s replaced by interpreter; old text in kill ring"
                       (plist-get record :name)))
            (ride-apl-edit--render record)))))))

(defun ride-apl-edit--handle-close (conn args)
  (let* ((id (car args))
         (buffer (alist-get id (ride-apl-conn-edit-buffers conn))))
    (setf (ride-apl-conn-edit-buffers conn)
          (assq-delete-all id (ride-apl-conn-edit-buffers conn)))
    (when (buffer-live-p buffer)
      (let ((ride-apl-edit--killing-by-effect t))
        (kill-buffer buffer)))))

(defun ride-apl-edit--handle-focus (conn args)
  (let ((buffer (alist-get (car args) (ride-apl-conn-edit-buffers conn))))
    (when (buffer-live-p buffer)
      (display-buffer buffer))))

(defun ride-apl-edit--handle-saved (conn args)
  (let ((buffer (alist-get (car args) (ride-apl-conn-edit-buffers conn))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (set-buffer-modified-p nil))
      (message "ride-apl: fixed %s" (buffer-name buffer)))))

(ride-apl-session-register-effect :open-window #'ride-apl-edit--handle-open)
(ride-apl-session-register-effect :update-window #'ride-apl-edit--handle-update)
(ride-apl-session-register-effect :close-window #'ride-apl-edit--handle-close)
(ride-apl-session-register-effect :focus-window #'ride-apl-edit--handle-focus)
(ride-apl-session-register-effect :window-saved #'ride-apl-edit--handle-saved)

;;; Internals.

(defun ride-apl-edit--render (record)
  "Replace buffer contents from RECORD; AD-19 conversion happens here."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (mapconcat #'identity (plist-get record :text) "\n"))
    (goto-char (point-min))
    (forward-line (or (plist-get record :current-row) 0))
    (setq buffer-read-only (plist-get record :read-only))
    (set-buffer-modified-p nil)
    (run-hook-with-args 'ride-apl-edit-render-functions record)))

(defun ride-apl-edit--buffer-name (record)
  (format "*ride-apl-%s:%s*"
          (if (plist-get record :tracer) "trace" "edit")
          (plist-get record :name)))

(defun ride-apl-edit--ensure-major-mode ()
  (cond ((fboundp 'dyalog-mode) (unless (eq major-mode 'dyalog-mode)
                                  (dyalog-mode)))
        ((require 'dyalog-mode nil t) (dyalog-mode))
        (t (unless (derived-mode-p 'prog-mode) (prog-mode)))))

(defun ride-apl-edit--record (conn id)
  (alist-get id (ride-apl-session-windows (ride-apl-conn-state conn))))

(defun ride-apl-edit--on-kill ()
  (when (and (not ride-apl-edit--killing-by-effect)
             ride-apl-edit--conn ride-apl-edit--win-id)
    (setf (ride-apl-conn-edit-buffers ride-apl-edit--conn)
          (assq-delete-all ride-apl-edit--win-id
                           (ride-apl-conn-edit-buffers ride-apl-edit--conn)))
    (ride-apl-session--dispatch ride-apl-edit--conn
                            (list :close-window-request ride-apl-edit--win-id))))

(provide 'ride-apl-edit)
;;; ride-apl-edit.el ends here
