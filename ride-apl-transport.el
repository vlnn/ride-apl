;;; ride-apl-transport.el --- RIDE frame codec -*- lexical-binding: t; -*-


;;; Commentary:
;; Pure frame codec for the RIDE protocol (AD-4, AD-15).  Frames are
;; 4-byte big-endian total length, "RIDE", UTF-8 payload.  All framing
;; arithmetic is in bytes over unibyte strings; UTF-8 decoding happens
;; here and nowhere else.

;;; Code:

(defconst ride-apl-transport--header-size 8)
(defconst ride-apl-transport--magic "RIDE")

(define-error 'ride-apl-transport-bad-frame "Malformed RIDE frame")

(defun ride-apl-transport-encode (payload)
  "Frame PAYLOAD string as unibyte RIDE wire bytes."
  (let ((bytes (encode-coding-string payload 'utf-8)))
    (concat (ride-apl-transport--length-header
             (+ ride-apl-transport--header-size (length bytes)))
            ride-apl-transport--magic
            bytes)))

(defun ride-apl-transport-decode (bytes)
  "Extract complete frames from unibyte BYTES.
Return (PAYLOADS . REMAINDER) where PAYLOADS are decoded UTF-8
strings in arrival order and REMAINDER is the unconsumed byte tail."
  (let (payloads frame)
    (while (setq frame (ride-apl-transport--pop-frame bytes))
      (push (car frame) payloads)
      (setq bytes (cdr frame)))
    (cons (nreverse payloads) bytes)))

(defun ride-apl-transport--length-header (total)
  (unibyte-string (logand (ash total -24) #xff)
                  (logand (ash total -16) #xff)
                  (logand (ash total -8) #xff)
                  (logand total #xff)))

(defun ride-apl-transport--pop-frame (bytes)
  "Return (PAYLOAD . REMAINDER) for the first complete frame in BYTES.
Return nil when no complete frame has arrived yet."
  (let ((total (ride-apl-transport--declared-length bytes)))
    (when (and total (<= total (length bytes)))
      (ride-apl-transport--check-frame bytes total)
      (cons (decode-coding-string
             (substring bytes ride-apl-transport--header-size total) 'utf-8)
            (substring bytes total)))))

(defun ride-apl-transport--declared-length (bytes)
  (when (>= (length bytes) 4)
    (+ (ash (aref bytes 0) 24)
       (ash (aref bytes 1) 16)
       (ash (aref bytes 2) 8)
       (aref bytes 3))))

(defun ride-apl-transport--check-frame (bytes total)
  (when (< total ride-apl-transport--header-size)
    (signal 'ride-apl-transport-bad-frame (list :declared-length total)))
  (unless (equal (substring bytes 4 ride-apl-transport--header-size)
                 ride-apl-transport--magic)
    (signal 'ride-apl-transport-bad-frame
            (list :magic (substring bytes 4 ride-apl-transport--header-size)))))

(defun ride-apl-transport-connect (host port on-payload on-close)
  "Open a binary TCP connection to HOST:PORT.
Each decoded payload string is passed to ON-PAYLOAD; ON-CLOSE is
called once with a reason string when the connection ends."
  (let ((process (make-network-process
                  :name (format "ride-apl:%s:%s" host port)
                  :host host :service port
                  :coding '(binary . binary)
                  :filter #'ride-apl-transport--filter
                  :sentinel #'ride-apl-transport--sentinel
                  :noquery t)))
    (process-put process 'ride-apl-accumulator "")
    (process-put process 'ride-apl-on-payload on-payload)
    (process-put process 'ride-apl-on-close on-close)
    process))

(defun ride-apl-transport-send (process payload)
  (process-send-string process (ride-apl-transport-encode payload)))

(defun ride-apl-transport-close (process)
  (when (process-live-p process)
    (delete-process process)))

(defun ride-apl-transport--filter (process chunk)
  (condition-case err
      (pcase-let ((`(,payloads . ,remainder)
                   (ride-apl-transport-decode
                    (concat (process-get process 'ride-apl-accumulator) chunk))))
        (process-put process 'ride-apl-accumulator remainder)
        (dolist (payload payloads)
          (funcall (process-get process 'ride-apl-on-payload) payload)))
    (ride-apl-transport-bad-frame
     (ride-apl-transport--finish process (format "bad frame: %S" (cdr err)))
     (delete-process process))))

(defun ride-apl-transport--sentinel (process event)
  (unless (process-live-p process)
    (ride-apl-transport--finish process (string-trim event))))

(defun ride-apl-transport--finish (process reason)
  (unless (process-get process 'ride-apl-closed)
    (process-put process 'ride-apl-closed t)
    (funcall (process-get process 'ride-apl-on-close) reason)))

(provide 'ride-apl-transport)
;;; ride-apl-transport.el ends here
