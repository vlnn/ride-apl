;;; ride-apl-eval-test.el --- Eval-from-file commands -*- lexical-binding: t; -*-

(require 'ert)
(require 'ride-apl)
(require 'ride-apl-test-server)
(require 'ride-apl-test-common)

(defun ride-apl-eval-test--executes ()
  (seq-filter (lambda (p) (equal (car (ride-apl-proto-parse p)) "Execute"))
              (reverse ride-apl-testsrv--received)))

(defun ride-apl-eval-test--execute-texts ()
  (mapcar (lambda (p) (ride-apl-proto-arg (ride-apl-proto-parse p) 'text))
          (ride-apl-eval-test--executes)))

(defmacro ride-apl-eval-test--in-apl-buffer (content &rest body)
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,content)
     (goto-char (point-min))
     ,@body))

(ert-deftest ride-apl-eval-line-sends-current-line ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (ride-apl-eval-test--in-apl-buffer "1+1\n2+2"
      (ride-apl-eval-line-or-region))
    (ert-info ("evaluating a line should send exactly that line")
      (should (ride-apl-test--wait-for
               (lambda () (member "      1+1\n" (ride-apl-eval-test--execute-texts)))))
      (should (not (member "      2+2\n" (ride-apl-eval-test--execute-texts)))))))

(ert-deftest ride-apl-eval-region-queues-lines-in-order ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (ride-apl-eval-test--in-apl-buffer "a←1\nb←2\na+b\n"
      (ride-apl-eval-region (point-min) (point-max)))
    (ert-info ("evaluating a region should execute each line, one at a time, in order")
      (should (ride-apl-test--wait-for
               (lambda () (member "      a+b\n" (ride-apl-eval-test--execute-texts)))))
      (should (equal (last (ride-apl-eval-test--execute-texts) 3)
                     '("      a←1\n" "      b←2\n" "      a+b\n"))))
    (ert-info ("the queue should be drained afterwards")
      (should (equal (ride-apl-session-pending-lines (ride-apl-conn-state conn)) nil)))))

(ert-deftest ride-apl-eval-region-skips-blank-lines ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (let ((before (length (ride-apl-eval-test--executes))))
      (ride-apl-eval-test--in-apl-buffer "x←3\n\n   \nx\n"
        (ride-apl-eval-buffer))
      (ert-info ("blank and whitespace-only lines should not be sent")
        (should (ride-apl-test--wait-for
                 (lambda () (member "      x\n" (ride-apl-eval-test--execute-texts)))))
        (should (equal (- (length (ride-apl-eval-test--executes)) before) 2))))))

(ert-deftest ride-apl-load-file-uses-fix ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (let ((file (make-temp-file "ride-apl-eval" nil ".apl" "z←⍳3\n")))
      (unwind-protect
          (progn
            (with-current-buffer (find-file-noselect file)
              (ride-apl-load-file)
              (kill-buffer))
            (ert-info ("loading a file should send 2⎕FIX with a file:// url")
              (should (ride-apl-test--wait-for
                       (lambda ()
                         (seq-find (lambda (text)
                                     (string-match-p
                                      (concat "2⎕FIX'file://"
                                              (regexp-quote file) "'")
                                      text))
                                   (ride-apl-eval-test--execute-texts)))))))
        (delete-file file)))))

(ert-deftest ride-apl-apl-string-quoting ()
  (pcase-dolist (`(,desc ,input ,expected)
                 '(("plain path" "/tmp/x.apl" "/tmp/x.apl")
                   ("embedded quote doubled" "/tmp/o'brien.apl"
                    "/tmp/o''brien.apl")
                   ("multiple quotes" "a'b'c" "a''b''c")))
    (ert-info ((format "APL string quoting: %s" desc))
      (should (equal (ride-apl--apl-quote input) expected)))))

(provide 'ride-apl-eval-test)
;;; ride-apl-eval-test.el ends here
