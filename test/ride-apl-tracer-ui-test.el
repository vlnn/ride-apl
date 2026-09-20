;;; ride-apl-tracer-ui-test.el --- Tracer UI units: highlight, stops, threads -*- lexical-binding: t; -*-

(require 'ert)
(require 'ride-apl)
(require 'ride-apl-test-common)

(defmacro ride-apl-tracer-ui--in-buffer (&rest body)
  "Run BODY in a temp buffer holding the canonical three-line tracer text."
  (declare (indent 0))
  `(with-temp-buffer
     (insert "r←f x\nr←x+1\nr←r×2")
     ,@body))

(ert-deftest ride-apl-tracer-highlight-honors-column-range ()
  (pcase-dolist (`(,desc ,line ,end-line ,start-col ,end-col ,start ,end)
                 '(("whole line on -1 columns" 1 1 -1 -1 7 13)
                   ("a column range within one line" 1 1 2 4 9 11)
                   ("an end column clamped to the line end" 1 1 2 99 9 12)
                   ("a range spanning lines" 0 1 2 3 3 10)
                   ("nil columns as whole line" 1 1 nil nil 7 13)))
    (ert-info ((format "highlighting %s should cover %s..%s" desc start end))
      (ride-apl-tracer-ui--in-buffer
        (ride-apl-tracer--move-highlight line end-line start-col end-col)
        (should (equal (overlay-start ride-apl-tracer--highlight) start))
        (should (equal (overlay-end ride-apl-tracer--highlight) end))))))

(ert-deftest ride-apl-tracer-stops-render-in-fringe ()
  (ert-info ("with the fringe indicator a stop should carry a fringe mark, not a line face")
    (ride-apl-tracer-ui--in-buffer
      (let ((ride-apl-tracer-stop-indicator 'fringe))
        (ride-apl-tracer--render-stops '(1)))
      (let ((overlay (car ride-apl-tracer--stop-overlays)))
        (should (null (overlay-get overlay 'face)))
        (should (equal (get-text-property 0 'display
                                          (overlay-get overlay 'before-string))
                       (list 'left-fringe (ride-apl-tracer--stop-bitmap)
                             'ride-apl-face-stop-fringe)))
        (should (equal (overlay-get overlay 'ride-apl-stop) 1))))))

(ert-deftest ride-apl-tracer-stops-render-as-line-face ()
  (ert-info ("with the line indicator a stop should keep the whole-line face")
    (ride-apl-tracer-ui--in-buffer
      (let ((ride-apl-tracer-stop-indicator 'line))
        (ride-apl-tracer--render-stops '(1)))
      (let ((overlay (car ride-apl-tracer--stop-overlays)))
        (should (equal (overlay-get overlay 'face) 'ride-apl-face-stop))
        (should (null (overlay-get overlay 'before-string)))))))

(ert-deftest ride-apl-tracer-motion-commands-dispatch-step ()
  (pcase-dolist (`(,command ,kind)
                 '((ride-apl-tracer-forward :forward)
                   (ride-apl-tracer-backward :backward)
                   (ride-apl-tracer-primitive :primitive)))
    (ert-info ((format "%s should dispatch a %s step for the window" command kind))
      (let (captured)
        (cl-letf (((symbol-function 'ride-apl-session--dispatch)
                   (lambda (_conn message) (push message captured))))
          (ride-apl-tracer-ui--in-buffer
            (setq ride-apl-edit--conn 'fake-conn)
            (setq ride-apl-edit--win-id 31)
            (funcall command)))
        (should (equal captured `((:step ,kind 31))))))))

(ert-deftest ride-apl-tracer-thread-commands-dispatch ()
  (pcase-dolist (`(,command ,message)
                 '((ride-apl-restart-threads (:restart-threads))
                   (ride-apl-clear-trace-stop-monitor (:clear-trace-stop-monitor))))
    (ert-info ((format "%s should dispatch %s on the session" command message))
      (let (captured)
        (cl-letf (((symbol-function 'ride-apl-current-conn) (lambda () 'fake-conn))
                  ((symbol-function 'ride-apl-session--dispatch)
                   (lambda (_conn msg) (push msg captured))))
          (funcall command))
        (should (equal captured (list message)))))))

(ert-deftest ride-apl-tracer-mode-line-names-thread ()
  (ert-info ("a tracer render should put the thread name into the mode line")
    (ride-apl-tracer-ui--in-buffer
      (ride-apl-tracer--after-render '(:tracer t :tname "Tid:7" :tid 7 :stop nil))
      (should (equal mode-line-process " [Tid:7]"))))
  (ert-info ("a tracer without tname should fall back to the tid")
    (ride-apl-tracer-ui--in-buffer
      (ride-apl-tracer--after-render '(:tracer t :tname nil :tid 7 :stop nil))
      (should (equal mode-line-process " [Tid:7]"))))
  (ert-info ("an editor render should leave the mode line alone")
    (ride-apl-tracer-ui--in-buffer
      (ride-apl-tracer--after-render '(:tracer nil :stop nil))
      (should (null mode-line-process)))))

(ert-deftest ride-apl-tracer-keymap-covers-new-commands ()
  (pcase-dolist (`(,key ,command)
                 '(("n" ride-apl-tracer-forward)
                   ("p" ride-apl-tracer-backward)
                   ("I" ride-apl-tracer-primitive)
                   ("r" ride-apl-restart-threads)))
    (ert-info ((format "%s should be bound to %s in tracer buffers" key command))
      (should (eq (lookup-key ride-apl-tracer-mode-map (kbd key)) command)))))

(ert-deftest ride-apl-tracer-quiet-open-skips-display ()
  (ert-info ("with pop-on-open nil a tracer open should not display its buffer")
    (let ((ride-apl-tracer-pop-on-open nil)
          displayed)
      (cl-letf (((symbol-function 'display-buffer)
                 (lambda (buffer &rest _) (push buffer displayed))))
        (with-temp-buffer
          (ride-apl-edit--display-buffer '(:tracer t :tname "Tid:2")
                                     (current-buffer))
          (should (null displayed))))))
  (ert-info ("with pop-on-open t a tracer open should display its buffer")
    (let ((ride-apl-tracer-pop-on-open t)
          displayed)
      (cl-letf (((symbol-function 'display-buffer)
                 (lambda (buffer &rest _) (push buffer displayed))))
        (with-temp-buffer
          (ride-apl-edit--display-buffer '(:tracer t) (current-buffer))
          (should (equal displayed (list (current-buffer))))))))
  (ert-info ("an editor window should display regardless of the tracer knob")
    (let ((ride-apl-tracer-pop-on-open nil)
          displayed)
      (cl-letf (((symbol-function 'display-buffer)
                 (lambda (buffer &rest _) (push buffer displayed))))
        (with-temp-buffer
          (ride-apl-edit--display-buffer '(:tracer nil) (current-buffer))
          (should (equal displayed (list (current-buffer)))))))))

(provide 'ride-apl-tracer-ui-test)
;;; ride-apl-tracer-ui-test.el ends here
