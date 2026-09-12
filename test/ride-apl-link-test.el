;;; ride-apl-link-test.el --- Linked-directory sync -*- lexical-binding: t; -*-

(require 'ert)
(require 'ride-apl)
(require 'ride-apl-test-server)
(require 'ride-apl-test-common)
(require 'ride-apl-eval-test)

(defmacro ride-apl-link-test--with-linked-file (file-var content &rest body)
  "Visit a saved CONTENT file inside a linked temp root; run BODY."
  (declare (indent 2))
  `(let* ((root (make-temp-file "ride-apl-link" t))
          (,file-var (expand-file-name "mean.aplf" root))
          (ride-apl-link-roots (list root)))
     (with-temp-file ,file-var (insert ,content))
     (let ((buffer (find-file-noselect ,file-var)))
       (unwind-protect
           (with-current-buffer buffer ,@body)
         (kill-buffer buffer)
         (delete-directory root t)))))

(ert-deftest ride-apl-link-file-linked-p-cases ()
  (let* ((root (make-temp-file "ride-apl-link" t))
         (inside (expand-file-name "sub/f.aplf" root))
         (outside (make-temp-file "ride-apl-unlinked" nil ".aplf")))
    (unwind-protect
        (pcase-dolist (`(,desc ,roots ,local ,file ,linked)
                       `(("file under a configured root" (,root) nil ,inside t)
                         ("file outside every root" (,root) nil ,outside nil)
                         ("no roots configured" nil nil ,inside nil)
                         ("buffer-local root" nil ,root ,inside t)))
          (let ((ride-apl-link-roots roots)
                (ride-apl-link-root local))
            (ert-info ((format "%s should be %slinked" desc (if linked "" "not ")))
              (should (equal (not (null (ride-apl-link-file-linked-p file)))
                             linked)))))
      (delete-directory root t)
      (delete-file outside))))

(ert-deftest ride-apl-link-notify-expression-quotes-path ()
  (pcase-dolist (`(,desc ,path ,fragment)
                 '(("plain path" "/tmp/src/mean.aplf"
                    "⎕SE.Link.Notify'/tmp/src/mean.aplf'")
                   ("path with quote" "/tmp/o'brien/f.aplf"
                    "⎕SE.Link.Notify'/tmp/o''brien/f.aplf'")))
    (ert-info ((format "notify expression should quote the %s" desc))
      (should (equal (ride-apl-link--notify-expression path) fragment)))))

(ert-deftest ride-apl-link-save-notifies-interpreter ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (ride-apl-link-test--with-linked-file file "r←mean x\nr←(+⌿x)÷≢x\n"
      (ride-apl-eval-minor-mode 1)
      (goto-char (point-max))
      (insert "⍝ tweak\n")
      (save-buffer)
      (ert-info ("saving a linked file should send Link.Notify for it")
        (should (ride-apl-test--wait-for
                 (lambda ()
                   (seq-find (lambda (text)
                               (string-match-p
                                (concat "⎕SE\\.Link\\.Notify'"
                                        (regexp-quote file) "'")
                                text))
                             (ride-apl-eval-test--execute-texts)))))))))

(ert-deftest ride-apl-link-save-outside-root-stays-silent ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (let* ((file (make-temp-file "ride-apl-plain" nil ".aplf" "r←f x\n"))
           (buffer (find-file-noselect file))
           (before (length (ride-apl-eval-test--executes))))
      (unwind-protect
          (with-current-buffer buffer
            (ride-apl-eval-minor-mode 1)
            (goto-char (point-max))
            (insert "⍝ tweak\n")
            (save-buffer)
            (sit-for 0.2)
            (ert-info ("saving an unlinked file should send nothing")
              (should (equal (length (ride-apl-eval-test--executes)) before))))
        (kill-buffer buffer)
        (delete-file file)))))

(ert-deftest ride-apl-load-file-notifies-inside-linked-root ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (ride-apl-link-test--with-linked-file file "r←mean x\n"
      (ride-apl-load-file)
      (ert-info ("C-c C-l inside a linked root should notify, not 2⎕FIX")
        (should (ride-apl-test--wait-for
                 (lambda ()
                   (seq-find (lambda (text)
                               (string-match-p "⎕SE\\.Link\\.Notify" text))
                             (ride-apl-eval-test--execute-texts)))))
        (should (not (seq-find (lambda (text) (string-match-p "2⎕FIX" text))
                               (ride-apl-eval-test--execute-texts))))))))

(ert-deftest ride-apl-link-resync-sends-user-command ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (with-temp-buffer
      (ride-apl-link-resync))
    (ert-info ("resync should send the ]LINK.Resync user command")
      (should (ride-apl-test--wait-for
               (lambda ()
                 (seq-find (lambda (text)
                             (string-match-p "\\]LINK\\.Resync" text))
                           (ride-apl-eval-test--execute-texts))))))))


(ert-deftest ride-apl-link-create-registers-root ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (let* ((root (make-temp-file "ride-apl-newlink" t))
           (inside (expand-file-name "f.aplf" root))
           (ride-apl-link-roots nil)
           (ride-apl-link-root nil))
      (unwind-protect
          (progn
            (ride-apl-link-create "#" root)
            (ert-info ("the ]LINK.Create user command should go through the queue")
              (should (ride-apl-test--wait-for
                       (lambda ()
                         (seq-find (lambda (text)
                                     (string-match-p "\\]LINK\\.Create #" text))
                                   (ride-apl-eval-test--execute-texts))))))
            (ert-info ("the directory should become a registered linked root")
              (should (ride-apl-link-file-linked-p inside))))
        (delete-directory root t)))))

(ert-deftest ride-apl-edit-stale-p-cases ()
  (pcase-dolist (`(,desc ,file-content ,window-lines ,stale)
                 '(("identical content" "f←{\n ⍵+1\n}\n" ("f←{" " ⍵+1" "}") nil)
                   ("identical without trailing newline" "f←{\n ⍵+1\n}"
                    ("f←{" " ⍵+1" "}") nil)
                   ("diverged body" "f←{\n ⍵+2\n}\n" ("f←{" " ⍵+1" "}") t)
                   ("extra line on disk" "f←{\n ⍵+1\n}\n⍝ new\n"
                    ("f←{" " ⍵+1" "}") t)))
    (with-temp-buffer
      (insert file-content)
      (ert-info ((format "%s should be %sstale" desc (if stale "" "not ")))
        (should (equal (not (null (ride-apl-edit--stale-p
                                   (list :text window-lines))))
                       stale))))))

(provide 'ride-apl-link-test)
;;; ride-apl-link-test.el ends here
