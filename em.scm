;; em.scm - shemacs: an Emacs-like editor in Scheme (runs on sheme)
;;
;; Standalone editor — all I/O handled via sheme builtins.
;; The bash launcher (em.sh) just sources bs.sh, loads this file,
;; and calls (em-main "filename").
;;
;; Public API:
;;   (em-main filename)          - launch the editor
;;   (em-init rows cols)         - initialize editor state
;;   (em-handle-key key rows cols) - process one keystroke
;;   (em-load-content lines-str) - load file content (newline-separated)

;; ===== ANSI helpers =====
(define ESC (string (integer->char 27)))
(define (ansi . parts) (apply string-append ESC parts))

;; ===== Editor state =====
;; Lines stored as a vector of strings for O(1) access
(define em-lines (vector ""))
(define em-nlines 1)
(define em-cy 0)
(define em-cx 0)
(define em-top 0)
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
;; Running state
(define em-running #t)

;; ===== Vector-based line storage =====
;; Lines stored as a vector of strings for O(1) access (vector-ref/vector-set!).
;; Insert/remove create new vectors (O(n)) but the common case is O(1).

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

;; list-take and list-drop are still used for undo-stack and kill-ring
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
          (substring s
            (max 0 start)
            (min end (string-length s))))))

(define (string-repeat s n)
  (if (<= n 0) ""
      (string-append s (string-repeat s (- n 1)))))

(define (number->string-simple n)
  (number->string n))

