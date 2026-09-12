;;; ride-apl-link.el --- Linked-directory (Link) sync -*- lexical-binding: t; -*-


;;; Commentary:
;; Support for working against a Dyalog Link'd directory (AD-24: files
;; are the source of truth).  Link replicates workspace->file on its
;; own (our SaveChanges path counts as the built-in editor), but the
;; file->workspace direction relies on a .NET file watcher that is
;; only dependable on Windows.  So Emacs tells the interpreter
;; explicitly: saving a file under a linked root sends ⎕SE.Link.Notify
;; through the normal input queue, visible in the REPL like any other
;; line.

;;; Code:

(require 'seq)
(require 'ride-apl-session)

(defcustom ride-apl-link-roots nil
  "Directories whose files belong to Link'd namespaces.
Files under these (or under the buffer-local `ride-apl-link-root') are
synced via ⎕SE.Link.Notify instead of 2⎕FIX."
  :type '(repeat directory) :group 'ride-apl)

(defcustom ride-apl-link-notify-on-save t
  "When non-nil, saving a linked file notifies the interpreter."
  :type 'boolean :group 'ride-apl)

(defvar-local ride-apl-link-root nil
  "Root of the Link'd directory this buffer's file belongs to.
Intended to be set as a directory-local variable at the project root.")
(put 'ride-apl-link-root 'safe-local-variable
     (lambda (value) (or (null value) (stringp value))))

(defun ride-apl-link-file-linked-p (file)
  "Non-nil when FILE lies under a configured linked root."
  (seq-some (lambda (root) (and root (file-in-directory-p file root)))
            (cons ride-apl-link-root ride-apl-link-roots)))

(defun ride-apl-link-after-save ()
  "Notify Link about the saved file when it lies under a linked root.
Installed on `after-save-hook' by `ride-apl-eval-minor-mode'."
  (when (and ride-apl-link-notify-on-save
             buffer-file-name
             (ride-apl-link-file-linked-p buffer-file-name))
    (let ((conn (ride-apl-current-conn)))
      (when (and conn (process-live-p (ride-apl-conn-process conn)))
        (ride-apl-session--dispatch
         conn (list :input
                    (list (ride-apl-link--notify-expression buffer-file-name))))
        (message "ride-apl: Link notified about %s"
                 (file-name-nondirectory buffer-file-name))))))

(defun ride-apl-link-create (namespace directory)
  "Link NAMESPACE to DIRECTORY and register it as a linked root.
Sends ]LINK.Create through the queue (output lands in the REPL) and
adds DIRECTORY to `ride-apl-link-roots' so saves under it notify the
interpreter from now on."
  (interactive (list (read-string "Namespace: " "#")
                     (read-directory-name "Directory: ")))
  (let ((conn (ride-apl-current-conn))
        (root (directory-file-name (expand-file-name directory))))
    (unless conn (user-error "ride-apl: no session"))
    (ride-apl-session--dispatch
     conn (list :input (list (format "]LINK.Create %s %s" namespace
                                     (ride-apl-link--command-path root)))))
    (add-to-list 'ride-apl-link-roots root)))

(defun ride-apl-link--command-path (path)
  "PATH as a ]command argument; double-quoted when it contains spaces."
  (if (string-match-p " " path) (format "\"%s\"" path) path))

(defun ride-apl-link-resync ()
  "Ask Link to resynchronise, e.g. after a git pull the watcher missed."
  (interactive)
  (let ((conn (ride-apl-current-conn)))
    (unless conn (user-error "ride-apl: no session"))
    (ride-apl-session--dispatch conn '(:input ("]LINK.Resync")))))

(defun ride-apl-link--notify-expression (file)
  "Link 4.0 API call for FILE.
Argument shape is per the Link 4.0 docs but unverified against a real
interpreter (PLAN, Link P0); adjust here only."
  (format "⎕SE.Link.Notify'%s'" (ride-apl--apl-quote (expand-file-name file))))

;;;###autoload
(defun ride-apl-link-setup-file-modes ()
  "Associate Link's source extensions with an APL major mode.
Uses `dyalog-mode' when installed, `prog-mode' otherwise; call from
your init file."
  (let ((mode (if (or (fboundp 'dyalog-mode) (require 'dyalog-mode nil t))
                  'dyalog-mode
                'prog-mode)))
    (dolist (extension '("aplf" "aplo" "apln" "aplc" "apli" "apla"))
      (add-to-list 'auto-mode-alist
                   (cons (format "\\.%s\\'" extension) mode)))))

(provide 'ride-apl-link)
;;; ride-apl-link.el ends here
