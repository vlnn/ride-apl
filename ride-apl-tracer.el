;;; ride-apl-tracer.el --- RIDE tracer windows -*- lexical-binding: t; -*-


;;; Commentary:
;; Tracer window UI (M4).  Tracer buffers are the editor buffers from
;; ride-apl-edit.el with `debugger:true'; this file adds the current-line
;; highlight, breakpoint marks, and single-key stepping mirroring RIDE
;; (i into, o over, c continue, u step out, b toggle stop).  The
;; 0-based protocol lines in :highlight-line and :set-stops convert to
;; buffer positions here only (AD-19).

;;; Code:

(require 'ride-apl-session)
(require 'ride-apl-edit)

(defface ride-apl-face-trace-highlight '((t :inherit highlight :extend t))
  "Current execution line in a tracer window." :group 'ride-apl)
(defface ride-apl-face-stop '((t :inherit error :weight bold))
  "Breakpoint marks." :group 'ride-apl)

(defvar-local ride-apl-tracer--highlight nil)
(defvar-local ride-apl-tracer--stop-overlays nil)

(defvar ride-apl-tracer-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "i") #'ride-apl-tracer-step-into)
    (define-key map (kbd "o") #'ride-apl-tracer-step-over)
    (define-key map (kbd "c") #'ride-apl-tracer-continue)
    (define-key map (kbd "u") #'ride-apl-tracer-step-out)
    (define-key map (kbd "b") #'ride-apl-tracer-toggle-stop)
    (define-key map (kbd "k") #'ride-apl-tracer-cutback)
    map))

(define-minor-mode ride-apl-tracer-mode
  "Single-key stepping in a RIDE tracer window."
  :lighter " RIDE-Trace"
  (setq buffer-read-only ride-apl-tracer-mode))

;;; Commands.

(defun ride-apl-tracer--step (kind)
  (ride-apl-session--dispatch ride-apl-edit--conn
                          (list :step kind ride-apl-edit--win-id)))

(defun ride-apl-tracer-step-into ()
  "Step into the current line."
  (interactive)
  (ride-apl-tracer--step :into))

(defun ride-apl-tracer-step-over ()
  "Execute the current line and stop on the next."
  (interactive)
  (ride-apl-tracer--step :over))

(defun ride-apl-tracer-continue ()
  "Resume the current thread."
  (interactive)
  (ride-apl-tracer--step :continue))

(defun ride-apl-tracer-step-out ()
  "Run to the next line of the caller."
  (interactive)
  (ride-apl-tracer--step :out))

(defun ride-apl-tracer-cutback ()
  "Cut the stack back one level without executing the remainder."
  (interactive)
  (ride-apl-tracer--step :cutback))

(defun ride-apl-tracer-toggle-stop ()
  "Toggle a breakpoint on the current line."
  (interactive)
  (let* ((line (1- (line-number-at-pos)))
         (stops (plist-get (ride-apl-edit--record ride-apl-edit--conn
                                              ride-apl-edit--win-id)
                           :stop)))
    (ride-apl-session--dispatch
     ride-apl-edit--conn
     (list :set-stops-request ride-apl-edit--win-id
           (if (memq line stops)
               (remq line stops)
             (sort (cons line (copy-sequence stops)) #'<))))))

;;; Effect handlers.

(defun ride-apl-tracer--handle-highlight (conn args)
  (pcase-let ((`(,id ,line ,end-line ,_start-col ,_end-col) args))
    (let ((buffer (alist-get id (ride-apl-conn-edit-buffers conn))))
      (if (not (buffer-live-p buffer))
          (message "ride-apl debug: highlight for missing buffer %s" id)
        (with-current-buffer buffer
          (ride-apl-tracer--move-highlight line (or end-line line)))))))

(defun ride-apl-tracer--move-highlight (line end-line)
  "Highlight protocol LINE..END-LINE; conversion to positions here (AD-19)."
  (let ((start (ride-apl-tracer--line-pos line))
        (end (ride-apl-tracer--line-pos (1+ end-line))))
    (if (overlayp ride-apl-tracer--highlight)
        (move-overlay ride-apl-tracer--highlight start end)
      (setq ride-apl-tracer--highlight (make-overlay start end))
      (overlay-put ride-apl-tracer--highlight 'face 'ride-apl-face-trace-highlight)
      (overlay-put ride-apl-tracer--highlight 'ride-apl-highlight t))
    (goto-char start)))

(defun ride-apl-tracer--handle-set-stops (conn args)
  (pcase-let ((`(,id ,stops) args))
    (let ((buffer (alist-get id (ride-apl-conn-edit-buffers conn))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (ride-apl-tracer--render-stops stops))))))

(defun ride-apl-tracer--render-stops (stops)
  (mapc #'delete-overlay ride-apl-tracer--stop-overlays)
  (setq ride-apl-tracer--stop-overlays
        (mapcar (lambda (line)
                  (let* ((start (ride-apl-tracer--line-pos line))
                         (overlay (make-overlay start
                                                (ride-apl-tracer--line-pos
                                                 (1+ line)))))
                    (overlay-put overlay 'face 'ride-apl-face-stop)
                    (overlay-put overlay 'ride-apl-stop line)
                    overlay))
                stops)))

(defun ride-apl-tracer--line-pos (line)
  "Buffer position of the start of 0-based protocol LINE."
  (save-excursion
    (goto-char (point-min))
    (forward-line line)
    (point)))

(defun ride-apl-tracer--after-render (record)
  (ride-apl-tracer-mode (if (plist-get record :tracer) 1 -1))
  (ride-apl-tracer--render-stops (plist-get record :stop)))

(add-hook 'ride-apl-edit-render-functions #'ride-apl-tracer--after-render)
(ride-apl-session-register-effect :highlight-line #'ride-apl-tracer--handle-highlight)
(ride-apl-session-register-effect :set-stops #'ride-apl-tracer--handle-set-stops)

(provide 'ride-apl-tracer)
;;; ride-apl-tracer.el ends here
