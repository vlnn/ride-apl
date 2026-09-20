;;; ride-apl-test-server.el --- Fake RIDE interpreter for tests -*- lexical-binding: t; -*-

(require 'ride-apl-transport)
(require 'ride-apl-proto)

(defvar ride-apl-testsrv--received nil)
(defvar ride-apl-testsrv--clients nil)
(defvar ride-apl-testsrv-edit-filename ""
  "Filename echoed in OpenWindow replies to Edit; tests may set this.")

(defun ride-apl-testsrv-start (behavior &optional port)
  "Start a fake interpreter with BEHAVIOR; return (SERVER . PORT).
BEHAVIOR: `happy' handshakes and identifies, `silent' says nothing,
`mismatch' offers an unsupported protocol, `repl' runs a canned REPL
\(reactions in ride-apl-repl-e2e-test.el).  Listen on PORT when
given, else on a kernel-assigned free port."
  (setq ride-apl-testsrv--received nil)
  (setq ride-apl-testsrv--clients nil)
  (setq ride-apl-testsrv-edit-filename "")
  (let ((server (make-network-process
                 :name "ride-apl-testsrv" :server t :host "127.0.0.1"
                 :service (or port t) :coding '(binary . binary) :noquery t
                 :plist (list 'ride-apl-behavior behavior)
                 :filter #'ride-apl-testsrv--filter
                 :sentinel #'ride-apl-testsrv--sentinel)))
    (cons server (process-contact server :service))))

(defun ride-apl-testsrv--sentinel (process event)
  (when (string-match-p "open" event)
    (push process ride-apl-testsrv--clients)
    (process-put process 'ride-apl-accumulator "")
    (pcase (process-get process 'ride-apl-behavior)
      ((or 'happy 'repl)
       (ride-apl-testsrv--send process "SupportedProtocols=2")
       (ride-apl-testsrv--send process "UsingProtocol=2"))
      ('mismatch (ride-apl-testsrv--send process "SupportedProtocols=9"))
      ('silent nil))))

(defun ride-apl-testsrv--filter (process chunk)
  (pcase-let ((`(,payloads . ,remainder)
               (ride-apl-transport-decode
                (concat (process-get process 'ride-apl-accumulator) chunk))))
    (process-put process 'ride-apl-accumulator remainder)
    (dolist (payload payloads)
      (push payload ride-apl-testsrv--received)
      (ride-apl-testsrv--react process payload))))

(defun ride-apl-testsrv--react (process payload)
  (when (string-prefix-p "[" payload)
    (if (eq (process-get process 'ride-apl-behavior) 'repl)
        (ride-apl-testsrv--repl-react process payload)
      (when (equal (car (ride-apl-proto-parse payload)) "Identify")
        (ride-apl-testsrv--send
         process
         (ride-apl-proto-serialize "ReplyIdentify"
                               '((apiVersion . 1) (version . "20.0.50000"))))))))

(declare-function ride-apl-testsrv--repl-react "ride-apl-repl-e2e-test")

(defun ride-apl-testsrv--send (process payload)
  (process-send-string process (ride-apl-transport-encode payload)))

(defun ride-apl-testsrv--repl-react (process payload)
  (pcase (car (ride-apl-proto-parse payload))
    ("Identify"
     (ride-apl-testsrv--send
      process (ride-apl-proto-serialize "ReplyIdentify" '((apiVersion . 1)))))
    ("Connect"
     (ride-apl-testsrv--send
      process (ride-apl-proto-serialize "SetPromptType" '((type . 1)))))
    ("GetLog"
     (ride-apl-testsrv--send
      process (ride-apl-proto-serialize
               "ReplyGetLog"
               `((result . ,(vector '((text . "log-line-1") (type . 2) (group . 0))))))))
    ("Edit"
     (let ((name (ride-apl-proto-arg (ride-apl-proto-parse payload) 'text)))
       (ride-apl-testsrv--send
        process (ride-apl-proto-serialize
                 "OpenWindow"
                 `((name . ,name) (filename . ,ride-apl-testsrv-edit-filename)
                   (text . ,(vector "f←{" " ⍵+1" "}"))
                   (token . 21) (currentRow . 1) (debugger . 0)
                   (entityType . 1) (offset . 0) (readOnly . 0)
                   (size . 3) (stop . ,(vector)) (tid . 0)
                   (tname . "Tid:0"))))))
    ("SaveChanges"
     (ride-apl-testsrv--send
      process (ride-apl-proto-serialize "ReplySaveChanges" '((win . 21) (err . 0)))))
    ("CloseAllWindows"
     (ride-apl-testsrv--send
      process (ride-apl-proto-serialize "CloseWindow" '((win . 21)))))
    ("CloseWindow"
     (ride-apl-testsrv--send
      process (ride-apl-proto-serialize "CloseWindow" '((win . 21)))))
    ((or "StepInto" "RunCurrentLine" "TraceForward" "TracePrimitive")
     (let ((line (1+ (or (process-get process 'ride-apl-trace-line) 0))))
       (process-put process 'ride-apl-trace-line line)
       (ride-apl-testsrv--send
        process (ride-apl-proto-serialize
                 "SetHighlightLine"
                 `((win . 31) (line . ,line) (end_line . ,line)
                   (start_col . -1) (end_col . -1))))))
    ("TraceBackward"
     (let ((line (max 0 (1- (or (process-get process 'ride-apl-trace-line) 0)))))
       (process-put process 'ride-apl-trace-line line)
       (ride-apl-testsrv--send
        process (ride-apl-proto-serialize
                 "SetHighlightLine"
                 `((win . 31) (line . ,line) (end_line . ,line)
                   (start_col . -1) (end_col . -1))))))
    ("Continue"
     (ride-apl-testsrv--send
      process (ride-apl-proto-serialize "CloseWindow" '((win . 31))))
     (ride-apl-testsrv--send
      process (ride-apl-proto-serialize
               "AppendSessionOutput" '((result . "8\n") (type . 2) (group . 0))))
     (ride-apl-testsrv--send
      process (ride-apl-proto-serialize "SetPromptType" '((type . 1)))))
    ("Cutback"
     (ride-apl-testsrv--send
      process (ride-apl-proto-serialize "CloseWindow" '((win . 31))))
     (ride-apl-testsrv--send
      process (ride-apl-proto-serialize "SetPromptType" '((type . 1)))))
    ("SetLineAttributes"
     (ride-apl-testsrv--send process payload))
    ("GetValueTip"
     (let ((args (cdr (ride-apl-proto-parse payload))))
       (ride-apl-testsrv--send
        process (ride-apl-proto-serialize
                 "ValueTip"
                 `((token . ,(alist-get 'token args)) (class . 2)
                   (tip . ,(vector "1 2 3"))
                   (startCol . 0) (endCol . 5))))))
    ("Execute"
     (let ((text (ride-apl-proto-arg (ride-apl-proto-parse payload) 'text))
           (trace (ride-apl-proto-arg (ride-apl-proto-parse payload) 'trace)))
       (if (eql trace 1)
           (ride-apl-testsrv--start-trace process)
         (ride-apl-testsrv--session-execute process text))))))

(defun ride-apl-testsrv--start-trace (process)
  (process-put process 'ride-apl-trace-line 0)
  (ride-apl-testsrv--send
   process (ride-apl-proto-serialize
            "OpenWindow"
            `((name . "#.f") (filename . "")
              (text . ,(vector "r←f x" "r←x+1" "r←r×2"))
              (token . 31) (currentRow . 0) (debugger . 1)
              (entityType . 1) (offset . 0) (readOnly . 1)
              (size . 3) (stop . ,(vector)) (tid . 0)
              (tname . "Tid:0"))))
  (ride-apl-testsrv--send
   process (ride-apl-proto-serialize
            "SetHighlightLine"
            '((win . 31) (line . 0) (end_line . 0)
              (start_col . -1) (end_col . -1)))))

(defun ride-apl-testsrv--session-execute (process text)
  "Echo TEXT and react, emulating Dyalog_LineEditor_Mode=1 multiline input."
  (ride-apl-testsrv--send
   process (ride-apl-proto-serialize
            "AppendSessionOutput" `((result . ,text) (type . 14) (group . 0))))
  (let ((depth (+ (or (process-get process 'ride-apl-ml-depth) 0)
                  (ride-apl-testsrv--brace-delta text))))
    (process-put process 'ride-apl-ml-depth (max 0 depth))
    (cond
     ((> depth 0)
      (ride-apl-testsrv--send
       process (ride-apl-proto-serialize "SetPromptType" '((type . 3)))))
     ((< depth 0)
      (ride-apl-testsrv--send
       process (ride-apl-proto-serialize
                "AppendSessionOutput"
                '((result . "SYNTAX ERROR: Unpaired brace\n")
                  (type . 3) (group . 0))))
      (ride-apl-testsrv--send process (ride-apl-proto-serialize "HadError" nil))
      (ride-apl-testsrv--send
       process (ride-apl-proto-serialize "SetPromptType" '((type . 1)))))
     (t
      (when (string-match-p "2\\+2" text)
        (ride-apl-testsrv--send
         process (ride-apl-proto-serialize
                  "AppendSessionOutput" '((result . "4\n") (type . 2) (group . 0)))))
      (ride-apl-testsrv--send
       process (ride-apl-proto-serialize "SetPromptType" '((type . 1))))))))

(defun ride-apl-testsrv--brace-delta (text)
  (- (seq-count (lambda (c) (eq c ?{)) text)
     (seq-count (lambda (c) (eq c ?})) text)))

(provide 'ride-apl-test-server)
;;; ride-apl-test-server.el ends here
