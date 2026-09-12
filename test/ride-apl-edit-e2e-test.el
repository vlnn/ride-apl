;;; ride-apl-edit-e2e-test.el --- Editor windows against the fake interpreter -*- lexical-binding: t; -*-

(require 'ert)
(require 'ride-apl)
(require 'ride-apl-test-server)
(require 'ride-apl-test-common)

(defun ride-apl-edit-e2e--buffer (conn)
  (alist-get 21 (ride-apl-conn-edit-buffers conn)))

(defun ride-apl-edit-e2e--open (conn)
  (ride-apl-session--dispatch conn '(:edit "f" 0 nil))
  (ride-apl-test--wait-for
   (lambda () (buffer-live-p (ride-apl-edit-e2e--buffer conn)))))

(ert-deftest ride-apl-edit-e2e-open-renders-window ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (ert-info ("an :edit request should open the interpreter's window as a buffer")
      (should (ride-apl-edit-e2e--open conn)))
    (with-current-buffer (ride-apl-edit-e2e--buffer conn)
      (ert-info ("the buffer should contain the window text")
        (should (equal (buffer-string) "f←{\n ⍵+1\n}")))
      (ert-info ("point should sit on currentRow converted at the UI boundary (AD-19)")
        (should (equal (line-number-at-pos) 2)))
      (ert-info ("a freshly opened window should not be marked modified")
        (should (not (buffer-modified-p)))))
    (ert-info ("the window record should be in the session table (AD-7)")
      (should (equal (plist-get (alist-get 21 (ride-apl-session-windows
                                               (ride-apl-conn-state conn)))
                                :name)
                     "f")))))

(ert-deftest ride-apl-edit-e2e-save-round-trip ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (should (ride-apl-edit-e2e--open conn))
    (with-current-buffer (ride-apl-edit-e2e--buffer conn)
      (goto-char (point-max))
      (forward-line -1)
      (end-of-line)
      (insert "0")
      (ride-apl-edit-save)
      (ert-info ("saving should clear the modified flag on ReplySaveChanges err 0")
        (should (ride-apl-test--wait-for (lambda () (not (buffer-modified-p)))))))
    (ert-info ("the server should have received the edited text as an array")
      (let ((save (seq-find (lambda (p) (equal (car (ride-apl-proto-parse p))
                                               "SaveChanges"))
                            ride-apl-testsrv--received)))
        (should save)
        (should (equal (ride-apl-proto-arg (ride-apl-proto-parse save) 'text)
                       '("f←{" " ⍵+10" "}")))))))

(ert-deftest ride-apl-edit-e2e-interpreter-wins-loudly ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (should (ride-apl-edit-e2e--open conn))
    (with-current-buffer (ride-apl-edit-e2e--buffer conn)
      (goto-char (point-max))
      (insert "\n local-dirt")
      (should (buffer-modified-p)))
    (ride-apl-session--dispatch
     conn '("UpdateWindow" . ((name . "f") (filename . "")
                              (text . ("f←{" " ⍵+2" "}")) (token . 21)
                              (currentRow . 0) (debugger . 0) (entityType . 1)
                              (offset . 0) (readOnly . 0) (size . 3)
                              (stop . ()) (tid . 0) (tname . "Tid:0"))))
    (with-current-buffer (ride-apl-edit-e2e--buffer conn)
      (ert-info ("UpdateWindow over local edits should replace the text (AD-21)")
        (should (equal (buffer-string) "f←{\n ⍵+2\n}"))
        (should (not (buffer-modified-p))))
      (ert-info ("the clobbered local text should be on the kill ring (AD-21)")
        (should (string-match-p "local-dirt" (current-kill 0)))))))

(ert-deftest ride-apl-edit-e2e-kill-buffer-close-handshake ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (should (ride-apl-edit-e2e--open conn))
    (kill-buffer (ride-apl-edit-e2e--buffer conn))
    (ert-info ("killing the buffer should send CloseWindow and await the echo (AD-20)")
      (should (ride-apl-test--wait-for
               (lambda ()
                 (null (ride-apl-session-windows (ride-apl-conn-state conn)))))))
    (ert-info ("after the echo the buffer table entry should be gone")
      (should (null (ride-apl-edit-e2e--buffer conn))))
    (ert-info ("a fresh :edit after closing should reopen a live buffer")
      (should (ride-apl-edit-e2e--open conn)))))


(ert-deftest ride-apl-edit-redirects-to-linked-file ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (let ((file (make-temp-file "ride-apl-redirect" nil ".aplf" "f←{\n ⍵+1\n}\n"))
          (ride-apl-testsrv-edit-filename nil))
      (setq ride-apl-testsrv-edit-filename file)
      (unwind-protect
          (progn
            (ride-apl-edit "f")
            (ert-info ("an OpenWindow with a filename should visit the real file")
              (should (ride-apl-test--wait-for
                       (lambda () (equal (buffer-file-name (window-buffer))
                                         file)))))
            (ert-info ("point should land on the interpreter's currentRow")
              (with-current-buffer (window-buffer)
                (should (equal (line-number-at-pos) 2))))
            (ert-info ("the protocol window should be released, not rendered")
              (should (ride-apl-test--wait-for
                       (lambda ()
                         (seq-find (lambda (p)
                                     (equal (car (ride-apl-proto-parse p))
                                            "CloseWindow"))
                                   ride-apl-testsrv--received))))
              (should (null (get-buffer "*ride-apl-edit:f*")))))
        (setq ride-apl-testsrv-edit-filename "")
        (when-let ((b (get-file-buffer file))) (kill-buffer b))
        (delete-file file)))))

(ert-deftest ride-apl-goto-definition-lands-in-file ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (let ((file (make-temp-file "ride-apl-goto" nil ".aplf" "f←{\n ⍵+1\n}\n")))
      (setq ride-apl-testsrv-edit-filename file)
      (unwind-protect
          (with-temp-buffer
            (insert "f 41")
            (goto-char (point-min))
            (ride-apl-goto-definition (thing-at-point 'symbol t))
            (ert-info ("M-. should resolve via the interpreter into the file")
              (should (ride-apl-test--wait-for
                       (lambda () (equal (buffer-file-name (window-buffer))
                                         file))))))
        (setq ride-apl-testsrv-edit-filename "")
        (when-let ((b (get-file-buffer file))) (kill-buffer b))
        (delete-file file)))))

(provide 'ride-apl-edit-e2e-test)
;;; ride-apl-edit-e2e-test.el ends here
