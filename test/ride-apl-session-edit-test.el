;;; ride-apl-session-edit-test.el --- M3 reducer tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'ride-apl-session)
(require 'ride-apl-proto)
(require 'ride-apl-test-common)

(defconst ride-apl-edit-test--open-args
  '((name . "#.f") (filename . "") (text . ("f←{" " ⍵+1" "}"))
    (token . 7) (currentRow . 0) (debugger . 0) (entityType . 1)
    (offset . 0) (readOnly . 0) (size . 3) (stop . (1)) (tid . 0)
    (tname . "Tid:0")))

(defun ride-apl-edit-test--with-window (&optional args)
  (ride-apl-session-step (ride-apl-test--connected-session)
                     (cons "OpenWindow" (or args ride-apl-edit-test--open-args))))

(defun ride-apl-edit-test--record (state id)
  (alist-get id (ride-apl-session-windows state)))

(ert-deftest ride-apl-session-open-window-creates-record ()
  (pcase-let ((`(,state . ,effects) (ride-apl-edit-test--with-window)))
    (let ((record (ride-apl-edit-test--record state 7)))
      (ert-info ("OpenWindow should key the record by its token")
        (should record)
        (should (equal (plist-get record :id) 7)))
      (ert-info ("OpenWindow should map the documented fields")
        (should (equal (plist-get record :name) "#.f"))
        (should (equal (plist-get record :text) '("f←{" " ⍵+1" "}")))
        (should (equal (plist-get record :tracer) nil))
        (should (equal (plist-get record :read-only) nil))
        (should (equal (plist-get record :entity-type) 1)))
      (ert-info ("OpenWindow should keep protocol coordinates untouched (AD-19)")
        (should (equal (plist-get record :stop) '(1)))
        (should (equal (plist-get record :current-row) 0)))
      (ert-info ("OpenWindow should mark the record open and emit :open-window")
        (should (equal (plist-get record :status) :open))
        (should (equal effects (list (list :open-window record))))))))

(ert-deftest ride-apl-session-update-window-refreshes-record ()
  (pcase-let* ((`(,opened . ,_) (ride-apl-edit-test--with-window))
               (updated-args (cons '(text . ("f←{" " ⍵+2" "}"))
                                   (assq-delete-all
                                    'text (copy-alist ride-apl-edit-test--open-args))))
               (`(,state . ,effects)
                (ride-apl-session-step opened (cons "UpdateWindow" updated-args))))
    (ert-info ("UpdateWindow should replace the record contents")
      (should (equal (plist-get (ride-apl-edit-test--record state 7) :text)
                     '("f←{" " ⍵+2" "}"))))
    (ert-info ("UpdateWindow should emit :update-window with the new record")
      (should (equal effects
                     (list (list :update-window 7
                                 (ride-apl-edit-test--record state 7))))))))

(ert-deftest ride-apl-session-close-window-echo-drops-record ()
  (pcase-let* ((`(,opened . ,_) (ride-apl-edit-test--with-window))
               (`(,state . ,effects)
                (ride-apl-session-step opened '("CloseWindow" . ((win . 7))))))
    (ert-info ("the CloseWindow echo should drop the record")
      (should (equal (ride-apl-session-windows state) nil)))
    (ert-info ("the CloseWindow echo should emit :close-window")
      (should (equal effects '((:close-window 7)))))))

(ert-deftest ride-apl-session-close-request-marks-closing ()
  (pcase-let* ((`(,opened . ,_) (ride-apl-edit-test--with-window))
               (`(,state . ,effects)
                (ride-apl-session-step opened '(:close-window-request 7))))
    (ert-info ("a close request should mark the record :closing, not drop it (AD-11/20)")
      (should (equal (plist-get (ride-apl-edit-test--record state 7) :status)
                     :closing)))
    (ert-info ("a close request should send CloseWindow")
      (should (equal effects
                     (list (list :send (ride-apl-proto-close-window 7))))))
    (ert-info ("the interpreter's echo should then drop the :closing record")
      (should (equal (ride-apl-session-windows
                      (car (ride-apl-session-step state '("CloseWindow" . ((win . 7))))))
                     nil)))))

(ert-deftest ride-apl-session-raced-close-recreates ()
  (pcase-let* ((`(,opened . ,_) (ride-apl-edit-test--with-window))
               (closing (car (ride-apl-session-step opened '(:close-window-request 7))))
               (`(,state . ,effects)
                (ride-apl-session-step closing
                                   (cons "OpenWindow" ride-apl-edit-test--open-args))))
    (ert-info ("OpenWindow for a :closing window is a raced-and-lost close: recreate (AD-20)")
      (should (equal (plist-get (ride-apl-edit-test--record state 7) :status) :open))
      (should (equal (car (car effects)) :open-window)))))

(ert-deftest ride-apl-session-update-while-closing-still-updates ()
  (pcase-let* ((`(,opened . ,_) (ride-apl-edit-test--with-window))
               (closing (car (ride-apl-session-step opened '(:close-window-request 7))))
               (`(,state . ,effects)
                (ride-apl-session-step closing
                                   (cons "UpdateWindow" ride-apl-edit-test--open-args))))
    (ert-info ("UpdateWindow during :closing should update the record normally (AD-20)")
      (should (equal (plist-get (ride-apl-edit-test--record state 7) :status) :closing))
      (should (equal (car (car effects)) :update-window)))))

(ert-deftest ride-apl-session-save-reply-outcomes ()
  (pcase-let ((`(,opened . ,_) (ride-apl-edit-test--with-window)))
    (ert-info ("a zero-err ReplySaveChanges should emit :window-saved")
      (should (equal (cdr (ride-apl-session-step
                           opened '("ReplySaveChanges" . ((win . 7) (err . 0)))))
                     '((:window-saved 7)))))
    (ert-info ("a nonzero-err ReplySaveChanges should notify an error naming the window")
      (pcase-let ((`(,_ . ,effects)
                   (ride-apl-session-step
                    opened '("ReplySaveChanges" . ((win . 7) (err . 11))))))
        (should (equal (ride-apl-test--effect-types effects) '(:notify)))
        (should (equal (cadr (car effects)) :error))))))

(ert-deftest ride-apl-session-focus-and-type-change ()
  (pcase-let ((`(,opened . ,_) (ride-apl-edit-test--with-window)))
    (ert-info ("GotoWindow should emit :focus-window")
      (should (equal (cdr (ride-apl-session-step opened '("GotoWindow" . ((win . 7)))))
                     '((:focus-window 7)))))
    (ert-info ("WindowTypeChanged should flip the tracer flag and emit :update-window")
      (pcase-let ((`(,state . ,effects)
                   (ride-apl-session-step
                    opened '("WindowTypeChanged" . ((win . 7) (tracer . 1))))))
        (should (equal (plist-get (ride-apl-edit-test--record state 7) :tracer) t))
        (should (equal (car (car effects)) :update-window))))))

(ert-deftest ride-apl-session-edit-event-sends-edit ()
  (pcase-dolist (`(,desc ,unsaved)
                 '(("no dirty windows" nil)
                   ("one dirty window" ((7 . "f←{\n ⍵+3\n}")))))
    (ert-info ((format "an :edit event with %s should send Edit with the unsaved map" desc))
      (should (equal (cdr (ride-apl-session-step (ride-apl-test--connected-session)
                                             `(:edit "f" 0 ,unsaved)))
                     (list (list :send (ride-apl-proto-edit "f" 0 unsaved))))))))

(ert-deftest ride-apl-session-save-event-sends-save-changes ()
  (pcase-let ((`(,opened . ,_) (ride-apl-edit-test--with-window)))
    (ert-info (":save-window should send SaveChanges with text and 0-based stops")
      (pcase-let ((`(,_ . ,effects)
                   (ride-apl-session-step opened
                                      '(:save-window 7 ("f←{" " ⍵+9" "}") (1)))))
        (should (equal effects
                       (list (list :send
                                   (ride-apl-proto-save-changes
                                    7 '("f←{" " ⍵+9" "}") '(1))))))
        (ert-info ("the payload arrays should round-trip through the parser")
          (should (equal (ride-apl-proto-arg (ride-apl-proto-parse (cadr (car effects)))
                                         'text)
                         '("f←{" " ⍵+9" "}"))))))))

(provide 'ride-apl-session-edit-test)
;;; ride-apl-session-edit-test.el ends here
