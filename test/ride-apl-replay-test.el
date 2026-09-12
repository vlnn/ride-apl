;;; ride-apl-replay-test.el --- Transcript round-trip tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'ride-apl)
(require 'ride-apl-replay)
(require 'ride-apl-test-server)
(require 'ride-apl-test-common)

(ert-deftest ride-apl-replay-live-session-round-trips ()
  (ride-apl-e2e--with-repl conn buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (ride-apl-e2e--type-and-send buffer "2+2")
    (should (ride-apl-test--wait-for
             (lambda () (with-current-buffer buffer
                          (string-match-p "^4$" (buffer-string))))))
    (let* ((file (make-temp-file "ride-apl-fixture" nil ".eld"))
           (result (progn (ride-apl-transcript-save file conn)
                          (ride-apl-replay-run (ride-apl-replay-load file)))))
      (unwind-protect
          (progn
            (ert-info ("replaying a saved live session should reach the same projection")
              (should (equal (ride-apl-replay-state-projection (plist-get result :state))
                             (ride-apl-replay-state-projection (ride-apl-conn-state conn)))))
            (ert-info ("replaying recorded inputs should reproduce the recorded outputs")
              (should (equal (plist-get result :sent)
                             (plist-get result :recorded-out))))
            (ert-info ("the replayed effect log should contain the evaluation result")
              (should (member '(:display-output "4\n" 2 0)
                              (ride-apl-replay-effects-of (plist-get result :effects)
                                                      '(:display-output))))))
        (delete-file file)))))

(defun ride-apl-replay-test--fixture (name)
  (expand-file-name (concat "fixtures/" name)
                    (file-name-directory
                     (or (locate-library "ride-apl-replay") load-file-name))))

(ert-deftest ride-apl-replay-real-dyalog-session ()
  (let* ((result (ride-apl-replay-run
                  (ride-apl-replay-load
                   (ride-apl-replay-test--fixture "session-m2-real.eld"))))
         (state (plist-get result :state)))
    (ert-info ("the real Dyalog 20 session should replay to a ready state")
      (should (equal (ride-apl-replay-state-projection state)
                     '(:conn-state connected :prompt-type 1
                       :log-state done :windows nil))))
    (ert-info ("replaying the real inputs should reproduce the real outputs byte-identically")
      (should (equal (plist-get result :sent) (plist-get result :recorded-out))))
    (ert-info ("the real ReplyIdentify shape should be stored")
      (should (equal (ride-apl-session-api-version state) 1))
      (should (equal (alist-get 'version (ride-apl-session-interpreter state))
                     "20.0.53963")))
    (ert-info ("the real UpdateSessionCaption text key should be stored")
      (should (equal (ride-apl-session-caption state) "CLEAR WS - Dyalog APL")))
    (ert-info ("evaluation results should come through as display effects")
      (let ((displays (ride-apl-replay-effects-of (plist-get result :effects)
                                              '(:display-output))))
        (should (member '(:display-output "23 24\n" 2 0) displays))
        (should (member '(:display-output "46 45 46\n" 2 0) displays))))
    (ert-info ("the stale post-backfill log-timeout should be a no-op")
      (should (not (seq-find (lambda (e) (equal (cadr e) :debug))
                             (ride-apl-replay-effects-of (plist-get result :effects)
                                                     '(:notify))))))))

(ert-deftest ride-apl-replay-connect-basic-fixture ()
  (let ((result (ride-apl-replay-run
                 (ride-apl-replay-load
                  (ride-apl-replay-test--fixture "connect-basic.eld")))))
    (ert-info ("the connect-basic fixture should reach a connected, ready session")
      (should (equal (ride-apl-replay-state-projection (plist-get result :state))
                     '(:conn-state connected :prompt-type 1
                       :log-state done :windows nil))))
    (ert-info ("the fixture replay should send the documented connect sequence")
      (should (equal (plist-get result :sent) (plist-get result :recorded-out))))
    (ert-info ("the fixture banner should come out as display effects")
      (should (ride-apl-replay-effects-of (plist-get result :effects)
                                      '(:display-output))))))

(ert-deftest ride-apl-replay-transcript-entry-shapes ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (let ((entries (ride-apl-session-transcript conn)))
      (ert-info ("handshake entries should be recorded as :raw base64")
        (should (equal (ride-apl-replay-entry-payload (car entries))
                       "SupportedProtocols=2"))
        (should (plist-get (car entries) :raw)))
      (ert-info ("framed entries should be recorded as parsed :msg")
        (should (seq-find (lambda (e)
                            (equal (car-safe (plist-get e :msg)) "Identify"))
                          entries)))
      (ert-info ("entries should carry monotone non-negative timestamps")
        (should (cl-every (lambda (e) (>= (plist-get e :t) 0)) entries))
        (should (apply #'<= (mapcar (lambda (e) (plist-get e :t)) entries)))))))

(provide 'ride-apl-replay-test)
;;; ride-apl-replay-test.el ends here
