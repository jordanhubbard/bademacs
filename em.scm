;; em.scm - shemacs: Emacs-like editor in Scheme (runs on sheme/bs.sh)
;;
;; FILE / BUFFER                        EDITING
;; C-x C-c   Quit                       C-d / DEL   Delete char forward
;; C-x C-s   Save buffer                BACKSPACE   Delete char backward
;; C-x C-f   Find (open) file           C-k         Kill to end of line
;; C-x C-w   Write file (save as)       C-y         Yank (paste)
;; C-x i     Insert file                C-w         Kill region
;; C-x b     Switch buffer              M-w         Copy region
;; C-x k     Kill buffer                C-SPC/M-SPC Set mark
;; C-x C-b   List buffers               C-t         Transpose chars
;; C-x h     Mark whole buffer          M-d/M-DEL   Kill word fwd/bkwd
;; C-x =     What cursor position       M-c/l/u     Cap/down/upcase word
;; C-x C-x   Exchange point/mark        C-i/TAB     Indent line (+2 sp)
;; C-x u / C-_  Undo                    SHIFT-TAB   Dedent line (-2 sp)
;;
;; MOVEMENT                             SEARCH
;; C-f / RIGHT   Forward char           C-s         Isearch forward
;; C-b / LEFT    Backward char          C-r         Isearch backward
;; C-n / DOWN    Next line              M-%         Query replace
;; C-p / UP      Previous line
;; C-a / HOME    Beginning of line      MISC
;; C-e / END     End of line            C-o         Open line
;; M-f / M-b     Fwd/bkwd word          C-u N       Universal argument
;; M-< / M->     Beg/end of buffer      C-q         Quoted insert
;; C-v / PGDN    Page down              M-q         Fill paragraph
;; M-v / PGUP    Page up                M-x         Extended command
;; C-l           Recenter               C-g         Cancel
;; C-z           Suspend                C-h b       Describe bindings
;;                                      C-j         Eval buffer (Scheme)
;;
;; RECTANGLES (C-x r)                   MACROS (C-x)
;; C-x r k   Kill rectangle             C-x (       Start macro
;; C-x r y   Yank rectangle             C-x )       Stop macro
;; C-x r r   Copy rectangle             C-x e       Execute macro
;; C-x r d   Delete rectangle
;; C-x r t   String rectangle
;; C-x r o   Open rectangle

;; ===== ANSI helpers =====
(define ESC (string (integer->char 27)))
(define (ansi . parts) (apply string-append ESC parts))

