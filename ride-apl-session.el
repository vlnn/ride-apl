;;; ride-apl-session.el --- RIDE session state machine -*- lexical-binding: t; -*-


;;; Commentary:
;; Pure reducer over session state (AD-2, AD-5).  The single entry
;; point is `ride-apl-session-step': (STATE MESSAGE) -> (NEW-STATE . EFFECTS).
;; Effects are data from the AD-16 vocabulary; nothing here touches
;; processes or buffers.  Connection lifecycle follows AD-17:
;; handshake -> identifying -> connected -> closing -> dead.

;;; Code:

(require 'cl-lib)
(require 'ride-apl-proto)

(defgroup ride-apl nil "Dyalog APL client via the RIDE protocol."
  :group 'languages)

(defvar ride-apl-session-log-lines 500
  "Requested maxLines for GetLog on connect.")

(cl-defstruct (ride-apl-session (:constructor ride-apl-session--make)
                            (:copier ride-apl-session--copy))
  (conn-state 'handshake)
  (seen-handshake nil)
  (api-version nil)
  (interpreter nil)
  (display-name nil)
  (caption nil)
  (windows nil)
  (prompt-type 0)
  (log-state nil)
  (queued-output nil)
  (pending-lines nil)
  (eval-origin nil)
  (eval-entries nil)
  (pw 80))

(defmacro ride-apl-session--with (state &rest bindings)
  "Copy STATE, set each (FIELD VALUE) of BINDINGS, return the copy."
  (declare (indent 1))
  (let ((copy (gensym "state")))
    `(let ((,copy (ride-apl-session--copy ,state)))
       ,@(mapcar (pcase-lambda (`(,field ,value))
                   `(setf (,(intern (format "ride-apl-session-%s" field)) ,copy)
                          ,value))
                 bindings)
       ,copy)))

(defun ride-apl-session-init ()
  "Fresh session and its opening effects."
  (cons (ride-apl-session--make)
        (list (list :send (ride-apl-proto-handshake-supported))
              (list :send (ride-apl-proto-handshake-using)))))

