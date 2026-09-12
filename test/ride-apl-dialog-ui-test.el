;;; ride-apl-dialog-ui-test.el --- Dialog choice mapping + close-all e2e -*- lexical-binding: t; -*-

(require 'ert)
(require 'ride-apl)
(require 'ride-apl-test-server)
(require 'ride-apl-test-common)

(ert-deftest ride-apl-repl-dialog-choice-indices ()
  (pcase-dolist (`(,desc ,kind ,dialog ,expected)
                 '(("options map to their indices"
                    :options ((options . ("Yes" "No" "Cancel")))
                    (("Yes" . 0) ("No" . 1) ("Cancel" . 2)))
                   ("task buttonText replies as 100+i"
                    :task ((options . ("A" "B")) (buttonText . ("OK" "Skip")))
                    (("A" . 0) ("B" . 1) ("OK" . 100) ("Skip" . 101)))
                   ("task with no options still offers buttons"
                    :task ((buttonText . ("OK")))
                    (("OK" . 100)))))
    (ert-info ((format "dialog choices: %s" desc))
      (should (equal (ride-apl-repl--dialog-choices kind dialog) expected)))))

(ert-deftest ride-apl-repl-dialog-prompt-strings ()
  (ert-info ("the prompt should combine title and text")
    (should (equal (ride-apl-repl--dialog-prompt
                    '((title . "Fix") (text . "Cannot fix")))
                   "Fix — Cannot fix: ")))
  (ert-info ("a missing title should fall back to Dyalog")
    (should (equal (ride-apl-repl--dialog-prompt '((text . "Pick")))
                   "Dyalog — Pick: "))))

(ert-deftest ride-apl-edit-e2e-close-all-windows ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (ride-apl-session--dispatch conn '(:edit "f" 0 nil))
    (should (ride-apl-test--wait-for
             (lambda () (buffer-live-p
                         (alist-get 21 (ride-apl-conn-edit-buffers conn))))))
    (ride-apl-close-all-windows)
    (ert-info ("close-all should drain the window table via per-window echoes")
      (should (ride-apl-test--wait-for
               (lambda () (null (ride-apl-session-windows (ride-apl-conn-state conn)))))))
    (ert-info ("close-all should kill the editor buffers")
      (should (null (alist-get 21 (ride-apl-conn-edit-buffers conn)))))))

(provide 'ride-apl-dialog-ui-test)
;;; ride-apl-dialog-ui-test.el ends here
