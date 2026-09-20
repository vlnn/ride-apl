;;; ride-apl-eval.el --- Evaluate APL source, results inline -*- lexical-binding: t; -*-


;;; Commentary:
;; Commands that send source-buffer lines through the session's pending
;; queue, each tagged with an origin marker.  The reducer captures the
;; output produced between that line's Execute and the prompt's return
;; and emits an :eval-result effect; here it becomes a CIDER-style
;; " ⇒ value" overlay on the evaluated line.  The REPL buffer still
;; receives everything, so the full result is always one C-c C-z away.

;;; Code:

(require 'seq)
(require 'ride-apl-conn)
(require 'ride-apl-eldoc)
(require 'ride-apl-link)

(defcustom ride-apl-eval-result-display 'overlay
  "Where to show results of evaluating source lines.
The REPL buffer always shows them; this adds an inline overlay at the
evaluated line, an echo-area message, or nothing."
  :type '(choice (const overlay) (const echo) (const nil))
  :group 'ride-apl)

(defcustom ride-apl-eval-result-max-length 120
  "Characters of a result shown inline before truncation."
  :type 'natnum :group 'ride-apl)

(defface ride-apl-face-result '((t :inherit shadow))
  "Inline evaluation results." :group 'ride-apl)
(defface ride-apl-face-result-error '((t :inherit error))
  "Inline evaluation errors." :group 'ride-apl)

(declare-function ride-apl-pop-to-repl "ride-apl")
(declare-function ride-apl-edit-at-point "ride-apl-edit")
(declare-function ride-apl-goto-definition "ride-apl-edit")

(defvar ride-apl-eval-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'ride-apl-eval-line-or-region)
    (define-key map (kbd "C-c C-t") #'ride-apl-trace-line)
    (define-key map (kbd "C-c C-b") #'ride-apl-eval-buffer)
    (define-key map (kbd "C-c C-l") #'ride-apl-load-file)
    (define-key map (kbd "C-c C-z") #'ride-apl-pop-to-repl)
    (define-key map (kbd "C-c C-e") #'ride-apl-edit-at-point)
    (define-key map (kbd "M-.") #'ride-apl-goto-definition)
    map))

;;;###autoload
(define-minor-mode ride-apl-eval-minor-mode
  "Evaluate APL source from this buffer in the connected session.
Enable it in `dyalog-mode' buffers, e.g.:
  (add-hook \\='dyalog-mode-hook #\\='ride-apl-eval-minor-mode)"
  :lighter " RIDE"
  (if ride-apl-eval-minor-mode
      (progn (ride-apl-eldoc-setup)
             (add-hook 'after-save-hook #'ride-apl-link-after-save nil t))
    (ride-apl-eldoc-teardown)
    (remove-hook 'after-save-hook #'ride-apl-link-after-save t)))

(defun ride-apl-eval-line-or-region ()
  "Send the active region, or else the current line, to the session."
  (interactive)
  (if (use-region-p)
      (ride-apl-eval-region (region-beginning) (region-end))
    (ride-apl-eval-region (line-beginning-position) (line-end-position))))

(defun ride-apl-eval-region (start end)
  "Queue each non-blank line of the region, one Execute at a time."
  (interactive "r")
  (let ((lines (ride-apl-eval--lines-with-origins start end)))
    (unless lines (user-error "ride-apl: nothing to evaluate"))
    (ride-apl--dispatch-input lines)
    (message "ride-apl: %d line%s queued" (length lines)
             (if (= 1 (length lines)) "" "s"))))

(defun ride-apl-trace (expression)
  "Run EXPRESSION under the tracer in the connected session.
Interactively, prompt for it with the expression at point as the
default."
  (interactive (list (read-string "Trace: "
                                  (ignore-errors (ride-apl-trace--expression)))))
  (when (string-blank-p expression)
    (user-error "ride-apl: nothing to trace"))
  (ride-apl-trace--dispatch expression))

(defun ride-apl-trace-line ()
  "Run the current line, or the active single-line region, under the tracer.
The tracer opens on the expression's first line; from there `i' steps
into any function it calls, so code that only ever lives in a file or
scratch buffer is traced without setting a breakpoint in it.  The
expression's definitions must already be in the workspace (evaluate or
load the buffer first)."
  (interactive)
  (ride-apl-trace--dispatch (ride-apl-trace--expression)))

(defun ride-apl-trace--expression ()
  (let ((text (string-trim (if (use-region-p)
                               (buffer-substring-no-properties
                                (region-beginning) (region-end))
                             (buffer-substring-no-properties
                              (line-beginning-position) (line-end-position))))))
    (when (string-empty-p text)
      (user-error "ride-apl: nothing to trace"))
    (when (string-match-p "\n" text)
      (user-error "ride-apl: trace takes a single expression"))
    text))

(defun ride-apl-trace--dispatch (text)
  (let ((conn (ride-apl-current-conn)))
    (unless conn (user-error "ride-apl: no session"))
    (ride-apl-session--dispatch conn (list :trace-line text))))

(defun ride-apl-eval-buffer ()
  "Evaluate the whole buffer line by line."
  (interactive)
  (ride-apl-eval-region (point-min) (point-max)))

(defun ride-apl-load-file (&optional file)
  "Bring FILE (default: this buffer's file) into the workspace.
Under a linked root this notifies Link (mixing 2⎕FIX into a link
corrupts its bookkeeping); elsewhere it fixes the file with
2⎕FIX \\='file://...\\='.  Saves the buffer first when modified."
  (interactive)
  (let ((file (or file buffer-file-name
                  (user-error "ride-apl: buffer has no file"))))
    (when (and (equal file buffer-file-name) (buffer-modified-p))
      (basic-save-buffer))
    (ride-apl--dispatch-input
     (list (if (ride-apl-link-file-linked-p file)
               (ride-apl-link--notify-expression file)
             (format "2⎕FIX'file://%s'" (ride-apl--apl-quote file)))))))

(defun ride-apl-eval-clear-results (&optional start end)
  "Remove inline result overlays between START and END (default: all)."
  (interactive)
  (dolist (overlay (overlays-in (or start (point-min)) (or end (point-max))))
    (when (overlay-get overlay 'ride-apl-eval-result)
      (delete-overlay overlay))))

(defun ride-apl--dispatch-input (lines)
  (let ((conn (ride-apl-current-conn)))
    (unless conn (user-error "ride-apl: no session"))
    (ride-apl-session--dispatch conn (list :input lines))))

(defun ride-apl-eval--lines-with-origins (start end)
  "Non-blank lines of START..END as (TEXT . ORIGIN), ORIGIN an end-of-line marker."
  (save-excursion
    (goto-char start)
    (let (lines)
      (while (< (point) end)
        (let ((bol (point))
              (eol (min end (line-end-position))))
          (let ((text (buffer-substring-no-properties bol eol)))
            (unless (string-blank-p text)
              (push (cons text (list :marker (copy-marker eol))) lines))))
        (forward-line 1))
      (nreverse lines))))

;;; Effect handler and rendering.

(defun ride-apl-eval--handle-result (_conn args)
  (pcase-let ((`(,origin ,entries ,errorp) args))
    (let ((text (ride-apl-eval--result-text entries)))
      (when (and errorp text (ride-apl-eval--multiline-hint-p text))
        (message (concat "ride-apl: multi-line input needs Dyalog_LineEditor_Mode=1 "
                         "on the interpreter (or load the file with C-c C-l)")))
      (when (and text (plist-get origin :marker))
        (pcase ride-apl-eval-result-display
          ('overlay (ride-apl-eval--show origin text errorp))
          ('echo (message "%s" text)))))))

(defun ride-apl-eval--multiline-hint-p (text)
  "Non-nil when TEXT is the error a multi-line dfn hits with collection off."
  (string-match-p "Unpaired brace" text))

(ride-apl-session-register-effect :eval-result #'ride-apl-eval--handle-result)

(defun ride-apl-eval--result-text (entries)
  (let ((text (string-trim-right (mapconcat #'car entries ""))))
    (unless (string-empty-p text) text)))

(defun ride-apl-eval--show (origin text errorp)
  (let ((marker (plist-get origin :marker)))
    (if (not (and (markerp marker) (buffer-live-p (marker-buffer marker))))
        (message "ride-apl result: %s" text)
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (goto-char marker)
          (ride-apl-eval--place-overlay (line-beginning-position)
                                    (line-end-position)
                                    text errorp))))))

(defun ride-apl-eval--place-overlay (start end text errorp)
  (ride-apl-eval-clear-results start (min (1+ end) (point-max)))
  (let ((overlay (make-overlay start end nil t)))
    (overlay-put overlay 'ride-apl-eval-result t)
    (overlay-put overlay 'after-string
                 (propertize (concat " ⇒ " (ride-apl-eval--one-line text))
                             'face (if errorp
                                       'ride-apl-face-result-error
                                     'ride-apl-face-result)))
    (add-hook 'before-change-functions #'ride-apl-eval--clear-on-change nil t)))

(defun ride-apl-eval--one-line (text)
  (let ((flat (replace-regexp-in-string "\n" " ⏎ " text)))
    (if (> (length flat) ride-apl-eval-result-max-length)
        (concat (substring flat 0 ride-apl-eval-result-max-length) "…")
      flat)))

(defun ride-apl-eval--clear-on-change (&rest _)
  (remove-hook 'before-change-functions #'ride-apl-eval--clear-on-change t)
  (ride-apl-eval-clear-results))

(provide 'ride-apl-eval)
;;; ride-apl-eval.el ends here
