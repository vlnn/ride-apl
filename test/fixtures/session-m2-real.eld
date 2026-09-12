;; -*- mode: lisp-data -*-
;; Real capture: Dyalog APL 20.0.53963 on macOS, RIDE apiVersion 1.
;; Anonymized per AD-18: Machine and User replaced; content otherwise
;; verbatim.  Covers: connect, backfill arriving after SetPromptType,
;; a stale :log-timeout event, empty-line submissions, evaluation,
;; and real type-3/14/2/5 output shapes including group continuations.
(:dir :out :t 0.0005 :raw "U3VwcG9ydGVkUHJvdG9jb2xzPTI=")
(:dir :out :t 0.0009 :raw "VXNpbmdQcm90b2NvbD0y")
(:dir :in :t 0.1920 :raw "U3VwcG9ydGVkUHJvdG9jb2xzPTI=")
(:dir :in :t 0.1921 :raw "VXNpbmdQcm90b2NvbD0y")
(:dir :out :t 0.1922 :msg ("Identify" (apiVersion . 1) (identity . 1)))
(:dir :in :t 0.1929 :msg ("ReplyIdentify" (Port . 0) (IPAddress . "") (Vendor . "Dyalog Limited") (Language . "APL") (version . "20.0.53963") (Machine . "host.local") (arch . "Unicode/64") (Project . "CLEAR WS") (Process . "") (User . "user") (pid . 12793) (token . "") (date . "Created: Jun  5 2026 at 01:28:25") (platform . "Mac-64") (apiVersion . 1)))
(:dir :out :t 0.1930 :msg ("Connect" (remoteId . 2)))
(:dir :out :t 0.1930 :msg ("GetLog" (format . "json") (maxLines . 500)))
(:dir :out :t 0.1931 :msg ("SetPW" (pw . 80)))
(:dir :in :t 0.1932 :msg ("UpdateDisplayName" (displayName . "CLEAR WS")))
(:dir :in :t 0.1935 :msg ("SetPromptType" (type . 1)))
(:dir :in :t 0.1936 :msg ("UpdateSessionCaption" (text . "CLEAR WS - Dyalog APL")))
(:dir :in :t 0.1947 :msg ("ReplyGetLog" (result ((type . 3) (group . 0) (text . "Dyalog APL - Version 20.0.52760")) ((type . 3) (group . 0) (text . "Serial number: UNREGISTERED - not for commercial use")) ((type . 3) (group . 0) (text . "+-----------------------------------------------------------------+")) ((type . 3) (group . 0) (text . "| Dyalog is free for non-commercial use but is not free software. |")) ((type . 3) (group . 0) (text . "| A basic licence can be used for experiments and proof of        |")) ((type . 3) (group . 0) (text . "| concept until the point in time that it is of value.            |")) ((type . 3) (group . 0) (text . "| For further information visit                                   |")) ((type . 3) (group . 0) (text . "| https://www.dyalog.com/prices-and-licences.htm                  |")) ((type . 3) (group . 0) (text . "+-----------------------------------------------------------------+")) ((type . 3) (group . 0) (text . "Wed Dec 24 14:41:39 2025")) ((type . 14) (group . 0) (text . "     ")) ((type . 14) (group . 0) (text . "      ")) ((type . 14) (group . 0) (text . "      1 2 3 4 5")) ((type . 2) (group . 0) (text . "1 2 3 4 5")) ((type . 14) (group . 0) (text . "      1 2 3 4 5")) ((type . 2) (group . 0) (text . "1 2 3 4 5")) ((type . 14) (group . 0) (text . "     ○ 1 2 3 4 5")) ((type . 2) (group . 0) (text . "3.141592654 6.283185307 9.424777961 12.56637061 15.70796327")) ((type . 14) (group . 0) (text . "     1 ○ 1 2 3 4 5")) ((type . 2) (group . 0) (text . "0.8414709848 0.9092974268 0.1411200081 ¯0.7568024953 ¯0.9589242747")) ((type . 14) (group . 0) (text . "     0 ○ 1 2 3 4 5")) ((type . 2) (group . 0) (text . "0 0J1.732050808 0J2.828427125 0J3.872983346 0J4.898979486")) ((type . 3) (group . 0) (text . "Dyalog APL - Version 20.0.53963")) ((type . 3) (group . 0) (text . "Serial number: UNREGISTERED - not for commercial use")) ((type . 3) (group . 0) (text . "Fri Sep 11 23:27:12 2026")) ((type . 14) (group . 0) (text . "      ⍳30")) ((type . 2) (group . 1) (text . "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29")) ((type . 2) (group . 1) (text . "      30")) ((type . 14) (group . 0) (text . "      *⍳30")) ((type . 2) (group . 2) (text . "2.718281828 7.389056099 20.08553692 54.59815003 148.4131591 403.4287935")) ((type . 2) (group . 2) (text . "      1096.633158 2980.957987 8103.083928 22026.46579 59874.14172 162754.7914")) ((type . 14) (group . 0) (text . "      */⍳30")) ((type . 5) (group . 0) (text . "DOMAIN ERROR")) ((type . 5) (group . 0) (text . "      */⍳30")) ((type . 5) (group . 0) (text . "      ∧")) ((type . 14) (group . 0) (text . "      *1")) ((type . 2) (group . 0) (text . "2.718281828")) ((type . 14) (group . 0) (text . "      e")) ((type . 5) (group . 0) (text . "VALUE ERROR: Undefined name: e")) ((type . 5) (group . 0) (text . "      e")) ((type . 5) (group . 0) (text . "      ∧")) ((type . 14) (group . 0) (text . "      2 + 4 3")) ((type . 2) (group . 0) (text . "6 5")) ((type . 14) (group . 0) (text . "       qq")) ((type . 5) (group . 0) (text . "VALUE ERROR: Undefined name: qq")) ((type . 5) (group . 0) (text . "      qq")) ((type . 5) (group . 0) (text . "      ∧")))))
(:dir :event :t 3.1867 :msg (:input ("")))
(:dir :out :t 3.1870 :msg ("Execute" (text . "      
") (trace . 0)))
(:dir :in :t 3.1931 :msg ("AppendSessionOutput" (result . "      
") (type . 14) (group . 0)))
(:dir :in :t 3.1934 :msg ("SetPromptType" (type . 0)))
(:dir :in :t 3.1935 :msg ("SetPromptType" (type . 1)))
(:dir :event :t 3.2016 :msg (:log-timeout))
(:dir :event :t 6.7319 :msg (:input ("2 3 + 21")))
(:dir :out :t 6.7321 :msg ("Execute" (text . "      2 3 + 21
") (trace . 0)))
(:dir :in :t 6.7371 :msg ("AppendSessionOutput" (result . "      2 3 + 21
") (type . 14) (group . 0)))
(:dir :in :t 6.7395 :msg ("SetPromptType" (type . 0)))
(:dir :in :t 6.7396 :msg ("AppendSessionOutput" (result . "23 24
") (type . 2) (group . 0)))
(:dir :in :t 6.7397 :msg ("SetPromptType" (type . 1)))
(:dir :event :t 14.7514 :msg (:input ("2 1 2 + 44")))
(:dir :out :t 14.7518 :msg ("Execute" (text . "      2 1 2 + 44
") (trace . 0)))
(:dir :in :t 14.7599 :msg ("AppendSessionOutput" (result . "      2 1 2 + 44
") (type . 14) (group . 0)))
(:dir :in :t 14.7603 :msg ("SetPromptType" (type . 0)))
(:dir :in :t 14.7605 :msg ("AppendSessionOutput" (result . "46 45 46
") (type . 2) (group . 0)))
(:dir :in :t 14.7606 :msg ("SetPromptType" (type . 1)))
