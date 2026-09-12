;;; ride-apl-shell-test.el --- Shell tests against a fake RIDE server -*- lexical-binding: t; -*-

(require 'ert)
(require 'ride-apl)
(require 'ride-apl-transport)
(require 'ride-apl-proto)
(require 'ride-apl-test-server)
(require 'ride-apl-test-common)

(defmacro ride-apl-test--with-server (behavior conn-var &rest body)
  (declare (indent 2))
  `(let* ((server+port (ride-apl-testsrv-start ,behavior))
          (,conn-var (ride-apl-session-open "127.0.0.1" (cdr server+port))))
     (unwind-protect (progn ,@body)
       (ride-apl-transport-close (ride-apl-conn-process ,conn-var))
       (delete-process (car server+port))
       (setq ride-apl--conns nil))))

(defun ride-apl-test--conn-state (conn)
  (ride-apl-session-conn-state (ride-apl-conn-state conn)))

(ert-deftest ride-apl-shell-connects-to-happy-server ()
  (ride-apl-test--with-server 'happy conn
    (ert-info ("the shell should reach connected against a well-behaved server")
      (should (ride-apl-test--wait-for
               (lambda () (eq (ride-apl-test--conn-state conn) 'connected)))))
    (ert-info ("the server should have received Identify, Connect, GetLog, SetPW in order")
      (should (ride-apl-test--wait-for
               (lambda () (>= (length ride-apl-testsrv--received) 6))))
      (should (equal (nthcdr 2 (reverse ride-apl-testsrv--received))
                     (list (ride-apl-proto-identify)
                           (ride-apl-proto-connect)
                           (ride-apl-proto-get-log ride-apl-session-log-lines)
                           (ride-apl-proto-set-pw 80)))))
    (ert-info ("the negotiated apiVersion should be recorded")
      (should (equal (ride-apl-session-api-version (ride-apl-conn-state conn)) 1)))))

(ert-deftest ride-apl-shell-times-out-on-silent-server ()
  (let ((ride-apl-handshake-timeout 0.2))
    (ride-apl-test--with-server 'silent conn
      (ert-info ("a silent server should yield a dead session")
        (should (ride-apl-test--wait-for
                 (lambda () (eq (ride-apl-test--conn-state conn) 'dead)))))
      (ert-info ("the death reason should be timeout")
        (should (equal (ride-apl-conn-death-reason conn) '(:timeout)))))))

(ert-deftest ride-apl-shell-rejects-mismatched-server ()
  (ride-apl-test--with-server 'mismatch conn
    (ert-info ("a protocol-mismatched server should yield a dead session")
      (should (ride-apl-test--wait-for
               (lambda () (eq (ride-apl-test--conn-state conn) 'dead)))))
    (ert-info ("the death reason should name the offered protocols")
      (should (equal (ride-apl-conn-death-reason conn)
                     '(:protocol-mismatch . "9"))))))

(ert-deftest ride-apl-shell-reports-server-drop ()
  (ride-apl-test--with-server 'happy conn
    (should (ride-apl-test--wait-for
             (lambda () (eq (ride-apl-test--conn-state conn) 'connected))))
    (mapc #'delete-process ride-apl-testsrv--clients)
    (ert-info ("a dropped connection should kill the session exactly once")
      (should (ride-apl-test--wait-for
               (lambda () (eq (ride-apl-test--conn-state conn) 'dead))))
      (should (equal (car (ride-apl-conn-death-reason conn)) :connection-lost)))))

(ert-deftest ride-apl-shell-logs-both-directions ()
  (ride-apl-test--with-server 'happy conn
    (should (ride-apl-test--wait-for
             (lambda () (eq (ride-apl-test--conn-state conn) 'connected))))
    (ert-info ("the protocol log should contain sent and received payloads")
      (with-current-buffer (ride-apl-session--log-buffer conn)
        (let ((log (buffer-string)))
          (should (string-match-p "-> SupportedProtocols=2" log))
          (should (string-match-p "<- UsingProtocol=2" log))
          (should (string-match-p "-> \\[\"Connect\"" log)))))))

(provide 'ride-apl-shell-test)
;;; ride-apl-shell-test.el ends here
