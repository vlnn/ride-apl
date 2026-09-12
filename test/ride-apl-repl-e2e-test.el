;;; ride-apl-repl-e2e-test.el --- REPL buffer against a fake interpreter -*- lexical-binding: t; -*-

(require 'ert)
(require 'ride-apl)
(require 'ride-apl-test-server)
(require 'ride-apl-test-common)

(ert-deftest ride-apl-e2e-repl-round-trip ()
  (ride-apl-e2e--with-repl conn buffer
    (ert-info ("the session should become ready for input")
      (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn)))))
    (ride-apl-e2e--type-and-send buffer "2+2")
    (ert-info ("the result should appear in the REPL buffer")
      (should (ride-apl-test--wait-for
               (lambda () (with-current-buffer buffer
                            (string-match-p "^4$" (buffer-string)))))))
    (with-current-buffer buffer
      (let ((content (buffer-string)))
        (ert-info ("the log backfill should precede the echoed input")
          (should (string-match-p "log-line-1" content))
          (should (< (string-match "log-line-1" content)
                     (string-match "2\\+2" content))))
        (ert-info ("the echoed input should precede its result")
          (should (< (string-match "2\\+2" content)
                     (string-match "^4$" content))))
        (ert-info ("the prompt should be open again after evaluation")
          (should (not buffer-read-only)))))
    (ert-info ("the log-backfill timer should be cancelled once the backfill is done")
      (should (null (ride-apl-conn-timer conn))))))

(ert-deftest ride-apl-e2e-multi-line-input-runs-in-order ()
  (ride-apl-e2e--with-repl conn buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (ride-apl-e2e--type-and-send buffer "1+1\n2+2")
    (ert-info ("both lines should execute, one Execute at a time, in order")
      (should (ride-apl-test--wait-for
               (lambda () (with-current-buffer buffer
                            (string-match-p "^4$" (buffer-string))))))
      (should (= 2 (seq-count
                    (lambda (p) (equal (car (ride-apl-proto-parse p)) "Execute"))
                    ride-apl-testsrv--received)))
      (with-current-buffer buffer
        (should (< (string-match "1\\+1" (buffer-string))
                   (string-match "2\\+2" (buffer-string))))))
    (ert-info ("the pending queue should be drained")
      (should (equal (ride-apl-session-pending-lines (ride-apl-conn-state conn)) nil)))))

(ert-deftest ride-apl-e2e-busy-buffer-rejects-typing ()
  (ride-apl-e2e--with-repl conn buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (ride-apl-session--dispatch conn '("SetPromptType" . ((type . 0))))
    (ert-info ("a busy prompt should make the buffer read-only")
      (with-current-buffer buffer
        (should buffer-read-only)))
    (ride-apl-session--dispatch conn '("SetPromptType" . ((type . 1))))
    (ert-info ("a reopened prompt should make the buffer writable again")
      (with-current-buffer buffer
        (should (not buffer-read-only))))))

(ert-deftest ride-apl-e2e-dead-session-leaves-tombstone ()
  (ride-apl-e2e--with-repl conn buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (mapc #'delete-process ride-apl-testsrv--clients)
    (should (ride-apl-test--wait-for
             (lambda () (eq (ride-apl-session-conn-state (ride-apl-conn-state conn)) 'dead))))
    (ert-info ("a dead session should leave a read-only banner in the REPL buffer")
      (with-current-buffer buffer
        (should buffer-read-only)
        (should (string-match-p "session died: :connection-lost" (buffer-string)))))))

(provide 'ride-apl-repl-e2e-test)
;;; ride-apl-repl-e2e-test.el ends here
