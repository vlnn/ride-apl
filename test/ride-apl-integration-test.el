;;; ride-apl-integration-test.el --- Layers wired together -*- lexical-binding: t; -*-

(require 'ert)
(require 'ride-apl-transport)
(require 'ride-apl-proto)
(require 'ride-apl-session)

(defun ride-apl-test--interpreter-bytes ()
  "M1 connect sequence as the interpreter would send it, one byte blob."
  (mapconcat
   #'ride-apl-transport-encode
   (list "SupportedProtocols=2"
         "UsingProtocol=2"
         (ride-apl-proto-serialize
          "ReplyIdentify" '((apiVersion . 1) (version . "20.0.50000")
                            (platform . "Linux-64") (pid . 4242)))
         (ride-apl-proto-serialize
          "UpdateDisplayName" '((displayName . "CLEAR WS"))))
   ""))

(defun ride-apl-test--drive (state bytes chunk-size)
  "Feed BYTES to the reducer in CHUNK-SIZE slices, as a process filter would.
Return (FINAL-STATE . ALL-EFFECTS)."
  (let ((accumulator "") (pos 0) effects)
    (while (< pos (length bytes))
      (let ((end (min (+ pos chunk-size) (length bytes))))
        (setq accumulator (concat accumulator (substring bytes pos end)))
        (setq pos end)
        (pcase-let ((`(,payloads . ,remainder)
                     (ride-apl-transport-decode accumulator)))
          (setq accumulator remainder)
          (dolist (payload payloads)
            (pcase-let ((`(,next . ,step-effects)
                         (ride-apl-session-step state (ride-apl-proto-parse payload))))
              (setq state next)
              (setq effects (append effects step-effects)))))))
    (cons state effects)))

(ert-deftest ride-apl-integration-connect-sequence ()
  (pcase-dolist (`(,desc ,chunk-size)
                 `(("one chunk" ,(length (ride-apl-test--interpreter-bytes)))
                   ("byte-at-a-time delivery" 1)
                   ("awkward 7-byte chunks" 7)))
    (pcase-let ((`(,state . ,effects)
                 (ride-apl-test--drive (car (ride-apl-session-init))
                                   (ride-apl-test--interpreter-bytes)
                                   chunk-size)))
      (ert-info ((format "the connect sequence via %s should reach connected" desc))
        (should (equal (ride-apl-session-conn-state state) 'connected)))
      (ert-info ((format "the connect sequence via %s should send Identify, Connect, GetLog, SetPW" desc))
        (should (equal effects
                       (list (list :send (ride-apl-proto-identify))
                             (list :send (ride-apl-proto-connect))
                             (list :send (ride-apl-proto-get-log ride-apl-session-log-lines))
                             (list :send (ride-apl-proto-set-pw 80))))))
      (ert-info ((format "the connect sequence via %s should record interpreter identity" desc))
        (should (equal (ride-apl-session-api-version state) 1))
        (should (equal (ride-apl-session-display-name state) "CLEAR WS"))))))

(ert-deftest ride-apl-integration-wrong-server-dies ()
  (ert-info ("a server speaking another protocol should yield exactly one session-died")
    (pcase-let ((`(,state . ,effects)
                 (ride-apl-test--drive (car (ride-apl-session-init))
                                   (ride-apl-transport-encode "SupportedProtocols=1,3")
                                   3)))
      (should (equal (ride-apl-session-conn-state state) 'dead))
      (should (equal effects
                     (list (list :session-died :protocol-mismatch "1,3")))))))

(provide 'ride-apl-integration-test)
;;; ride-apl-integration-test.el ends here