;; ===== Editor state =====
(define em-lines (vector ""))
(define em-nlines 1)
(define em-cy 0)
(define em-cx 0)
(define em-top 0)
(define em-left 0)
(define em-rows 24)
(define em-cols 80)
(define em-mark-y -1)
(define em-mark-x -1)
(define em-modified 0)
(define em-filename "")
(define em-bufname "*scratch*")
(define em-message "")
(define em-msg-persist 0)
(define em-last-cmd "")
(define em-goal-col -1)
(define em-kill-ring '())
(define em-undo-stack '())
(define em-mode "normal")
(define em-fill-column 72)
;; Isearch state
(define em-isearch-str "")
(define em-isearch-dir 1)
(define em-isearch-y -1)
(define em-isearch-x -1)
(define em-isearch-len 0)
(define em-isearch-saved-cy 0)
(define em-isearch-saved-cx 0)
(define em-isearch-saved-top 0)
;; Minibuffer state
(define em-mb-prompt "")
(define em-mb-input "")
(define em-mb-callback "")
(define em-mb-comp-type "")
;; Rectangle kill ring (list of strings, one per row)
(define em-rect-ring '())
;; Keyboard macro state
(define em-macro-recording #f)
(define em-macro-keys '())
;; Query replace state
(define em-qr-from "")
(define em-qr-count 0)
;; Buffer management (list of buffer vectors, 15 elements each)
(define em-buffers '())
(define em-cur-buf-id 0)
(define em-buf-id-counter 0)
;; Clipboard commands (shell commands; empty = no clipboard)
(define em-clip-copy "")
(define em-clip-paste "")
;; Running flag
(define em-running #t)

;; ===== Vector helpers =====
(define (vector-ref-safe vec n)
  (if (or (< n 0) (>= n (vector-length vec))) ""
      (vector-ref vec n)))

(define (vector-insert vec n val)
  (let* ((len (vector-length vec))
         (new-vec (make-vector (+ len 1) "")))
    (do ((i 0 (+ i 1))) ((= i n))
      (vector-set! new-vec i (vector-ref vec i)))
    (vector-set! new-vec n val)
    (do ((i n (+ i 1))) ((= i len))
      (vector-set! new-vec (+ i 1) (vector-ref vec i)))
    new-vec))

(define (vector-remove vec n)
  (let* ((len (vector-length vec))
         (new-vec (make-vector (- len 1) "")))
    (do ((i 0 (+ i 1))) ((= i n))
      (vector-set! new-vec i (vector-ref vec i)))
    (do ((i (+ n 1) (+ i 1))) ((= i len))
      (vector-set! new-vec (- i 1) (vector-ref vec i)))
    new-vec))

(define (list-take lst n)
  (if (or (<= n 0) (null? lst)) '()
      (cons (car lst) (list-take (cdr lst) (- n 1)))))

(define (list-drop lst n)
  (if (or (<= n 0) (null? lst)) lst
      (list-drop (cdr lst) (- n 1))))

;; ===== String helpers =====
(define (substr s start end)
  (if (>= start end) ""
      (if (>= start (string-length s)) ""
          (substring s (max 0 start) (min end (string-length s))))))

(define (string-repeat s n)
  (if (<= n 0) ""
      (string-append s (string-repeat s (- n 1)))))

(define (char-word? ch)
  (or (char-alphabetic? ch) (char-numeric? ch) (char=? ch #\_)))

(define (char-upcase ch)
  (let ((n (char->integer ch)))
    (if (and (>= n 97) (<= n 122)) (integer->char (- n 32)) ch)))

(define (char-downcase ch)
  (let ((n (char->integer ch)))
    (if (and (>= n 65) (<= n 90)) (integer->char (+ n 32)) ch)))

(define (string-trim-left s)
  (let ((len (string-length s)))
    (let loop ((i 0))
      (if (>= i len) ""
          (if (char=? (string-ref s i) #\space)
              (loop (+ i 1))
              (substr s i len))))))

;; ===== Tab expansion =====
(define em-tab-width 8)

(define (expand-tabs line)
  (let loop ((i 0) (col 0) (result ""))
    (if (>= i (string-length line))
        result
        (let ((ch (string-ref line i)))
          (if (char=? ch #\tab)
              (let ((spaces (- em-tab-width (remainder col em-tab-width))))
                (loop (+ i 1) (+ col spaces)
                      (string-append result (string-repeat " " spaces))))
              (loop (+ i 1) (+ col 1)
                    (string-append result (string ch))))))))

(define (col-to-display line target-col)
  (let loop ((i 0) (col 0))
    (if (or (>= i (string-length line)) (>= i target-col))
        col
        (if (char=? (string-ref line i) #\tab)
            (loop (+ i 1) (+ col (- em-tab-width (remainder col em-tab-width))))
            (loop (+ i 1) (+ col 1))))))

;; ===== Ensure cursor visible (vertical + horizontal scroll) =====
(define (em-ensure-visible)
  (let ((visible (- em-rows 2)))
    (if (< em-cy 0) (set! em-cy 0) #f)
    (if (>= em-cy em-nlines) (set! em-cy (- em-nlines 1)) #f)
    (if (< em-cx 0) (set! em-cx 0) #f)
    (let ((line-len (string-length (vector-ref-safe em-lines em-cy))))
      (if (> em-cx line-len) (set! em-cx line-len) #f))
    (if (< em-cy em-top) (set! em-top em-cy) #f)
    (if (>= em-cy (+ em-top visible))
        (set! em-top (+ (- em-cy visible) 1))
        #f)
    (if (< em-top 0) (set! em-top 0) #f)
    ;; Horizontal scroll
    (let* ((disp-cx (col-to-display (vector-ref-safe em-lines em-cy) em-cx))
           (win-w (- em-cols 1)))
      (if (< disp-cx em-left)
          (set! em-left (max 0 (- disp-cx 5)))
          #f)
      (if (>= disp-cx (+ em-left win-w))
          (set! em-left (- disp-cx (- win-w 5)))
          #f)
      (if (< em-left 0) (set! em-left 0) #f))))

;; ===== Undo system =====
;; Record types:
;;   ("insert_char"  y x ch)              – undo: insert ch back at y,x
;;   ("delete_char"  y x)                 – undo: delete char at y,x
;;   ("join_lines"   y x)                 – undo: split line y at x
;;   ("split_line"   y x)                 – undo: join lines y and y+1
;;   ("replace_line" y x old-line)        – undo: restore line y to old-line
;;   ("replace_region" sy n-cur scy scx orig-lines-list)
;;                                        – undo: remove n-cur lines at sy,
;;                                               insert orig-lines-list back
(define (em-undo-push record)
  (set! em-undo-stack (cons record em-undo-stack))
  (when (> (length em-undo-stack) 200)
    (set! em-undo-stack (list-take em-undo-stack 200))))

(define (em-undo)
  (if (null? em-undo-stack)
      (set! em-message "No further undo information")
      (let* ((record (car em-undo-stack))
             (type (car record)))
        (set! em-undo-stack (cdr em-undo-stack))
        (cond
          ((equal? type "insert_char")
           (let* ((y (list-ref record 1)) (x (list-ref record 2))
                  (ch (list-ref record 3))
                  (line (vector-ref-safe em-lines y)))
             (vector-set! em-lines y
               (string-append (substr line 0 x) ch (substr line x (string-length line))))
             (set! em-cy y) (set! em-cx x)))
          ((equal? type "delete_char")
           (let* ((y (list-ref record 1)) (x (list-ref record 2))
                  (line (vector-ref-safe em-lines y)))
             (vector-set! em-lines y
               (string-append (substr line 0 x) (substr line (+ x 1) (string-length line))))
             (set! em-cy y) (set! em-cx x)))
          ((equal? type "join_lines")
           (let* ((y (list-ref record 1)) (x (list-ref record 2))
                  (line (vector-ref-safe em-lines y)))
             (vector-set! em-lines y (substr line 0 x))
             (set! em-lines (vector-insert em-lines (+ y 1) (substr line x (string-length line))))
             (set! em-nlines (+ em-nlines 1))
             (set! em-cy y) (set! em-cx x)))
          ((equal? type "split_line")
           (let* ((y (list-ref record 1)) (x (list-ref record 2))
                  (line (vector-ref-safe em-lines y))
                  (next (vector-ref-safe em-lines (+ y 1))))
             (vector-set! em-lines y (string-append line next))
             (set! em-lines (vector-remove em-lines (+ y 1)))
             (set! em-nlines (- em-nlines 1))
             (set! em-cy y) (set! em-cx x)))
          ((equal? type "replace_line")
           (let* ((y (list-ref record 1)) (x (list-ref record 2))
                  (old-line (list-ref record 3)))
             (vector-set! em-lines y old-line)
             (set! em-cy y) (set! em-cx x)))
          ((equal? type "replace_region")
           (let* ((sy (list-ref record 1))
                  (n-cur (list-ref record 2))
                  (scy (list-ref record 3))
                  (scx (list-ref record 4))
                  (orig-lines (list-ref record 5)))
             ;; Remove n-cur lines starting at sy
             (let loop ((i 0))
               (when (and (< i n-cur) (> em-nlines 0))
                 (set! em-lines (vector-remove em-lines sy))
                 (set! em-nlines (- em-nlines 1))
                 (loop (+ i 1))))
             ;; Insert original lines back at sy
             (let loop ((i 0) (lst orig-lines))
               (when (not (null? lst))
                 (set! em-lines (vector-insert em-lines (+ sy i) (car lst)))
                 (set! em-nlines (+ em-nlines 1))
                 (loop (+ i 1) (cdr lst))))
             (when (= em-nlines 0)
               (set! em-lines (vector ""))
               (set! em-nlines 1))
             (set! em-cy scy) (set! em-cx scx)))
          (#t #f))
        (set! em-modified 1)
        (em-ensure-visible)
        (set! em-message "Undo!"))))

;; Helper: collect lines sy..ey into a list
(define (em-lines-list sy ey)
  (let loop ((i sy) (acc '()))
    (if (> i ey) (reverse acc)
        (loop (+ i 1) (cons (vector-ref-safe em-lines i) acc)))))

;; ===== Render =====
(define (em-render)
  (let* ((visible (- em-rows 2))
         (parts '()))
    (define (emit s) (set! parts (cons s parts)))

    ;; Hide cursor during redraw
    (emit (ansi "[?25l"))

    ;; Render each visible line
    (let loop ((screen-row 1))
      (when (<= screen-row visible)
        (let ((buf-row (+ em-top (- screen-row 1))))
          (emit (ansi "[" (number->string screen-row) ";1H"))
          (if (< buf-row em-nlines)
              (let* ((line (vector-ref-safe em-lines buf-row))
                     (display (expand-tabs line))
                     ;; Apply horizontal scroll
                     (display (if (> em-left 0)
                                  (substr display em-left (string-length display))
                                  display))
                     (display (if (> (string-length display) em-cols)
                                  (substr display 0 em-cols)
                                  display))
                     (dlen (string-length display))
                     (display (if (< dlen em-cols)
                                  (string-append display (string-repeat " " (- em-cols dlen)))
                                  display)))
                ;; Isearch highlight
                (if (and (equal? em-mode "isearch")
                         (>= em-isearch-y 0)
                         (= buf-row em-isearch-y)
                         (> em-isearch-len 0))
                    (let* ((mhs (max 0 (- (col-to-display line em-isearch-x) em-left)))
                           (mhe (max 0 (- (col-to-display line (+ em-isearch-x em-isearch-len)) em-left)))
                           (mhs (min mhs (string-length display)))
                           (mhe (min mhe (string-length display))))
                      (if (< mhs mhe)
                          (begin
                            (emit (substr display 0 mhs))
                            (emit (ansi "[1;7m"))
                            (emit (substr display mhs mhe))
                            (emit (ansi "[0m"))
                            (emit (substr display mhe (string-length display))))
                          (emit display)))
                    ;; Region highlight
                    (if (and (>= em-mark-y 0)
                             (not (and (= em-mark-y em-cy) (= em-mark-x em-cx)))
                             (let ((sy (min em-mark-y em-cy))
                                   (ey (max em-mark-y em-cy)))
                               (and (>= buf-row sy) (<= buf-row ey))))
                        (let* ((sy (min em-mark-y em-cy))
                               (ey (max em-mark-y em-cy))
                               (sx (if (< em-mark-y em-cy) em-mark-x em-cx))
                               (ex (if (> em-mark-y em-cy) em-mark-x em-cx))
                               (hs (max 0 (- (if (= buf-row sy) (col-to-display line sx) 0) em-left)))
                               (he (max 0 (- (if (= buf-row ey) (col-to-display line ex) (string-length display)) em-left)))
                               (hs (min hs (string-length display)))
                               (he (min he (string-length display))))
                          (if (< hs he)
                              (begin
                                (emit (substr display 0 hs))
                                (emit (ansi "[7m"))
                                (emit (substr display hs he))
                                (emit (ansi "[0m"))
                                (emit (substr display he (string-length display))))
                              (emit display)))
                        (emit display))))
              ;; Past end of buffer — clear line
              (emit (ansi "[K")))
          (loop (+ screen-row 1)))))

    ;; Status line (mode line)
    (let* ((status-row (- em-rows 1))
           (mod-flag (if (= em-modified 0) "--" "**"))
           (total em-nlines)
           (pct (if (<= total visible) "All"
                    (if (= em-top 0) "Top"
                        (if (>= (+ em-top visible) total) "Bot"
                            (string-append
                              (number->string (quotient (* em-top 100) (max 1 (- total visible))))
                              "%")))))
           (macro-ind (if em-macro-recording " [Macro]" ""))
           (status (string-append "-UUU:" mod-flag "-  "
                     em-bufname macro-ind
                     (string-repeat " " (max 1 (- 22 (+ (string-length em-bufname) (string-length macro-ind)))))
                     "(Fundamental) L" (number->string (+ em-cy 1))
                     "      " pct))
           (slen (string-length status))
           (status (if (< slen em-cols)
                       (string-append status (string-repeat "-" (- em-cols slen)))
                       (substr status 0 em-cols))))
      (emit (ansi "[" (number->string status-row) ";1H"))
      (emit (ansi "[7m"))
      (emit status)
      (emit (ansi "[0m")))

    ;; Echo / message line
    (let ((msg-row em-rows))
      (emit (ansi "[" (number->string msg-row) ";1H"))
      (emit (ansi "[K"))
      (cond
        ((equal? em-mode "isearch")
         (let ((prompt (if (= em-isearch-dir 1) "I-search: " "I-search backward: ")))
           (emit (string-append prompt em-isearch-str))))
        ((equal? em-mode "minibuffer")
         (emit (string-append em-mb-prompt em-mb-input)))
        (#t
         (when (not (equal? em-message ""))
           (emit (substr em-message 0 em-cols))
           (when (= em-msg-persist 0)
             (set! em-message ""))))))

    ;; Cursor position
    (let* ((screen-cy (+ (- em-cy em-top) 1))
           (disp-cx (col-to-display (vector-ref-safe em-lines em-cy) em-cx))
           (screen-cx (cond
             ((equal? em-mode "minibuffer")
              (+ (string-length em-mb-prompt) (string-length em-mb-input) 1))
             (#t (+ (- disp-cx em-left) 1)))))
      (emit (ansi "[" (number->string screen-cy) ";" (number->string (max 1 screen-cx)) "H")))

    ;; Show cursor
    (emit (ansi "[?25h"))

    (write-stdout (apply string-append (reverse parts)))))

;; ===== Movement =====
(define (em-forward-char)
  (let ((line-len (string-length (vector-ref-safe em-lines em-cy))))
    (if (< em-cx line-len)
        (set! em-cx (+ em-cx 1))
        (when (< em-cy (- em-nlines 1))
          (set! em-cy (+ em-cy 1)) (set! em-cx 0))))
  (set! em-goal-col -1) (em-ensure-visible))

(define (em-backward-char)
  (if (> em-cx 0)
      (set! em-cx (- em-cx 1))
      (when (> em-cy 0)
        (set! em-cy (- em-cy 1))
        (set! em-cx (string-length (vector-ref-safe em-lines em-cy)))))
  (set! em-goal-col -1) (em-ensure-visible))

(define (em-next-line)
  (when (< em-cy (- em-nlines 1))
    (when (< em-goal-col 0) (set! em-goal-col em-cx))
    (set! em-cy (+ em-cy 1))
    (let ((ll (string-length (vector-ref-safe em-lines em-cy))))
      (set! em-cx (min em-goal-col ll))))
  (em-ensure-visible))

(define (em-previous-line)
  (when (> em-cy 0)
    (when (< em-goal-col 0) (set! em-goal-col em-cx))
    (set! em-cy (- em-cy 1))
    (let ((ll (string-length (vector-ref-safe em-lines em-cy))))
      (set! em-cx (min em-goal-col ll))))
  (em-ensure-visible))

(define (em-beginning-of-line)
  (set! em-cx 0) (set! em-goal-col -1) (em-ensure-visible))

(define (em-end-of-line)
  (set! em-cx (string-length (vector-ref-safe em-lines em-cy)))
  (set! em-goal-col -1) (em-ensure-visible))

(define (em-beginning-of-buffer)
  (set! em-cy 0) (set! em-cx 0) (set! em-goal-col -1) (em-ensure-visible))

(define (em-end-of-buffer)
  (set! em-cy (- em-nlines 1))
  (set! em-cx (string-length (vector-ref-safe em-lines em-cy)))
  (set! em-goal-col -1) (em-ensure-visible))

(define (em-scroll-down)
  (let* ((visible (- em-rows 2)) (page (max 1 (- visible 2))))
    (set! em-top (+ em-top page))
    (set! em-cy (+ em-cy page))
    (set! em-goal-col -1) (em-ensure-visible)))

(define (em-scroll-up)
  (let* ((visible (- em-rows 2)) (page (max 1 (- visible 2))))
    (set! em-top (max 0 (- em-top page)))
    (set! em-cy (- em-cy page))
    (set! em-goal-col -1) (em-ensure-visible)))

(define (em-recenter)
  (let ((visible (- em-rows 2)))
    (set! em-top (max 0 (- em-cy (quotient visible 2))))))

;; ===== Indent / Dedent =====
(define (em-indent-line)
  (let* ((sy (if (>= em-mark-y 0) (min em-mark-y em-cy) em-cy))
         (ey (if (>= em-mark-y 0) (max em-mark-y em-cy) em-cy))
         (saved-lines (em-lines-list sy ey))
         (n (+ (- ey sy) 1)))
    (em-undo-push (list "replace_region" sy n em-cy em-cx saved-lines))
    (let loop ((i sy))
      (when (<= i ey)
        (vector-set! em-lines i (string-append "  " (vector-ref-safe em-lines i)))
        (loop (+ i 1))))
    (set! em-cx (+ em-cx 2))
    (when (>= em-mark-y 0) (set! em-mark-x (+ em-mark-x 2)))
    (set! em-modified 1) (set! em-goal-col -1)))

(define (em-dedent-line)
  (let* ((sy (if (>= em-mark-y 0) (min em-mark-y em-cy) em-cy))
         (ey (if (>= em-mark-y 0) (max em-mark-y em-cy) em-cy))
         (saved-lines (em-lines-list sy ey))
         (n (+ (- ey sy) 1))
         (changed #f))
    (let loop ((i sy))
      (when (<= i ey)
        (let* ((line (vector-ref-safe em-lines i))
               (stripped (cond
                           ((and (>= (string-length line) 2)
                                 (equal? (substr line 0 2) "  "))
                            (begin (set! changed #t) (substr line 2 (string-length line))))
                           ((and (>= (string-length line) 1)
                                 (equal? (substr line 0 1) " "))
                            (begin (set! changed #t) (substr line 1 (string-length line))))
                           (#t line))))
          (vector-set! em-lines i stripped)
          (loop (+ i 1)))))
    (when changed
      (em-undo-push (list "replace_region" sy n em-cy em-cx saved-lines))
      (set! em-cx (max 0 (- em-cx 2)))
      (when (and (>= em-mark-y 0) (> em-mark-x 0))
        (set! em-mark-x (max 0 (- em-mark-x 2))))
      (set! em-modified 1))
    (set! em-goal-col -1)))

;; ===== Basic Editing =====
(define (em-self-insert ch)
  (let ((line (vector-ref-safe em-lines em-cy)))
    (em-undo-push (list "delete_char" em-cy em-cx))
    (vector-set! em-lines em-cy
      (string-append (substr line 0 em-cx) ch (substr line em-cx (string-length line))))
    (set! em-cx (+ em-cx 1))
    (set! em-modified 1) (set! em-goal-col -1)))

(define (em-newline)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (before (substr line 0 em-cx))
         (after (substr line em-cx (string-length line))))
    (em-undo-push (list "split_line" em-cy em-cx))
    (vector-set! em-lines em-cy before)
    (set! em-lines (vector-insert em-lines (+ em-cy 1) after))
    (set! em-cy (+ em-cy 1)) (set! em-cx 0)
    (set! em-nlines (vector-length em-lines))
    (set! em-modified 1) (set! em-goal-col -1) (em-ensure-visible)))

(define (em-open-line)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (before (substr line 0 em-cx))
         (after (substr line em-cx (string-length line))))
    (em-undo-push (list "split_line" em-cy em-cx))
    (vector-set! em-lines em-cy before)
    (set! em-lines (vector-insert em-lines (+ em-cy 1) after))
    (set! em-nlines (vector-length em-lines))
    (set! em-modified 1)))

(define (em-delete-char)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (line-len (string-length line)))
    (if (< em-cx line-len)
        (begin
          (em-undo-push (list "insert_char" em-cy em-cx (substr line em-cx (+ em-cx 1))))
          (vector-set! em-lines em-cy
            (string-append (substr line 0 em-cx) (substr line (+ em-cx 1) line-len)))
          (set! em-modified 1))
        (when (< em-cy (- em-nlines 1))
          (let ((next (vector-ref-safe em-lines (+ em-cy 1))))
            (em-undo-push (list "join_lines" em-cy em-cx))
            (vector-set! em-lines em-cy (string-append line next))
            (set! em-lines (vector-remove em-lines (+ em-cy 1)))
            (set! em-nlines (- em-nlines 1))
            (set! em-modified 1))))
    (set! em-goal-col -1)))

(define (em-backward-delete-char)
  (if (> em-cx 0)
      (begin (set! em-cx (- em-cx 1)) (em-delete-char))
      (when (> em-cy 0)
        (set! em-cy (- em-cy 1))
        (set! em-cx (string-length (vector-ref-safe em-lines em-cy)))
        (em-delete-char)))
  (set! em-goal-col -1) (em-ensure-visible))

(define (em-transpose-chars)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (len (string-length line)))
    (when (>= len 2)
      (let* ((cx (if (>= em-cx len) (- len 1) em-cx))
             (cx (if (<= cx 0) 1 cx))
             (ch1 (substr line (- cx 1) cx))
             (ch2 (substr line cx (+ cx 1))))
        (em-undo-push (list "replace_line" em-cy em-cx line))
        (vector-set! em-lines em-cy
          (string-append (substr line 0 (- cx 1)) ch2 ch1 (substr line (+ cx 1) len)))
        (set! em-cx (min (+ cx 1) len))
        (set! em-modified 1) (set! em-goal-col -1)))))

;; ===== Clipboard =====
(define (em-clipboard-copy text)
  (when (not (equal? em-clip-copy ""))
    (shell-exec em-clip-copy text)))

(define (em-clipboard-paste)
  (if (equal? em-clip-paste "") #f
      (shell-capture em-clip-paste)))

;; ===== Kill / Yank =====
(define (em-string-contains str sub)
  (let ((slen (string-length str)) (sublen (string-length sub)))
    (if (> sublen slen) #f
        (let loop ((i 0))
          (if (> i (- slen sublen)) #f
              (if (equal? (substr str i (+ i sublen)) sub) #t
                  (loop (+ i 1))))))))

(define (em-string-split str sep)
  (let ((slen (string-length str)) (seplen (string-length sep)))
    (let loop ((i 0) (start 0) (parts '()))
      (if (>= i slen)
          (reverse (cons (substr str start slen) parts))
          (if (equal? (substr str i (+ i seplen)) sep)
              (loop (+ i seplen) (+ i seplen) (cons (substr str start i) parts))
              (loop (+ i 1) start parts))))))

(define (em-kill-push text)
  ;; If last command was C-k, append; otherwise prepend new entry
  (if (and (equal? em-last-cmd "C-k") (not (null? em-kill-ring)))
      (set! em-kill-ring (cons (string-append (car em-kill-ring) text) (cdr em-kill-ring)))
      (set! em-kill-ring (cons text em-kill-ring)))
  (when (> (length em-kill-ring) 60)
    (set! em-kill-ring (list-take em-kill-ring 60))))

(define (em-kill-line)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (line-len (string-length line)))
    (if (< em-cx line-len)
        (let ((killed (substr line em-cx line-len)))
          (em-undo-push (list "replace_line" em-cy em-cx line))
          (vector-set! em-lines em-cy (substr line 0 em-cx))
          (em-kill-push killed))
        (when (< em-cy (- em-nlines 1))
          (let ((next (vector-ref-safe em-lines (+ em-cy 1))))
            (em-undo-push (list "join_lines" em-cy em-cx))
            (vector-set! em-lines em-cy (string-append line next))
            (set! em-lines (vector-remove em-lines (+ em-cy 1)))
            (set! em-nlines (- em-nlines 1))
            (em-kill-push "\n"))))
    (set! em-modified 1) (set! em-goal-col -1)))

(define (em-yank)
  (if (null? em-kill-ring)
      (set! em-message "Kill ring is empty")
      (let* ((text (car em-kill-ring))
             (save-cy em-cy) (save-cx em-cx)
             (save-line (vector-ref-safe em-lines em-cy)))
        (set! em-mark-y em-cy) (set! em-mark-x em-cx)
        (if (not (em-string-contains text "\n"))
            (begin
              (em-undo-push (list "replace_region" save-cy 1 save-cy save-cx (list save-line)))
              (let ((line (vector-ref-safe em-lines em-cy)))
                (vector-set! em-lines em-cy
                  (string-append (substr line 0 em-cx) text (substr line em-cx (string-length line))))
                (set! em-cx (+ em-cx (string-length text)))))
            (let* ((yank-lines (em-string-split text "\n"))
                   (nparts (length yank-lines))
                   (line (vector-ref-safe em-lines em-cy))
                   (before (substr line 0 em-cx))
                   (after (substr line em-cx (string-length line))))
              (em-undo-push (list "replace_region" save-cy nparts save-cy save-cx (list save-line)))
              (vector-set! em-lines em-cy (string-append before (car yank-lines)))
              (let loop ((i 1) (rest (cdr yank-lines)))
                (when (not (null? rest))
                  (if (null? (cdr rest))
                      (begin
                        (set! em-lines (vector-insert em-lines (+ save-cy i)
                          (string-append (car rest) after)))
                        (set! em-cy (+ save-cy i))
                        (set! em-cx (string-length (car rest))))
                      (begin
                        (set! em-lines (vector-insert em-lines (+ save-cy i) (car rest)))
                        (loop (+ i 1) (cdr rest))))))))
        (set! em-nlines (vector-length em-lines))
        (set! em-modified 1) (set! em-goal-col -1) (em-ensure-visible))))

;; ===== Mark / Region =====
(define (em-set-mark)
  (set! em-mark-y em-cy) (set! em-mark-x em-cx)
  (set! em-message "Mark set"))

(define (em-keyboard-quit)
  (set! em-mark-y -1) (set! em-mark-x -1)
  (set! em-mode "normal")
  (set! em-message "Quit"))

(define (em-extract-region sy sx ey ex)
  (if (= sy ey)
      (substr (vector-ref-safe em-lines sy) sx ex)
      (let loop ((i sy) (parts '()))
        (if (> i ey)
            (apply string-append (reverse parts))
            (let* ((line (vector-ref-safe em-lines i))
                   (part (cond
                           ((= i sy) (substr line sx (string-length line)))
                           ((= i ey) (substr line 0 ex))
                           (#t line))))
              (loop (+ i 1)
                    (if (< i ey)
                        (cons (string-append part "\n") parts)
                        (cons part parts))))))))

(define (em-delete-region sy sx ey ex)
  (let* ((first-line (vector-ref-safe em-lines sy))
         (last-line (vector-ref-safe em-lines ey))
         (new-line (string-append (substr first-line 0 sx)
                                  (substr last-line ex (string-length last-line)))))
    (let loop ((i ey))
      (when (> i sy)
        (set! em-lines (vector-remove em-lines i))
        (loop (- i 1))))
    (vector-set! em-lines sy new-line)
    (set! em-nlines (vector-length em-lines))))

(define (em-normalize-region)
  ;; Returns (sy sx ey ex) with sy/sx <= ey/ex
  (let ((my em-mark-y) (mx em-mark-x) (cy em-cy) (cx em-cx))
    (if (or (> my cy) (and (= my cy) (> mx cx)))
        (list cy cx my mx)
        (list my mx cy cx))))

(define (em-kill-region)
  (if (< em-mark-y 0)
      (set! em-message "The mark is not set now")
      (let* ((r (em-normalize-region))
             (sy (list-ref r 0)) (sx (list-ref r 1))
             (ey (list-ref r 2)) (ex (list-ref r 3))
             (killed (em-extract-region sy sx ey ex))
             (saved-lines (em-lines-list sy ey))
             (n-lines (+ (- ey sy) 1)))
        (em-undo-push (list "replace_region" sy 1 sy sx saved-lines))
        (set! em-kill-ring (cons killed em-kill-ring))
        (when (> (length em-kill-ring) 60)
          (set! em-kill-ring (list-take em-kill-ring 60)))
        (em-clipboard-copy killed)
        (em-delete-region sy sx ey ex)
        (set! em-cy sy) (set! em-cx sx)
        (set! em-mark-y -1) (set! em-mark-x -1)
        (set! em-modified 1) (set! em-goal-col -1) (em-ensure-visible))))

(define (em-copy-region)
  (if (< em-mark-y 0)
      (set! em-message "The mark is not set now")
      (let* ((r (em-normalize-region))
             (sy (list-ref r 0)) (sx (list-ref r 1))
             (ey (list-ref r 2)) (ex (list-ref r 3))
             (copied (em-extract-region sy sx ey ex)))
        (set! em-kill-ring (cons copied em-kill-ring))
        (when (> (length em-kill-ring) 60)
          (set! em-kill-ring (list-take em-kill-ring 60)))
        (em-clipboard-copy copied)
        (set! em-mark-y -1) (set! em-mark-x -1)
        (set! em-message "Region copied"))))

(define (em-mark-whole-buffer)
  (set! em-mark-y 0) (set! em-mark-x 0)
  (set! em-cy (- em-nlines 1))
  (set! em-cx (string-length (vector-ref-safe em-lines (- em-nlines 1))))
  (set! em-goal-col -1) (em-ensure-visible)
  (set! em-message "Mark set"))

(define (em-exchange-point-and-mark)
  (if (< em-mark-y 0)
      (set! em-message "No mark set in this buffer")
      (let ((ty em-cy) (tx em-cx))
        (set! em-cy em-mark-y) (set! em-cx em-mark-x)
        (set! em-mark-y ty) (set! em-mark-x tx)
        (set! em-goal-col -1) (em-ensure-visible))))

;; ===== Rectangles =====
(define (em-rect-bounds)
  ;; Returns (sy sx ey ex) normalized so sx <= ex
  (let* ((sy em-mark-y) (sx em-mark-x) (ey em-cy) (ex em-cx))
    (when (> sy ey) (let ((t sy)) (set! sy ey) (set! ey t)))
    (when (> sx ex) (let ((t sx)) (set! sx ex) (set! ex t)))
    (list sy sx ey ex)))

(define (em-kill-rectangle)
  (if (< em-mark-y 0)
      (set! em-message "The mark is not set now")
      (let* ((b (em-rect-bounds))
             (sy (list-ref b 0)) (sx (list-ref b 1))
             (ey (list-ref b 2)) (ex (list-ref b 3))
             (saved-lines (em-lines-list sy ey))
             (n (+ (- ey sy) 1)))
        (em-undo-push (list "replace_region" sy n sy sx saved-lines))
        (set! em-rect-ring '())
        (let loop ((i sy))
          (when (<= i ey)
            (let* ((line (vector-ref-safe em-lines i))
                   (ll (string-length line))
                   (rsx (min sx ll)) (rex (min ex ll)))
              (set! em-rect-ring (append em-rect-ring (list (substr line rsx rex))))
              (vector-set! em-lines i
                (string-append (substr line 0 rsx) (substr line rex ll))))
            (loop (+ i 1))))
        (set! em-cy sy) (set! em-cx sx)
        (set! em-mark-y -1) (set! em-mark-x -1)
        (set! em-modified 1)
        (set! em-message "Rectangle killed"))))

(define (em-yank-rectangle)
  (if (null? em-rect-ring)
      (set! em-message "No rectangle to yank")
      (let* ((nrect (length em-rect-ring))
             (saved-lines (em-lines-list em-cy (min (- em-nlines 1) (+ em-cy nrect -1))))
             (n-existing (length saved-lines)))
        ;; Ensure enough lines exist
        (let loop ((need (- (+ em-cy nrect) em-nlines)))
          (when (> need 0)
            (set! em-lines (vector-insert em-lines em-nlines ""))
            (set! em-nlines (+ em-nlines 1))
            (loop (- need 1))))
        (em-undo-push (list "replace_region" em-cy nrect em-cy em-cx saved-lines))
        (let loop ((i 0) (rects em-rect-ring))
          (when (not (null? rects))
            (let* ((line (vector-ref-safe em-lines (+ em-cy i)))
                   (ll (string-length line))
                   (pad (if (< ll em-cx) (string-repeat " " (- em-cx ll)) ""))
                   (line (string-append line pad))
                   (rect-str (car rects)))
              (vector-set! em-lines (+ em-cy i)
                (string-append (substr line 0 em-cx) rect-str
                               (substr line (+ em-cx (string-length rect-str)) (string-length line)))))
            (loop (+ i 1) (cdr rects))))
        (set! em-modified 1)
        (set! em-message "Rectangle yanked"))))

(define (em-copy-rectangle)
  (if (< em-mark-y 0)
      (set! em-message "The mark is not set now")
      (let* ((b (em-rect-bounds))
             (sy (list-ref b 0)) (sx (list-ref b 1))
             (ey (list-ref b 2)) (ex (list-ref b 3)))
        (set! em-rect-ring '())
        (let loop ((i sy))
          (when (<= i ey)
            (let* ((line (vector-ref-safe em-lines i))
                   (ll (string-length line))
                   (rsx (min sx ll)) (rex (min ex ll)))
              (set! em-rect-ring (append em-rect-ring (list (substr line rsx rex)))))
            (loop (+ i 1))))
        (set! em-message "Rectangle copied"))))

(define (em-delete-rectangle)
  (if (< em-mark-y 0)
      (set! em-message "The mark is not set now")
      (let* ((b (em-rect-bounds))
             (sy (list-ref b 0)) (sx (list-ref b 1))
             (ey (list-ref b 2)) (ex (list-ref b 3))
             (saved-lines (em-lines-list sy ey))
             (n (+ (- ey sy) 1)))
        (em-undo-push (list "replace_region" sy n sy sx saved-lines))
        (let loop ((i sy))
          (when (<= i ey)
            (let* ((line (vector-ref-safe em-lines i))
                   (ll (string-length line))
                   (rsx (min sx ll)) (rex (min ex ll)))
              (vector-set! em-lines i
                (string-append (substr line 0 rsx) (substr line rex ll))))
            (loop (+ i 1))))
        (set! em-cy sy) (set! em-cx sx)
        (set! em-mark-y -1) (set! em-mark-x -1)
        (set! em-modified 1)
        (set! em-message "Rectangle deleted"))))

(define (em-string-rectangle)
  (if (< em-mark-y 0)
      (set! em-message "The mark is not set now")
      (em-minibuffer-start "String rectangle: " "string-rect")))

(define (em-do-string-rectangle str)
  (let* ((b (em-rect-bounds))
         (sy (list-ref b 0)) (sx (list-ref b 1))
         (ey (list-ref b 2)) (ex (list-ref b 3))
         (saved-lines (em-lines-list sy ey))
         (n (+ (- ey sy) 1)))
    (em-undo-push (list "replace_region" sy n sy sx saved-lines))
    (let loop ((i sy))
      (when (<= i ey)
        (let* ((line (vector-ref-safe em-lines i))
               (ll (string-length line))
               (rsx (min sx ll)) (rex (min ex ll)))
          (vector-set! em-lines i
            (string-append (substr line 0 rsx) str (substr line rex ll))))
        (loop (+ i 1))))
    (set! em-mark-y -1) (set! em-mark-x -1)
    (set! em-modified 1)
    (set! em-message "String rectangle done")))

(define (em-open-rectangle)
  (if (< em-mark-y 0)
      (set! em-message "The mark is not set now")
      (let* ((b (em-rect-bounds))
             (sy (list-ref b 0)) (sx (list-ref b 1))
             (ey (list-ref b 2)) (ex (list-ref b 3))
             (width (- ex sx))
             (saved-lines (em-lines-list sy ey))
             (n (+ (- ey sy) 1)))
        (when (> width 0)
          (em-undo-push (list "replace_region" sy n sy sx saved-lines))
          (let ((pad (string-repeat " " width)))
            (let loop ((i sy))
              (when (<= i ey)
                (let* ((line (vector-ref-safe em-lines i))
                       (ll (string-length line))
                       (rsx (min sx ll)))
                  (vector-set! em-lines i
                    (string-append (substr line 0 rsx) pad (substr line rsx ll))))
                (loop (+ i 1)))))
          (set! em-mark-y -1) (set! em-mark-x -1)
          (set! em-modified 1)
          (set! em-message "Open rectangle done")))))

;; ===== Word operations =====
(define (em-forward-word)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (len (string-length line)))
    ;; Skip non-word chars
    (let loop ()
      (if (>= em-cx len)
          (when (< em-cy (- em-nlines 1))
            (set! em-cy (+ em-cy 1)) (set! em-cx 0)
            (set! line (vector-ref-safe em-lines em-cy))
            (set! len (string-length line))
            (loop))
          (when (not (char-word? (string-ref line em-cx)))
            (set! em-cx (+ em-cx 1)) (loop))))
    ;; Skip word chars
    (set! line (vector-ref-safe em-lines em-cy))
    (set! len (string-length line))
    (let loop ()
      (when (and (< em-cx len) (char-word? (string-ref line em-cx)))
        (set! em-cx (+ em-cx 1)) (loop))))
  (set! em-goal-col -1) (em-ensure-visible))

(define (em-backward-word)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (len (string-length line)))
    ;; Move back one position first
    (if (> em-cx 0)
        (set! em-cx (- em-cx 1))
        (when (> em-cy 0)
          (set! em-cy (- em-cy 1))
          (set! line (vector-ref-safe em-lines em-cy))
          (set! len (string-length line))
          (set! em-cx (if (> len 0) (- len 1) 0))))
    ;; Skip non-word chars backward
    (let loop ()
      (if (<= em-cx 0)
          (when (> em-cy 0)
            (set! em-cy (- em-cy 1))
            (set! line (vector-ref-safe em-lines em-cy))
            (set! len (string-length line))
            (set! em-cx len)
            (loop))
          (when (and (> (string-length line) 0)
                     (not (char-word? (string-ref line (- em-cx 1)))))
            (set! em-cx (- em-cx 1)) (loop))))
    ;; Skip word chars backward
    (set! line (vector-ref-safe em-lines em-cy))
    (let loop ()
      (when (and (> em-cx 0) (char-word? (string-ref line (- em-cx 1))))
        (set! em-cx (- em-cx 1)) (loop))))
  (set! em-goal-col -1) (em-ensure-visible))

(define (em-kill-word)
  (let ((save-cy em-cy) (save-cx em-cx))
    (em-forward-word)
    (when (or (not (= em-cy save-cy)) (not (= em-cx save-cx)))
      (let* ((r (if (or (> save-cy em-cy) (and (= save-cy em-cy) (> save-cx em-cx)))
                    (list em-cy em-cx save-cy save-cx)
                    (list save-cy save-cx em-cy em-cx)))
             (sy (list-ref r 0)) (sx (list-ref r 1))
             (ey (list-ref r 2)) (ex (list-ref r 3))
             (killed (em-extract-region sy sx ey ex))
             (saved-lines (em-lines-list sy ey)))
        (em-undo-push (list "replace_region" sy 1 sy sx saved-lines))
        (set! em-kill-ring (cons killed em-kill-ring))
        (em-delete-region sy sx ey ex)
        (set! em-cy sy) (set! em-cx sx)
        (set! em-modified 1) (set! em-goal-col -1) (em-ensure-visible)))))

(define (em-backward-kill-word)
  (let ((save-cy em-cy) (save-cx em-cx))
    (em-backward-word)
    (when (or (not (= em-cy save-cy)) (not (= em-cx save-cx)))
      (let* ((sy em-cy) (sx em-cx) (ey save-cy) (ex save-cx)
             (killed (em-extract-region sy sx ey ex))
             (saved-lines (em-lines-list sy ey)))
        (em-undo-push (list "replace_region" sy 1 sy sx saved-lines))
        (set! em-kill-ring (cons killed em-kill-ring))
        (em-delete-region sy sx ey ex)
        (set! em-modified 1) (set! em-goal-col -1) (em-ensure-visible)))))

;; ===== Case conversion =====
(define (em-upcase-word)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (len (string-length line))
         (cx em-cx))
    (when (< cx len)
      (em-undo-push (list "replace_line" em-cy em-cx line))
      (let loop () (when (and (< cx len) (not (char-word? (string-ref line cx))))
        (set! cx (+ cx 1)) (loop)))
      (let loop () (when (and (< cx len) (char-word? (string-ref line cx)))
        (set! line (string-append (substr line 0 cx)
          (string (char-upcase (string-ref line cx)))
          (substr line (+ cx 1) len)))
        (set! cx (+ cx 1)) (loop)))
      (vector-set! em-lines em-cy line)
      (set! em-cx cx) (set! em-modified 1) (set! em-goal-col -1))))

(define (em-downcase-word)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (len (string-length line))
         (cx em-cx))
    (when (< cx len)
      (em-undo-push (list "replace_line" em-cy em-cx line))
      (let loop () (when (and (< cx len) (not (char-word? (string-ref line cx))))
        (set! cx (+ cx 1)) (loop)))
      (let loop () (when (and (< cx len) (char-word? (string-ref line cx)))
        (set! line (string-append (substr line 0 cx)
          (string (char-downcase (string-ref line cx)))
          (substr line (+ cx 1) len)))
        (set! cx (+ cx 1)) (loop)))
      (vector-set! em-lines em-cy line)
      (set! em-cx cx) (set! em-modified 1) (set! em-goal-col -1))))

(define (em-capitalize-word)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (len (string-length line))
         (cx em-cx))
    (when (< cx len)
      (em-undo-push (list "replace_line" em-cy em-cx line))
      (let loop () (when (and (< cx len) (not (char-word? (string-ref line cx))))
        (set! cx (+ cx 1)) (loop)))
      (when (< cx len)
        (set! line (string-append (substr line 0 cx)
          (string (char-upcase (string-ref line cx)))
          (substr line (+ cx 1) len)))
        (set! cx (+ cx 1)))
      (let loop () (when (and (< cx len) (char-word? (string-ref line cx)))
        (set! line (string-append (substr line 0 cx)
          (string (char-downcase (string-ref line cx)))
          (substr line (+ cx 1) len)))
        (set! cx (+ cx 1)) (loop)))
      (vector-set! em-lines em-cy line)
      (set! em-cx cx) (set! em-modified 1) (set! em-goal-col -1))))

;; ===== Isearch =====
(define (em-string-find line sub start)
  (let ((llen (string-length line)) (slen (string-length sub)))
    (if (> slen llen) -1
        (let loop ((i (max 0 start)))
          (if (> i (- llen slen)) -1
              (if (equal? (substr line i (+ i slen)) sub) i
                  (loop (+ i 1))))))))

(define (em-string-rfind line sub start)
  (let ((llen (string-length line)) (slen (string-length sub)))
    (if (> slen llen) -1
        (let loop ((i (min start (- llen slen))))
          (if (< i 0) -1
              (if (equal? (substr line i (+ i slen)) sub) i
                  (loop (- i 1))))))))

(define (em-isearch-start dir)
  (set! em-mode "isearch")
  (set! em-isearch-str "")
  (set! em-isearch-dir dir)
  (set! em-isearch-y -1) (set! em-isearch-x -1) (set! em-isearch-len 0)
  (set! em-isearch-saved-cy em-cy)
  (set! em-isearch-saved-cx em-cx)
  (set! em-isearch-saved-top em-top))

(define (em-isearch-do)
  (if (equal? em-isearch-str "")
      (begin (set! em-isearch-y -1) (set! em-isearch-len 0))
      (let ((found #f) (slen (string-length em-isearch-str)))
        (if (= em-isearch-dir 1)
            (let loop ((y em-cy) (start-x em-cx))
              (when (and (not found) (< y em-nlines))
                (let* ((line (vector-ref-safe em-lines y))
                       (pos (em-string-find line em-isearch-str start-x)))
                  (if (>= pos 0)
                      (begin
                        (set! found #t)
                        (set! em-isearch-y y) (set! em-isearch-x pos)
                        (set! em-isearch-len slen)
                        (set! em-cy y) (set! em-cx pos))
                      (loop (+ y 1) 0)))))
            (let loop ((y em-cy) (start-x (- em-cx 1)))
              (when (and (not found) (>= y 0))
                (let* ((line (vector-ref-safe em-lines y))
                       (pos (em-string-rfind line em-isearch-str start-x)))
                  (if (>= pos 0)
                      (begin
                        (set! found #t)
                        (set! em-isearch-y y) (set! em-isearch-x pos)
                        (set! em-isearch-len slen)
                        (set! em-cy y) (set! em-cx pos))
                      (loop (- y 1) 99999))))))
        (when (not found)
          (set! em-isearch-y -1) (set! em-isearch-len 0)
          (set! em-message "Failing I-search"))
        (em-ensure-visible))))

(define (em-isearch-next-match from-y from-x)
  ;; Search forward from (from-y, from-x) — used by query-replace
  (let ((slen (string-length em-qr-from)) (found #f))
    (let loop ((y from-y) (start-x from-x))
      (when (and (not found) (< y em-nlines))
        (let* ((line (vector-ref-safe em-lines y))
               (pos (em-string-find line em-qr-from start-x)))
          (if (>= pos 0)
              (begin
                (set! found #t)
                (set! em-cy y) (set! em-cx pos)
                (em-ensure-visible))
              (loop (+ y 1) 0)))))
    found))

(define (em-isearch-handle-key key)
  (cond
    ((equal? key "C-s")
     (set! em-isearch-dir 1)
     (if (> (string-length em-isearch-str) 0)
         (begin (set! em-cx (+ em-cx 1)) (em-isearch-do))
         #f))
    ((equal? key "C-r")
     (set! em-isearch-dir -1)
     (if (> (string-length em-isearch-str) 0)
         (begin (set! em-cx (- em-cx 1)) (em-isearch-do))
         #f))
    ((equal? key "C-g")
     (set! em-cy em-isearch-saved-cy) (set! em-cx em-isearch-saved-cx)
     (set! em-top em-isearch-saved-top)
     (set! em-isearch-y -1) (set! em-isearch-len 0)
     (set! em-mode "normal") (set! em-message "Quit"))
    ((equal? key "BACKSPACE")
     (if (> (string-length em-isearch-str) 0)
         (begin
           (set! em-isearch-str
             (substr em-isearch-str 0 (- (string-length em-isearch-str) 1)))
           (set! em-cy em-isearch-saved-cy) (set! em-cx em-isearch-saved-cx)
           (em-isearch-do))
         (begin (set! em-mode "normal") (set! em-message ""))))
    ((equal? key "C-m")
     (set! em-isearch-y -1) (set! em-isearch-len 0)
     (set! em-mode "normal") (set! em-message ""))
    ((and (> (string-length key) 5) (equal? (substr key 0 5) "SELF:"))
     (set! em-isearch-str (string-append em-isearch-str (substr key 5 (string-length key))))
     (em-isearch-do))
    (#t
     (set! em-isearch-y -1) (set! em-isearch-len 0)
     (set! em-mode "normal")
     (em-dispatch key))))

;; ===== Minibuffer =====
(define (em-minibuffer-start prompt callback)
  (set! em-mode "minibuffer")
  (set! em-mb-prompt prompt)
  (set! em-mb-input "")
  (set! em-mb-callback callback)
  (set! em-mb-comp-type
    (cond
      ((or (equal? callback "find-file") (equal? callback "write-file")
           (equal? callback "insert-file") (equal? callback "save-as"))
       "file")
      ((or (equal? callback "switch-buffer") (equal? callback "kill-buffer"))
       "buffer")
      ((equal? callback "mx-command")
       "command")
      (#t ""))))

(define (em-minibuffer-handle-key key)
  (cond
    ((equal? key "C-g")
     (set! em-mode "normal") (set! em-message "Quit"))
    ((equal? key "C-m")
     (let ((result em-mb-input) (callback em-mb-callback))
       (set! em-mode "normal")
       (cond
         ((equal? callback "save-as")
          (when (not (equal? result ""))
            (set! em-filename result) (set! em-bufname result)
            (em-buf-update-name result result)
            (if (file-write-atomic result (em-build-save-data))
                (begin (set! em-modified 0)
                       (set! em-message (string-append "Wrote " (number->string em-nlines) " lines to " result)))
                (set! em-message "Error writing file"))))
         ((equal? callback "quit-confirm")
          (if (equal? result "yes")
              (set! em-running #f)
              (set! em-message "Cancelled")))
         ((equal? callback "find-file")
          (when (not (equal? result ""))
            (em-do-find-file result)))
         ((equal? callback "write-file")
          (when (not (equal? result ""))
            (set! em-filename result)
            (set! em-bufname result)
            (em-buf-update-name result result)
            (em-do-save)))
         ((equal? callback "insert-file")
          (when (not (equal? result ""))
            (em-do-insert-file result)))
         ((equal? callback "switch-buffer")
          (em-do-switch-buffer result))
         ((equal? callback "kill-buffer")
          (em-do-kill-buffer result))
         ((equal? callback "goto-line")
          (let ((n (string->number result)))
            (if (and n (> n 0))
                (begin
                  (set! em-cy (min (- em-nlines 1) (- n 1)))
                  (set! em-cx 0) (em-ensure-visible))
                (set! em-message "Invalid line number"))))
         ((equal? callback "set-fill-column")
          (let ((n (string->number result)))
            (if (and n (> n 0))
                (begin (set! em-fill-column n)
                       (set! em-message (string-append "Fill column set to " (number->string n))))
                (set! em-message "Invalid column"))))
         ((equal? callback "qr-from")
          (if (equal? result "")
              (set! em-message "")
              (begin
                (set! em-qr-from result)
                (em-minibuffer-start
                  (string-append "Query replace " result " with: ")
                  "qr-to"))))
         ((equal? callback "qr-to")
          (em-do-query-replace em-qr-from result))
         ((equal? callback "string-rect")
          (em-do-string-rectangle result))
         ((equal? callback "mx-command")
          (cond
            ((equal? result "goto-line")
             (em-minibuffer-start "Goto line: " "goto-line"))
            ((equal? result "what-line")
             (set! em-message (string-append "Line " (number->string (+ em-cy 1)))))
            ((equal? result "set-fill-column")
             (em-minibuffer-start "Set fill column to: " "set-fill-column"))
            ((equal? result "query-replace")
             (em-minibuffer-start "Query replace: " "qr-from"))
            ((equal? result "save-buffer")
             (em-do-save))
            ((equal? result "find-file")
             (em-minibuffer-start "Find file: " "find-file"))
            ((equal? result "write-file")
             (em-minibuffer-start "Write file: " "write-file"))
            ((equal? result "insert-file")
             (em-minibuffer-start "Insert file: " "insert-file"))
            ((equal? result "kill-buffer")
             (em-minibuffer-start
               (string-append "Kill buffer (default " em-bufname "): ")
               "kill-buffer"))
            ((equal? result "switch-to-buffer")
             (em-minibuffer-start "Switch to buffer: " "switch-buffer"))
            ((equal? result "list-buffers")
             (em-list-buffers))
            ((equal? result "describe-bindings")
             (em-show-bindings))
            ((equal? result "clipboard-yank")
             (let ((clip (em-clipboard-paste)))
               (if (and clip (not (equal? clip "")))
                   (begin
                     (set! em-kill-ring (cons clip em-kill-ring))
                     (em-yank))
                   (set! em-message "System clipboard is empty"))))
            ((equal? result "what-cursor-position")
             (em-what-cursor-position))
            ((equal? result "eval-buffer")
             (em-eval-buffer))
            (#t (set! em-message (string-append "[No match] " result)))))
         (#t (set! em-message "")))))
    ((equal? key "C-i")
     ;; TAB — complete
     (em-minibuffer-complete))
    ((equal? key "BACKSPACE")
     (when (> (string-length em-mb-input) 0)
       (set! em-mb-input (substr em-mb-input 0 (- (string-length em-mb-input) 1)))))
    ((equal? key "C-a")
     (set! em-mb-input ""))
    ((equal? key "C-k")
     (set! em-mb-input ""))
    ((and (> (string-length key) 5) (equal? (substr key 0 5) "SELF:"))
     (set! em-mb-input (string-append em-mb-input (substr key 5 (string-length key)))))
    (#t #f)))

;; ===== Tab Completion =====
(define (em-minibuffer-complete)
  (cond
    ((equal? em-mb-comp-type "file") (em-complete-file em-mb-input))
    ((equal? em-mb-comp-type "buffer") (em-complete-buffer em-mb-input))
    ((equal? em-mb-comp-type "command") (em-complete-command em-mb-input))
    (#t #f)))

(define (em-common-prefix lst)
  (if (null? lst) ""
      (if (null? (cdr lst)) (car lst)
          (let loop ((prefix (car lst)) (rest (cdr lst)))
            (if (null? rest) prefix
                (let shrink ((p prefix))
                  (if (or (equal? p "") ((lambda (m) (not (equal? (substr m 0 (string-length p)) p))) (car rest)))
                      (shrink (substr p 0 (max 0 (- (string-length p) 1))))
                      (loop p (cdr rest)))))))))

(define (em-complete-file input)
  (let* ((expanded (if (and (> (string-length input) 0) (char=? (string-ref input 0) #\~))
                       (string-append (shell-capture "echo $HOME") (substr input 1 (string-length input)))
                       input))
         (matches (if (equal? expanded "") '() (file-glob expanded))))
    (if (null? matches)
        (set! em-message "[No match]")
        (if (null? (cdr matches))
            (let* ((m (car matches))
                   (result (if (file-directory? m)
                               (string-append m "/")
                               m)))
              (set! em-mb-input result))
            (let ((prefix (em-common-prefix matches)))
              (set! em-mb-input prefix)
              (when (equal? input prefix)
                (let ((display (apply string-append
                                 (map (lambda (m)
                                        (string-append (if (file-directory? m)
                                                           (string-append m "/")
                                                           m)
                                                       "  "))
                                      matches))))
                  (set! em-message (string-append "{" display "}"))
                  (set! em-msg-persist 1))))))))

(define (em-complete-buffer input)
  (let* ((names (map (lambda (buf) (vector-ref buf 1)) em-buffers))
         (matches (filter (lambda (n)
                            (and (>= (string-length n) (string-length input))
                                 (equal? (substr n 0 (string-length input)) input)))
                          names)))
    (if (null? matches)
        (set! em-message "[No match]")
        (if (null? (cdr matches))
            (set! em-mb-input (car matches))
            (let ((prefix (em-common-prefix matches)))
              (set! em-mb-input prefix)
              (when (equal? input prefix)
                (set! em-message
                  (string-append "{" (apply string-append (map (lambda (m) (string-append m "  ")) matches)) "}"))
                (set! em-msg-persist 1)))))))

(define em-mx-commands
  '("goto-line" "what-line" "set-fill-column" "query-replace"
    "save-buffer" "find-file" "write-file" "insert-file"
    "kill-buffer" "switch-to-buffer" "list-buffers"
    "describe-bindings" "clipboard-yank" "what-cursor-position" "eval-buffer"))

(define (em-complete-command input)
  (let ((matches (filter (lambda (cmd)
                           (and (>= (string-length cmd) (string-length input))
                                (equal? (substr cmd 0 (string-length input)) input)))
                         em-mx-commands)))
    (if (null? matches)
        (set! em-message "[No match]")
        (if (null? (cdr matches))
            (set! em-mb-input (car matches))
            (let ((prefix (em-common-prefix matches)))
              (set! em-mb-input prefix)
              (when (equal? input prefix)
                (set! em-message
                  (string-append "{" (apply string-append (map (lambda (m) (string-append m "  ")) matches)) "}"))
                (set! em-msg-persist 1)))))))

;; ===== Query Replace =====
(define em-qr-to "")

(define (em-do-query-replace from to)
  (set! em-qr-from from)
  (set! em-qr-to to)
  (set! em-qr-count 0)
  (set! em-mode "query-replace")
  (set! em-message
    (string-append "Query replacing " from " with " to ": (y/n/!/q/.) "))
  (set! em-msg-persist 1)
  ;; Position at first match
  (unless (em-isearch-next-match em-cy em-cx)
    (set! em-mode "normal")
    (set! em-message (string-append "No matches for: " from))))

(define (em-qr-handle-key key)
  (let ((from em-qr-from) (to em-qr-to))
    (cond
      ((or (equal? key "SELF:y") (equal? key "C-m"))
       ;; Replace current match
       (let ((line (vector-ref-safe em-lines em-cy)))
         (em-undo-push (list "replace_line" em-cy em-cx line))
         (vector-set! em-lines em-cy
           (string-append (substr line 0 em-cx) to
                          (substr line (+ em-cx (string-length from)) (string-length line))))
         (set! em-cx (+ em-cx (string-length to)))
         (set! em-qr-count (+ em-qr-count 1))
         (set! em-modified 1))
       (unless (em-isearch-next-match em-cy em-cx)
         (set! em-mode "normal")
         (set! em-message (string-append "Replaced " (number->string em-qr-count) " occurrence(s)"))))
      ((or (equal? key "SELF:n") (equal? key "BACKSPACE"))
       ;; Skip this match
       (set! em-cx (+ em-cx 1))
       (unless (em-isearch-next-match em-cy em-cx)
         (set! em-mode "normal")
         (set! em-message (string-append "Replaced " (number->string em-qr-count) " occurrence(s)"))))
      ((equal? key "SELF:!")
       ;; Replace all remaining
       (let loop ()
         (let ((line (vector-ref-safe em-lines em-cy)))
           (em-undo-push (list "replace_line" em-cy em-cx line))
           (vector-set! em-lines em-cy
             (string-append (substr line 0 em-cx) to
                            (substr line (+ em-cx (string-length from)) (string-length line))))
           (set! em-cx (+ em-cx (string-length to)))
           (set! em-qr-count (+ em-qr-count 1))
           (set! em-modified 1))
         (when (em-isearch-next-match em-cy em-cx) (loop)))
       (set! em-mode "normal")
       (set! em-message (string-append "Replaced " (number->string em-qr-count) " occurrence(s)")))
      ((equal? key "SELF:.")
       ;; Replace and quit
       (let ((line (vector-ref-safe em-lines em-cy)))
         (em-undo-push (list "replace_line" em-cy em-cx line))
         (vector-set! em-lines em-cy
           (string-append (substr line 0 em-cx) to
                          (substr line (+ em-cx (string-length from)) (string-length line))))
         (set! em-qr-count (+ em-qr-count 1))
         (set! em-modified 1))
       (set! em-mode "normal")
       (set! em-message (string-append "Replaced " (number->string em-qr-count) " occurrence(s)")))
      ((or (equal? key "SELF:q") (equal? key "C-g"))
       (set! em-mode "normal")
       (set! em-message (string-append "Replaced " (number->string em-qr-count) " occurrence(s)")))
      (#t #f))
    (when (equal? em-mode "query-replace")
      (set! em-message
        (string-append "Query replacing " from " with " to ": (y/n/!/q/.) "))
      (set! em-msg-persist 1))))

;; ===== Fill Paragraph =====
(define (em-fill-paragraph)
  (let* ((total em-nlines)
         (start em-cy)
         (end em-cy))
    ;; Find paragraph start (go up while non-blank line)
    (let loop ()
      (when (and (> start 0)
                 (not (equal? (vector-ref-safe em-lines (- start 1)) "")))
        (set! start (- start 1))
        (loop)))
    ;; Find paragraph end (go down while non-blank line)
    (let loop ()
      (when (and (< end (- total 1))
                 (not (equal? (vector-ref-safe em-lines (+ end 1)) "")))
        (set! end (+ end 1))
        (loop)))
    (let* ((saved-lines (em-lines-list start end))
           (n-orig (+ (- end start) 1)))
      ;; Join all lines into one text, collapsing whitespace
      (let* ((text (let loop ((i start) (acc ""))
                     (if (> i end) acc
                         (let* ((line (vector-ref-safe em-lines i))
                                (stripped (string-trim-left line))
                                (acc (if (equal? acc "") stripped
                                         (if (equal? stripped "") acc
                                             (string-append acc " " stripped)))))
                           (loop (+ i 1) acc)))))
             ;; Re-wrap at fill column
             (new-lines
               (let loop ((text text) (acc '()))
                 (if (<= (string-length text) em-fill-column)
                     (reverse (if (equal? text "") acc (cons text acc)))
                     (let* ((break-at
                              (let bloop ((i em-fill-column))
                                (cond
                                  ((< i 0) em-fill-column)
                                  ((char=? (string-ref text i) #\space) i)
                                  (#t (bloop (- i 1)))))))
                       (loop (string-trim-left (substr text (+ break-at 1) (string-length text)))
                             (cons (substr text 0 break-at) acc))))))
             (new-lines (if (null? new-lines) (list "") new-lines))
             (n-new (length new-lines)))
        ;; Remove original lines
        (let loop ((i 0))
          (when (< i n-orig)
            (set! em-lines (vector-remove em-lines start))
            (set! em-nlines (- em-nlines 1))
            (loop (+ i 1))))
        ;; Insert new lines
        (let loop ((i 0) (lst new-lines))
          (when (not (null? lst))
            (set! em-lines (vector-insert em-lines (+ start i) (car lst)))
            (set! em-nlines (+ em-nlines 1))
            (loop (+ i 1) (cdr lst))))
        (em-undo-push (list "replace_region" start n-new em-cy em-cx saved-lines))
        (set! em-cy start) (set! em-cx 0)
        (set! em-modified 1) (em-ensure-visible)
        (set! em-message "Filled paragraph")))))

;; ===== Show Bindings (C-h b) =====
(define em-bindings-text
  (list
    "FILE / BUFFER                        EDITING"
    "C-x C-c   Quit                       C-d / DEL   Delete char fwd"
    "C-x C-s   Save buffer                BACKSPACE   Delete char bkwd"
    "C-x C-f   Find (open) file           C-k         Kill to end of line"
    "C-x C-w   Write file (save as)       C-y         Yank (paste)"
    "C-x i     Insert file                C-w         Kill region"
    "C-x b     Switch buffer              M-w         Copy region"
    "C-x k     Kill buffer                C-SPC/M-SPC Set mark"
    "C-x C-b   List buffers               C-t         Transpose chars"
    "C-x h     Mark whole buffer          M-d/M-DEL   Kill word fwd/bkwd"
    "C-x =     What cursor position       M-c/l/u     Cap/down/upcase word"
    "C-x C-x   Exchange pt/mark           C-i/TAB     Indent line (+2 sp)"
    "C-x u / C-_  Undo                    SHIFT-TAB   Dedent line (-2 sp)"
    ""
    "MOVEMENT                             SEARCH"
    "C-f / RIGHT   Forward char           C-s         Isearch forward"
    "C-b / LEFT    Backward char          C-r         Isearch backward"
    "C-n / DOWN    Next line              M-%         Query replace"
    "C-p / UP      Previous line"
    "C-a / HOME    Beginning of line      MISC"
    "C-e / END     End of line            C-o         Open line"
    "M-f / M-b     Fwd/bkwd word          C-u N       Universal argument"
    "M-< / M->     Beg/end of buffer      C-q         Quoted insert"
    "C-v / PGDN    Page down              M-q         Fill paragraph"
    "M-v / PGUP    Page up                M-x         Extended command"
    "C-l           Recenter               C-g         Cancel"
    "C-z           Suspend                C-h b       Describe bindings"
    "                                     C-j         Eval buffer (Scheme)"
    ""
    "RECTANGLES (C-x r)                   MACROS (C-x)"
    "C-x r k   Kill rectangle             C-x (       Start macro"
    "C-x r y   Yank rectangle             C-x )       Stop macro"
    "C-x r r   Copy rectangle             C-x e       Execute macro"
    "C-x r d   Delete rectangle"
    "C-x r t   String rectangle"
    "C-x r o   Open rectangle"
    ""
    "TAB   Complete in minibuffer (file/buffer/command)"
    "M-x goto-line           Go to line number"
    "M-x clipboard-yank      Paste from OS clipboard"
    "M-x describe-bindings   Show this help"
    ""
    "[Press C-g or q to return]"))

(define (em-show-bindings)
  ;; Save current state
  (let ((saved-lines em-lines) (saved-nlines em-nlines)
        (saved-cy em-cy) (saved-cx em-cx) (saved-top em-top)
        (saved-mod em-modified) (saved-name em-bufname) (saved-file em-filename))
    ;; Load bindings as pseudo-buffer
    (set! em-lines (list->vector em-bindings-text))
    (set! em-nlines (vector-length em-lines))
    (set! em-cy 0) (set! em-cx 0) (set! em-top 0)
    (set! em-bufname "*Help*") (set! em-filename "") (set! em-modified 0)
    (set! em-message "Press C-g or q to return")
    (set! em-msg-persist 1)
    ;; Read keys until quit
    (let loop ()
      (em-render)
      (let ((key (em-read-key)))
        (cond
          ((or (equal? key "C-g") (equal? key "SELF:q")) #f)
          ((or (equal? key "C-n") (equal? key "DOWN")) (em-next-line) (loop))
          ((or (equal? key "C-p") (equal? key "UP")) (em-previous-line) (loop))
          ((or (equal? key "C-v") (equal? key "PGDN")) (em-scroll-down) (loop))
          ((or (equal? key "M-v") (equal? key "PGUP")) (em-scroll-up) (loop))
          ((equal? key "M-<") (em-beginning-of-buffer) (loop))
          ((equal? key "M->") (em-end-of-buffer) (loop))
          (#t (loop)))))
    ;; Restore
    (set! em-lines saved-lines) (set! em-nlines saved-nlines)
    (set! em-cy saved-cy) (set! em-cx saved-cx) (set! em-top saved-top)
    (set! em-modified saved-mod) (set! em-bufname saved-name) (set! em-filename saved-file)
    (set! em-message "")))

;; ===== Keyboard Macros =====
(define (em-start-macro)
  (set! em-macro-recording #t)
  (set! em-macro-keys '())
  (set! em-message "Defining keyboard macro..."))

(define (em-end-macro)
  (set! em-macro-recording #f)
  (set! em-message "Keyboard macro defined"))

(define (em-execute-macro)
  (if (null? em-macro-keys)
      (set! em-message "No keyboard macro defined")
      (let ((saved-recording em-macro-recording))
        (set! em-macro-recording #f)
        (for-each (lambda (k) (em-dispatch k)) em-macro-keys)
        (set! em-macro-recording saved-recording))))

;; ===== Buffer Management =====
;; Buffer record vector slots:
;;  0=id  1=name  2=filename  3=lines  4=nlines
;;  5=cy  6=cx  7=top  8=left  9=modified
;;  10=mark-y  11=mark-x  12=goal-col  13=undo-stack  14=kill-ring

(define (em-make-buffer id name filename)
  (let ((buf (make-vector 15 #f)))
    (vector-set! buf 0 id)
    (vector-set! buf 1 name)
    (vector-set! buf 2 filename)
    (vector-set! buf 3 (vector ""))
    (vector-set! buf 4 1)
    (vector-set! buf 5 0) (vector-set! buf 6 0) (vector-set! buf 7 0) (vector-set! buf 8 0)
    (vector-set! buf 9 0)
    (vector-set! buf 10 -1) (vector-set! buf 11 -1) (vector-set! buf 12 -1)
    (vector-set! buf 13 '()) (vector-set! buf 14 '())
    buf))

(define (em-find-buffer-by-id id)
  (let loop ((bufs em-buffers))
    (if (null? bufs) #f
        (if (= (vector-ref (car bufs) 0) id) (car bufs)
            (loop (cdr bufs))))))

(define (em-find-buffer-by-name name)
  (let loop ((bufs em-buffers))
    (if (null? bufs) #f
        (if (equal? (vector-ref (car bufs) 1) name) (car bufs)
            (loop (cdr bufs))))))

(define (em-find-buffer-by-filename filename)
  (let loop ((bufs em-buffers))
    (if (null? bufs) #f
        (if (equal? (vector-ref (car bufs) 2) filename) (car bufs)
            (loop (cdr bufs))))))

(define (em-save-buffer-state)
  (let ((buf (em-find-buffer-by-id em-cur-buf-id)))
    (when buf
      (vector-set! buf 1 em-bufname)
      (vector-set! buf 2 em-filename)
      (vector-set! buf 3 em-lines)
      (vector-set! buf 4 em-nlines)
      (vector-set! buf 5 em-cy)
      (vector-set! buf 6 em-cx)
      (vector-set! buf 7 em-top)
      (vector-set! buf 8 em-left)
      (vector-set! buf 9 em-modified)
      (vector-set! buf 10 em-mark-y)
      (vector-set! buf 11 em-mark-x)
      (vector-set! buf 12 em-goal-col)
      (vector-set! buf 13 em-undo-stack)
      (vector-set! buf 14 em-kill-ring))))

(define (em-restore-buffer-state buf)
  (set! em-cur-buf-id (vector-ref buf 0))
  (set! em-bufname    (vector-ref buf 1))
  (set! em-filename   (vector-ref buf 2))
  (set! em-lines      (vector-ref buf 3))
  (set! em-nlines     (vector-ref buf 4))
  (set! em-cy         (vector-ref buf 5))
  (set! em-cx         (vector-ref buf 6))
  (set! em-top        (vector-ref buf 7))
  (set! em-left       (vector-ref buf 8))
  (set! em-modified   (vector-ref buf 9))
  (set! em-mark-y     (vector-ref buf 10))
  (set! em-mark-x     (vector-ref buf 11))
  (set! em-goal-col   (vector-ref buf 12))
  (set! em-undo-stack (vector-ref buf 13))
  (set! em-kill-ring  (vector-ref buf 14)))

(define (em-new-buffer name filename)
  (set! em-buf-id-counter (+ em-buf-id-counter 1))
  (let ((buf (em-make-buffer em-buf-id-counter name filename)))
    (set! em-buffers (append em-buffers (list buf)))
    (set! em-cur-buf-id em-buf-id-counter)
    (set! em-bufname name) (set! em-filename filename)
    (set! em-lines (vector "")) (set! em-nlines 1)
    (set! em-cy 0) (set! em-cx 0) (set! em-top 0) (set! em-left 0)
    (set! em-modified 0) (set! em-goal-col -1)
    (set! em-mark-y -1) (set! em-mark-x -1)
    (set! em-undo-stack '()) (set! em-kill-ring '())
    buf))

(define (em-buf-update-name name filename)
  ;; Update current buffer's name in the buffer list
  (let ((buf (em-find-buffer-by-id em-cur-buf-id)))
    (when buf
      (vector-set! buf 1 name)
      (vector-set! buf 2 filename))))

(define (em-do-switch-buffer target)
  (let ((target (if (equal? target "") em-bufname target)))
    (let ((buf (em-find-buffer-by-name target)))
      (if (not buf)
          (set! em-message (string-append "No buffer named '" target "'"))
          (begin
            (em-save-buffer-state)
            (em-restore-buffer-state buf)
            (set! em-message em-bufname))))))

(define (em-do-kill-buffer target)
  (let ((target (if (equal? target "") em-bufname target)))
    (if (= (length em-buffers) 1)
        (set! em-message "Cannot kill the only buffer")
        (let ((buf (em-find-buffer-by-name target)))
          (if (not buf)
              (set! em-message (string-append "No buffer named '" target "'"))
              (let* ((is-cur (= (vector-ref buf 0) em-cur-buf-id))
                     (is-mod (if is-cur em-modified (vector-ref buf 9)))
                     (bname (vector-ref buf 1)))
                (if (and (= is-mod 1) (not (equal? bname "*scratch*")))
                    (begin
                      ;; TODO: prompt for confirmation - for now just kill
                      #f))
                (set! em-buffers (filter (lambda (b) (not (= (vector-ref b 0) (vector-ref buf 0)))) em-buffers))
                (when is-cur
                  (em-restore-buffer-state (car em-buffers)))
                (set! em-message (string-append "Killed buffer '" target "'"))))))))

(define (em-list-buffers)
  (let ((saved-lines em-lines) (saved-nlines em-nlines)
        (saved-cy em-cy) (saved-cx em-cx) (saved-top em-top)
        (saved-mod em-modified) (saved-name em-bufname) (saved-file em-filename))
    (em-save-buffer-state)
    (let* ((header (string-append " MR  " (string-repeat " " 20) "  Size    File"))
           (sep    (string-append " --  " (string-repeat "-" 20) "  ----    ----"))
           (entries (map (lambda (buf)
                           (let* ((bid (vector-ref buf 0))
                                  (bname (vector-ref buf 1))
                                  (bfile (vector-ref buf 2))
                                  (bmod (vector-ref buf 9))
                                  (bnlines (vector-ref buf 4))
                                  (cur-ch (if (= bid em-cur-buf-id) "." " "))
                                  (mod-ch (if (= bmod 1) "*" " ")))
                             (string-append " " cur-ch mod-ch "  "
                                            bname
                                            (string-repeat " " (max 1 (- 20 (string-length bname))))
                                            "  " (number->string bnlines)
                                            "  " (if bfile bfile ""))))
                         em-buffers)))
      (set! em-lines (list->vector (append (list header sep) entries (list "" "[Press C-g or q to return]"))))
      (set! em-nlines (vector-length em-lines))
      (set! em-cy 0) (set! em-cx 0) (set! em-top 0)
      (set! em-bufname "*Buffer List*") (set! em-filename "") (set! em-modified 0)
      (set! em-message "")
      (let loop ()
        (em-render)
        (let ((key (em-read-key)))
          (cond
            ((or (equal? key "C-g") (equal? key "SELF:q")) #f)
            ((or (equal? key "C-n") (equal? key "DOWN")) (em-next-line) (loop))
            ((or (equal? key "C-p") (equal? key "UP")) (em-previous-line) (loop))
            ((or (equal? key "C-v") (equal? key "PGDN")) (em-scroll-down) (loop))
            ((or (equal? key "M-v") (equal? key "PGUP")) (em-scroll-up) (loop))
            (#t (loop))))))
    (em-restore-buffer-state (em-find-buffer-by-id em-cur-buf-id))
    (set! em-message "")))

;; ===== File I/O =====
(define (em-build-save-data)
  (let loop ((i 0) (parts '()))
    (if (>= i em-nlines)
        (apply string-append (reverse parts))
        (loop (+ i 1)
              (cons (if (> i 0)
                        (string-append "\n" (vector-ref-safe em-lines i))
                        (vector-ref-safe em-lines i))
                    parts)))))

(define (em-do-save)
  (if (equal? em-filename "")
      (em-minibuffer-start "Write file: " "save-as")
      (if (file-write-atomic em-filename (em-build-save-data))
          (begin
            (set! em-modified 0)
            (em-buf-update-name em-bufname em-filename)
            (set! em-message (string-append "Wrote " (number->string em-nlines) " lines to " em-filename)))
          (set! em-message "Error writing file"))))

(define (em-do-quit)
  (em-save-buffer-state)
  (let ((unsaved (length (filter (lambda (buf)
                                   (and (= (vector-ref buf 9) 1)
                                        (not (equal? (vector-ref buf 1) "*scratch*"))))
                                 em-buffers))))
    (if (> unsaved 0)
        (em-minibuffer-start
          (string-append (number->string unsaved)
                         " modified buffer(s) not saved; exit anyway? (yes or no) ")
          "quit-confirm")
        (set! em-running #f))))

(define (em-load-content lines-str)
  (if (equal? lines-str "")
      (begin (set! em-lines (vector "")) (set! em-nlines 1))
      (begin
        (set! em-lines (list->vector (em-string-split lines-str "\n")))
        (set! em-nlines (vector-length em-lines))
        ;; Remove trailing empty line if file ended with newline
        (when (and (> em-nlines 1)
                   (equal? (vector-ref-safe em-lines (- em-nlines 1)) ""))
          (let ((new-vec (make-vector (- em-nlines 1) "")))
            (do ((i 0 (+ i 1))) ((= i (- em-nlines 1)))
              (vector-set! new-vec i (vector-ref em-lines i)))
            (set! em-lines new-vec)
            (set! em-nlines (- em-nlines 1))))))
  (set! em-cy 0) (set! em-cx 0) (set! em-top 0) (set! em-left 0)
  (set! em-modified 0) (set! em-undo-stack '()))

(define (em-load-file filename)
  (let ((content (file-read filename)))
    (if content
        (begin
          (set! em-filename filename)
          (set! em-bufname filename)
          (em-load-content content)
          #t)
        #f)))

(define (em-do-find-file path)
  ;; Check if already open
  (let ((existing (em-find-buffer-by-filename path)))
    (if existing
        (begin
          (em-save-buffer-state)
          (em-restore-buffer-state existing)
          (set! em-message em-bufname))
        (begin
          (em-save-buffer-state)
          (em-new-buffer path path)
          (if (em-load-file path)
              (em-buf-update-name path path)
              (begin
                (set! em-message (string-append "(New file) " path))
                (set! em-msg-persist 1)))))))

(define (em-do-insert-file path)
  (let ((content (file-read path)))
    (if (not content)
        (set! em-message (string-append "File not found: " path))
        (let* ((flines (em-string-split content "\n"))
               (nf (length flines))
               (save-cy em-cy) (save-cx em-cx)
               (save-line (vector-ref-safe em-lines em-cy)))
          (if (= nf 0)
              #f
              (begin
                (em-undo-push (list "replace_region" save-cy 1 save-cy save-cx (list save-line)))
                (if (= nf 1)
                    (begin
                      (let ((line (vector-ref-safe em-lines em-cy)))
                        (vector-set! em-lines em-cy
                          (string-append (substr line 0 em-cx) (car flines)
                                         (substr line em-cx (string-length line))))
                        (set! em-cx (+ em-cx (string-length (car flines))))))
                    (begin
                      (let* ((line (vector-ref-safe em-lines em-cy))
                             (before (substr line 0 em-cx))
                             (after (substr line em-cx (string-length line))))
                        (vector-set! em-lines em-cy (string-append before (car flines)))
                        (let loop ((i 1) (rest (cdr flines)))
                          (when (not (null? rest))
                            (if (null? (cdr rest))
                                (begin
                                  (set! em-lines (vector-insert em-lines (+ em-cy i)
                                    (string-append (car rest) after)))
                                  (set! em-cy (+ em-cy i))
                                  (set! em-cx (string-length (car rest))))
                                (begin
                                  (set! em-lines (vector-insert em-lines (+ em-cy i) (car rest)))
                                  (loop (+ i 1) (cdr rest))))))
                        (set! em-nlines (vector-length em-lines)))))
                (set! em-modified 1) (em-ensure-visible)
                (set! em-message (string-append "Inserted: " path))))))))

(define (em-eval-buffer)
  (let ((result (eval-string (em-build-save-data))))
    (if (car result)
        (begin
          (set! em-message (string-append "Eval: " (cdr result)))
          (set! em-msg-persist 1))
        (begin
          (set! em-message (string-append "Eval error: " (cdr result)))
          (set! em-msg-persist 1)))))

(define (em-what-cursor-position)
  (let* ((line-num (+ em-cy 1))
         (col-num (+ em-cx 1))
         (total em-nlines)
         (line (vector-ref-safe em-lines em-cy))
         (ch-info (if (< em-cx (string-length line))
                      (let* ((ch (string-ref line em-cx))
                             (n (char->integer ch)))
                        (string-append "Char: " (string ch)
                                       " (" (number->string n) ")"))
                      "Char: EOL")))
    (set! em-message
      (string-append "Line " (number->string line-num) "/" (number->string total)
                     ", Column " (number->string col-num) " -- " ch-info))))

(define (em-suspend)
  (terminal-restore!)
  (write-stdout (string-append ESC "[0m" ESC "[?25h" ESC "[?1049l"))
  (terminal-suspend!)
  ;; Resumed here
  (terminal-raw!)
  (write-stdout (string-append ESC "[?1049h" ESC "[?25l"))
  (let ((size (terminal-size)))
    (set! em-rows (car size))
    (set! em-cols (cdr size)))
  (set! em-message "Resumed"))

(define (em-quoted-insert)
  (set! em-message "C-q-")
  (em-render)
  (let ((key (em-read-key)))
    (cond
      ((and (> (string-length key) 5) (equal? (substr key 0 5) "SELF:"))
       (em-self-insert (substr key 5 (string-length key))))
      ((equal? key "C-i")
       (em-self-insert (string (integer->char 9))))
      ((equal? key "C-m")
       (em-newline))
      (#t
       ;; Try to extract the raw character for control chars
       (when (and (> (string-length key) 2) (equal? (substr key 0 2) "C-"))
         (let* ((ch (string-ref key 2))
                (n (char->integer ch))
                (ctrl (if (and (>= n 97) (<= n 122)) (- n 96) n)))
           (em-self-insert (string (integer->char ctrl)))))))))

(define (em-universal-argument)
  ;; Read digits and additional C-u presses, then execute key that many times
  (let ((arg 4))
    (set! em-message "C-u-")
    (em-render)
    (let ((key (em-read-key)))
      ;; Accumulate digit keys
      (let loop ((key key) (arg arg) (has-digits #f))
        (if (and (> (string-length key) 5) (equal? (substr key 0 5) "SELF:")
                 (let ((ch (string-ref key 5)))
                   (and (char>=? ch #\0) (char<=? ch #\9))))
            (begin
              (let ((d (- (char->integer (string-ref key 5)) 48)))
                (let ((new-arg (if has-digits (+ (* arg 10) d) d)))
                  (set! em-message (string-append "C-u " (number->string new-arg) "-"))
                  (em-render)
                  (loop (em-read-key) new-arg #t))))
            (if (equal? key "C-u")
                (begin
                  (let ((new-arg (* arg 4)))
                    (set! em-message (string-append "C-u " (number->string new-arg) "-"))
                    (em-render)
                    (loop (em-read-key) new-arg has-digits)))
                ;; Execute key arg times
                (let iloop ((i 0))
                  (when (< i arg)
                    (em-dispatch key)
                    (iloop (+ i 1))))))))))

;; ===== Dispatch =====
(define (em-dispatch key)
  ;; Record macro keys
  (when (and em-macro-recording
             (not (equal? key "C-x"))
             (not (equal? key "ESC")))
    (set! em-macro-keys (append em-macro-keys (list key))))
  (cond
    ;; C-x prefix
    ((equal? key "C-x") (em-cx-dispatch))
    ;; ESC/Meta prefix
    ((equal? key "ESC") (set! em-mode "esc-prefix"))
    ;; C-h prefix
    ((equal? key "C-h") (em-ch-dispatch))
    ;; Navigation
    ((or (equal? key "C-f") (equal? key "RIGHT"))  (em-forward-char))
    ((or (equal? key "C-b") (equal? key "LEFT"))   (em-backward-char))
    ((or (equal? key "C-n") (equal? key "DOWN"))   (em-next-line))
    ((or (equal? key "C-p") (equal? key "UP"))     (em-previous-line))
    ((or (equal? key "C-a") (equal? key "HOME"))   (em-beginning-of-line))
    ((or (equal? key "C-e") (equal? key "END"))    (em-end-of-line))
    ((or (equal? key "C-v") (equal? key "PGDN"))   (em-scroll-down))
    ((or (equal? key "M-v") (equal? key "PGUP"))   (em-scroll-up))
    ((equal? key "M-<")  (em-beginning-of-buffer))
    ((equal? key "M->")  (em-end-of-buffer))
    ;; Deletion
    ((or (equal? key "C-d") (equal? key "DEL"))    (em-delete-char))
    ((equal? key "BACKSPACE")                       (em-backward-delete-char))
    ;; Kill/yank
    ((equal? key "C-k")  (em-kill-line))
    ((equal? key "C-y")  (em-yank))
    ((equal? key "C-w")  (em-kill-region))
    ((equal? key "M-w")  (em-copy-region))
    ;; Mark
    ((or (equal? key "C-SPC") (equal? key "M- "))  (em-set-mark))
    ;; Misc
    ((equal? key "C-l")  (em-recenter))
    ((equal? key "C-g")  (em-keyboard-quit))
    ((equal? key "C-s")  (em-isearch-start 1))
    ((equal? key "C-r")  (em-isearch-start -1))
    ((equal? key "C-o")  (em-open-line))
    ((equal? key "C-m")  (em-newline))
    ((equal? key "C-j")  (em-eval-buffer))
    ((equal? key "C-t")  (em-transpose-chars))
    ((equal? key "C-_")  (em-undo))
    ((equal? key "C-z")  (em-suspend))
    ((equal? key "C-q")  (em-quoted-insert))
    ((equal? key "C-u")  (em-universal-argument))
    ((or (equal? key "C-i") (equal? key "TAB"))    (em-indent-line))
    ((equal? key "SHIFT-TAB")                       (em-dedent-line))
    ;; Word operations
    ((equal? key "M-f")  (em-forward-word))
    ((equal? key "M-b")  (em-backward-word))
    ((equal? key "M-d")  (em-kill-word))
    ((equal? key "M-DEL") (em-backward-kill-word))
    ;; Case conversion
    ((equal? key "M-u")  (em-upcase-word))
    ((equal? key "M-l")  (em-downcase-word))
    ((equal? key "M-c")  (em-capitalize-word))
    ;; Query replace / fill
    ((equal? key "M-%")  (em-minibuffer-start "Query replace: " "qr-from"))
    ((equal? key "M-q")  (em-fill-paragraph))
    ;; M-x extended commands
    ((equal? key "M-x")  (em-minibuffer-start "M-x " "mx-command"))
    ;; Self-insert
    ((and (> (string-length key) 5) (equal? (substr key 0 5) "SELF:"))
     (em-self-insert (substr key 5 (string-length key))))
    ;; Unknown / ignored
    ((or (equal? key "UNKNOWN") (equal? key "INS")) #f)
    (#t (set! em-message (string-append key " is undefined")))))

(define (em-cx-dispatch)
  (set! em-message "C-x-")
  (em-render)
  (let ((key (em-read-key)))
    ;; Record for macros (except macro start/stop)
    (when (and em-macro-recording
               (not (or (equal? key "SELF:(") (equal? key "SELF:)"))))
      (set! em-macro-keys (append em-macro-keys (list "C-x" key))))
    (cond
      ((equal? key "C-c") (em-do-quit))
      ((equal? key "C-s") (em-do-save))
      ((equal? key "C-f") (em-minibuffer-start "Find file: " "find-file"))
      ((equal? key "C-w") (em-minibuffer-start "Write file: " "write-file"))
      ((equal? key "C-x") (em-exchange-point-and-mark))
      ((equal? key "C-b") (em-list-buffers))
      ((or (equal? key "u") (equal? key "SELF:u")) (em-undo))
      ((or (equal? key "b") (equal? key "SELF:b"))
       (em-minibuffer-start "Switch to buffer: " "switch-buffer"))
      ((or (equal? key "k") (equal? key "SELF:k"))
       (em-minibuffer-start
         (string-append "Kill buffer (default " em-bufname "): ") "kill-buffer"))
      ((or (equal? key "h") (equal? key "SELF:h")) (em-mark-whole-buffer))
      ((or (equal? key "i") (equal? key "SELF:i"))
       (em-minibuffer-start "Insert file: " "insert-file"))
      ((or (equal? key "=") (equal? key "SELF:=")) (em-what-cursor-position))
      ((or (equal? key "r") (equal? key "SELF:r")) (em-cx-r-dispatch))
      ((or (equal? key "(") (equal? key "SELF:(")) (em-start-macro))
      ((or (equal? key ")") (equal? key "SELF:)")) (em-end-macro))
      ((or (equal? key "e") (equal? key "SELF:e")) (em-execute-macro))
      (#t (set! em-message (string-append "C-x " key " is undefined"))))))

(define (em-cx-r-dispatch)
  (set! em-message "C-x r-")
  (em-render)
  (let ((key (em-read-key)))
    (when em-macro-recording
      (set! em-macro-keys (append em-macro-keys (list "C-x" "r" key))))
    (cond
      ((or (equal? key "k") (equal? key "SELF:k")) (em-kill-rectangle))
      ((or (equal? key "y") (equal? key "SELF:y")) (em-yank-rectangle))
      ((or (equal? key "r") (equal? key "SELF:r")) (em-copy-rectangle))
      ((or (equal? key "d") (equal? key "SELF:d")) (em-delete-rectangle))
      ((or (equal? key "t") (equal? key "SELF:t")) (em-string-rectangle))
      ((or (equal? key "o") (equal? key "SELF:o")) (em-open-rectangle))
      (#t (set! em-message (string-append "C-x r " key " is undefined"))))))

(define (em-ch-dispatch)
  (set! em-message "C-h-")
  (em-render)
  (let ((key (em-read-key)))
    (cond
      ((or (equal? key "b") (equal? key "SELF:b")) (em-show-bindings))
      (#t (set! em-message (string-append "C-h " key ": no help available"))))))

(define (em-esc-dispatch key)
  (set! em-mode "normal")
  (let ((meta-key
         (if (and (> (string-length key) 5) (equal? (substr key 0 5) "SELF:"))
             (string-append "M-" (substr key 5 (string-length key)))
             (string-append "M-" key))))
    (em-dispatch meta-key)))

;; ===== Init / Handle Key =====
(define (em-init rows cols)
  (set! em-rows rows) (set! em-cols cols)
  ;; Create initial scratch buffer
  (em-new-buffer "*scratch*" "")
  ;; Detect clipboard
  (set! em-clip-copy
    (cond
      ((not (equal? (shell-capture "command -v xclip 2>/dev/null") #f))
       "xclip -selection clipboard")
      ((not (equal? (shell-capture "command -v xsel 2>/dev/null") #f))
       "xsel --clipboard --input")
      ((not (equal? (shell-capture "command -v pbcopy 2>/dev/null") #f))
       "pbcopy")
      (#t "")))
  (set! em-clip-paste
    (cond
      ((not (equal? em-clip-copy ""))
       (cond
         ((not (equal? (shell-capture "command -v xclip 2>/dev/null") #f))
          "xclip -selection clipboard -o")
         ((not (equal? (shell-capture "command -v xsel 2>/dev/null") #f))
          "xsel --clipboard --output")
         ((not (equal? (shell-capture "command -v pbpaste 2>/dev/null") #f))
          "pbpaste")
         (#t "")))
      (#t "")))
  (set! em-message "em: shemacs (C-x C-c to quit, C-h b for help)")
  (set! em-msg-persist 1)
  (set! em-mode "normal")
  (set! em-running #t)
  (em-render))

(define (em-handle-key key rows cols)
  (set! em-rows rows) (set! em-cols cols)
  (set! em-msg-persist 0)
  (cond
    ((equal? em-mode "isearch")      (em-isearch-handle-key key))
    ((equal? em-mode "minibuffer")   (em-minibuffer-handle-key key))
    ((equal? em-mode "query-replace")(em-qr-handle-key key))
    ((equal? em-mode "esc-prefix")  (em-esc-dispatch key))
    (#t (em-dispatch key)))
  (set! em-last-cmd key)
  (em-render))

;; ===== Key Reading =====
(define em-abc "abcdefghijklmnopqrstuvwxyz")

(define (em-read-key)
  (let ((b (read-byte)))
    (if (not b)
        (let ((b2 (read-byte)))
          (if (not b2) "QUIT"
              (em-read-key-byte b2)))
        (em-read-key-byte b))))

(define (em-read-key-byte byte)
  (cond
    ((= byte 0)  "C-SPC")
    ((= byte 27) (em-read-escape-seq))
    ((and (>= byte 1) (<= byte 26))
     (string-append "C-" (string (string-ref em-abc (- byte 1)))))
    ((= byte 127) "BACKSPACE")
    ((= byte 8)   "C-h")
    (#t (string-append "SELF:" (string (integer->char byte))))))

(define (em-read-escape-seq)
  (let ((b2 (read-byte-timeout "0.05")))
    (if (not b2)
        "ESC"
        (cond
          ((= b2 91) (em-read-csi))
          ((= b2 79) (em-read-ss3))
          ((or (= b2 127) (= b2 8)) "M-DEL")
          (#t (string-append "M-" (string (integer->char b2))))))))

(define (em-read-csi)
  (let ((b3 (read-byte-timeout "0.05")))
    (if (not b3)
        "UNKNOWN"
        (cond
          ((= b3 65) "UP")    ((= b3 66) "DOWN")
          ((= b3 67) "RIGHT") ((= b3 68) "LEFT")
          ((= b3 72) "HOME")  ((= b3 70) "END")
          ((= b3 90) "SHIFT-TAB")
          ((and (>= b3 48) (<= b3 57))
           (em-read-csi-num (string (integer->char b3))))
          (#t "UNKNOWN")))))

(define (em-read-csi-num seq)
  (let ((b (read-byte-timeout "0.05")))
    (if (not b)
        "UNKNOWN"
        (cond
          ((= b 126)
           (let ((full (string-append seq "~")))
             (cond
               ((equal? full "3~") "DEL")
               ((equal? full "5~") "PGUP")
               ((equal? full "6~") "PGDN")
               ((equal? full "2~") "INS")
               ((equal? full "1~") "HOME")
               ((equal? full "4~") "END")
               (#t "UNKNOWN"))))
          ((or (and (>= b 65) (<= b 90)) (and (>= b 97) (<= b 122)))
           "UNKNOWN")
          (#t (em-read-csi-num (string-append seq (string (integer->char b)))))))))

(define (em-read-ss3)
  (let ((b3 (read-byte-timeout "0.05")))
    (if (not b3)
        "UNKNOWN"
        (cond
          ((= b3 65) "UP")    ((= b3 66) "DOWN")
          ((= b3 67) "RIGHT") ((= b3 68) "LEFT")
          ((= b3 72) "HOME")  ((= b3 70) "END")
          (#t "UNKNOWN")))))

;; ===== Main Entry Point =====
(define (em-main filename)
  (terminal-raw!)
  (write-stdout (string-append ESC "[?1049h" ESC "[?25h"))
  (let ((size (terminal-size)))
    (em-init (car size) (cdr size)))
  ;; Load file if provided
  (when (not (equal? filename ""))
    (if (em-load-file filename)
        (em-buf-update-name filename filename)
        (begin
          (set! em-filename filename)
          (set! em-bufname filename)
          (em-buf-update-name filename filename)
          (set! em-message (string-append "(New file) " filename))
          (set! em-msg-persist 1))))
  (em-render)
  ;; Main loop
  (let loop ()
    (when em-running
      (let* ((size (terminal-size))
             (key (em-read-key)))
        (unless (equal? key "QUIT")
          (em-handle-key key (car size) (cdr size))
          (loop)))))
  ;; Cleanup
  (write-stdout (string-append ESC "[0m" ESC "[?25h" ESC "[?1049l"))
  (terminal-restore!))
