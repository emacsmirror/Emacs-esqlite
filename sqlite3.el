;;; sqlite3.el --- TODO

;; Author: Masahiro Hayashi <mhayashi1120@gmail.com>
;; Keywords: sqlite3
;; URL: http://github.com/mhayashi1120/Emacs-sqlite3/raw/master/sqlite3.el
;; Emacs: TODO GNU Emacs 24 or later
;; Version: 0.0.1
;; Package-Requires: ((pcsv "1.1.0"))

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; TODO

;; * Specification
;; allow invalid character in data.
;; disallow invalid character in column and table.

;;; Install:

;;TODO

;;; TODO:
;; * incremental search all data in table
;; * incremental search invisible cell.
;; * number to right.
;; * blob
;; * check sqlite3 command is exists.
;; * windows
;; * resize column
;; * when table have `ROWID' column.

;;; Code:

;;TODO when table is locked

(require 'pcsv)

(defgroup sqlite3 ()
  "Manipulate Sqlite3 Database."
  :group 'applications)

(defcustom sqlite3-program "sqlite3"
  ""
  :type 'file
  :group 'sqlite3)

(defvar sqlite3-mode-map nil)

(unless sqlite3-mode-map
  ;;TODO or is testing
  (let ((map (or sqlite3-mode-map (make-sparse-keymap))))

    (suppress-keymap map)

    (define-key map "\C-c\C-c" 'sqlite3-mode-toggle-display)
    (define-key map "\C-c\C-d" 'sqlite3-mode-delete-row)
    (define-key map "\C-c\C-q" 'sqlite3-mode-send-query)
    (define-key map "\C-x\C-s" 'sqlite3-mode-commit-changes)
    (define-key map "\C-c\C-j" 'sqlite3-mode-jump-to-page)
    (define-key map "\C-c\C-n" 'sqlite3-mode-new-row)
    (define-key map "\C-c>" 'sqlite3-mode-forward-page)
    (define-key map "\C-c<" 'sqlite3-mode-backward-page)
    (define-key map "\C-i" 'sqlite3-mode-forward-cell)
    (define-key map "\e\C-i" 'sqlite3-mode-backward-cell)
    (define-key map "\C-m" 'sqlite3-mode-start-edit)
    (define-key map "v" 'sqlite3-mode-view-cell)
    (define-key map "g" 'revert-buffer)
    (define-key map "h" 'sqlite3-mode-previous-column)
    (define-key map "l" 'sqlite3-mode-next-column)
    (define-key map "k" 'sqlite3-mode-previous-row)
    (define-key map "j" 'sqlite3-mode-next-row)
    ;TODO
    (define-key map "\C-c\C-f" 'sqlite3-mode-narrow-down)
    (define-key map "\C-c\C-o" 'sqlite3-mode-open-table)
    (define-key map "\C-c\C-r" 'sqlite3-mode-rollback)

    (setq sqlite3-mode-map map)))

(defvar sqlite3-mode--stream nil)
(make-variable-buffer-local 'sqlite3-mode--stream)

(defvar sqlite3-mode-hook nil)

(defun sqlite3-mode ()
  (interactive)
  (unless buffer-file-name
    (error "Not a file buffer"))
  (kill-all-local-variables)
  (setq major-mode 'sqlite3-mode)
  (setq mode-name "Sqlite3")
  (setq buffer-undo-list t)
  (setq truncate-lines t)
  (setq indent-tabs-mode nil)
  (set (make-local-variable 'backup-inhibited) t)
  (setq revert-buffer-function
        'sqlite3-mode-revert-buffer)
  (setq sqlite3-mode--current-page 0)
  (setq sqlite3-mode--current-table nil)
  ;; disable creating #hoge.sqlite# file
  (auto-save-mode -1)
  (add-hook 'kill-emacs-hook 'sqlite3-killing-emacs)
  (add-hook 'post-command-hook
            'sqlite3-mode--post-command nil t)
  (add-hook 'pre-command-hook
            'sqlite3-mode--pre-command nil t)
  (add-hook 'kill-buffer-hook
            'sqlite3-after-kill-buffer nil t)
  (use-local-map sqlite3-mode-map)
  (sqlite3-mode-setup-mode-line)
  (unless sqlite3-mode--popup-timer
    (setq sqlite3-mode--popup-timer
          (run-with-idle-timer
           1 t 'sqlite3-mode-popup-contents)))
  (run-mode-hooks 'sqlite3-mode-hook))

(defun sqlite3-mode-view-cell ()
  "View current cell with opening subwindow."
  (interactive)
  (let ((value (sqlite3-mode-current-value)))
    (unless value
      (error "No cell is here"))
    (let ((buf (sqlite3-mode--create-sub-buffer value)))
      (display-buffer buf))))

(defun sqlite3-mode-new-row ()
  "TODO"
  (interactive)
  (sqlite3-mode--insert-empty-row))

(defun sqlite3-mode-delete-row ()
  "Delete current row."
  (interactive)
  (when (y-or-n-p "Really delete this row? ")
    (unless (eq (sqlite3-mode-stream-status) 'transaction)
      (sqlite3-mode--transaction-begin))
    (sqlite3-mode--update-with-handler
     (let* ((rowid (get-text-property (point) 'sqlite3-rowid))
            (query (sqlite3-mode--delete-query rowid)))
       (message "Deleting...")
       (sqlite3-mode-read-data query)   ; no read wait until prompt.
       (let ((inhibit-read-only t))
         (delete-region (line-beginning-position)
                        (line-beginning-position 2)))))))

(defun sqlite3-mode-start-edit ()
  "Edit current cell with opening subwindow."
  (interactive)
  (when (plusp (recursion-depth))
    (error "%s"
           (substitute-command-keys 
            "Other recursive edit. Type \\[abort-recursive-edit] to quit recursive edit")))
  (let ((value (sqlite3-mode-current-value)))
    (unless value
      (error "No cell is here"))
    ;; verify before start editing although start transaction after change value.
    (unless (verify-visited-file-modtime (current-buffer))
      (error "Database was modified after open"))
    (let* ((pos (point))
           (region (or 
                    (sqlite3-text-property-region 
                     pos 'sqlite3-edit-value)
                    (sqlite3-text-property-region
                     pos 'sqlite3-source-value)))
           (new (sqlite3-mode-open-edit-window value)))
      (unless (equal value new)
        (let ((inhibit-read-only t))
          (unless (eq (sqlite3-mode-stream-status) 'transaction)
            (sqlite3-mode--transaction-begin))
          (goto-char pos)
          (sqlite3-mode--replace-current-cell new))))))

(defun sqlite3-mode-commit-changes ()
  "Commit changes to database file.
If changed data violate database constraint, transaction will be rollback.
"
  (interactive)
  (unless (eq (sqlite3-mode-stream-status) 'transaction)
    (error "No commit are here"))
  (when (y-or-n-p "Commit all changes? ")
    (condition-case err
        (sqlite3-mode--transaction-commit)
      (error
       (sqlite3-mode--transaction-rollback)))
    ;; sync with physical data.
    (sqlite3-mode-redraw-page)))

(defun sqlite3-mode-rollback ()
  "Discard all changes."
  (interactive)
  (unless (eq (sqlite3-mode-stream-status) 'transaction)
    (error "Have not began a transaction"))
  (unless (y-or-n-p "Really discard changes? ")
    (signal 'quit nil))
  (sqlite3-mode--transaction-rollback)
  (sqlite3-mode-redraw-page))

(defun sqlite3-mode-reset ()
  "Cause of unknown problem of editing buffer, reset sqlite3 command stream if you want."
  (interactive)
  (when (y-or-n-p "Restart sqlite3 process with discarding changes? ")
    (when sqlite3-mode--stream
      (sqlite3-stream-close sqlite3-mode--stream)
      (setq sqlite3-mode--stream
            (sqlite3-stream-open buffer-file-name)))
    (sqlite3-mode-redraw-page)))

;;TODO
;; raw-data <-> table-view
(defun sqlite3-mode-toggle-display ()
  (interactive)
  )

;;TODO
(defun sqlite3-mode-send-query (query)
  (interactive "sSQL: ")
  (sqlite3-mode--send-query query))

(defun sqlite3-mode-jump-to-page (page)
  "Jump to selected PAGE"
  (interactive
   (list (read-number "Page: ")))
  (unless (sqlite3-mode-draw-page
           sqlite3-mode--current-table page)
    (error "No such page")))

(defun sqlite3-mode-forward-page (&optional arg)
  "TODO"
  (interactive "p")
  (unless (sqlite3-mode--check-error-line)
    (signal 'quit nil))
  (unless (sqlite3-mode-draw-page
           sqlite3-mode--current-table
           (+ sqlite3-mode--current-page arg))
    (error "No more next page")))

(defun sqlite3-mode-backward-page (&optional arg)
  "TODO"
  (interactive "p")
  (unless (sqlite3-mode--check-error-line)
    (signal 'quit nil))
  (when (= sqlite3-mode--current-page 0)
    (error "This is a first page"))
  (unless (sqlite3-mode-draw-page 
           sqlite3-mode--current-table
           (- sqlite3-mode--current-page arg))
    (error "No more previous page")))

(defun sqlite3-mode-next-row (&optional arg)
  "TODO"
  (interactive "p")
  (sqlite3-mode--move-line arg)
  ;;TODO next page
  )

(defun sqlite3-mode-previous-row (&optional arg)
  "TODO"
  (interactive "p")
  (sqlite3-mode--move-line (- arg))
  ;;TODO prev page
  )

(defun sqlite3-mode-next-column ()
  "Goto next column."
  (interactive)
  (let ((next (sqlite3-mode--next-cell (point) t)))
    (when next
      (goto-char next))))

(defun sqlite3-mode-previous-column ()
  "Goto previous column."
  (interactive)
  (let ((prev (sqlite3-mode--previous-cell (point) t)))
    (when prev
      (goto-char prev))))

(defun sqlite3-mode-forward-cell ()
  "Forward cell over the row."
  (interactive)
  (let ((next (sqlite3-mode--next-cell (point))))
    (when next
      (goto-char next))))

(defun sqlite3-mode-backward-cell ()
  "Backward cell over the row."
  (interactive)
  (let ((prev (sqlite3-mode--previous-cell (point))))
    (when prev
      (goto-char prev))))

;;TODO name
(defun sqlite3-mode-narrow-down ()
  (interactive)
  ;;
  )

;;;
;;; `sqlite3-mode' functions
;;;

