;;; ride-apl-tracer.el --- RIDE tracer windows -*- lexical-binding: t; -*-


;;; Commentary:
;; Tracer window UI (M4).  Tracer buffers are the editor buffers from
;; ride-apl-edit.el with `debugger:true'; this file adds the current-line
;; highlight, breakpoint marks, and single-key stepping mirroring RIDE
;; (i into, o over, c continue, u step out, b toggle stop).  The
;; 0-based protocol lines in :highlight-line and :set-stops convert to
;; buffer positions here only (AD-19).

;;; Code:

(require 'ride-apl-conn)
(require 'ride-apl-edit)

(defface ride-apl-face-trace-highlight '((t :inherit highlight :extend t))
  "Current execution line in a tracer window." :group 'ride-apl)
(defface ride-apl-face-stop '((t :inherit error :weight bold))
  "Breakpoint marks rendered as a whole-line face." :group 'ride-apl)
(defface ride-apl-face-stop-fringe '((t :inherit error))
  "Breakpoint marks rendered in the fringe." :group 'ride-apl)

(defcustom ride-apl-tracer-stop-indicator 'auto
  "How breakpoints are marked in tracer buffers.
`fringe' puts a dot in the left fringe, `line' puts a face on the
whole line, `auto' picks fringe on graphic displays and line on ttys."
  :type '(choice (const auto) (const fringe) (const line))
  :group 'ride-apl)

(defcustom ride-apl-tracer-pop-on-open t
  "When nil, a new tracer window does not pop up a buffer (AD-23).
The buffer is still created and tracked; a message names the stopped
thread instead, so a background thread hitting a stop cannot grab the
display while you work elsewhere."
  :type 'boolean :group 'ride-apl)

(defvar-local ride-apl-tracer--highlight nil)
(defvar-local ride-apl-tracer--stop-overlays nil)

(when (fboundp 'define-fringe-bitmap)
  (define-fringe-bitmap 'ride-apl-tracer--stop-circle
    [#b00111100 #b01111110 #b11111111 #b11111111
     #b11111111 #b11111111 #b01111110 #b00111100]))

(defvar ride-apl-tracer-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "i") #'ride-apl-tracer-step-into)
    (define-key map (kbd "o") #'ride-apl-tracer-step-over)
    (define-key map (kbd "c") #'ride-apl-tracer-continue)
    (define-key map (kbd "u") #'ride-apl-tracer-step-out)
    (define-key map (kbd "b") #'ride-apl-tracer-toggle-stop)
    (define-key map (kbd "k") #'ride-apl-tracer-cutback)
    (define-key map (kbd "n") #'ride-apl-tracer-forward)
    (define-key map (kbd "p") #'ride-apl-tracer-backward)
    (define-key map (kbd "I") #'ride-apl-tracer-primitive)
    (define-key map (kbd "r") #'ride-apl-restart-threads)
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

(defun ride-apl-tracer-forward ()
  "Move the line pointer down one line without executing it."
  (interactive)
  (ride-apl-tracer--step :forward))

(defun ride-apl-tracer-backward ()
  "Move the line pointer up one line without executing anything."
  (interactive)
  (ride-apl-tracer--step :backward))

(defun ride-apl-tracer-primitive ()
  "Step into the current line at primitive granularity."
  (interactive)
  (ride-apl-tracer--step :primitive))

(defun ride-apl-restart-threads ()
  "Resume all paused threads."
  (interactive)
  (ride-apl-tracer--dispatch '(:restart-threads)))

(defun ride-apl-clear-trace-stop-monitor ()
  "Clear all trace, stop and monitor settings in the workspace."
  (interactive)
  (ride-apl-tracer--dispatch '(:clear-trace-stop-monitor)))

(defun ride-apl-tracer--dispatch (message)
  (let ((conn (or ride-apl-edit--conn (ride-apl-current-conn))))
    (unless conn (user-error "ride-apl: no session"))
    (ride-apl-session--dispatch conn message)))

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
  (pcase-let ((`(,id ,line ,end-line ,start-col ,end-col) args))
    (let ((buffer (alist-get id (ride-apl-conn-edit-buffers conn))))
      (if (not (buffer-live-p buffer))
          (message "ride-apl debug: highlight for missing buffer %s" id)
        (with-current-buffer buffer
          (ride-apl-tracer--move-highlight line (or end-line line)
                                       start-col end-col))))))

