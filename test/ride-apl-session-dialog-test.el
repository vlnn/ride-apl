;;; ride-apl-session-dialog-test.el --- M3 close-out reducer tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'ride-apl-session)
(require 'ride-apl-proto)
(require 'ride-apl-test-common)

(ert-deftest ride-apl-session-dialogs-become-effects ()
  (pcase-dolist (`(,desc ,message ,kind)
                 '(("options dialog"
                    ("OptionsDialog" . ((title . "Fix") (text . "Cannot fix")
                                        (options . ("Yes" "No")) (token . 33)))
                    :options)
                   ("task dialog"
                    ("TaskDialog" . ((title . "T") (text . "Pick")
                                     (options . ("A")) (buttonText . ("OK"))
                                     (token . 34)))
                    :task)
                   ("string dialog"
                    ("StringDialog" . ((title . "S") (text . "Name?")
                                       (initialValue . "x") (token . 35)))
                    :string)))
    (pcase-let ((`(,state . ,effects)
                 (ride-apl-session-step (ride-apl-test--connected-session) message)))
      (ert-info ((format "%s should surface as a :show-dialog effect" desc))
        (should (equal effects
                       (list (list :show-dialog kind (cdr message))))))
      (ert-info ((format "%s should not change the connection state" desc))
        (should (equal (ride-apl-session-conn-state state) 'connected))))))

(ert-deftest ride-apl-session-notification-message-notifies ()
  (ert-info ("NotificationMessage should surface as an info notify")
    (should (equal (cdr (ride-apl-session-step
                         (ride-apl-test--connected-session)
                         '("NotificationMessage" . ((text . "hello")))))
                   '((:notify :info "hello"))))))

(ert-deftest ride-apl-session-dialog-replies-send ()
  (pcase-dolist (`(,desc ,event ,payload)
                 `(("an options choice" (:dialog-reply :options 33 1)
                    ,(ride-apl-proto-reply-options-dialog 1 33))
                   ("a dismissed options dialog" (:dialog-reply :options 33 -1)
                    ,(ride-apl-proto-reply-options-dialog -1 33))
                   ("a task choice" (:dialog-reply :task 34 100)
                    ,(ride-apl-proto-reply-task-dialog 100 34))
                   ("a string value" (:dialog-reply :string 35 "name")
                    ,(ride-apl-proto-reply-string-dialog "name" 35))))
    (ert-info ((format "%s should send the matching reply" desc))
      (should (equal (cdr (ride-apl-session-step (ride-apl-test--connected-session)
                                             event))
                     (list (list :send payload)))))))

(ert-deftest ride-apl-session-close-all-windows ()
  (ert-info ("a :close-all-windows event should send CloseAllWindows")
    (should (equal (cdr (ride-apl-session-step (ride-apl-test--connected-session)
                                           '(:close-all-windows)))
                   (list (list :send (ride-apl-proto-close-all-windows)))))))

(ert-deftest ride-apl-session-edit-carries-pos ()
  (ert-info (":edit should pass line text and cursor pos through to Edit")
    (should (equal (cdr (ride-apl-session-step (ride-apl-test--connected-session)
                                           '(:edit "      f 5" 7 nil)))
                   (list (list :send (ride-apl-proto-edit "      f 5" 7 nil)))))))

(provide 'ride-apl-session-dialog-test)
;;; ride-apl-session-dialog-test.el ends here
