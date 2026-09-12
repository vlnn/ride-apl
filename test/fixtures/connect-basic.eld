;; -*- mode: lisp-data -*-
;; Minimal connect sequence; message shapes verified against a real
;; Dyalog 20 capture (see session-m2-real.eld for the full session).
(:dir :out :t 0.000 :raw "U3VwcG9ydGVkUHJvdG9jb2xzPTI=")
(:dir :out :t 0.001 :raw "VXNpbmdQcm90b2NvbD0y")
(:dir :in :t 0.050 :raw "U3VwcG9ydGVkUHJvdG9jb2xzPTI=")
(:dir :in :t 0.051 :raw "VXNpbmdQcm90b2NvbD0y")
(:dir :out :t 0.052 :msg ("Identify" . ((apiVersion . 1) (identity . 1))))
(:dir :in :t 0.120 :msg ("ReplyIdentify" (Port . 0) (IPAddress . "") (Vendor . "Dyalog Limited") (Language . "APL") (version . "20.0.53963") (Machine . "host.local") (arch . "Unicode/64") (Project . "CLEAR WS") (Process . "") (User . "user") (pid . 12345) (token . "") (date . "Created: Jun  5 2026 at 01:28:25") (platform . "Mac-64") (apiVersion . 1)))
(:dir :out :t 0.121 :msg ("Connect" . ((remoteId . 2))))
(:dir :out :t 0.122 :msg ("GetLog" . ((format . "json") (maxLines . 500))))
(:dir :out :t 0.123 :msg ("SetPW" . ((pw . 80))))
(:dir :in :t 0.180 :msg ("UpdateDisplayName" . ((displayName . "CLEAR WS"))))
(:dir :in :t 0.185 :msg ("UpdateSessionCaption" . ((text . "CLEAR WS - Dyalog APL"))))
(:dir :in :t 0.200 :msg ("ReplyGetLog" . ((result . (((text . "Dyalog APL/S-64 Version 19.0.50027\n") (type . 2) (group . 0)))))))
(:dir :in :t 0.210 :msg ("SetPromptType" . ((type . 1))))
