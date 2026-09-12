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
    (:out . "ContinueTrace") (:cutback . "Cutback")))

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

;;; Imperative shell: connection object, dispatcher, effect interpreter.

(require 'ride-apl-transport)

(defcustom ride-apl-handshake-timeout 5
  "Seconds allowed for the handshake and for the Identify reply (AD-17)."
  :type 'number :group 'ride-apl)

(defgroup ride-apl nil "Dyalog APL client via the RIDE protocol."
  :group 'languages)

(defcustom ride-apl-log-timeout 3
  "Seconds to wait for ReplyGetLog before rendering live output (M2)."
  :type 'number :group 'ride-apl)

(cl-defstruct (ride-apl-conn (:constructor ride-apl-conn--make))
  process state timer host port death-reason repl-buffer
  (edit-buffers nil) (log nil) (start-time (float-time))
  (tip-token 0) (tip-callback nil))

(defvar ride-apl-session--effect-handlers (make-hash-table :test 'eq)
  "Effect symbol -> (lambda (conn args)); UI layers register here.")

(defvar ride-apl-session-died-hook nil
  "Run with (CONN REASON DETAIL) after core teardown.")

(defun ride-apl-session-register-effect (symbol handler)
  (puthash symbol handler ride-apl-session--effect-handlers))

(defvar ride-apl--conns nil)

(defun ride-apl-session-open (host port)
  "Connect to HOST:PORT; return the live connection object."
  (let* ((conn (ride-apl-conn--make :host host :port port))
         (process (ride-apl-transport-connect
                   host port
                   (lambda (payload) (ride-apl-session--on-payload conn payload))
                   (lambda (reason) (ride-apl-session--on-close conn reason)))))
    (setf (ride-apl-conn-process conn) process)
    (push conn ride-apl--conns)
    (pcase-let ((`(,state . ,effects) (ride-apl-session-init)))
      (setf (ride-apl-conn-state conn) state)
      (ride-apl-session--arm-timer conn)
      (ride-apl-session--execute conn effects))
    conn))

(defun ride-apl-session-close (conn)
  "Politely disconnect CONN."
  (when (process-live-p (ride-apl-conn-process conn))
    (ignore-errors
      (ride-apl-session--execute
       conn (list (list :send (ride-apl-proto-disconnect "goodbye")))))
    (ride-apl-transport-close (ride-apl-conn-process conn))))

(defun ride-apl-value-tip (conn line pos callback)
  "Ask CONN for a value tip at 0-based column POS of LINE.
CALLBACK receives the ValueTip args alist.  Only the most recent
request per connection is answered; superseded callbacks are dropped."
  (let ((token (cl-incf (ride-apl-conn-tip-token conn))))
    (setf (ride-apl-conn-tip-callback conn) (cons token callback))
    (ride-apl-session--dispatch conn (list :value-tip 0 token line pos))))

(defun ride-apl-session--handle-tip-reply (conn args)
  (pcase-let ((`(,reply) args))
    (pcase (ride-apl-conn-tip-callback conn)
      (`(,token . ,callback)
       (when (eql token (alist-get 'token reply))
         (setf (ride-apl-conn-tip-callback conn) nil)
         (funcall callback reply))))))

(ride-apl-session-register-effect :value-tip-reply #'ride-apl-session--handle-tip-reply)

(defun ride-apl--apl-quote (string)
  "Escape STRING for inclusion in an APL character literal."
  (replace-regexp-in-string "'" "''" string))

(defun ride-apl-current-conn ()
  "Most recently opened live connection, else most recent, else nil."
  (or (seq-find (lambda (c) (process-live-p (ride-apl-conn-process c)))
                ride-apl--conns)
      (car ride-apl--conns)))

(defun ride-apl-session--on-payload (conn payload)
  (ride-apl-session--log conn "<-" payload)
  (condition-case err
      (ride-apl-session--dispatch conn (ride-apl-proto-parse payload))
    (ride-apl-proto-bad-message
     (message "ride-apl: unparseable payload: %S" (cdr err)))))

(defun ride-apl-session--on-close (conn reason)
  (ride-apl-session--dispatch conn (list :closed reason)))

(defun ride-apl-session--dispatch (conn message)
  (when (keywordp (car message))
    (ride-apl-session--log-event conn message))
  (let ((before (ride-apl-session-conn-state (ride-apl-conn-state conn))))
    (pcase-let ((`(,state . ,effects)
                 (ride-apl-session-step (ride-apl-conn-state conn) message)))
      (setf (ride-apl-conn-state conn) state)
      (ride-apl-session--manage-timer conn before (ride-apl-session-conn-state state))
      (when (and (ride-apl-conn-timer conn)
                 (eq (ride-apl-session-conn-state state) 'connected)
                 (eq (ride-apl-session-log-state state) 'done))
        (ride-apl-session--cancel-timer conn))
      (ride-apl-session--execute conn effects))))

(defun ride-apl-session--manage-timer (conn before after)
  (unless (eq before after)
    (ride-apl-session--cancel-timer conn)
    (pcase after
      ('identifying (ride-apl-session--arm-timer conn))
      ('connected (setf (ride-apl-conn-timer conn)
                        (run-at-time ride-apl-log-timeout nil
                                     #'ride-apl-session--dispatch conn
                                     '(:log-timeout)))))))

(defun ride-apl-session--arm-timer (conn)
  (setf (ride-apl-conn-timer conn)
        (run-at-time ride-apl-handshake-timeout nil
                     #'ride-apl-session--dispatch conn '(:timeout))))

(defun ride-apl-session--cancel-timer (conn)
  (when (ride-apl-conn-timer conn)
    (cancel-timer (ride-apl-conn-timer conn))
    (setf (ride-apl-conn-timer conn) nil)))

(defun ride-apl-session--execute (conn effects)
  (dolist (effect (ride-apl-session--batch-display effects))
    (pcase effect
      (`(:send ,payload)
       (ride-apl-session--log conn "->" payload)
       (ride-apl-transport-send (ride-apl-conn-process conn) payload))
      (`(:notify ,level ,text)
       (message "ride-apl %s: %s" level text))
      (`(:session-died ,reason . ,detail)
       (ride-apl-session--on-died conn reason (car detail)))
      (`(,symbol . ,args)
       (let ((handler (gethash symbol ride-apl-session--effect-handlers)))
         (unless handler (error "ride-apl: unknown effect: %S" effect))
         (funcall handler conn args))))))

(defun ride-apl-session--batch-display (effects)
  "Coalesce runs of :display-output in EFFECTS into batches (AD-22)."
  (let (result run)
    (dolist (effect effects)
      (if (eq (car effect) :display-output)
          (push (cdr effect) run)
        (when run
          (push (list :display-output-batch (nreverse run)) result)
          (setq run nil))
        (push effect result)))
    (when run (push (list :display-output-batch (nreverse run)) result))
    (nreverse result)))

(defun ride-apl-session--on-died (conn reason detail)
  (setf (ride-apl-conn-death-reason conn) (cons reason detail))
  (ride-apl-session--cancel-timer conn)
  (ride-apl-transport-close (ride-apl-conn-process conn))
  (ride-apl-session--log conn "--" (format "session died: %s %s" reason
                                       (or detail "")))
  (message "ride-apl: session %s:%s died: %s%s"
           (ride-apl-conn-host conn) (ride-apl-conn-port conn) reason
           (if detail (format " (%s)" detail) ""))
  (run-hook-with-args 'ride-apl-session-died-hook conn reason detail))

(defun ride-apl-session--log (conn direction payload)
  (ride-apl-session--log-transcript conn direction payload)
  (with-current-buffer (ride-apl-session--log-buffer conn)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (format-time-string "%T.%3N ") direction " " payload "\n"))))

(defun ride-apl-session--log-transcript (conn direction payload)
  (let ((dir (pcase direction ("->" :out) ("<-" :in))))
    (when dir
      (push (ride-apl-session--transcript-entry
             dir (- (float-time) (ride-apl-conn-start-time conn)) payload)
            (ride-apl-conn-log conn)))))

(defun ride-apl-session--transcript-entry (dir elapsed payload)
  "AD-18 fixture entry for DIR/PAYLOAD: JSON as :msg, anything else as :raw."
  (if (and (string-prefix-p "[" payload)
           (ignore-errors (ride-apl-proto-parse payload)))
      (list :dir dir :t elapsed :msg (ride-apl-proto-parse payload))
    (list :dir dir :t elapsed
          :raw (base64-encode-string
                (encode-coding-string payload 'utf-8) t))))

(defun ride-apl-session--log-event (conn message)
  "Record a synthetic reducer event on CONN so replays are deterministic."
  (push (list :dir :event
              :t (- (float-time) (ride-apl-conn-start-time conn))
              :msg message)
        (ride-apl-conn-log conn))
  (with-current-buffer (ride-apl-session--log-buffer conn)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (format-time-string "%T.%3N ") "== " (format "%S" message) "\n"))))

(defun ride-apl-session-transcript (conn)
  "Chronological AD-18 transcript entries for CONN."
  (reverse (ride-apl-conn-log conn)))

(defun ride-apl-session--log-buffer (conn)
  (let ((name (format "*ride-apl-log:%s:%s*"
                      (ride-apl-conn-host conn) (ride-apl-conn-port conn))))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (special-mode)
          (current-buffer)))))

(provide 'ride-apl-session)
;;; ride-apl-session.el ends here