(define (char-word? ch)
  (or (char-alphabetic? ch) (char-numeric? ch) (char=? ch #\_)))

(define (char-upcase ch)
  (let ((n (char->integer ch)))
    (if (and (>= n 97) (<= n 122))
        (integer->char (- n 32))
        ch)))

(define (char-downcase ch)
  (let ((n (char->integer ch)))
    (if (and (>= n 65) (<= n 90))
        (integer->char (+ n 32))
        ch)))

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

;; ===== Ensure cursor visible =====
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
    (if (< em-top 0) (set! em-top 0) #f)))

;; ===== Undo system =====
;; Each undo record is a list: (type arg1 arg2 ...)
(define (em-undo-push record)
  (set! em-undo-stack (cons record em-undo-stack))
  (if (> (length em-undo-stack) 200)
      (set! em-undo-stack (list-take em-undo-stack 200))
      #f))

(define (em-undo)
  (if (null? em-undo-stack)
      (set! em-message "No further undo information")
      (let ((record (car em-undo-stack)))
        (set! em-undo-stack (cdr em-undo-stack))
        (let ((type (car record)))
          (cond
            ((equal? type "insert_char")
             (let* ((y (list-ref record 1))
                    (x (list-ref record 2))
                    (ch (list-ref record 3))
                    (line (vector-ref-safe em-lines y)))
               (vector-set! em-lines y
                 (string-append (substr line 0 x) ch (substr line x (string-length line))))
               (set! em-cy y)
               (set! em-cx x)))
            ((equal? type "delete_char")
             (let* ((y (list-ref record 1))
                    (x (list-ref record 2))
                    (line (vector-ref-safe em-lines y)))
               (vector-set! em-lines y
                 (string-append (substr line 0 x) (substr line (+ x 1) (string-length line))))
               (set! em-cy y)
               (set! em-cx x)))
            ((equal? type "join_lines")
             (let* ((y (list-ref record 1))
                    (x (list-ref record 2))
                    (line (vector-ref-safe em-lines y)))
               (vector-set! em-lines y (substr line 0 x))
               (set! em-lines (vector-insert em-lines (+ y 1) (substr line x (string-length line))))
               (set! em-nlines (+ em-nlines 1))
               (set! em-cy y)
               (set! em-cx x)))
            ((equal? type "split_line")
             (let* ((y (list-ref record 1))
                    (x (list-ref record 2))
                    (line (vector-ref-safe em-lines y))
                    (next (vector-ref-safe em-lines (+ y 1))))
               (vector-set! em-lines y (string-append line next))
               (set! em-lines (vector-remove em-lines (+ y 1)))
               (set! em-nlines (- em-nlines 1))
               (set! em-cy y)
               (set! em-cx x)))
            ((equal? type "replace_line")
             (let* ((y (list-ref record 1))
                    (x (list-ref record 2))
                    (old-line (list-ref record 3)))
               (vector-set! em-lines y old-line)
               (set! em-cy y)
               (set! em-cx x)))
            (#t #f)))
        (set! em-modified 1)
        (em-ensure-visible)
        (set! em-message "Undo!"))))

;; ===== Render =====
(define (em-render)
  (let* ((visible (- em-rows 2))
         (parts '()))
    ;; Helper to accumulate string parts (prepends, reversed at end)
    (define (emit s) (set! parts (cons s parts)))

    ;; Hide cursor
    (emit (ansi "[?25l"))

    ;; Render each visible line
    (let loop ((screen-row 1))
      (if (> screen-row visible) #f
          (let ((i (+ em-top (- screen-row 1))))
            (emit (ansi "[" (number->string screen-row) ";1H"))
            (if (< i em-nlines)
                (let* ((line (vector-ref-safe em-lines i))
                       (display (expand-tabs line))
                       (display (if (> (string-length display) em-cols)
                                    (substr display 0 em-cols)
                                    display))
                       (dlen (string-length display))
                       (display (if (< dlen em-cols)
                                    (string-append display (string-repeat " " (- em-cols dlen)))
                                    display)))
                  ;; Isearch highlighting
                  (if (and (equal? em-mode "isearch")
                           (>= em-isearch-y 0)
                           (= i em-isearch-y)
                           (> em-isearch-len 0))
                      (let* ((mhs (col-to-display line em-isearch-x))
                             (mhe (col-to-display line (+ em-isearch-x em-isearch-len)))
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
                      ;; Region highlighting
                      (if (and (>= em-mark-y 0)
                               (not (and (= em-mark-y em-cy) (= em-mark-x em-cx)))
                               (let ((sy (min em-mark-y em-cy))
                                     (ey (max em-mark-y em-cy)))
                                 (and (>= i sy) (<= i ey))))
                          (let* ((sy (min em-mark-y em-cy))
                                 (sx (if (or (< em-mark-y em-cy)
                                            (and (= em-mark-y em-cy) (< em-mark-x em-cx)))
                                         em-mark-x em-cx))
                                 (ey (max em-mark-y em-cy))
                                 (ex (if (or (> em-mark-y em-cy)
                                            (and (= em-mark-y em-cy) (> em-mark-x em-cx)))
                                         em-mark-x em-cx))
                                 (hs (if (= i sy) (col-to-display line sx) 0))
                                 (he (if (= i ey) (col-to-display line ex) (string-length display)))
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
                ;; Empty line (past end of buffer)
                (emit (ansi "[K")))
            (loop (+ screen-row 1)))))

    ;; Status line
    (let* ((status-row (- em-rows 1))
           (mod-flag (if (= em-modified 0) "--" "**"))
           (total em-nlines)
           (pct (if (<= total visible) "All"
                    (if (= em-top 0) "Top"
                        (if (>= (+ em-top visible) total) "Bot"
                            (string-append
                              (number->string (quotient (* em-top 100)
                                               (max 1 (- total visible))))
                              "%")))))
           (status (string-append "-UUU:" mod-flag "-  "
                     em-bufname
                     (string-repeat " " (max 1 (- 22 (string-length em-bufname))))
                     "(Fundamental) L"
                     (number->string (+ em-cy 1))
                     (string-repeat " " 6)
                     pct))
           (slen (string-length status))
           (status (if (< slen em-cols)
                       (string-append status (string-repeat "-" (- em-cols slen)))
                       (substr status 0 em-cols))))
      (emit (ansi "[" (number->string status-row) ";1H"))
      (emit (ansi "[7m"))
      (emit status)
      (emit (ansi "[0m")))

    ;; Message line
    (let ((msg-row em-rows))
      (emit (ansi "[" (number->string msg-row) ";1H"))
      (emit (ansi "[K"))
      (cond
        ((equal? em-mode "isearch")
         (emit (string-append (if (= em-isearch-dir 1) "I-search: " "I-search backward: ")
                              em-isearch-str)))
        ((equal? em-mode "minibuffer")
         (emit (string-append em-mb-prompt em-mb-input)))
        (#t
         (if (not (equal? em-message ""))
             (begin
               (emit (substr em-message 0 em-cols))
               (if (= em-msg-persist 0)
                   (set! em-message "")
                   #f))
             #f))))

    ;; Position cursor
    (let* ((screen-cy (+ (- em-cy em-top) 1))
           (screen-cx (+ (col-to-display (vector-ref-safe em-lines em-cy) em-cx) 1)))
      (emit (ansi "[" (number->string screen-cy) ";" (number->string screen-cx) "H")))

    ;; Show cursor
    (emit (ansi "[?25h"))

    ;; Write render output directly to terminal
    (write-stdout (apply string-append (reverse parts)))))

;; ===== Movement =====

(define (em-forward-char)
  (let ((line-len (string-length (vector-ref-safe em-lines em-cy))))
    (if (< em-cx line-len)
        (set! em-cx (+ em-cx 1))
        (if (< em-cy (- em-nlines 1))
            (begin (set! em-cy (+ em-cy 1)) (set! em-cx 0))
            #f)))
  (set! em-goal-col -1)
  (em-ensure-visible))

(define (em-backward-char)
  (if (> em-cx 0)
      (set! em-cx (- em-cx 1))
      (if (> em-cy 0)
          (begin
            (set! em-cy (- em-cy 1))
            (set! em-cx (string-length (vector-ref-safe em-lines em-cy))))
          #f))
  (set! em-goal-col -1)
  (em-ensure-visible))

(define (em-next-line)
  (if (< em-cy (- em-nlines 1))
      (begin
        (if (< em-goal-col 0) (set! em-goal-col em-cx) #f)
        (set! em-cy (+ em-cy 1))
        (let ((line-len (string-length (vector-ref-safe em-lines em-cy))))
          (set! em-cx em-goal-col)
          (if (> em-cx line-len) (set! em-cx line-len) #f)))
      #f)
  (em-ensure-visible))

(define (em-previous-line)
  (if (> em-cy 0)
      (begin
        (if (< em-goal-col 0) (set! em-goal-col em-cx) #f)
        (set! em-cy (- em-cy 1))
        (let ((line-len (string-length (vector-ref-safe em-lines em-cy))))
          (set! em-cx em-goal-col)
          (if (> em-cx line-len) (set! em-cx line-len) #f)))
      #f)
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
  (let* ((visible (- em-rows 2))
         (page (max 1 (- visible 2))))
    (set! em-top (+ em-top page))
    (set! em-cy (+ em-cy page))
    (set! em-goal-col -1)
    (em-ensure-visible)))

(define (em-scroll-up)
  (let* ((visible (- em-rows 2))
         (page (max 1 (- visible 2))))
    (set! em-top (max 0 (- em-top page)))
    (set! em-cy (- em-cy page))
    (set! em-goal-col -1)
    (em-ensure-visible)))

(define (em-recenter)
  (let ((visible (- em-rows 2)))
    (set! em-top (max 0 (- em-cy (quotient visible 2))))))

;; ===== Basic editing =====

(define (em-self-insert ch)
  (let ((line (vector-ref-safe em-lines em-cy)))
    (em-undo-push (list "delete_char" em-cy em-cx))
    (vector-set! em-lines em-cy
      (string-append (substr line 0 em-cx) ch (substr line em-cx (string-length line))))
    (set! em-cx (+ em-cx 1))
    (set! em-modified 1)
    (set! em-goal-col -1)))

(define (em-newline)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (before (substr line 0 em-cx))
         (after (substr line em-cx (string-length line))))
    (em-undo-push (list "split_line" em-cy em-cx))
    (vector-set! em-lines em-cy before)
    (set! em-lines (vector-insert em-lines (+ em-cy 1) after))
    (set! em-cy (+ em-cy 1))
    (set! em-cx 0)
    (set! em-nlines (vector-length em-lines))
    (set! em-modified 1)
    (set! em-goal-col -1)
    (em-ensure-visible)))

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
        (if (< em-cy (- em-nlines 1))
            (let ((next (vector-ref-safe em-lines (+ em-cy 1))))
              (em-undo-push (list "join_lines" em-cy em-cx))
              (vector-set! em-lines em-cy (string-append line next))
              (set! em-lines (vector-remove em-lines (+ em-cy 1)))
              (set! em-nlines (- em-nlines 1))
              (set! em-modified 1))
            #f)))
  (set! em-goal-col -1))

(define (em-backward-delete-char)
  (if (> em-cx 0)
      (begin (set! em-cx (- em-cx 1)) (em-delete-char))
      (if (> em-cy 0)
          (begin
            (set! em-cy (- em-cy 1))
            (set! em-cx (string-length (vector-ref-safe em-lines em-cy)))
            (em-delete-char))
          #f))
  (set! em-goal-col -1)
  (em-ensure-visible))

;; ===== Kill / Yank =====

(define (em-kill-line)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (line-len (string-length line)))
    (if (< em-cx line-len)
        (let ((killed (substr line em-cx line-len)))
          (em-undo-push (list "replace_line" em-cy em-cx line))
          (vector-set! em-lines em-cy (substr line 0 em-cx))
          (if (equal? em-last-cmd "C-k")
              (set! em-kill-ring (cons (string-append (car em-kill-ring) killed) (cdr em-kill-ring)))
              (set! em-kill-ring (cons killed em-kill-ring))))
        (if (< em-cy (- em-nlines 1))
            (let ((next (vector-ref-safe em-lines (+ em-cy 1))))
              (em-undo-push (list "join_lines" em-cy em-cx))
              (vector-set! em-lines em-cy (string-append line next))
              (set! em-lines (vector-remove em-lines (+ em-cy 1)))
              (set! em-nlines (- em-nlines 1))
              (let ((killed "\n"))
                (if (equal? em-last-cmd "C-k")
                    (set! em-kill-ring (cons (string-append (car em-kill-ring) killed) (cdr em-kill-ring)))
                    (set! em-kill-ring (cons killed em-kill-ring)))))
            #f))
    (if (> (length em-kill-ring) 60)
        (set! em-kill-ring (list-take em-kill-ring 60))
        #f)
    (set! em-modified 1)
    (set! em-goal-col -1)))

(define (em-yank)
  (if (null? em-kill-ring)
      (set! em-message "Kill ring is empty")
      (let ((text (car em-kill-ring)))
        (set! em-mark-y em-cy)
        (set! em-mark-x em-cx)
        ;; Split text on newlines
        (let ((save-cy em-cy) (save-cx em-cx)
              (save-line (vector-ref-safe em-lines em-cy)))
          ;; Simple case: no newlines
          (if (not (em-string-contains text "\n"))
              (let ((line (vector-ref-safe em-lines em-cy)))
                (em-undo-push (list "replace_line" save-cy save-cx save-line))
                (vector-set! em-lines em-cy
                  (string-append (substr line 0 em-cx) text (substr line em-cx (string-length line))))
                (set! em-cx (+ em-cx (string-length text))))
              ;; Multi-line yank
              (let* ((yank-lines (em-string-split text "\n"))
                     (nparts (length yank-lines))
                     (line (vector-ref-safe em-lines em-cy))
                     (before (substr line 0 em-cx))
                     (after (substr line em-cx (string-length line)))
                     (first-part (car yank-lines))
                     (last-part (list-ref yank-lines (- nparts 1))))
                (em-undo-push (list "replace_line" save-cy save-cx save-line))
                (vector-set! em-lines em-cy (string-append before first-part))
                (let loop ((i 1) (ylines (cdr yank-lines)))
                  (if (null? ylines) #f
                      (if (null? (cdr ylines))
                          ;; Last part
                          (begin
                            (set! em-lines (vector-insert em-lines (+ em-cy i)
                              (string-append (car ylines) after)))
                            (set! em-cy (+ em-cy i))
                            (set! em-cx (string-length (car ylines))))
                          (begin
                            (set! em-lines (vector-insert em-lines (+ em-cy i) (car ylines)))
                            (loop (+ i 1) (cdr ylines))))))
                (set! em-nlines (vector-length em-lines))))
          (set! em-modified 1)
          (set! em-goal-col -1)
          (em-ensure-visible)))))

;; String helper: check if str contains sub
(define (em-string-contains str sub)
  (let ((slen (string-length str))
        (sublen (string-length sub)))
    (if (> sublen slen) #f
        (let loop ((i 0))
          (if (> i (- slen sublen)) #f
              (if (equal? (substr str i (+ i sublen)) sub) #t
                  (loop (+ i 1))))))))

;; String helper: split str by sep (single char separator)
(define (em-string-split str sep)
  (let ((slen (string-length str))
        (seplen (string-length sep)))
    (let loop ((i 0) (start 0) (parts '()))
      (if (>= i slen)
          (reverse (cons (substr str start slen) parts))
          (if (equal? (substr str i (+ i seplen)) sep)
              (loop (+ i seplen) (+ i seplen)
                    (cons (substr str start i) parts))
              (loop (+ i 1) start parts))))))

;; ===== Mark / Region =====

(define (em-set-mark)
  (set! em-mark-y em-cy)
  (set! em-mark-x em-cx)
  (set! em-message "Mark set"))

(define (em-keyboard-quit)
  (set! em-mark-y -1) (set! em-mark-x -1)
  (set! em-mode "normal")
  (set! em-message "Quit"))

(define (em-kill-region)
  (if (< em-mark-y 0)
      (set! em-message "The mark is not set now")
      (let* ((sy em-mark-y) (sx em-mark-x) (ey em-cy) (ex em-cx))
        ;; Normalize: sy/sx <= ey/ex
        (if (or (> sy ey) (and (= sy ey) (> sx ex)))
            (begin
              (let ((t sy)) (set! sy ey) (set! ey t))
              (let ((t sx)) (set! sx ex) (set! ex t)))
            #f)
        ;; Extract region text
        (let ((killed (em-extract-region sy sx ey ex)))
          (set! em-kill-ring (cons killed em-kill-ring))
          ;; Delete region
          (em-delete-region sy sx ey ex)
          (set! em-cy sy) (set! em-cx sx)
          (set! em-mark-y -1) (set! em-mark-x -1)
          (set! em-modified 1)
          (set! em-goal-col -1)
          (em-ensure-visible)))))

(define (em-copy-region)
  (if (< em-mark-y 0)
      (set! em-message "The mark is not set now")
      (let* ((sy em-mark-y) (sx em-mark-x) (ey em-cy) (ex em-cx))
        (if (or (> sy ey) (and (= sy ey) (> sx ex)))
            (begin
              (let ((t sy)) (set! sy ey) (set! ey t))
              (let ((t sx)) (set! sx ex) (set! ex t)))
            #f)
        (let ((copied (em-extract-region sy sx ey ex)))
          (set! em-kill-ring (cons copied em-kill-ring))
          (set! em-mark-y -1) (set! em-mark-x -1)
          (set! em-message "Region copied")))))

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
              (if (< i ey)
                  (loop (+ i 1) (cons (string-append part "\n") parts))
                  (loop (+ i 1) (cons part parts))))))))

(define (em-delete-region sy sx ey ex)
  (let* ((first-line (vector-ref-safe em-lines sy))
         (last-line (vector-ref-safe em-lines ey))
         (new-line (string-append (substr first-line 0 sx)
                                  (substr last-line ex (string-length last-line)))))
    ;; Remove lines from ey down to sy+1, then set sy
    (let loop ((i ey))
      (if (<= i sy) #f
          (begin (set! em-lines (vector-remove em-lines i))
                 (loop (- i 1)))))
    (vector-set! em-lines sy new-line)
    (set! em-nlines (vector-length em-lines))))

;; ===== Word operations =====

(define (em-forward-word)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (len (string-length line)))
    ;; Skip non-word chars
    (let loop ()
      (if (>= em-cx len)
          (if (< em-cy (- em-nlines 1))
              (begin (set! em-cy (+ em-cy 1)) (set! em-cx 0)
                     (set! line (vector-ref-safe em-lines em-cy))
                     (set! len (string-length line))
                     (loop))
              #f)
          (if (not (char-word? (string-ref line em-cx)))
              (begin (set! em-cx (+ em-cx 1)) (loop))
              #f)))
    ;; Skip word chars
    (set! line (vector-ref-safe em-lines em-cy))
    (set! len (string-length line))
    (let loop ()
      (if (< em-cx len)
          (if (char-word? (string-ref line em-cx))
              (begin (set! em-cx (+ em-cx 1)) (loop))
              #f)
          #f)))
  (set! em-goal-col -1)
  (em-ensure-visible))

(define (em-backward-word)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (len (string-length line)))
    ;; Skip non-word chars backward
    (let loop ()
      (if (<= em-cx 0)
          (if (> em-cy 0)
              (begin (set! em-cy (- em-cy 1))
                     (set! line (vector-ref-safe em-lines em-cy))
                     (set! len (string-length line))
                     (set! em-cx len)
                     (loop))
              #f)
          (if (not (char-word? (string-ref line (- em-cx 1))))
              (begin (set! em-cx (- em-cx 1)) (loop))
              #f)))
    ;; Skip word chars backward
    (set! line (vector-ref-safe em-lines em-cy))
    (let loop ()
      (if (> em-cx 0)
          (if (char-word? (string-ref line (- em-cx 1)))
              (begin (set! em-cx (- em-cx 1)) (loop))
              #f)
          #f)))
  (set! em-goal-col -1)
  (em-ensure-visible))

(define (em-kill-word)
  (set! em-mark-y em-cy) (set! em-mark-x em-cx)
  (em-forward-word)
  (em-kill-region))

(define (em-backward-kill-word)
  (set! em-mark-y em-cy) (set! em-mark-x em-cx)
  (em-backward-word)
  (em-kill-region))

;; ===== Case conversion =====

(define (em-upcase-word)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (len (string-length line))
         (cx em-cx))
    (if (>= cx len) #f
        (begin
          (em-undo-push (list "replace_line" em-cy em-cx line))
          ;; Skip non-word chars
          (let loop ()
            (if (< cx len)
                (if (not (char-word? (string-ref line cx)))
                    (begin (set! cx (+ cx 1)) (loop))
                    #f)
                #f))
          ;; Upcase word chars
          (let loop ()
            (if (< cx len)
                (if (char-word? (string-ref line cx))
                    (begin
                      (set! line (string-append
                        (substr line 0 cx)
                        (string (char-upcase (string-ref line cx)))
                        (substr line (+ cx 1) len)))
                      (set! cx (+ cx 1))
                      (loop))
                    #f)
                #f))
          (vector-set! em-lines em-cy line)
          (set! em-cx cx)
          (set! em-modified 1)
          (set! em-goal-col -1)))))

(define (em-downcase-word)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (len (string-length line))
         (cx em-cx))
    (if (>= cx len) #f
        (begin
          (em-undo-push (list "replace_line" em-cy em-cx line))
          (let loop ()
            (if (< cx len)
                (if (not (char-word? (string-ref line cx)))
                    (begin (set! cx (+ cx 1)) (loop))
                    #f)
                #f))
          (let loop ()
            (if (< cx len)
                (if (char-word? (string-ref line cx))
                    (begin
                      (set! line (string-append
                        (substr line 0 cx)
                        (string (char-downcase (string-ref line cx)))
                        (substr line (+ cx 1) len)))
                      (set! cx (+ cx 1))
                      (loop))
                    #f)
                #f))
          (vector-set! em-lines em-cy line)
          (set! em-cx cx)
          (set! em-modified 1)
          (set! em-goal-col -1)))))

(define (em-capitalize-word)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (len (string-length line))
         (cx em-cx))
    (if (>= cx len) #f
        (begin
          (em-undo-push (list "replace_line" em-cy em-cx line))
          ;; Skip non-word chars
          (let loop ()
            (if (< cx len)
                (if (not (char-word? (string-ref line cx)))
                    (begin (set! cx (+ cx 1)) (loop))
                    #f)
                #f))
          ;; Upcase first, then downcase rest
          (if (< cx len)
              (begin
                (set! line (string-append
                  (substr line 0 cx)
                  (string (char-upcase (string-ref line cx)))
                  (substr line (+ cx 1) len)))
                (set! cx (+ cx 1)))
              #f)
          (let loop ()
            (if (< cx len)
                (if (char-word? (string-ref line cx))
                    (begin
                      (set! line (string-append
                        (substr line 0 cx)
                        (string (char-downcase (string-ref line cx)))
                        (substr line (+ cx 1) len)))
                      (set! cx (+ cx 1))
                      (loop))
                    #f)
                #f))
          (vector-set! em-lines em-cy line)
          (set! em-cx cx)
          (set! em-modified 1)
          (set! em-goal-col -1)))))

(define (em-transpose-chars)
  (let* ((line (vector-ref-safe em-lines em-cy))
         (len (string-length line)))
    (if (>= len 2)
        (let* ((cx (if (>= em-cx len) (- len 1) em-cx))
               (cx (if (<= cx 0) 1 cx))
               (ch1 (substr line (- cx 1) cx))
               (ch2 (substr line cx (+ cx 1))))
          (em-undo-push (list "replace_line" em-cy em-cx line))
          (vector-set! em-lines em-cy
            (string-append (substr line 0 (- cx 1)) ch2 ch1 (substr line (+ cx 1) len)))
          (set! em-cx (min (+ cx 1) len))
          (set! em-modified 1)
          (set! em-goal-col -1))
        #f)))

;; ===== Isearch =====

(define (em-isearch-start dir)
  (set! em-mode "isearch")
  (set! em-isearch-str "")
  (set! em-isearch-dir dir)
  (set! em-isearch-y -1)
  (set! em-isearch-x -1)
  (set! em-isearch-len 0)
  (set! em-isearch-saved-cy em-cy)
  (set! em-isearch-saved-cx em-cx)
  (set! em-isearch-saved-top em-top))

(define (em-isearch-do)
  ;; Search for em-isearch-str in the buffer
  (if (equal? em-isearch-str "")
      (begin (set! em-isearch-y -1) (set! em-isearch-len 0))
      (let ((found #f)
            (slen (string-length em-isearch-str)))
        (if (= em-isearch-dir 1)
            ;; Forward search from current position
            (let loop ((y em-cy) (start-x em-cx))
              (if (or found (>= y em-nlines)) #f
                  (let* ((line (vector-ref-safe em-lines y))
                         (pos (em-string-find line em-isearch-str start-x)))
                    (if (>= pos 0)
                        (begin
                          (set! found #t)
                          (set! em-isearch-y y)
                          (set! em-isearch-x pos)
                          (set! em-isearch-len slen)
                          (set! em-cy y)
                          (set! em-cx pos))
                        (loop (+ y 1) 0)))))
            ;; Backward search
            (let loop ((y em-cy) (start-x (- em-cx 1)))
              (if (or found (< y 0)) #f
                  (let* ((line (vector-ref-safe em-lines y))
                         (pos (em-string-rfind line em-isearch-str start-x)))
                    (if (>= pos 0)
                        (begin
                          (set! found #t)
                          (set! em-isearch-y y)
                          (set! em-isearch-x pos)
                          (set! em-isearch-len slen)
                          (set! em-cy y)
                          (set! em-cx pos))
                        (loop (- y 1) 99999))))))
        (if (not found)
            (begin (set! em-isearch-y -1) (set! em-isearch-len 0))
            #f)
        (em-ensure-visible))))

;; Find substring in line starting at pos
(define (em-string-find line sub start)
  (let ((llen (string-length line))
        (slen (string-length sub)))
    (if (> slen llen) -1
        (let loop ((i (max 0 start)))
          (if (> i (- llen slen)) -1
              (if (equal? (substr line i (+ i slen)) sub) i
                  (loop (+ i 1))))))))

;; Find substring in line from right, starting at pos
(define (em-string-rfind line sub start)
  (let ((llen (string-length line))
        (slen (string-length sub)))
    (if (> slen llen) -1
        (let loop ((i (min start (- llen slen))))
          (if (< i 0) -1
              (if (equal? (substr line i (+ i slen)) sub) i
                  (loop (- i 1))))))))

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
     ;; Cancel: restore position
     (set! em-cy em-isearch-saved-cy)
     (set! em-cx em-isearch-saved-cx)
     (set! em-top em-isearch-saved-top)
     (set! em-mode "normal")
     (set! em-message "Quit"))
    ((equal? key "BACKSPACE")
     (if (> (string-length em-isearch-str) 0)
         (begin
           (set! em-isearch-str
             (substr em-isearch-str 0 (- (string-length em-isearch-str) 1)))
           (set! em-cy em-isearch-saved-cy)
           (set! em-cx em-isearch-saved-cx)
           (em-isearch-do))
         (begin
           (set! em-mode "normal")
           (set! em-message ""))))
    ((equal? key "C-m")
     ;; Accept search
     (set! em-mode "normal")
     (set! em-message ""))
    ;; Self-insert character
    ((and (> (string-length key) 5) (equal? (substr key 0 5) "SELF:"))
     (set! em-isearch-str (string-append em-isearch-str (substr key 5 (string-length key))))
     (em-isearch-do))
    ;; Any other key: exit isearch and dispatch normally
    (#t
     (set! em-mode "normal")
     (em-dispatch key))))

;; ===== Minibuffer =====

(define (em-minibuffer-start prompt callback)
  (set! em-mode "minibuffer")
  (set! em-mb-prompt prompt)
  (set! em-mb-input "")
  (set! em-mb-callback callback))

(define (em-minibuffer-handle-key key)
  (cond
    ((equal? key "C-g")
     (set! em-mode "normal")
     (set! em-message "Quit"))
    ((equal? key "C-m")
     ;; Accept input
     (let ((result em-mb-input)
           (callback em-mb-callback))
       (set! em-mode "normal")
       (cond
         ((equal? callback "save-as")
          (set! em-filename result)
          (set! em-bufname result)
          (if (file-write result (em-build-save-data))
              (begin
                (set! em-modified 0)
                (set! em-message (string-append "Wrote " (number->string em-nlines) " lines to " result)))
              (set! em-message "Error writing file")))
         ((equal? callback "quit-confirm")
          (if (equal? result "yes")
              (set! em-running #f)
              (set! em-message "Cancelled")))
         ((equal? callback "mx-command")
          (cond
            ((equal? result "eval-buffer") (em-eval-buffer))
            (#t (set! em-message (string-append "[No match] " result)))))
         (#t (set! em-message "")))))
    ((equal? key "BACKSPACE")
     (if (> (string-length em-mb-input) 0)
         (set! em-mb-input (substr em-mb-input 0 (- (string-length em-mb-input) 1)))
         #f))
    ((and (> (string-length key) 5) (equal? (substr key 0 5) "SELF:"))
     (set! em-mb-input (string-append em-mb-input (substr key 5 (string-length key)))))
    (#t #f)))

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
      (if (file-write em-filename (em-build-save-data))
          (begin
            (set! em-modified 0)
            (set! em-message (string-append "Wrote " (number->string em-nlines) " lines to " em-filename)))
          (set! em-message "Error writing file"))))

(define (em-do-quit)
  (if (and (= em-modified 1) (not (equal? em-bufname "*scratch*")))
      (em-minibuffer-start "Modified buffer not saved; exit anyway? (yes or no) " "quit-confirm")
      (set! em-running #f)))

(define (em-eval-buffer)
  (let ((result (eval-string (em-build-save-data))))
    (if (car result)
        (begin
          (set! em-message (string-append "Eval: " (cdr result)))
          (set! em-msg-persist 1))
        (begin
          (set! em-message (string-append "Eval error: " (cdr result)))
          (set! em-msg-persist 1)))))

;; ===== Load content =====
(define (em-load-content lines-str)
  (if (equal? lines-str "")
      (begin (set! em-lines (vector "")) (set! em-nlines 1))
      (begin
        (set! em-lines (list->vector (em-string-split lines-str "\n")))
        (set! em-nlines (vector-length em-lines))
        ;; Remove trailing empty if file ended with newline
        (if (and (> em-nlines 1)
                 (equal? (vector-ref-safe em-lines (- em-nlines 1)) ""))
            (let ((new-vec (make-vector (- em-nlines 1) "")))
              (do ((i 0 (+ i 1))) ((= i (- em-nlines 1)))
                (vector-set! new-vec i (vector-ref em-lines i)))
              (set! em-lines new-vec)
              (set! em-nlines (- em-nlines 1)))
            #f)))
  (set! em-cy 0) (set! em-cx 0) (set! em-top 0)
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

;; ===== Dispatch =====

(define (em-dispatch key)
  (cond
    ;; C-x prefix
    ((equal? key "C-x")
     (set! em-mode "cx-prefix")
     (set! em-message "C-x -"))
    ;; ESC prefix (bare ESC without timeout → read next key as meta)
    ((equal? key "ESC")
     (set! em-mode "esc-prefix"))
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
    ;; Word operations
    ((equal? key "M-f")  (em-forward-word))
    ((equal? key "M-b")  (em-backward-word))
    ((equal? key "M-d")  (em-kill-word))
    ((equal? key "M-DEL") (em-backward-kill-word))
    ;; Case conversion
    ((equal? key "M-u")  (em-upcase-word))
    ((equal? key "M-l")  (em-downcase-word))
    ((equal? key "M-c")  (em-capitalize-word))
    ;; M-x extended commands
    ((equal? key "M-x")
     (em-minibuffer-start "M-x " "mx-command"))
    ;; Self-insert
    ((and (> (string-length key) 5) (equal? (substr key 0 5) "SELF:"))
     (em-self-insert (substr key 5 (string-length key))))
    ;; Unknown
    ((or (equal? key "UNKNOWN") (equal? key "INS")) #f)
    (#t (set! em-message (string-append key " is undefined")))))

(define (em-cx-dispatch key)
  (set! em-mode "normal")
  (cond
    ((equal? key "C-c") (set! em-message "C-x C-c") (em-do-quit))
    ((equal? key "C-s") (em-do-save))
    ((or (equal? key "u") (equal? key "SELF:u")) (em-undo))
    ((or (equal? key "h") (equal? key "SELF:h"))
     (set! em-mark-y 0) (set! em-mark-x 0)
     (set! em-cy (- em-nlines 1))
     (set! em-cx (string-length (vector-ref-safe em-lines (- em-nlines 1))))
     (set! em-goal-col -1) (em-ensure-visible)
     (set! em-message "Mark set"))
    ((equal? key "C-x")
     (if (>= em-mark-y 0)
         (let ((ty em-cy) (tx em-cx))
           (set! em-cy em-mark-y) (set! em-cx em-mark-x)
           (set! em-mark-y ty) (set! em-mark-x tx)
           (set! em-goal-col -1) (em-ensure-visible))
         (set! em-message "No mark set in this buffer")))
    (#t (set! em-message (string-append "C-x " key " is undefined")))))

(define (em-esc-dispatch key)
  ;; Convert key to meta equivalent
  (set! em-mode "normal")
  (let ((meta-key
         (cond
           ((and (> (string-length key) 5) (equal? (substr key 0 5) "SELF:"))
            (string-append "M-" (substr key 5 (string-length key))))
           (#t (string-append "M-" key)))))
    (em-dispatch meta-key)))

;; ===== Main entry points =====

(define (em-init rows cols)
  (set! em-rows rows)
  (set! em-cols cols)
  (set! em-lines (vector ""))
  (set! em-nlines 1)
  (set! em-cy 0) (set! em-cx 0) (set! em-top 0)
  (set! em-modified 0)
  (set! em-message "em: shemacs (C-x C-c to quit, C-h b for help)")
  (set! em-mode "normal")
  (set! em-running #t)
  (set! em-kill-ring '())
  (set! em-undo-stack '())
  (em-render))

(define (em-handle-key key rows cols)
  (set! em-rows rows)
  (set! em-cols cols)
  (set! em-msg-persist 0)
  ;; Route based on mode
  (cond
    ((equal? em-mode "isearch") (em-isearch-handle-key key))
    ((equal? em-mode "minibuffer") (em-minibuffer-handle-key key))
    ((equal? em-mode "cx-prefix") (em-cx-dispatch key))
    ((equal? em-mode "esc-prefix") (em-esc-dispatch key))
    (#t (em-dispatch key)))
  (set! em-last-cmd key)
  (em-render))

;; ===== Key reading (uses read-byte / read-byte-timeout builtins) =====

(define em-abc "abcdefghijklmnopqrstuvwxyz")

(define (em-read-key)
  ;; Read one byte, blocking
  (let ((b (read-byte)))
    (if (not b)
        ;; EOF — retry once (bash edge case on terminal setup)
        (let ((b2 (read-byte)))
          (if (not b2)
              "QUIT"
              (em-read-key-byte b2)))
        (em-read-key-byte b))))

(define (em-read-key-byte byte)
  (cond
    ((= byte 0) "C-SPC")                              ;; NUL
    ((= byte 27) (em-read-escape-seq))                 ;; ESC
    ((and (>= byte 1) (<= byte 26))                    ;; Ctrl+letter
     (string-append "C-" (string (string-ref em-abc (- byte 1)))))
    ((or (= byte 127) (= byte 8)) "BACKSPACE")        ;; DEL or BS
    (#t (string-append "SELF:" (string (integer->char byte))))))

(define (em-read-escape-seq)
  (let ((b2 (read-byte-timeout "0.05")))
    (if (not b2)
        "ESC"                                          ;; bare ESC
        (cond
          ((= b2 91) (em-read-csi))                    ;; [ → CSI
          ((= b2 79) (em-read-ss3))                    ;; O → SS3
          ((or (= b2 127) (= b2 8)) "M-DEL")          ;; Meta+DEL
          (#t (string-append "M-" (string (integer->char b2))))))))

(define (em-read-csi)
  (let ((b3 (read-byte-timeout "0.05")))
    (if (not b3)
        "UNKNOWN"
        (cond
          ((= b3 65) "UP")     ((= b3 66) "DOWN")
          ((= b3 67) "RIGHT")  ((= b3 68) "LEFT")
          ((= b3 72) "HOME")   ((= b3 70) "END")
          ((and (>= b3 48) (<= b3 57))                ;; digit → CSI number
           (em-read-csi-num (string (integer->char b3))))
          (#t "UNKNOWN")))))

(define (em-read-csi-num seq)
  ;; Accumulate digits until ~ or letter
  (let ((b (read-byte-timeout "0.05")))
    (if (not b)
        "UNKNOWN"
        (cond
          ((= b 126)                                   ;; ~
           (let ((full (string-append seq "~")))
             (cond
               ((equal? full "3~") "DEL")
               ((equal? full "5~") "PGUP")
               ((equal? full "6~") "PGDN")
               ((equal? full "2~") "INS")
               ((equal? full "1~") "HOME")
               ((equal? full "4~") "END")
               (#t "UNKNOWN"))))
          ((or (and (>= b 65) (<= b 90))              ;; A-Z
               (and (>= b 97) (<= b 122)))            ;; a-z
           "UNKNOWN")
          (#t (em-read-csi-num (string-append seq (string (integer->char b)))))))))

(define (em-read-ss3)
  (let ((b3 (read-byte-timeout "0.05")))
    (if (not b3)
        "UNKNOWN"
        (cond
          ((= b3 65) "UP")     ((= b3 66) "DOWN")
          ((= b3 67) "RIGHT")  ((= b3 68) "LEFT")
          ((= b3 72) "HOME")   ((= b3 70) "END")
          (#t "UNKNOWN")))))

;; ===== Main entry point =====

(define (em-main filename)
  ;; Enter raw mode and alternate screen
  (terminal-raw!)
  (write-stdout (string-append ESC "[?1049h" ESC "[?25h"))
  ;; Initialize editor
  (let ((size (terminal-size)))
    (em-init (car size) (cdr size)))
  ;; Load file if provided
  (if (not (equal? filename ""))
      (if (em-load-file filename)
          #t
          (begin
            (set! em-filename filename)
            (set! em-bufname filename)
            (set! em-message (string-append "(New file) " filename))))
      #f)
  (em-render)
  ;; Main loop — poll terminal-size each keystroke (replaces WINCH trap)
  (let loop ()
    (if em-running
        (let* ((size (terminal-size))
               (key (em-read-key)))
          (if (equal? key "QUIT")
              #f
              (begin
                (em-handle-key key (car size) (cdr size))
                (loop))))
        #f))
  ;; Cleanup: restore terminal
  (write-stdout (string-append ESC "[0m" ESC "[?25h" ESC "[?1049l"))
  (terminal-restore!))
