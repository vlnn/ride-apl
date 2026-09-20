;;; ride-apl-trace-command-test.el --- Tracing from source buffers -*- lexical-binding: t; -*-

(require 'ert)
(require 'ride-apl)
(require 'ride-apl-test-server)
(require 'ride-apl-test-common)

(defmacro ride-apl-trace-test--in-apl-buffer (content &rest body)
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,content)
     (goto-char (point-min))
     ,@body))

(defmacro ride-apl-trace-test--capturing-dispatch (captured &rest body)
  "Run BODY with dispatch stubbed; CAPTURED collects the messages."
  (declare (indent 1))
  `(let (,captured)
     (cl-letf (((symbol-function 'ride-apl-current-conn) (lambda () 'fake-conn))
               ((symbol-function 'ride-apl-session--dispatch)
                (lambda (_conn message) (push message ,captured))))
       ,@body)))

(ert-deftest ride-apl-trace-line-dispatches-current-line ()
  (pcase-dolist (`(,desc ,content ,expected)
                 '(("a bare expression" "PartOne ⍬" "PartOne ⍬")
                   ("surrounding blanks trimmed" "   f 3  " "f 3")
                   ("only the current line" "f 3\ng 4" "f 3")))
    (ert-info ((format "tracing %s should dispatch :trace-line with %S" desc expected))
      (ride-apl-trace-test--capturing-dispatch captured
        (ride-apl-trace-test--in-apl-buffer content
          (ride-apl-trace-line))
        (should (equal captured (list (list :trace-line expected))))))))

(ert-deftest ride-apl-trace-line-prefers-single-line-region ()
  (ert-info ("an active single-line region should be traced instead of the whole line")
    (ride-apl-trace-test--capturing-dispatch captured
      (ride-apl-trace-test--in-apl-buffer "f 3 ⋄ g 4"
        (transient-mark-mode 1)
        (push-mark (point) t t)
        (goto-char (+ (point) 3))
        (ride-apl-trace-line))
      (should (equal captured '((:trace-line "f 3")))))))

(ert-deftest ride-apl-trace-line-rejects-bad-input ()
  (ert-info ("a blank line should be a user error, not a dispatch")
    (ride-apl-trace-test--capturing-dispatch captured
      (ride-apl-trace-test--in-apl-buffer "   \nf 3"
        (should-error (ride-apl-trace-line) :type 'user-error))
      (should (null captured))))
  (ert-info ("a multi-line region should be a user error naming the limit")
    (ride-apl-trace-test--capturing-dispatch captured
      (ride-apl-trace-test--in-apl-buffer "f 3\ng 4"
        (transient-mark-mode 1)
        (push-mark (point-min) t t)
        (goto-char (point-max))
        (should-error (ride-apl-trace-line) :type 'user-error))
      (should (null captured)))))

(ert-deftest ride-apl-trace-takes-a-typed-expression ()
  (ert-info ("ride-apl-trace should dispatch the expression it was given")
    (ride-apl-trace-test--capturing-dispatch captured
      (ride-apl-trace "mean 3 1 4")
      (should (equal captured '((:trace-line "mean 3 1 4"))))))
  (ert-info ("a blank expression should be a user error, not a dispatch")
    (ride-apl-trace-test--capturing-dispatch captured
      (should-error (ride-apl-trace "   ") :type 'user-error)
      (should (null captured)))))

(ert-deftest ride-apl-trace-line-needs-a-session ()
  (ert-info ("with no live connection the command should say so")
    (let ((ride-apl--conns nil))
      (ride-apl-trace-test--in-apl-buffer "f 3"
        (should-error (ride-apl-trace-line) :type 'user-error)))))

(ert-deftest ride-apl-trace-line-e2e-opens-tracer ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (ride-apl-trace-test--in-apl-buffer "f 3"
      (ride-apl-trace-line))
    (ert-info ("the command should send Execute with the trace flag set")
      (should (ride-apl-test--wait-for
               (lambda ()
                 (seq-find (lambda (payload)
                             (let ((message (ride-apl-proto-parse payload)))
                               (and (equal (car message) "Execute")
                                    (equal (ride-apl-proto-arg message 'text) "      f 3\n")
                                    (eql (ride-apl-proto-arg message 'trace) 1))))
                           ride-apl-testsrv--received)))))
    (ert-info ("the interpreter's tracer window should land as a trace buffer")
      (should (ride-apl-test--wait-for
               (lambda ()
                 (let ((buffer (alist-get 31 (ride-apl-conn-edit-buffers conn))))
                   (and (buffer-live-p buffer)
                        (with-current-buffer buffer
                          (and ride-apl-tracer-mode
                               (string-prefix-p "*ride-apl-trace:" (buffer-name))))))))))))

(provide 'ride-apl-trace-command-test)
;;; ride-apl-trace-command-test.el ends here
