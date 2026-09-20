;;; ride-apl-proto.el --- RIDE protocol messages -*- lexical-binding: t; -*-


;;; Commentary:
;; Message constructors and parser (AD-12), pure.  A parsed message is
;; (NAME . ARGS): NAME a string, ARGS an alist with symbol keys, both
;; for JSON commands and for the name=value handshake strings.  All
;; apiVersion conditionals belong in this file and nowhere else.

;;; Code:

(defconst ride-apl-proto-api-version 1)
(defconst ride-apl-proto-protocol-version "2")

(define-error 'ride-apl-proto-bad-message "Unparseable RIDE payload")

(defun ride-apl-proto-parse (payload)
  "Parse PAYLOAD string into a (NAME . ARGS) message."
  (cond
   ((string-prefix-p "[" payload) (ride-apl-proto--parse-json payload))
   ((string-match-p "\\`[A-Za-z]+=" payload) (ride-apl-proto--parse-handshake payload))
   (t (signal 'ride-apl-proto-bad-message (list payload)))))

(defun ride-apl-proto-serialize (name args)
  "Serialize NAME and alist ARGS into a wire payload string."
  (format "[%s,%s]"
          (json-serialize name)
          (if args (json-serialize args) "{}")))

(defun ride-apl-proto-arg (message key)
  "Fetch KEY from the args of parsed MESSAGE."
  (alist-get key (cdr message)))

(defun ride-apl-proto-true-p (value)
  "Protocol truthiness: JSON booleans and 0/1 interchangeably."
  (and value (not (eql value 0))))

(defun ride-apl-proto-handshake-supported ()
  (concat "SupportedProtocols=" ride-apl-proto-protocol-version))

(defun ride-apl-proto-handshake-using ()
  (concat "UsingProtocol=" ride-apl-proto-protocol-version))

(defun ride-apl-proto-identify ()
  (ride-apl-proto-serialize
   "Identify" `((apiVersion . ,ride-apl-proto-api-version) (identity . 1))))

(defun ride-apl-proto-connect ()
  (ride-apl-proto-serialize "Connect" '((remoteId . 2))))

(defun ride-apl-proto-disconnect (message)
  (ride-apl-proto-serialize "Disconnect" `((message . ,message))))

(defun ride-apl-proto-execute (text trace)
  (ride-apl-proto-serialize "Execute" `((text . ,text) (trace . ,trace))))

(defun ride-apl-proto-get-log (max-lines)
  (ride-apl-proto-serialize "GetLog" `((format . "json") (maxLines . ,max-lines))))

(defun ride-apl-proto-set-pw (pw)
  (ride-apl-proto-serialize "SetPW" `((pw . ,pw))))

(defun ride-apl-proto-weak-interrupt ()
  (ride-apl-proto-serialize "WeakInterrupt" nil))

(defun ride-apl-proto-strong-interrupt ()
  (ride-apl-proto-serialize "StrongInterrupt" nil))

(defun ride-apl-proto-edit (name pos unsaved)
  "Edit request for NAME at POS; UNSAVED is ((WIN-ID . TEXT)...)."
  (ride-apl-proto-serialize
   "Edit" `((win . 0) (text . ,name) (pos . ,pos)
            (unsaved . ,(ride-apl-proto--unsaved-object unsaved)))))

(defun ride-apl-proto-save-changes (win lines stops)
  (ride-apl-proto-serialize
   "SaveChanges" `((win . ,win)
                   (text . ,(vconcat lines))
                   (stop . ,(vconcat stops)))))

(defun ride-apl-proto-close-window (win)
  (ride-apl-proto-serialize "CloseWindow" `((win . ,win))))

(defun ride-apl-proto-close-all-windows ()
  (ride-apl-proto-serialize "CloseAllWindows" nil))

(defun ride-apl-proto-reply-options-dialog (index token)
  (ride-apl-proto-serialize "ReplyOptionsDialog" `((index . ,index) (token . ,token))))

(defun ride-apl-proto-reply-task-dialog (index token)
  (ride-apl-proto-serialize "ReplyTaskDialog" `((index . ,index) (token . ,token))))

(defun ride-apl-proto-reply-string-dialog (value token)
  "VALUE is a string, or nil for a dismissed dialog (sent as JSON null)."
  (ride-apl-proto-serialize "ReplyStringDialog"
                        `((value . ,(or value :null)) (token . ,token))))

(defun ride-apl-proto-get-value-tip (win token line pos)
  "Value tip request for column POS (0-based) of LINE in window WIN."
  (ride-apl-proto-serialize
   "GetValueTip" `((win . ,win) (token . ,token) (line . ,line) (pos . ,pos)
                   (maxWidth . 100) (maxHeight . 30))))

(defun ride-apl-proto-tracer-command (name win)
  "A win-keyed tracer message: StepInto, RunCurrentLine, Continue,
ContinueTrace, Cutback, TraceForward, TraceBackward, TracePrimitive."
  (ride-apl-proto-serialize name `((win . ,win))))

(defun ride-apl-proto-restart-threads ()
  (ride-apl-proto-serialize "RestartThreads" nil))

(defun ride-apl-proto-clear-trace-stop-monitor (token)
  (ride-apl-proto-serialize "ClearTraceStopMonitor" `((token . ,token))))

(defun ride-apl-proto-set-line-attributes (win stops)
  (ride-apl-proto-serialize "SetLineAttributes"
                        `((win . ,win) (stop . ,(vconcat stops)))))

(defun ride-apl-proto--unsaved-object (unsaved)
  (mapcar (pcase-lambda (`(,id . ,text))
            (cons (intern (number-to-string id)) text))
          unsaved))

(defun ride-apl-proto--parse-json (payload)
  (pcase (ride-apl-proto--json-read payload)
    (`(,(and (pred stringp) name) ,args) (cons name args))
    (parsed (signal 'ride-apl-proto-bad-message (list payload parsed)))))

(defun ride-apl-proto--json-read (payload)
  (condition-case err
      (json-parse-string payload
                         :object-type 'alist
                         :array-type 'list
                         :false-object nil
                         :null-object nil)
    (json-parse-error
     (signal 'ride-apl-proto-bad-message (list payload err)))))

(defun ride-apl-proto--parse-handshake (payload)
  (let ((eq-pos (string-match "=" payload)))
    (cons (substring payload 0 eq-pos)
          (substring payload (1+ eq-pos)))))

(provide 'ride-apl-proto)
;;; ride-apl-proto.el ends here