(defun ride-apl-session-step (state message)
  "Reduce MESSAGE into STATE; return (NEW-STATE . EFFECTS)."
  (if (eq (ride-apl-session-conn-state state) 'dead)
      (cons state nil)
    (pcase (car message)
      ((or "SupportedProtocols" "UsingProtocol")
       (ride-apl-session--on-handshake state message))
      ("ReplyIdentify" (ride-apl-session--on-identify-reply state message))
      ("AppendSessionOutput" (ride-apl-session--on-output state message))
      ("SetPromptType" (ride-apl-session--on-prompt-type state message))
      ("ReplyGetLog" (ride-apl-session--on-log-reply state message))
      ("HadError"
       (pcase-let ((`(,next . ,result) (ride-apl-session--finish-eval state :error)))
         (cons (ride-apl-session--with next (pending-lines nil))
               (append result (list (list :focus-repl))))))
      ("ValueTip" (cons state (list (list :value-tip-reply (cdr message)))))
      ("SetSessionLineGroup" (cons state nil))
      (:value-tip
       (pcase-let ((`(,_ ,win ,token ,line ,pos) message))
         (cons state
               (list (list :send
                           (ride-apl-proto-get-value-tip win token line pos))))))
      ((or "OpenWindow" "UpdateWindow")
       (ride-apl-session--on-window-message state message))
      ("CloseWindow" (ride-apl-session--on-close-window state message))
      ("ReplySaveChanges" (ride-apl-session--on-save-reply state message))
      ("GotoWindow"
       (cons state (list (list :focus-window (ride-apl-proto-arg message 'win)))))
      ("WindowTypeChanged" (ride-apl-session--on-type-changed state message))
      ("SetHighlightLine" (ride-apl-session--on-highlight state message))
      ("SetLineAttributes" (ride-apl-session--on-line-attributes state message))
      ("OptionsDialog" (cons state (list (list :show-dialog :options
                                               (cdr message)))))
      ("TaskDialog" (cons state (list (list :show-dialog :task
                                            (cdr message)))))
      ("StringDialog" (cons state (list (list :show-dialog :string
                                              (cdr message)))))
      ("NotificationMessage"
       (ride-apl-session--notify state :info (ride-apl-proto-arg message 'text)))
      ("Disconnect" (ride-apl-session--die state :disconnect
                                       (ride-apl-proto-arg message 'message)))
      ("SysError" (ride-apl-session--die state :sys-error
                                     (ride-apl-proto-arg message 'text)))
      ("UnknownCommand"
       (ride-apl-session--notify state :warn
                             (format "Interpreter rejected message: %s"
                                     (ride-apl-proto-arg message 'name))))
      ("InternalError"
       (ride-apl-session--notify state :error
                             (format "Interpreter internal error %s: %s"
                                     (ride-apl-proto-arg message 'error)
                                     (ride-apl-proto-arg message 'error_text))))
      ("UpdateDisplayName"
       (cons (ride-apl-session--with state
               (display-name (ride-apl-proto-arg message 'displayName)))
             nil))
      ("UpdateSessionCaption"
       (cons (ride-apl-session--with state
               (caption (ride-apl-proto-arg message 'text)))
             nil))
      (:timeout (ride-apl-session--on-timeout state))
      (:closed (ride-apl-session--die state :connection-lost (cadr message)))
      (:log-timeout (ride-apl-session--on-log-timeout state))
      (:input (ride-apl-session--on-input state (cadr message)))
      (:interrupt (ride-apl-session--on-interrupt state (cadr message)))
      (:set-pw (cons (ride-apl-session--with state (pw (cadr message)))
                     (list (list :send (ride-apl-proto-set-pw (cadr message))))))
      (:edit (pcase-let ((`(,_ ,name ,pos ,unsaved) message))
               (cons state
                     (list (list :send (ride-apl-proto-edit name pos unsaved))))))
      (:save-window
       (pcase-let ((`(,_ ,win ,lines ,stops) message))
         (cons state
               (list (list :send (ride-apl-proto-save-changes win lines stops))))))
      (:close-window-request
       (ride-apl-session--on-close-request state (cadr message)))
      (:close-all-windows
       (cons state (list (list :send (ride-apl-proto-close-all-windows)))))
      (:step
       (pcase-let ((`(,_ ,kind ,win) message))
         (cons state
               (list (list :send
                           (ride-apl-proto-tracer-command
                            (alist-get kind ride-apl-session--step-commands)
                            win))))))
      (:set-stops-request
       (pcase-let ((`(,_ ,win ,stops) message))
         (cons state
               (list (list :send (ride-apl-proto-set-line-attributes win stops))))))
      (:restart-threads
       (cons state (list (list :send (ride-apl-proto-restart-threads)))))
      (:clear-trace-stop-monitor
       (cons state (list (list :send (ride-apl-proto-clear-trace-stop-monitor 0)))))
      ("ReplyClearTraceStopMonitor"
       (ride-apl-session--notify state :info
                             (ride-apl-session--cleared-text message)))
      (:trace-line (ride-apl-session--on-trace-line state (cadr message)))
      (:dialog-reply
       (pcase-let ((`(,_ ,kind ,token ,value) message))
         (cons state
               (list (list :send
                           (pcase kind
                             (:options (ride-apl-proto-reply-options-dialog value token))
                             (:task (ride-apl-proto-reply-task-dialog value token))
                             (:string (ride-apl-proto-reply-string-dialog value token))))))))
      (name (ride-apl-session--notify state :debug
                                  (format "Unhandled message: %s" name))))))

(defun ride-apl-session--on-handshake (state message)
  (cond
   ((not (ride-apl-session--handshake-acceptable-p message))
    (ride-apl-session--die state :protocol-mismatch (cdr message)))
   ((not (eq (ride-apl-session-conn-state state) 'handshake))
    (ride-apl-session--notify state :debug "Stray handshake string"))
   (t (ride-apl-session--record-handshake state (car message)))))

(defun ride-apl-session--handshake-acceptable-p (message)
  (member ride-apl-proto-protocol-version
          (split-string (cdr message) "," t)))

(defun ride-apl-session--record-handshake (state name)
  (let ((seen (cons name (ride-apl-session-seen-handshake state))))
    (if (ride-apl-session--handshake-complete-p seen)
        (cons (ride-apl-session--with state
                (conn-state 'identifying)
                (seen-handshake seen))
              (list (list :send (ride-apl-proto-identify))))
      (cons (ride-apl-session--with state (seen-handshake seen)) nil))))

(defun ride-apl-session--handshake-complete-p (seen)
  (and (member "SupportedProtocols" seen)
       (member "UsingProtocol" seen)))

(defun ride-apl-session--on-identify-reply (state message)
  (if (eq (ride-apl-session-conn-state state) 'identifying)
      (cons (ride-apl-session--with state
              (conn-state 'connected)
              (api-version (ride-apl-proto-arg message 'apiVersion))
              (interpreter (cdr message))
              (log-state 'waiting))
            (list (list :send (ride-apl-proto-connect))
                  (list :send (ride-apl-proto-get-log ride-apl-session-log-lines))
                  (list :send (ride-apl-proto-set-pw (ride-apl-session-pw state)))))
    (ride-apl-session--notify state :debug "Unexpected ReplyIdentify")))

(defun ride-apl-session--on-output (state message)
  (let ((entry (list (ride-apl-proto-arg message 'result)
                     (ride-apl-proto-arg message 'type)
                     (ride-apl-proto-arg message 'group))))
    (if (eq (ride-apl-session-log-state state) 'done)
        (cons (ride-apl-session--capture-eval state entry)
              (list (cons :display-output entry)))
      (cons (ride-apl-session--with state
              (queued-output (append (ride-apl-session-queued-output state)
                                     (list entry))))
            nil))))

(defun ride-apl-session--on-prompt-type (state message)
  (let ((type (ride-apl-proto-arg message 'type)))
    (pcase-let ((`(,next . ,result)
                 (if (> type 0)
                     (ride-apl-session--finish-eval state nil)
                   (cons state nil))))
      (ride-apl-session--and-drain
       (ride-apl-session--with next (prompt-type type))
       (append (list (list :set-prompt type)) result)))))

(defun ride-apl-session--capture-eval (state entry)
  "Accumulate ENTRY into STATE for the in-flight origin, skipping echoes."
  (if (and (ride-apl-session-eval-origin state)
           (not (memq (cadr entry) '(11 14))))
      (ride-apl-session--with state
        (eval-entries (append (ride-apl-session-eval-entries state) (list entry))))
    state))

(defun ride-apl-session--finish-eval (state errorp)
  "Close STATE's in-flight capture flagged ERRORP; return (STATE . EFFECTS)."
  (if (ride-apl-session-eval-origin state)
      (cons (ride-apl-session--with state (eval-origin nil) (eval-entries nil))
            (list (list :eval-result
                        (ride-apl-session-eval-origin state)
                        (ride-apl-session-eval-entries state)
                        errorp)))
    (cons state nil)))

(defun ride-apl-session--line-text (line)
  (if (consp line) (car line) line))

(defun ride-apl-session--line-origin (line)
  (and (consp line) (cdr line)))

(defun ride-apl-session--on-log-reply (state message)
  (ride-apl-session--finish-backfill
   state
   (mapcar #'ride-apl-session--log-entry-effect
           (ride-apl-session--trim-log (ride-apl-proto-arg message 'result)))))

(defun ride-apl-session--trim-log (entries)
  "Drop a trailing empty string entry from ENTRIES, as RIDE does."
  (if (equal (last (append entries nil)) '(""))
      (butlast (append entries nil))
    entries))

(defun ride-apl-session--on-log-timeout (state)
  (if (eq (ride-apl-session-log-state state) 'done)
      (cons state nil)
    (ride-apl-session--finish-backfill
     state
     (list (list :notify :debug "Log backfill timed out")))))

(defun ride-apl-session--finish-backfill (state lead-effects)
  (ride-apl-session--and-drain
   (ride-apl-session--with state (log-state 'done) (queued-output nil))
   (append lead-effects
           (mapcar (lambda (entry) (cons :display-output entry))
                   (ride-apl-session-queued-output state)))))

(defun ride-apl-session--log-entry-effect (entry)
  "Display effect for log ENTRY; entries arrive newline-less, add one."
  (if (stringp entry)
      (list :display-output (concat entry "\n") 2 0)
    (list :display-output (concat (alist-get 'text entry) "\n")
          (alist-get 'type entry) (alist-get 'group entry))))

(defconst ride-apl-session--step-commands
  '((:into . "StepInto") (:over . "RunCurrentLine") (:continue . "Continue")
    (:out . "ContinueTrace") (:cutback . "Cutback") (:forward . "TraceForward")
    (:backward . "TraceBackward") (:primitive . "TracePrimitive")))

(defun ride-apl-session--cleared-text (message)
  (format "Cleared %s traces, %s stops, %s monitors"
          (or (ride-apl-proto-arg message 'traces) 0)
          (or (ride-apl-proto-arg message 'stops) 0)
          (or (ride-apl-proto-arg message 'monitors) 0)))

(defun ride-apl-session--on-highlight (state message)
  (let* ((id (ride-apl-proto-arg message 'win))
         (line (ride-apl-proto-arg message 'line))
         (record (alist-get id (ride-apl-session-windows state)))
         (effect (list :highlight-line id line
                       (ride-apl-proto-arg message 'end_line)
                       (ride-apl-proto-arg message 'start_col)
                       (ride-apl-proto-arg message 'end_col))))
    (cons (if record
              (ride-apl-session--put-window
               state id (plist-put (copy-sequence record) :current-row line))
            state)
          (list effect))))

(defun ride-apl-session--on-line-attributes (state message)
  (let* ((id (ride-apl-proto-arg message 'win))
         (stops (ride-apl-proto-arg message 'stop))
         (record (alist-get id (ride-apl-session-windows state))))
    (cons (if record
              (ride-apl-session--put-window
               state id (plist-put (copy-sequence record) :stop stops))
            state)
          (list (list :set-stops id stops)))))

(defun ride-apl-session--on-trace-line (state line)
  (if (ride-apl-session--ready-to-send-p
       (ride-apl-session--with state (pending-lines (list line))))
      (cons (ride-apl-session--with state (prompt-type 0))
            (list (list :send
                        (ride-apl-proto-execute
                         (concat (ride-apl-session--input-prefix
                                  (ride-apl-session-prompt-type state))
                                 line "
")
                         1))))
    (ride-apl-session--notify state :warn "Session busy; cannot start tracing")))

(defun ride-apl-session--on-window-message (state message)
  "Apply an OpenWindow/UpdateWindow MESSAGE to STATE (AD-11, AD-20 races)."
  (let* ((id (ride-apl-proto-arg message 'token))
         (existing (alist-get id (ride-apl-session-windows state)))
         (opening (or (equal (car message) "OpenWindow")
                      (null existing)))
         (record (ride-apl-session--window-record
                  id (cdr message)
                  (if opening :open (plist-get existing :status)))))
    (cons (ride-apl-session--put-window state id record)
          (list (if opening
                    (list :open-window record)
                  (list :update-window id record))))))

(defun ride-apl-session--window-record (id args status)
  (list :id id
        :name (alist-get 'name args)
        :filename (alist-get 'filename args)
        :text (alist-get 'text args)
        :current-row (alist-get 'currentRow args)
        :tracer (ride-apl-proto-true-p (alist-get 'debugger args))
        :entity-type (alist-get 'entityType args)
        :offset (alist-get 'offset args)
        :read-only (ride-apl-proto-true-p (alist-get 'readOnly args))
        :stop (alist-get 'stop args)
        :tid (alist-get 'tid args)
        :tname (alist-get 'tname args)
        :status status))

(defun ride-apl-session--put-window (state id record)
  (ride-apl-session--with state
    (windows (cons (cons id record)
                   (assq-delete-all id (copy-alist
                                        (ride-apl-session-windows state)))))))

(defun ride-apl-session--on-close-window (state message)
  (let ((id (ride-apl-proto-arg message 'win)))
    (cons (ride-apl-session--with state
            (windows (assq-delete-all id (copy-alist
                                          (ride-apl-session-windows state)))))
          (list (list :close-window id)))))

(defun ride-apl-session--on-close-request (state id)
  (let ((record (alist-get id (ride-apl-session-windows state))))
    (cons (if record
              (ride-apl-session--put-window
               state id (plist-put (copy-sequence record) :status :closing))
            state)
          (list (list :send (ride-apl-proto-close-window id))))))

(defun ride-apl-session--on-save-reply (state message)
  (let ((win (ride-apl-proto-arg message 'win))
        (err (ride-apl-proto-arg message 'err)))
    (cons state
          (if (eql err 0)
              (list (list :window-saved win))
            (list (list :notify :error
                        (format "Fix failed for window %s (err %s)" win err)))))))

(defun ride-apl-session--on-type-changed (state message)
  (let* ((id (ride-apl-proto-arg message 'win))
         (record (alist-get id (ride-apl-session-windows state))))
    (if (not record)
        (ride-apl-session--notify state :debug "WindowTypeChanged for unknown window")
      (let ((updated (plist-put (copy-sequence record) :tracer
                                (ride-apl-proto-true-p
                                 (ride-apl-proto-arg message 'tracer)))))
        (cons (ride-apl-session--put-window state id updated)
              (list (list :update-window id updated)))))))

(defun ride-apl-session--on-input (state lines)
  (ride-apl-session--and-drain
   (ride-apl-session--with state
     (pending-lines (append (ride-apl-session-pending-lines state) lines)))
   nil))

(defun ride-apl-session--on-interrupt (state kind)
  (if (eq (ride-apl-session-conn-state state) 'connected)
      (cons state (list (list :send (pcase kind
                                      (:weak (ride-apl-proto-weak-interrupt))
                                      (:strong (ride-apl-proto-strong-interrupt))))))
    (ride-apl-session--notify state :debug "Interrupt with no live session")))

(defun ride-apl-session--and-drain (state effects)
  "Attach EFFECTS to STATE, sending the next pending line when ready."
  (pcase-let ((`(,next . ,drain) (ride-apl-session--drain-pending state)))
    (cons next (append effects drain))))

(defun ride-apl-session--drain-pending (state)
  (if (ride-apl-session--ready-to-send-p state)
      (cons (ride-apl-session--with state
              (pending-lines (cdr (ride-apl-session-pending-lines state)))
              (prompt-type 0)
              (eval-origin (ride-apl-session--line-origin
                            (car (ride-apl-session-pending-lines state))))
              (eval-entries nil))
            (list (list :send (ride-apl-session--execute-payload state))))
    (cons state nil)))

(defun ride-apl-session--ready-to-send-p (state)
  (and (eq (ride-apl-session-log-state state) 'done)
       (> (ride-apl-session-prompt-type state) 0)
       (ride-apl-session-pending-lines state)))

(defun ride-apl-session--execute-payload (state)
  (ride-apl-proto-execute
   (concat (ride-apl-session--input-prefix (ride-apl-session-prompt-type state))
           (ride-apl-session--line-text (car (ride-apl-session-pending-lines state)))
           "\n")
   0))

(defun ride-apl-session--input-prefix (prompt-type)
  (if (memq prompt-type '(1 5)) "      " ""))

(defun ride-apl-session--on-timeout (state)
  (if (memq (ride-apl-session-conn-state state) '(handshake identifying))
      (ride-apl-session--die state :timeout nil)
    (cons state nil)))

(defun ride-apl-session--die (state reason detail)
  (cons (ride-apl-session--with state (conn-state 'dead))
        (list (if detail
                  (list :session-died reason detail)
                (list :session-died reason)))))

(defun ride-apl-session--notify (state level text)
  (cons state (list (list :notify level text))))


(provide 'ride-apl-session)
;;; ride-apl-session.el ends here