(defun ride-apl-tracer--move-highlight (line end-line start-col end-col)
  "Highlight protocol LINE..END-LINE, narrowed to START-COL..END-COL.
Columns are 0-based; -1 or nil means the whole line.  Conversion to
buffer positions happens here and nowhere else (AD-19)."
  (pcase-let ((`(,start . ,end)
               (ride-apl-tracer--highlight-range line end-line start-col end-col)))
    (if (overlayp ride-apl-tracer--highlight)
        (move-overlay ride-apl-tracer--highlight start end)
      (setq ride-apl-tracer--highlight (make-overlay start end))
      (overlay-put ride-apl-tracer--highlight 'face 'ride-apl-face-trace-highlight)
      (overlay-put ride-apl-tracer--highlight 'ride-apl-highlight t))
    (goto-char start)))

(defun ride-apl-tracer--highlight-range (line end-line start-col end-col)
  (cons (ride-apl-tracer--column-pos line start-col)
        (if (ride-apl-tracer--column-p end-col)
            (ride-apl-tracer--column-pos end-line end-col)
          (ride-apl-tracer--line-pos (1+ end-line)))))

(defun ride-apl-tracer--column-p (col)
  (and (integerp col) (>= col 0)))

(defun ride-apl-tracer--column-pos (line col)
  "Position of 0-based COL within protocol LINE, clamped to the line end."
  (save-excursion
    (goto-char (ride-apl-tracer--line-pos line))
    (if (ride-apl-tracer--column-p col)
        (min (+ (point) col) (line-end-position))
      (point))))

(defun ride-apl-tracer--handle-set-stops (conn args)
  (pcase-let ((`(,id ,stops) args))
    (let ((buffer (alist-get id (ride-apl-conn-edit-buffers conn))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (ride-apl-tracer--render-stops stops))))))

(defun ride-apl-tracer--render-stops (stops)
  (mapc #'delete-overlay ride-apl-tracer--stop-overlays)
  (setq ride-apl-tracer--stop-overlays
        (mapcar #'ride-apl-tracer--stop-overlay stops)))

(defun ride-apl-tracer--stop-overlay (line)
  (let ((overlay (make-overlay (ride-apl-tracer--line-pos line)
                               (ride-apl-tracer--line-pos (1+ line)))))
    (overlay-put overlay 'ride-apl-stop line)
    (if (ride-apl-tracer--fringe-stops-p)
        (overlay-put overlay 'before-string (ride-apl-tracer--fringe-mark))
      (overlay-put overlay 'face 'ride-apl-face-stop))
    overlay))

(defun ride-apl-tracer--fringe-stops-p ()
  (pcase ride-apl-tracer-stop-indicator
    ('fringe t)
    ('line nil)
    (_ (display-graphic-p))))

(defun ride-apl-tracer--fringe-mark ()
  (propertize "●" 'display (list 'left-fringe (ride-apl-tracer--stop-bitmap)
                                 'ride-apl-face-stop-fringe)))

(defun ride-apl-tracer--stop-bitmap ()
  (if (and (fboundp 'fringe-bitmap-p)
           (fringe-bitmap-p 'ride-apl-tracer--stop-circle))
      'ride-apl-tracer--stop-circle
    'filled-square))

(defun ride-apl-tracer--line-pos (line)
  "Buffer position of the start of 0-based protocol LINE."
  (save-excursion
    (goto-char (point-min))
    (forward-line line)
    (point)))

(defun ride-apl-tracer--after-render (record)
  (ride-apl-tracer-mode (if (plist-get record :tracer) 1 -1))
  (setq mode-line-process (ride-apl-tracer--thread-label record))
  (ride-apl-tracer--render-stops (plist-get record :stop)))

(defun ride-apl-tracer--thread-label (record)
  "Mode-line suffix naming RECORD's thread; nil for editor windows (AD-23)."
  (when (plist-get record :tracer)
    (let ((tname (plist-get record :tname))
          (tid (plist-get record :tid)))
      (when (or tname tid)
        (format " [%s]" (or tname (format "Tid:%s" tid)))))))

(defun ride-apl-tracer--maybe-inhibit-display (record buffer)
  "AD-23: keep a stopping background thread from grabbing the display."
  (when (and (plist-get record :tracer) (not ride-apl-tracer-pop-on-open))
    (message "ride-apl: thread %s stopped; tracer in %s"
             (or (plist-get record :tname) (plist-get record :tid) "?")
             (buffer-name buffer))
    t))

(add-hook 'ride-apl-edit-render-functions #'ride-apl-tracer--after-render)
(add-hook 'ride-apl-edit-display-buffer-functions
          #'ride-apl-tracer--maybe-inhibit-display)
(ride-apl-session-register-effect :highlight-line #'ride-apl-tracer--handle-highlight)
(ride-apl-session-register-effect :set-stops #'ride-apl-tracer--handle-set-stops)

(provide 'ride-apl-tracer)
;;; ride-apl-tracer.el ends here
