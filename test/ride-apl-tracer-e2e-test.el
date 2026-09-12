;;; ride-apl-tracer-e2e-test.el --- Tracer against the fake interpreter -*- lexical-binding: t; -*-

(require 'ert)
(require 'ride-apl)
(require 'ride-apl-test-server)
(require 'ride-apl-test-common)

(defun ride-apl-tracer-e2e--buffer (conn)
  (alist-get 31 (ride-apl-conn-edit-buffers conn)))

(defun ride-apl-tracer-e2e--highlight-line (conn)
  (let ((buffer (ride-apl-tracer-e2e--buffer conn)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (overlayp ride-apl-tracer--highlight)
          (line-number-at-pos (overlay-start ride-apl-tracer--highlight)))))))

(defun ride-apl-tracer-e2e--start (conn)
  (ride-apl-session--dispatch conn '(:trace-line "f 3"))
  (ride-apl-test--wait-for
   (lambda () (equal (ride-apl-tracer-e2e--highlight-line conn) 1))))

(ert-deftest ride-apl-tracer-e2e-opens-with-highlight ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (ert-info ("tracing should open a tracer buffer with line 0 highlighted as line 1 (AD-19)")
      (should (ride-apl-tracer-e2e--start conn)))
    (with-current-buffer (ride-apl-tracer-e2e--buffer conn)
      (ert-info ("the tracer buffer should be read-only with the stepping map active")
        (should buffer-read-only)
        (should ride-apl-tracer-mode))
      (ert-info ("the tracer buffer should be named as a trace window")
        (should (string-prefix-p "*ride-apl-trace:" (buffer-name)))))))

(ert-deftest ride-apl-tracer-e2e-stepping-moves-highlight ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (should (ride-apl-tracer-e2e--start conn))
    (with-current-buffer (ride-apl-tracer-e2e--buffer conn)
      (ride-apl-tracer-step-into))
    (ert-info ("step into should advance the highlight to the next line")
      (should (ride-apl-test--wait-for
               (lambda () (equal (ride-apl-tracer-e2e--highlight-line conn) 2)))))
    (with-current-buffer (ride-apl-tracer-e2e--buffer conn)
      (ride-apl-tracer-step-over))
    (ert-info ("step over should advance the highlight again")
      (should (ride-apl-test--wait-for
               (lambda () (equal (ride-apl-tracer-e2e--highlight-line conn) 3)))))
    (ert-info ("point should follow the highlight")
      (with-current-buffer (ride-apl-tracer-e2e--buffer conn)
        (should (equal (line-number-at-pos) 3))))))

(ert-deftest ride-apl-tracer-e2e-toggle-stop-round-trips ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (should (ride-apl-tracer-e2e--start conn))
    (with-current-buffer (ride-apl-tracer-e2e--buffer conn)
      (goto-char (point-min))
      (forward-line 1)
      (ride-apl-tracer-toggle-stop))
    (ert-info ("toggling a stop should round-trip through the interpreter's echo")
      (should (ride-apl-test--wait-for
               (lambda ()
                 (equal (plist-get (alist-get 31 (ride-apl-session-windows
                                                  (ride-apl-conn-state conn)))
                                   :stop)
                       '(1))))))
    (ert-info ("the echoed stop should render as an overlay on the right line")
      (with-current-buffer (ride-apl-tracer-e2e--buffer conn)
        (should (equal (mapcar (lambda (o) (overlay-get o 'ride-apl-stop))
                               ride-apl-tracer--stop-overlays)
                       '(1)))
        (should (equal (line-number-at-pos
                        (overlay-start (car ride-apl-tracer--stop-overlays)))
                       2))))
    (with-current-buffer (ride-apl-tracer-e2e--buffer conn)
      (goto-char (point-min))
      (forward-line 1)
      (ride-apl-tracer-toggle-stop))
    (ert-info ("toggling again should clear the stop")
      (should (ride-apl-test--wait-for
               (lambda ()
                 (null (plist-get (alist-get 31 (ride-apl-session-windows
                                                 (ride-apl-conn-state conn)))
                                  :stop))))))))

(ert-deftest ride-apl-tracer-e2e-continue-closes-and-outputs ()
  (ride-apl-e2e--with-repl conn buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (should (ride-apl-tracer-e2e--start conn))
    (with-current-buffer (ride-apl-tracer-e2e--buffer conn)
      (ride-apl-tracer-continue))
    (ert-info ("continue should close the tracer window via the echo")
      (should (ride-apl-test--wait-for
               (lambda () (null (ride-apl-tracer-e2e--buffer conn))))))
    (ert-info ("the result should land in the REPL and the prompt reopen")
      (should (ride-apl-test--wait-for
               (lambda () (with-current-buffer buffer
                            (string-match-p "^8$" (buffer-string))))))
      (should (ride-apl-test--wait-for
               (lambda () (with-current-buffer buffer
                            (not buffer-read-only))))))))

(provide 'ride-apl-tracer-e2e-test)
;;; ride-apl-tracer-e2e-test.el ends here
