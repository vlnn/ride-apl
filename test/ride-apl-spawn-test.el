;;; ride-apl-spawn-test.el --- Tests for spawning an interpreter -*- lexical-binding: t; -*-

(require 'ert)
(require 'ride-apl)
(require 'ride-apl-test-server)
(require 'ride-apl-test-common)

(ert-deftest ride-apl-spawn-command-default-is-plain-dyalog ()
  (let ((ride-apl-program "dyalog")
        (ride-apl-program-args nil))
    (should (equal (ride-apl-spawn--command nil) '("dyalog")))))

(ert-deftest ride-apl-spawn-command-honors-custom-program-and-args ()
  (let ((ride-apl-program "/opt/mdyalog/20.0/64/unicode/dyalog")
        (ride-apl-program-args '("-tty" "+s")))
    (should (equal (ride-apl-spawn--command nil)
                   '("/opt/mdyalog/20.0/64/unicode/dyalog" "-tty" "+s")))))

(ert-deftest ride-apl-spawn-command-explicit-line-wins ()
  (let ((ride-apl-program "dyalog"))
    (should (equal (ride-apl-spawn--command "mydyalog -tty '+s'")
                   '("mydyalog" "-tty" "+s")))))

(ert-deftest ride-apl-spawn-environment-tells-interpreter-to-serve ()
  (should (member "RIDE_INIT=SERVE:127.0.0.1:4502"
                  (ride-apl-spawn--environment 4502))))

(ert-deftest ride-apl-spawn-environment-overrides-inherited-ride-init ()
  (let* ((process-environment (cons "RIDE_INIT=CONNECT:elsewhere:99"
                                    process-environment))
         (process-environment (ride-apl-spawn--environment 4502)))
    (should (equal (getenv "RIDE_INIT") "SERVE:127.0.0.1:4502"))))

(ert-deftest ride-apl-spawn-free-port-is-bindable ()
  (let ((port (ride-apl-spawn--free-port)))
    (should (integerp port))
    (let ((server (make-network-process :name "ride-apl-spawn-test" :server t
                                        :host "127.0.0.1" :service port
                                        :noquery t)))
      (unwind-protect
          (should (equal port (process-contact server :service)))
        (delete-process server)))))

(ert-deftest ride-apl-spawn-errors-when-interpreter-dies-before-serving ()
  (let ((process (make-process :name "ride-apl-doomed" :command '("true")
                               :noquery t)))
    (ride-apl-test--wait-for (lambda () (not (process-live-p process))))
    (should-error (ride-apl-spawn--connect-when-ready
                   process "127.0.0.1" (ride-apl-spawn--free-port)
                   (+ (float-time) 1))
                  :type 'user-error)))

(ert-deftest ride-apl-spawn-errors-when-deadline-passes ()
  (let ((process (make-process :name "ride-apl-idle" :command '("sleep" "5")
                               :noquery t)))
    (unwind-protect
        (should-error (ride-apl-spawn--connect-when-ready
                       process "127.0.0.1" (ride-apl-spawn--free-port)
                       (- (float-time) 1))
                      :type 'user-error)
      (delete-process process))))

(ert-deftest ride-apl-spawn-connects-once-interpreter-serves ()
  (let ((port (ride-apl-spawn--free-port))
        (process (make-process :name "ride-apl-fake-dyalog"
                               :command '("sleep" "5") :noquery t))
        (server nil))
    (unwind-protect
        (progn
          (run-at-time 0.3 nil
                       (lambda ()
                         (setq server (car (ride-apl-testsrv-start 'happy port)))))
          (ride-apl-spawn--connect-when-ready process "127.0.0.1" port
                                          (+ (float-time) 5))
          (should (ride-apl-test--wait-for
                   (lambda ()
                     (let ((conn (ride-apl-current-conn)))
                       (and conn
                            (equal (ride-apl-conn-port conn) port)
                            (eq (ride-apl-session-conn-state
                                 (ride-apl-conn-state conn))
                                'connected))))
                   5)))
      (delete-process process)
      (when server (delete-process server))
      (let ((conn (ride-apl-current-conn)))
        (when conn
          (ride-apl-transport-close (ride-apl-conn-process conn))
          (when (buffer-live-p (ride-apl-conn-repl-buffer conn))
            (kill-buffer (ride-apl-conn-repl-buffer conn))))))))

(provide 'ride-apl-spawn-test)
;;; ride-apl-spawn-test.el ends here