(defun sqlite3-mode--sync-modtime ()
  (set-visited-file-modtime
   (nth 5 (file-attributes buffer-file-name))))

(defvar sqlite3-mode--popup-timer nil)

(defun sqlite3-mode--cleanup-timer ()
  (when sqlite3-mode--popup-timer
    (loop for b in (buffer-list)
          if (and (eq (buffer-local-value 'major-mode b) 'sqlite3-mode)
                  (buffer-live-p b))
          return t
          finally (progn 
                    (cancel-timer sqlite3-mode--popup-timer)
                    (setq sqlite3-mode--popup-timer nil)))))

(defun sqlite3-mode-current-value ()
  (or 
   (get-text-property (point) 'sqlite3-edit-value)
   (get-text-property (point) 'sqlite3-source-value)))

(defun sqlite3-mode-popup-contents ()
  (save-match-data
    ;;TODO only show current cell exceed window.
    (when (and (eq major-mode 'sqlite3-mode)
               ;; suppress tooltip if last command were C-g
               (not (eq last-command 'keyboard-quit)))
      (when (get-text-property (point) 'sqlite3-mode-truncated)
        (sqlite3-tooltip-show (sqlite3-mode-current-value))))))

(defconst sqlite3-mode-line-format
  '(
    (sqlite3-mode--current-table
     (:eval
      (concat " [" 
              (propertize 
               (format "%s:%d"
                       sqlite3-mode--current-table 
                       (1+ sqlite3-mode--current-page))
               'face 'mode-line-emphasis)
              "]")))
    (:eval
     (concat
      " "
      (let ((status (sqlite3-mode-stream-status)))
        (cond
         ((eq status 'prompt)
          (propertize "Run" 'face 'minibuffer-prompt))
         ((eq status 'transaction)
          (propertize "Transaction" 'face 'compilation-info))
         ((eq status 'querying)
          (propertize "Querying" 'face 'compilation-warning))
         (t
          (propertize "No Process" 'face 'shadow))))))))

(defun sqlite3-mode-setup-mode-line ()
  (setq mode-line-process sqlite3-mode-line-format))

(defconst sqlite3-mode-sub-buffer " *Sqlite3 Sub* ")

(defun sqlite3-mode--create-sub-buffer (value)
  (let ((buf (get-buffer-create sqlite3-mode-sub-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer))
      (insert value)
      (setq buffer-undo-list nil)
      (set-buffer-modified-p nil))
    buf))

(defun sqlite3-mode-open-edit-window (value)
  (let* ((config (current-window-configuration))
         (buf (sqlite3-mode--create-sub-buffer value)))
    (pop-to-buffer buf)
    (message "%s"
             (substitute-command-keys 
              "Type \\[exit-recursive-edit] to finish the edit."))
    (recursive-edit)
    (let ((new-value (buffer-string)))
      (set-window-configuration config)
      new-value)))

(defun sqlite3-tooltip-show (text)
  ;; show tooltip at cursor point.
  ;; Unable calculate exactly absolute coord but almost case is ok.
  ;;TODO consider `x-max-tooltip-size'
  (let* ((xy (sqlite3-tooltip-absolute-coordinate (point)))
         (y
          (cond
           ((< (/ (ftruncate (cdr xy)) (x-display-pixel-height)) 0.2)
            (+ (cdr xy) (* (frame-char-height) 3)))
           (t
            (cdr xy)))))
    (x-show-tip 
     text nil 
     `((left . ,(car xy))
       (top . ,y))
     ;; huge timeout value
     100000)))

(defun sqlite3-tooltip-absolute-coordinate (point)
  (let* ((posn (posn-at-point point))
         (xy (posn-x-y posn))
         (x (+ (sqlite3-tooltip-frame-posn 'top) 
               (car xy)))
         (y (truncate
             (+ (sqlite3-tooltip-frame-posn 'left)
                (cdr xy)
                ;; FIXME calculate fringe of bar roughly..
                (* (or (and tool-bar-mode tool-bar-images-pixel-height) 0)
                   1.5)
                (* (or (and menu-bar-mode (frame-char-height)) 0)
                   1.5)))))
    (cons x y)))

(defun sqlite3-tooltip-frame-posn (prop)
  (let ((res (cdr (assq prop (frame-parameters)))))
    (or
     (cond
      ((consp res)
       (loop for o in res
             if (numberp o)
             return o))
      (t
       res))
     0)))

(defun sqlite3-killing-emacs ()
  (mapc
   (lambda (proc)
     (when (process-get proc 'sqlite3-stream-process-p)
       (condition-case err
           (sqlite3-stream-close proc)
         (error (message "Sqlite3: %s" err)))))
   (process-list)))

(defun sqlite3-after-kill-buffer ()
  (when sqlite3-mode--stream
    (sqlite3-stream-close sqlite3-mode--stream))
  (sqlite3-mode--cleanup-timer))

(defvar sqlite3-mode--moved-column nil)
(defun sqlite3-mode--move-line (arg)
  (let ((col (if (memq last-command 
                       '(sqlite3-mode-previous-row sqlite3-mode-next-row))
                 sqlite3-mode--moved-column
               (current-column))))
    (setq sqlite3-mode--moved-column col)
    (forward-line arg)
    (move-to-column col)))

(defun sqlite3-mode--pre-command ()
  (condition-case err
      (progn
        (sqlite3-mode--pre-handle-rowid))
    (error
     (message "%s" err))))

(defun sqlite3-mode--post-command ()
  (condition-case err
      (progn
        (sqlite3-mode--highlight-selected)
        (sqlite3-mode--post-change-row)
        (sqlite3-mode--delayed-draw-header))
    (error
     (message "%s" err))))

(defvar sqlite3-mode--previous-row nil)
(make-variable-buffer-local 'sqlite3-mode--previous-row)

(defun sqlite3-mode--pre-handle-rowid ()
  (setq sqlite3-mode--previous-row (sqlite3-mode-current-row)))

(defun sqlite3-mode--post-change-row ()
  (when sqlite3-mode--previous-row
    ;;TODO row have error that must have insert.
    (unless (equal (car sqlite3-mode--previous-row)
                   (get-text-property (point) 'sqlite3-rowid))
      (sqlite3-mode--apply-changes)
      (let ((msg (sqlite3-mode--get-error)))
        (when msg
          (if (current-message)
              (message "%s %s" (current-message) msg)
            (message "%s" msg)))))))

(defmacro sqlite3-mode--update-with-handler (&rest form)
  "Update current row with FORM."
  `(condition-case err
       (progn 
         ,@form
         (sqlite3-mode--clear-error))
     (error 
      (sqlite3-mode--put-error (format "%s" err))
      (signal (car err) (cdr err)))))

(defun sqlite3-mode--sync-row (rowid)
  ;;TODO rowid will be changed if changing primary key value..
  (let ((inhibit-read-only t))
    (let ((data (sqlite3-mode-read-data (format "SELECT * FROM %s WHERE ROWID = %s" 
                                                sqlite3-mode--current-table
                                                rowid) t)))
      (unless data
        ;;TODO
        (error "Change primary key? Currently PRIMARY KEY changing is not supported"))
      (delete-region (line-beginning-position) (line-end-position))
      (sqlite3-mode--insert-row (cons rowid (car data))))))

(defun sqlite3-mode--row-is-modified (row)
  (loop for (name source edit) in (cdr row)
        unless (or (null edit) (equal source edit))
        return t))

(defvar sqlite3-mode--highlight-overlay nil)
(make-variable-buffer-local 'sqlite3-mode--highlight-overlay)

(defun sqlite3-mode--highlight-selected ()
  (let ((ov (or sqlite3-mode--highlight-overlay
                (let ((tmp (make-overlay (point-max) (point-max))))
                  ;;TODo face
                  (overlay-put tmp 'face 'match)
                  tmp))))
    (cond
     ((memq ov (overlays-at (point))))
     ((get-text-property (point) 'sqlite3-source-value (current-buffer))
      (let* ((region (sqlite3-text-property-region (point) 'sqlite3-source-value))
             (start (car region))
             (end (cdr region)))
        (move-overlay ov start end)
        (setq sqlite3-mode--highlight-overlay ov)))
     (t
      (move-overlay ov (point-max) (point-max))))))

(defun sqlite3-text-property-region (point property)
  (let ((val (get-text-property point property)))
    (and val
         (let* ((start (previous-single-property-change 
                        point property
                        nil (line-beginning-position)))
                (end (next-single-property-change
                      point property 
                      nil (line-end-position))))
           (unless (eq (get-text-property start property) val)
             (setq start (point)))
           (unless (eq (get-text-property (1- end) property) val)
             (setq end (point)))
           (cons start end)))))

(defun sqlite3-mode--previous-cell (point &optional current-line)
  (let ((region (sqlite3-text-property-region point 'sqlite3-source-value)))
    (cond
     ((null region)
      (previous-single-property-change
       point 'sqlite3-source-value nil
       (if current-line (line-beginning-position) (point-min))))
     ((eq (car region) (point-min))
      (point-min))
     (t
      (sqlite3-mode--previous-cell (1- (car region)) current-line)))))

(defun sqlite3-mode--next-cell (point &optional current-line)
  (let ((region (sqlite3-text-property-region point 'sqlite3-source-value)))
    (next-single-property-change 
     (or (cdr region) point) 
     'sqlite3-source-value nil
     (and current-line (line-end-position)))))

(defun sqlite3-mode--data-to-text (datum)
  (let ((oneline (or
                  (and (string-match "^\\([^\n]+\\)" datum)
                       (match-string 1 datum))
                  datum)))
    (replace-regexp-in-string "\t" "\\\\t" oneline)))

(defun sqlite3-mode--truncate-text (width text)
  (truncate-string-to-width text width nil ?\s t))

(defface sqlite3-header-background
  '((((type x w32 mac ns) (class color))
     :background "LightSteelBlue" :foreground "black")
    (((class color))
     (:background "white" :foreground "black")))
  "*Face to fontify background of header line."
  :group 'faces)

(defun sqlite3-header-background-propertize (string)
  (let ((end (length string)))
    (add-text-properties 0 end 
                         (list
                          'face (list 'sqlite3-header-background)
                          'tab-separator t)
                         string)
    string))

(defvar sqlite3-header-column-separator
  (let ((sep " "))
    (sqlite3-header-background-propertize sep)
    (propertize sep 'display 
                '(space :width 1)))
  "String used to separate tabs.")

(defun sqlite3-mode--set-header (width-def headers)
  (setq sqlite3-mode--header
        (loop for max in (cdr width-def)
              for hdr in (cdr headers)
              ;;TODO 30
              collect (list hdr max (min max 30)))))

(defvar sqlite3-mode--header nil)
(make-variable-buffer-local 'sqlite3-mode--header)

(defun sqlite3-mode--insert-empty-row ()
  (when sqlite3-mode--highlight-overlay
    (move-overlay sqlite3-mode--highlight-overlay
                  (point-max) (point-max)))
  (forward-line 0)
  (let ((row (cons nil (make-list (length sqlite3-mode--header) "")))
        (inhibit-read-only t))
    (insert "\n")
    (forward-line -1)
    (sqlite3-mode--insert-row row)
    (forward-line 0)))

(defun sqlite3-mode--put-error (msg)
  (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
    (overlay-put ov 'sqlite3-error-line-p t)
    (overlay-put ov 'sqlite3-error-message msg)
    (overlay-put ov 'face 'sqlite3-error-line-face)))

(defun sqlite3-mode--get-error ()
  (let ((ovs (overlays-in (line-beginning-position) (line-end-position))))
    (loop for o in ovs
          if (overlay-get o 'sqlite3-error-line-p)
          return (overlay-get o 'sqlite3-error-message))))

(defun sqlite3-mode--clear-error ()
  (remove-overlays (line-beginning-position) (line-end-position) 
                   'sqlite3-error-line-p t))

(defun sqlite3-mode--apply-changes ()
  (let ((row sqlite3-mode--previous-row)
        (not-found))
    (save-excursion 
      (setq not-found (null (sqlite3-mode--goto-rowid (car row))))
      (cond
       (not-found)
       ((null (car row))
        (sqlite3-mode--update-with-handler
         (let ((query (sqlite3-mode--insert-query row)))
           (message "Inserting...")
           (sqlite3-mode-read-data query) ; no read. wait until prompt.
           (let* ((last (sqlite3-mode-read-data "SELECT LAST_INSERT_ROWID()"))
                  (rowid (caar last)))
             (sqlite3-mode--sync-row rowid)))))
       ((sqlite3-mode--row-is-modified row)
        (sqlite3-mode--update-with-handler
         (let ((query (sqlite3-mode--update-query row)))
           (message "Updating...")
           (sqlite3-mode-read-data query) ; no read. wait until prompt.
           (sqlite3-mode--sync-row (car row)))))))))

(defun sqlite3-mode--goto-rowid (rowid)
  (let ((first (point)))
    (goto-char (point-min))
    (loop while (not (eobp))
          if (equal rowid (get-text-property (point) 'sqlite3-rowid))
          return (point)
          do (forward-line 1)
          finally (goto-char first))))

(defface sqlite3-error-line-face
  '((t (:inherit isearch-fail)))
  "Face for highlighting failed part in Isearch echo-area message."
  :group 'sqlite3)

(defun sqlite3-mode-current-row ()
  (unless (eobp)
    (save-excursion
      (forward-line 0)
      (cons 
       (get-text-property (point) 'sqlite3-rowid)
       (loop with p = (point)
             for (name . rest) in sqlite3-mode--header
             collect (list name
                           (get-text-property p 'sqlite3-source-value)
                           (get-text-property p 'sqlite3-edit-value))
             do (setq p (sqlite3-mode--next-cell p t)))))))

(defun sqlite3-mode--check-error-line ()
  (let ((errs (remove-if-not 
               (lambda (o) (overlay-get o 'sqlite3-error-line-p))
               (overlays-in (point-min) (point-max)))))
    (cond
     ((null errs) t)
      ;;TODO
     ((y-or-n-p "Non saved lines are exists. Really continue? ") t)
     (t nil))))

(defvar sqlite3-mode--previous-hscroll nil)
(make-variable-buffer-local 'sqlite3-mode--previous-hscroll)

(defun sqlite3-mode--delayed-draw-header (&optional force)
  (when force
    (setq sqlite3-mode--previous-hscroll nil))
  (cancel-function-timers 'sqlite3-mode--draw-header)
  ;; in the `post-command-hook', `window-hscroll' still return previous value.
  ;; although after calling `scroll-right' return correct value.
  (run-with-timer 0.1 nil 'sqlite3-mode--draw-header))

(defun sqlite3-mode--draw-header ()
  (unless (eq sqlite3-mode--previous-hscroll (window-hscroll))
    (setq sqlite3-mode--previous-hscroll (window-hscroll))
    (let* ((disp-headers 
            (loop with hscroll = (window-hscroll)
                  ;;  set t after first displaying column in window
                  with flag
                  for (header max-width wid) in sqlite3-mode--header
                  sum (1+ wid) into right
                  if (<= hscroll right)
                  collect (progn
                            (unless flag
                              (setq wid (- right hscroll 1)))
                            (setq flag t)
                            (when (< wid 3)
                              ;; Beginning of line header may have too short length of name.
                              (setq header ""))
                            (sqlite3-mode--truncate-text wid header))))
           (filler (make-string (frame-width) ?\s))
           (tail (sqlite3-header-background-propertize filler)))
      (setq header-line-format
            (and disp-headers
                 (list 
                  sqlite3-header-column-separator
                  (mapconcat
                   'identity
                   disp-headers
                   sqlite3-header-column-separator)
                  tail))))))

(defun sqlite3-mode--insert-row (row)
  ;; (car row) is ROWID
  (loop for v in (cdr row)
        for i from 0
        do (progn
             (when (> i 0)
               (insert " "))
             (let ((region (sqlite3-mode--insert-cell v)))
               (put-text-property (car region) (cdr region) 
                                  'sqlite3-source-value v))))
  (put-text-property
   (line-beginning-position) (line-end-position)
   'sqlite3-rowid (car row)))

(defun sqlite3-mode--cell-width (width)
  ;; TODO defvar 30
  (min width 30))

(defun sqlite3-mode--insert-cell (value)
  (let* ((start (point))
         (column (sqlite3-mode--column-index))
         (wid (nth 2 (nth column sqlite3-mode--header)))
         (truncated (sqlite3-mode--truncate-insert (or value "") wid)))
    (let ((end (point)))
      (put-text-property start end 'sqlite3-mode-truncated truncated)
      (cons start end))))

(defun sqlite3-mode--truncate-insert (value width)
  (let* ((pos-beg (point))
         (text (sqlite3-mode--data-to-text value))
         (first-column (current-column))
         (next-column (+ first-column width)))
    (insert text)
    (let ((pos-end (point)))
      (move-to-column next-column t)
      (let ((col-end (point)))
        (while (< next-column (current-column))
          (backward-char))
        (let* ((end (max pos-end col-end))
               (truncated 
                (cond 
                 ((> end (point))
                  (let ((start (max pos-beg (- (point) 3))))
                    (delete-region start end))
                  (insert (make-string (- next-column (current-column)) ?\.))
                  t)
                 ((not (equal text value)) t)
                 (t nil))))
          truncated)))))

(defun sqlite3-mode--column-index ()
  (save-excursion
    (let ((pos (point)))
      (forward-line 0)
      (loop with prev
            for i from 0
            if (eolp)
            return i
            do (let ((next (sqlite3-mode--next-cell (point) t)))
                 (when next (goto-char next)))
            if (< pos (point))
            return i))))

(defun sqlite3-mode--replace-current-cell (value)
  (let* ((pos (point))                  ;save position
         (region (sqlite3-text-property-region pos 'sqlite3-source-value)))
    (unless region
      (error "Not a cell"))
    (let ((source (get-text-property pos 'sqlite3-source-value))
          (rowid (get-text-property (point) 'sqlite3-rowid))
          (rest (buffer-substring (cdr region) (line-end-position))))
      (delete-region (car region) (line-end-position))
      (let ((new (sqlite3-mode--insert-cell value)))
        (put-text-property (line-beginning-position) (line-end-position) 'sqlite3-rowid
                           rowid)
        (put-text-property (car region) (cdr region) 'sqlite3-edit-value
                           value)
        ;; restore source value if exist
        (put-text-property (car new) (cdr new) 'sqlite3-source-value source)
        (insert rest)))
    ;; restore previous position
    (goto-char pos)))

;;TODO hack function make obsolete later
(defun sqlite3-mode-open-table (table)
  (interactive 
   (let ((table (sqlite3-mode--read-table)))
     (list table)))
  (unless (sqlite3-mode-draw-page table 0)
    (error "No data")))

(defvar sqlite3-mode-read-table-history nil)
(defun sqlite3-mode--read-table ()
  (completing-read
   "Table: "
   (mapcar
    (lambda (x) (car x))
    (sqlite3-mode-read-data sqlite3-select-table-query t))
   nil t nil 'sqlite3-mode-read-table-history))

(defun sqlite3-mode--send-query (query)
  (sqlite3-mode--check-stream)
  (sqlite3-stream--send-query sqlite3-mode--stream query))

(defun sqlite3-mode--check-stream ()
  "Check current buffer's database file is opend by sqlite."
  (unless (and sqlite3-mode--stream
               (eq (process-status sqlite3-mode--stream) 'run))
    (setq sqlite3-mode--stream
          (sqlite3-stream-open buffer-file-name))))

(defun sqlite3-mode-read-data (query &optional ommit-header)
  (sqlite3-mode--check-stream)
  (let ((data (sqlite3-stream--read-result sqlite3-mode--stream query)))
    (if ommit-header
        (cdr data)
      data)))

(defun sqlite3-mode-redraw-page ()
  (when sqlite3-mode--current-table
    (let ((start (window-start))
          (pos (point)))
      (sqlite3-mode-draw-page
       sqlite3-mode--current-table
       sqlite3-mode--current-page)
      (goto-char pos)
      (set-window-start (selected-window) start))))

(defun sqlite3-mode-draw-page (table page)
  ;; sync mtime with disk file.
  ;; to detect database modifying 
  ;; between reading from disk and beginning of transaction.
  (sqlite3-mode--sync-modtime)
  (save-excursion
    (let* ((where (or sqlite3-mode--current-cond "1 = 1"))
           (order "") ;; TODO order by
           (order-by "")                ;TODO
           (query (format 
                   (concat "SELECT ROWID, *"
                           " FROM %s"
                           " WHERE %s"
                           " LIMIT %s OFFSET %s * %s"
                           "%s")
                   table where
                   sqlite3-mode--maximum
                   sqlite3-mode--maximum
                   page order-by))
           (data (sqlite3-mode-read-data query)))
      (cond
       ((or data
            (not (equal sqlite3-mode--current-table table)))
        (setq sqlite3-mode--current-table table)
        (let ((inhibit-read-only t)
              (width-def (sqlite3-mode--calculate-max-width data)))
          (erase-buffer)
          (remove-overlays (point-min) (point-max))
          ;;TODO merge to calculate max-width function
          (sqlite3-mode--set-header width-def (car data))
          (mapc
           (lambda (row)
             (sqlite3-mode--insert-row row)
             (insert "\n"))
           ;; ignore header row
           (cdr data))
          (set-buffer-modified-p nil))
        (setq buffer-read-only t)
        (setq sqlite3-mode--current-page page)
        ;; redraw header forcibly
        (sqlite3-mode--delayed-draw-header t))
       (t nil)))))

(defun sqlite3-mode--calculate-max-width (data)
  ;; decide list length by header line
  (loop with all-width = (make-list (length (car data)) 3)
        for row in data
        do (loop for datum in row
                 for pair on all-width
                 for idx from 0
                 do (let* ((text (sqlite3-mode--data-to-text datum))
                           (wid (string-width text)))
                      (setcar pair (max (car pair) wid))))
        finally return all-width))

(defun sqlite3-mode-stream-status ()
  (let ((stream sqlite3-mode--stream))
    (cond
     ((null stream) 'exit)
     ((not (eq (process-status stream) 'run)) 'exit)
     ((with-current-buffer (process-buffer stream)
        (sqlite3--prompt-waiting-p))
      (cond
       ((process-get stream 'sqlite3-mode-transaction)
        'transaction)
       (t
        'prompt)))
     (t 'querying))))

(defvar sqlite3-mode--context nil)
(make-variable-buffer-local 'sqlite3-mode--context)

;;TODO this local variable to one context variable?

(defvar sqlite3-mode--current-order nil)
(make-variable-buffer-local 'sqlite3-mode--current-order)

(defvar sqlite3-mode--current-cond nil)
(make-variable-buffer-local 'sqlite3-mode--current-cond)

(defvar sqlite3-mode--current-table nil)
(make-variable-buffer-local 'sqlite3-mode--current-table)

(defvar sqlite3-mode--current-page nil)
(make-variable-buffer-local 'sqlite3-mode--current-page)

(defvar sqlite3-mode--maximum 100)

(defun sqlite3-mode--transaction-begin ()
  (sqlite3-mode--send-query "BEGIN")
  (process-put sqlite3-mode--stream 'sqlite3-mode-transaction t))

(defun sqlite3-mode--transaction-rollback ()
  ;;TODO file modtime do-suru?
  (sqlite3-mode--send-query "ROLLBACK")
  (process-put sqlite3-mode--stream 'sqlite3-mode-transaction nil))

(defun sqlite3-mode--transaction-commit ()
  ;;TODO file modtime do-suru?
  (sqlite3-mode--send-query "COMMIT")
  (process-put sqlite3-mode--stream 'sqlite3-mode-transaction nil))

(defun sqlite3-mode--update-query (row)
  (format "UPDATE %s SET %s WHERE ROWID = %s;"
          sqlite3-mode--current-table
          (mapconcat
           (lambda (x)
             (format "%s = %s"
                     (car x)
                     (sqlite3-to-escaped-string (cdr x))))
           (loop for (name source edit) in (cdr row)
                 if edit
                 collect (cons name edit))
           ", ")
          (car row)))

(defun sqlite3-mode--insert-query (row)
  (let (columns values)
    (loop for (name source edit) in (cdr row)
          do (setq columns (cons name columns)
                   values (cons (or edit "") values)))
    (format "INSERT INTO %s (%s) VALUES (%s);"
            sqlite3-mode--current-table
            (mapconcat 'identity columns ", ")
            (mapconcat
             (lambda (x) (sqlite3-to-escaped-string x))
             values ", "))))

(defun sqlite3-mode--delete-query (rowid)
  (format "DELETE FROM %s WHERE ROWID = %s;" 
          sqlite3-mode--current-table
          rowid))

;;TODO order by
;; TODO threshold of getting.
(defun sqlite3--select-query (table)
  (format "SELECT * FROM %s;" table))

(defvar sqlite3-stream--csv-accumulation nil)

(defun sqlite3--csv-select-filter ()
  (let ((data (sqlite3--read-csv-with-deletion)))
    (setq sqlite3-stream--csv-accumulation
          (append sqlite3-stream--csv-accumulation data))))

;;;
;;; Sqlite3 stream
;;;

(defmacro sqlite3--with-process (proc &rest form)
  (declare (indent 1))
  `(let ((buf (process-buffer proc)))
     (when (buffer-live-p buf)
       (with-current-buffer buf
         ,@form))))

(defun sqlite3-stream-open (file)
  (let* ((buf (sqlite3-stream--create-buffer))
         (proc (start-process "Sqlite3 Stream" buf
                              sqlite3-program
                              "-header"
                              "-init" (sqlite3--init-file)
                              "-csv" file)))
    (process-put proc 'sqlite3-stream-process-p t)
    (set-process-filter proc 'sqlite3-stream--filter)
    (set-process-sentinel proc 'sqlite3-stream--sentinel)
    (sqlite3-stream--wait-until-prompt proc)
    proc))

(defun sqlite3-stream-close (stream)
  (let ((proc stream))
    (unless (process-get proc 'sqlite3-stream-process-p)
      (error "Not a sqlite3 process"))
    (with-timeout (5 (kill-process proc))
      (process-send-string proc ".quit\n")
      (while (eq (process-status proc) 'run)
        (sleep-for 0.1)))
    (delete-process stream)))

(defun sqlite3-stream--create-buffer ()
  (generate-new-buffer " *Sqlite3 work* "))

(defun sqlite3-stream--parse-error ()
  (save-excursion
    (goto-char (point-min))
    ;;FIXME this error output to stderr. Separate stderr to other file??
    ;;     Anxious to confuse stdout/stderr but rarely happens.
    (and (looking-at "^Error: \\(.*\\)")
         (format "Sqlite3 Error: %s" (match-string 1)))))

(defun sqlite3-stream--filter (proc event)
  (sqlite3--with-process proc
    (goto-char (point-max))
    (insert event)
    (unless sqlite3-stream--error
      ;; check only first time filter received data.
      (setq sqlite3-stream--error
            (or (sqlite3-stream--parse-error) t)))
    (goto-char (point-min))
    (when (functionp sqlite3-stream--filter-function)
      (funcall sqlite3-stream--filter-function))))

(defun sqlite3-stream--sentinel (proc event)
  (sqlite3--with-process proc
    (unless (eq (process-status proc) 'run)
      (kill-buffer (current-buffer)))))

(defvar sqlite3-stream--filter-function nil)

(defun sqlite3-stream--read-result (stream query)
  "Pass STREAM and QUERY to `sqlite3-stream--send-query'

TODO comment
This function return nil immediately unless FILTER and SENTINEL.
When previous QUERY is running, QUERY is waiting until QUERY was finished.

FILTER is called while receiving data from sqlite3 command.
SENTINEL is called when return from QUERY.
"
  ;; wait until previous query was finished.
  (sqlite3-stream--wait-until-prompt stream)
  ;; send synchrounous variables.
  (setq sqlite3-stream--filter-function
        'sqlite3--csv-select-filter)
  (setq sqlite3-stream--csv-accumulation nil)
  (sqlite3-stream--send-query stream query)
  ;; wait until prompt is displayed.
  ;; filter function handling csv data.
  (sqlite3-stream--wait-until-prompt stream)
  sqlite3-stream--csv-accumulation)

(defvar sqlite3-stream--error nil)
(make-variable-buffer-local 'sqlite3-stream--error)

(defun sqlite3-stream--send-query (stream query)
  "Send QUERY to sqlite3 STREAM. (currently STREAM is a process object)
This function check syntax error of QUERY.

QUERY is a sql statement that can have not statement end (`;').
 Do Not have multiple statements.

Examples:
Good: SELECT * FROM table1;
Good: SELECT * FROM table1
Good: SELECT * FROM table1\n
 Bad: SELECT * FROM table1; SELECT * FROM table2;
"
  ;; wait until previous query was finished.
  (sqlite3-stream--wait-until-prompt stream)
  (let* ((proc stream)
         (buf (process-buffer proc)))
    (with-current-buffer buf
      ;; clear all text contains prompt.
      (erase-buffer)
      (setq sqlite3-stream--error nil)
      (process-send-string proc query)
      (cond
       ((not (string-match ";[ \t\n]*$" query))
        (process-send-string proc ";\n"))
       ((not (string-match "\n+" query))
        (process-send-string proc "\n")))
      ;; only check syntax error.
      (while (and (eq (process-status proc) 'run)
                  (not (sqlite3--prompt-waiting-p))
                  (null sqlite3-stream--error))
        (sqlite3-sleep 0.1))
      (when (stringp sqlite3-stream--error)
        (error "%s" sqlite3-stream--error))
      t)))

(defun sqlite3-stream--wait-until-prompt (proc)
  (let ((buf (process-buffer proc)))
    (with-current-buffer buf
      (while (and (eq (process-status proc) 'run)
                  (not (sqlite3--prompt-waiting-p)))
        (sqlite3-sleep 0.1)))))

(defun sqlite3-sleep (seconds)
  ;; Other code affect to buffer while `sleep-for'.
  ;; TODO timer? filter? I can't get clue.
  (save-excursion
    (redisplay)
    (sleep-for seconds)))

;;;
;;; Utilities to handle any sqlite3 item.
;;;

(defvar sqlite3--init-file nil)

(defun sqlite3--init-file (&optional refresh)
  (or (and (not refresh) sqlite3--init-file)
      (setq sqlite3--init-file
            (sqlite3--create-init-file))))

(defun sqlite3--create-init-file ()
  (let ((file (make-temp-file "emacs-sqlite3-")))
    (with-temp-buffer
      (write-region (point-min) (point-max) file nil 'no-msg))
    file))

(defconst sqlite3-file-header-regexp "\\`SQLite format 3\000")

;;TODO
;; (add-to-list 'magic-mode-alist
;;              `(,sqlite3-file-header-regexp . sqlite3-mode))

;;TODO about autoload  seems `sqlite3-file-guessed-valid-p' is not works.

;;;###autoload
(defun sqlite3-file-guessed-valid-p (file)
  (with-temp-buffer
    (insert-file-contents file nil 0 256)
    (looking-at sqlite3-file-header-regexp)))

;;;###autoload
(defun sqlite3-find-file (db-file)
  (interactive "FSqlite3 File: ")
  (unless (sqlite3-file-guessed-valid-p db-file)
    (error "Not a valid database file"))
  (let ((buf (get-file-buffer db-file)))
    (unless buf
      (setq buf (create-file-buffer (file-name-nondirectory db-file)))
      (with-current-buffer buf
        (set-visited-file-name db-file)
        (set-buffer-modified-p nil)
        (sqlite3-mode)))
    (switch-to-buffer buf)))

(defun sqlite3-mode-revert-buffer (&rest dummy)
  (sqlite3-mode-redraw-page))

(defun sqlite3--prompt-waiting-p ()
  (save-excursion
    (goto-char (point-max))
    (forward-line 0)
    (looking-at "^sqlite> \\'")))

(defun sqlite3--read-csv-with-deletion ()
  "Read csv data from current point. Delete csv data if read was succeeded."
  (let ((pcsv-quoted-value-regexp  (pcsv-quoted-value-regexp))
        (pcsv-value-regexp (pcsv-value-regexp))
        pcsv-eobp res)
    (condition-case nil
        (while (not (eobp))
          (let ((start (point)))
            (let ((l (sqlite3--read-csv-line)))
              (delete-region start (point))
              (setq res (cons l res)))))
      ;;TODO error is continue.
      (invalid-read-syntax nil))
    (nreverse res)))

(defun sqlite3--read-csv-line ()
  (let ((first (point))
        (line (loop with v = nil
                    while (setq v (pcsv-read))
                    collect v
                    until (bolp))))
    (unless (memq (char-before) '(?\n ?\r))
      (goto-char first)
      (signal 'invalid-read-syntax nil))
    line))

(defun sqlite3-to-escaped-string (object)
  (cond
   ((stringp object)
    (concat
     "'"
     (replace-regexp-in-string "'" "''" object)
     "'"))
   ((numberp object)
    (prin1-to-string object))
   (t
    (sqlite3-to-escaped-string (prin1-to-string object)))))

(defconst sqlite3-select-table-query
  "SELECT name FROM sqlite_master WHERE type='table'")

(defun sqlite3-stream--tables (stream)
  (mapcar
   'car
   (sqlite3-stream--read-result 
    stream sqlite3-select-table-query)))

(defun sqlite3-stream--table-info (stream table)
  "Get TABLE information in FILE.
Elements of the item list are:
0. cid
1. name
2. type
3. not null
4. default_value
5. primary key"
  (mapcar
   (lambda (row)
     (list
      (string-to-number (nth 0 row))
      (nth 1 row)
      (nth 2 row)
      (equal (nth 3 row) "1")
      (nth 4 row)
      (equal (nth 5 row) "1")))
   (cdr
    (sqlite3-stream--read-result 
     stream (format "PRAGMA table_info(%s)" table)))))

;;;
;;; Synchronous utilities
;;;

(defmacro sqlite3-with-db-stream (file stream-var &rest form)
  (declare (indent 2))
  `(let ((,stream-var (sqlite3-stream-open file)))
     (unwind-protect
         (progn ,@form)
       (sqlite3-stream-close ,stream-var))))

;; TODO order by where
(defun sqlite3-db-select-from-table (file table)
  (sqlite3-with-db-stream file stream
    (sqlite3-stream--read-result
     stream (format "SELECT * FROM %s" table))))

(defun sqlite3-db-tables (file)
  (sqlite3-with-db-stream file stream
    (sqlite3-stream--tables stream)))

(defun sqlite3-db-table-columns (file table)
  (mapcar
   (lambda (r) (nth 1 r))
   (sqlite3-db-table-info file table)))

(defun sqlite3-db-table-info (file table)
  "See `sqlite3-stream--table-info'"
  (sqlite3-with-db-stream file stream
    (sqlite3-stream--table-info stream table)))

;;TODO other file
(require 'ert)

(ert-deftest sqlite3-normal-0001 ()
  :tags '(sqlite3)
  (let* ((db (make-temp-file "sqlite3-test-"))
         (stream (sqlite3-stream-open db)))
    (unwind-protect
        (progn
          (should (sqlite3-stream--send-query stream "CREATE TABLE hoge (id INTEGER PRIMARY KEY, text TEXT)"))
          (should (equal (sqlite3-db-table-info db "hoge") 
                         '((0 "id" "INTEGER" nil "" t) (1 "text" "TEXT" nil "" nil))))
          (should (sqlite3-stream--send-query stream "INSERT INTO hoge VALUES (1, 'a')"))
          (should (sqlite3-stream--send-query stream "INSERT INTO hoge VALUES (2, 'b')"))
          (should (equal (sqlite3-stream--read-result
                          stream "SELECT * FROM hoge ORDER BY id")
                         '(("id" "text") ("1" "a") ("2" "b"))))
          (should (sqlite3-stream--send-query stream "UPDATE hoge SET id = id + 10, text = text || 'z'"))
          (should (equal
                   (sqlite3-stream--read-result stream "SELECT * FROM hoge")
                   '(("id" "text") ("11" "az") ("12" "bz"))))
          (should (sqlite3-stream--send-query stream "DELETE FROM hoge WHERE id = 11"))
          (should (equal
                   (sqlite3-stream--read-result stream "SELECT * FROM hoge")
                   '(("id" "text") ("12" "bz"))))
          )
      (sqlite3-stream-close stream))))

(ert-deftest sqlite3-irregular-0001 ()
  :tags '(sqlite3)
  (let* ((db (make-temp-file "sqlite3-test-"))
         (stream (sqlite3-stream-open db)))
    (unwind-protect
        (progn
          (sqlite3-stream--send-query stream "CREATE TABLE hoge (id INTEGER PRIMARY KEY)")
          (should-error (sqlite3-stream--send-query stream "CREATE TABLE1"))
          (should-error (sqlite3-stream--send-query stream "CREATE TABLE hoge (id INTEGER PRIMARY KEY)"))
          (sqlite3-stream--send-query stream "INSERT INTO hoge VALUES (1)")
          (should-error (sqlite3-stream--send-query stream "INSERT INTO hoge VALUES (1)"))
          )
      (sqlite3-stream-close stream))))

(provide 'sqlite3)

;;; sqlite3.el ends here
