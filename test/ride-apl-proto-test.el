;;; ride-apl-proto-test.el --- Protocol message tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'ride-apl-proto)

(ert-deftest ride-apl-proto-parse-handshake ()
  (pcase-dolist (`(,desc ,payload ,expected)
                 '(("supported protocols" "SupportedProtocols=2"
                    ("SupportedProtocols" . "2"))
                   ("using protocol" "UsingProtocol=2"
                    ("UsingProtocol" . "2"))
                   ("multi-valued list" "SupportedProtocols=1,2"
                    ("SupportedProtocols" . "1,2"))))
    (ert-info ((format "parse should split %s into name and value" desc))
      (should (equal (ride-apl-proto-parse payload) expected)))))

(ert-deftest ride-apl-proto-parse-json ()
  (pcase-dolist (`(,desc ,payload ,name ,args)
                 '(("no-arg command" "[\"HadError\",{}]" "HadError" nil)
                   ("scalar args" "[\"SetPromptType\",{\"type\":1}]"
                    "SetPromptType" ((type . 1)))
                   ("apl glyphs in strings"
                    "[\"AppendSessionOutput\",{\"result\":\"⍳9\",\"type\":2}]"
                    "AppendSessionOutput" ((result . "⍳9") (type . 2)))
                   ("nested arrays"
                    "[\"UpdateWindow\",{\"text\":[\"a\",\"b\"],\"stop\":[0,2]}]"
                    "UpdateWindow" ((text . ("a" "b")) (stop . (0 2))))))
    (ert-info ((format "parse should return name and alist args for %s" desc))
      (should (equal (ride-apl-proto-parse payload) (cons name args))))))

(ert-deftest ride-apl-proto-parse-rejects-garbage ()
  (pcase-dolist (`(,desc ,payload)
                 '(("not json, not handshake" "hello there")
                   ("json but not a command vector" "{\"a\":1}")
                   ("empty payload" "")))
    (ert-info ((format "parse should signal ride-apl-proto-bad-message on %s" desc))
      (should-error (ride-apl-proto-parse payload)
                    :type 'ride-apl-proto-bad-message))))

(ert-deftest ride-apl-proto-serialize-roundtrip ()
  (pcase-dolist (`(,desc ,name ,args)
                 '(("identify" "Identify" ((apiVersion . 1) (identity . 1)))
                   ("execute with glyphs" "Execute" ((text . "      ⍳9\n") (trace . 0)))
                   ("empty args" "GetWindowLayout" nil)))
    (ert-info ((format "parse of serialize should return the original %s message" desc))
      (should (equal (ride-apl-proto-parse (ride-apl-proto-serialize name args))
                     (cons name args))))))

(ert-deftest ride-apl-proto-constructors ()
  (pcase-dolist (`(,desc ,payload ,expected)
                 `(("identify" ,(ride-apl-proto-identify)
                    ("Identify" . ((apiVersion . 1) (identity . 1))))
                   ("connect" ,(ride-apl-proto-connect)
                    ("Connect" . ((remoteId . 2))))
                   ("disconnect" ,(ride-apl-proto-disconnect "bye")
                    ("Disconnect" . ((message . "bye"))))
                   ("execute" ,(ride-apl-proto-execute "      2+2\n" 0)
                    ("Execute" . ((text . "      2+2\n") (trace . 0))))
                   ("get-log" ,(ride-apl-proto-get-log 500)
                    ("GetLog" . ((format . "json") (maxLines . 500))))
                   ("set-pw" ,(ride-apl-proto-set-pw 100)
                    ("SetPW" . ((pw . 100))))
                   ("weak interrupt" ,(ride-apl-proto-weak-interrupt)
                    ("WeakInterrupt" . nil))
                   ("strong interrupt" ,(ride-apl-proto-strong-interrupt)
                    ("StrongInterrupt" . nil))))
    (ert-info ((format "%s constructor should build the documented message" desc))
      (should (equal (ride-apl-proto-parse payload) expected)))))

(ert-deftest ride-apl-proto-handshake-constructors ()
  (ert-info ("handshake constructors should produce the literal spec strings")
    (should (equal (ride-apl-proto-handshake-supported) "SupportedProtocols=2"))
    (should (equal (ride-apl-proto-handshake-using) "UsingProtocol=2"))))

(ert-deftest ride-apl-proto-arg-access ()
  (ert-info ("arg should fetch a value by key from a parsed message")
    (should (equal (ride-apl-proto-arg '("SetPromptType" . ((type . 3))) 'type) 3)))
  (ert-info ("arg should return nil for a missing key")
    (should (equal (ride-apl-proto-arg '("HadError" . nil) 'type) nil))))

(ert-deftest ride-apl-proto-truthiness ()
  (pcase-dolist (`(,desc ,value ,expected)
                 '(("json true" t t)
                   ("json false" nil nil)
                   ("protocol 1" 1 t)
                   ("protocol 0" 0 nil)))
    (ert-info ((format "true-p should treat %s as %s" desc
                       (if expected "true" "false")))
      (should (equal (ride-apl-proto-true-p value) expected)))))

(provide 'ride-apl-proto-test)
;;; ride-apl-proto-test.el ends here
