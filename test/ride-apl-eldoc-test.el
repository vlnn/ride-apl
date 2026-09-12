;;; ride-apl-eldoc-test.el --- Eldoc + inline results, e2e -*- lexical-binding: t; -*-

(require 'ert)
(require 'ride-apl)
(require 'ride-apl-test-server)
(require 'ride-apl-test-common)

(defmacro ride-apl-eldoc-test--with-apl-buffer (content &rest body)
  (declare (indent 1))
  `(let ((buffer (generate-new-buffer " *ride-apl-apl-test*")))
     (unwind-protect
         (with-current-buffer buffer
           (insert ,content)
           (goto-char (point-min))
           ,@body)
       (kill-buffer buffer))))

(defun ride-apl-eldoc-test--result-overlays ()
  (seq-filter (lambda (o) (overlay-get o 'ride-apl-eval-result))
              (overlays-in (point-min) (point-max))))

(defun ride-apl-eldoc-test--overlay-text ()
  (let ((overlay (car (ride-apl-eldoc-test--result-overlays))))
    (and overlay (substring-no-properties (overlay-get overlay 'after-string)))))

(ert-deftest ride-apl-eval-shows-result-overlay ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (ride-apl-eldoc-test--with-apl-buffer "2+2"
      (ride-apl-eval-line-or-region)
      (ert-info ("evaluating a line should attach its value as an overlay")
        (should (ride-apl-test--wait-for #'ride-apl-eldoc-test--result-overlays))
        (should (equal (ride-apl-eldoc-test--overlay-text) " ⇒ 4"))))))

(ert-deftest ride-apl-eval-silent-line-shows-no-overlay ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (ride-apl-eldoc-test--with-apl-buffer "a←1"
      (ride-apl-eval-line-or-region)
      (should (ride-apl-test--wait-for
               (lambda () (null (ride-apl-session-pending-lines
                                 (ride-apl-conn-state conn))))))
      (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
      (ert-info ("output-free evaluation should leave the buffer clean")
        (should (null (ride-apl-eldoc-test--result-overlays)))))))

(ert-deftest ride-apl-eval-overlay-clears-on-edit ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (ride-apl-eldoc-test--with-apl-buffer "2+2"
      (ride-apl-eval-line-or-region)
      (should (ride-apl-test--wait-for #'ride-apl-eldoc-test--result-overlays))
      (goto-char (point-max))
      (insert "×3")
      (ert-info ("editing the buffer should clear result overlays")
        (should (null (ride-apl-eldoc-test--result-overlays)))))))

(ert-deftest ride-apl-eldoc-asks-interpreter ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (ride-apl-eldoc-test--with-apl-buffer "myvar"
      (let (doc)
        (ert-info ("with a live session the eldoc member should go async")
          (should (ride-apl-eldoc-function (lambda (text &rest _) (setq doc text)))))
        (ert-info ("the ValueTip reply should reach the eldoc callback")
          (should (ride-apl-test--wait-for (lambda () doc)))
          (should (equal doc "1 2 3")))))))

(ert-deftest ride-apl-eldoc-declines-without-session ()
  (ride-apl-eldoc-test--with-apl-buffer "myvar"
    (let ((ride-apl--conns nil))
      (ert-info ("without a session the eldoc member should yield to others")
        (should (null (ride-apl-eldoc-function #'ignore)))))))

(ert-deftest ride-apl-eldoc-latest-request-wins ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (let (first second)
      (ride-apl-value-tip conn "old" 0 (lambda (_) (setq first t)))
      (ride-apl-value-tip conn "new" 0 (lambda (_) (setq second t)))
      (ert-info ("only the most recent tip request should be answered")
        (should (ride-apl-test--wait-for (lambda () second)))
        (should (null first))))))

(ert-deftest ride-apl-eldoc-setup-keeps-legacy-function-as-fallback ()
  (skip-unless (boundp 'eldoc-documentation-functions))
  (with-temp-buffer
    (setq-local eldoc-documentation-function (lambda () "legacy"))
    (ride-apl-eldoc-setup)
    (ert-info ("ride-apl's member should be consulted first")
      (should (eq (car eldoc-documentation-functions) #'ride-apl-eldoc-function)))
    (ert-info ("the legacy single function should survive as a hook member")
      (should (member "legacy"
                      (mapcar (lambda (fn)
                                (and (functionp fn)
                                     (not (eq fn #'ride-apl-eldoc-function))
                                     (not (eq fn t))
                                     (ignore-errors (funcall fn #'ignore))))
                              eldoc-documentation-functions))))
    (ert-info ("the obsolete variable should no longer shadow the hook")
      (should (not (local-variable-p 'eldoc-documentation-function))))))


(ert-deftest ride-apl-eval-multiline-dfn-drains-through-collection ()
  (ride-apl-e2e--with-repl conn _buffer
    (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn))))
    (ride-apl-eldoc-test--with-apl-buffer "mean←{\n(+⌿⍵)÷≢⍵\n}\n2+2\n"
      (ride-apl-eval-buffer)
      (ert-info ("all lines of the dfn should drain through prompt-type-3 collection")
        (should (ride-apl-test--wait-for
                 (lambda () (null (ride-apl-session-pending-lines
                                   (ride-apl-conn-state conn)))))))
      (ert-info ("the session should come back to a ready prompt")
        (should (ride-apl-test--wait-for (lambda () (ride-apl-e2e--ready-p conn)))))
      (ert-info ("the expression after the dfn should still get its overlay")
        (should (ride-apl-test--wait-for #'ride-apl-eldoc-test--result-overlays))
        (should (equal (ride-apl-eldoc-test--overlay-text) " ⇒ 4"))))))

(ert-deftest ride-apl-eval-hints-on-unpaired-brace ()
  (pcase-dolist (`(,desc ,text ,hinted)
                 '(("unpaired brace error" "SYNTAX ERROR: Unpaired brace" t)
                   ("other syntax error" "SYNTAX ERROR" nil)
                   ("value error" "VALUE ERROR: undefined name" nil)))
    (ert-info ((format "multiline hint for %s should be %s" desc
                       (if hinted "shown" "absent")))
      (should (equal (not (null (ride-apl-eval--multiline-hint-p text))) hinted)))))

(provide 'ride-apl-eldoc-test)
;;; ride-apl-eldoc-test.el ends here
