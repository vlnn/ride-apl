;;; ride-apl-session-trace-test.el --- M4 reducer tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'ride-apl-session)
(require 'ride-apl-proto)
(require 'ride-apl-test-common)

(defconst ride-apl-trace-test--open-args
  '((name . "#.f") (filename . "") (text . ("r←f x" "r←x+1"))
    (token . 31) (currentRow . 0) (debugger . 1) (entityType . 1)
    (offset . 0) (readOnly . 1) (size . 2) (stop . ()) (tid . 0)
    (tname . "Tid:0")))

(defun ride-apl-trace-test--with-tracer ()
  (car (ride-apl-session-step (ride-apl-test--connected-session)
                          (cons "OpenWindow" ride-apl-trace-test--open-args))))

(ert-deftest ride-apl-session-tracer-window-flagged ()
  (ert-info ("an OpenWindow with debugger:1 should mark the record as a tracer")
    (should (equal (plist-get (alist-get 31 (ride-apl-session-windows
                                             (ride-apl-trace-test--with-tracer)))
                              :tracer)
                   t))))

(ert-deftest ride-apl-session-highlight-line-effect ()
  (pcase-let ((`(,state . ,effects)
               (ride-apl-session-step
                (ride-apl-trace-test--with-tracer)
                '("SetHighlightLine" . ((win . 31) (line . 1) (end_line . 1)
                                        (start_col . -1) (end_col . -1))))))
    (ert-info ("SetHighlightLine should emit :highlight-line with protocol coords (AD-19)")
      (should (equal effects '((:highlight-line 31 1 1 -1 -1)))))
    (ert-info ("SetHighlightLine should track the current row in the record")
      (should (equal (plist-get (alist-get 31 (ride-apl-session-windows state))
                                :current-row)
                     1)))))

(ert-deftest ride-apl-session-line-attributes-update-stops ()
  (pcase-let ((`(,state . ,effects)
               (ride-apl-session-step
                (ride-apl-trace-test--with-tracer)
                '("SetLineAttributes" . ((win . 31) (stop . (0 1)))))))
    (ert-info ("SetLineAttributes should update the record's 0-based stops")
      (should (equal (plist-get (alist-get 31 (ride-apl-session-windows state))
                                :stop)
                     '(0 1))))
    (ert-info ("SetLineAttributes should emit :set-stops")
      (should (equal effects '((:set-stops 31 (0 1))))))))

(ert-deftest ride-apl-session-step-events-send ()
  (pcase-dolist (`(,kind ,command)
                 '((:into "StepInto") (:over "RunCurrentLine")
                   (:continue "Continue") (:out "ContinueTrace")
                   (:cutback "Cutback") (:forward "TraceForward")
                   (:backward "TraceBackward") (:primitive "TracePrimitive")))
    (ert-info ((format "a %s step event should send %s for the window" kind command))
      (should (equal (cdr (ride-apl-session-step (ride-apl-trace-test--with-tracer)
                                             `(:step ,kind 31)))
                     (list (list :send
                                 (ride-apl-proto-tracer-command command 31))))))))

(ert-deftest ride-apl-session-set-stops-request-sends ()
  (ert-info (":set-stops-request should send SetLineAttributes with a stop array")
    (pcase-let ((`(,_ . ,effects)
                 (ride-apl-session-step (ride-apl-trace-test--with-tracer)
                                    '(:set-stops-request 31 (1)))))
      (should (equal effects
                     (list (list :send
                                 (ride-apl-proto-set-line-attributes 31 '(1))))))
      (should (equal (ride-apl-proto-arg (ride-apl-proto-parse (cadr (car effects)))
                                     'stop)
                     '(1))))))

(ert-deftest ride-apl-session-restart-threads-sends ()
  (ert-info (":restart-threads should send RestartThreads")
    (should (equal (cdr (ride-apl-session-step (ride-apl-trace-test--with-tracer)
                                           '(:restart-threads)))
                   (list (list :send (ride-apl-proto-restart-threads)))))))

(ert-deftest ride-apl-session-clear-trace-stop-monitor-sends ()
  (ert-info (":clear-trace-stop-monitor should send ClearTraceStopMonitor")
    (pcase-let ((`(,_ . ,effects)
                 (ride-apl-session-step (ride-apl-trace-test--with-tracer)
                                    '(:clear-trace-stop-monitor))))
      (should (equal effects
                     (list (list :send
                                 (ride-apl-proto-clear-trace-stop-monitor 0)))))
      (should (equal (car (ride-apl-proto-parse (cadr (car effects))))
                     "ClearTraceStopMonitor")))))

(ert-deftest ride-apl-session-reply-clear-notifies-counts ()
  (ert-info ("ReplyClearTraceStopMonitor should notify info with cleared counts")
    (pcase-let ((`(,_ . ,effects)
                 (ride-apl-session-step
                  (ride-apl-trace-test--with-tracer)
                  '("ReplyClearTraceStopMonitor" . ((token . 0) (traces . 2)
                                                    (stops . 3) (monitors . 0))))))
      (should (equal effects
                     '((:notify :info
                        "Cleared 2 traces, 3 stops, 0 monitors")))))))

(ert-deftest ride-apl-session-trace-line-gates-like-input ()
  (ert-info ("a :trace-line at an open prompt should send Execute with trace 1")
    (let ((ready (car (ride-apl-test--fold
                       (ride-apl-test--connected-session)
                       '(("ReplyGetLog" . ((result . nil)))
                         ("SetPromptType" . ((type . 1))))))))
      (pcase-let ((`(,state . ,effects)
                   (ride-apl-session-step ready '(:trace-line "f 3"))))
        (should (equal effects
                       (list (list :send (ride-apl-proto-execute "      f 3\n" 1)))))
        (should (equal (ride-apl-session-prompt-type state) 0)))))
  (ert-info ("a :trace-line on a busy session should warn instead of queueing")
    (pcase-let ((`(,_ . ,effects)
                 (ride-apl-session-step (ride-apl-test--connected-session)
                                    '(:trace-line "f 3"))))
      (should (equal (ride-apl-test--effect-types effects) '(:notify)))
      (should (equal (cadr (car effects)) :warn)))))

(provide 'ride-apl-session-trace-test)
;;; ride-apl-session-trace-test.el ends here
