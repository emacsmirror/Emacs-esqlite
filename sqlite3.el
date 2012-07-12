;;; sqlite3.el --- sqlite3 file editing mode.

;; Author: Masahiro Hayashi <mhayashi1120@gmail.com>
;; Keywords: sqlite3
;; URL: http://github.com/mhayashi1120/sqlite3.el/raw/master/sqlite3.el
;; Emacs: GNU Emacs 22 or later
;; Version: 0.0.0
;; Package-Requires: ((pcsv "1.2.0"))

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

;; * save-all-buffers...
;; * Specification
;; allow invalid character in data.
;; disallow invalid character in column and table.

;;; Install:

;; (autoload 'sqlite3-find-file "sqlite3"
;;   "Open as Sqlite3 database" t)

;; (autoload 'sqlite3-file-guessed-database-p "sqlite3"
;;   "Guess the file is a sqlite3 database or not")

;;; TODO:
;; * incremental search all data in table
;; * incremental search invisible text in cell.
;; * number to right.
;; * blob
;; * windows (cygwin)
;; * create hook (ex: commit, update delete...)
;; * clone row
;; * easy filter
;; * order by
;; * sqlite_temp_master

;; * sqlite3-mode
;;     table is valid -> schema -> read data

;;; Code:

;;TODO when table is locked

(eval-when-compile
  (require 'cl))

(require 'pcsv)

(defgroup sqlite3 ()
  "Manipulate sqlite3 database."
  :group 'applications)

;; external variables
(defvar indent-tabs-mode)
(defvar revert-buffer-function)
(defvar last-command)
(defvar tool-bar-mode)
(defvar tool-bar-images-pixel-height)
(defvar menu-bar-mode)
(defvar last-command)
(defvar quit-flag)
(defvar with-timeout-timers)
(defvar revert-buffer-function)

(defcustom sqlite3-program "sqlite3"
  "Command name or path to command."
  :type 'file
  :group 'sqlite3)

(defcustom sqlite3-use-highlight-line t
  "Use `hl-line-mode' or not."
  :type 'boolean
  :group 'sqlite3)

(defface sqlite3-header-background
  '((((type x w32 mac ns) (class color))
     :background "LightSteelBlue" :foreground "black")
    (((class color))
     (:background "white" :foreground "black")))
  "Face to fontify background of header line."
  :group 'sqlite3)

(defface sqlite3-selected-face
  '((t (:inherit mode-line-highlight)))
  "Face for highlighting current cell."
  :group 'sqlite3)

(defface sqlite3-error-line-face
  '((t (:inherit isearch-fail)))
  "Face for highlighting failed part in changing row."
  :group 'sqlite3)

(defface sqlite3-null-face
  '((t (:inherit font-lock-keyword-face)))
  "Face for any NULL."
  :group 'sqlite3)

(defface sqlite3-mode-table-face
  '((t (:inherit font-lock-function-name-face)))
  "todo Face to fontify background of header line."
  :group 'sqlite3)

;;TODO use sqlite3-mode header-line?
(defface sqlite3-mode-column-face
  '((t (:inherit font-lock-variable-name-face)))
  "todo Face to fontify background of header line."
  :group 'sqlite3)

;;;
;;; Sqlite3 file handling api command
;;;

;;;###autoload
(defun sqlite3-find-file (file)
  "Open FILE as Sqlite3 database"
  (interactive "FSqlite3 File: ")
  (unless (sqlite3-file-guessed-database-p file)
    (error "Not a valid database file"))
  (let ((buf (get-file-buffer file)))
    (unless buf
      (setq buf (create-file-buffer (file-name-nondirectory file)))
      (with-current-buffer buf
        (set-visited-file-name file)
        (sqlite3-view-mode)))
    (switch-to-buffer buf)))

;;;###autoload
(defun sqlite3-file-guessed-database-p (file)
  "Guess the FILE is a sqlite3 database or not."
  (and (file-regular-p file)
       (with-temp-buffer
         (insert-file-contents file nil 0 256)
         (looking-at sqlite3-file-header-regexp))))

;;;###autoload
(defun sqlite3-view-mode ()
  "TODO"
  (interactive)
  (set-buffer-modified-p nil)
  (sqlite3-mode-open-schema-mode))

;;;
;;; sqlite3-mode
;;;

(defvar sqlite3-mode-map nil)

(unless sqlite3-mode-map
  (let ((map (make-sparse-keymap)))

    (suppress-keymap map)

    (define-key map "\C-c\C-q" 'sqlite3-mode-send-query)
    (define-key map "\C-x\C-s" 'sqlite3-mode-commit-changes)
    (define-key map "\C-c\C-o" 'sqlite3-mode-open-table)
    (define-key map "\C-c\C-r" 'sqlite3-mode-rollback)
    (define-key map "\C-c\C-c" 'sqlite3-mode-toggle-view)
    (define-key map "g" 'revert-buffer)

    (setq sqlite3-mode-map map)))

(defcustom sqlite3-mode-hook nil
  "Hook called enter the `sqlite3-mode'."
  :group 'sqlite3
  :type 'hook)

(defcustom sqlite3-mode-before-transaction-hook nil
  "Run before transaction is started."
  :group 'sqlite3
  :type 'hook)

(defcustom sqlite3-mode-after-transaction-hook nil
  "Run after transaction is finished. (commit / rollback)"
  :group 'sqlite3
  :type 'hook)

(defvar sqlite3-mode--context nil)
(make-variable-buffer-local 'sqlite3-mode--context)
(put 'sqlite3-mode--context 'permanent-local t)

(defvar sqlite3-mode--default-page-rows 100)

(defconst sqlite3-mode--cell-min-width 3)

;;TODO -> sqlite3-view-mode
(define-derived-mode sqlite3-mode fundamental-mode "Sqlite3"
  (unless buffer-file-name
    (error "Not a file buffer"))
  (let ((inhibit-read-only t))
    (erase-buffer))
  (remove-overlays (point-min) (point-max))
  (sqlite3-mode--new-context)
  (setq buffer-undo-list t)
  (setq truncate-lines t)
  (setq indent-tabs-mode nil)
  (setq buffer-read-only t)
  (setq header-line-format nil)
  (add-hook 'kill-buffer-hook
            'sqlite3-mode--after-kill-buffer nil t)
  (when (fboundp 'hl-line-mode)
    (hl-line-mode -1))
  ;; disable creating #hoge.sqlite# file
  (set (make-local-variable 'backup-inhibited) t)
  (auto-save-mode -1)
  (sqlite3-mode-setup-mode-line)
  (run-mode-hooks 'sqlite3-mode-hook))

(defun sqlite3-mode-commit-changes ()
  "Commit changes to database file.
If changed data violate database constraint, transaction will be rollback.
"
  (interactive)
  (unless (eq (sqlite3-mode-stream-status) 'transaction)
    (error "Commit has not been started"))
  (sqlite3-table-mode--before-move-page)
  (when (y-or-n-p "Commit all changes? ")
    (sqlite3-mode--transaction-commit)
    ;; sync with physical data.
    (sqlite3-table-mode-redraw-page)))

(defun sqlite3-mode-rollback ()
  "Discard all changes."
  (interactive)
  (unless (eq (sqlite3-mode-stream-status) 'transaction)
    (error "Have not began a transaction"))
  (unless (y-or-n-p "Really discard changes? ")
    (signal 'quit nil))
  (sqlite3-mode--transaction-rollback)
  (sqlite3-table-mode-redraw-page))

(defun sqlite3-mode-reset ()
  "Cause of unknown problem of editing buffer, reset sqlite3 command stream
if you want."
  (interactive)
  (when (y-or-n-p "Restart sqlite3 process with discarding changes? ")
    (when (sqlite3-mode-ref :stream)
      (sqlite3-stream-close (sqlite3-mode-ref :stream)))
    (sqlite3-mode--check-stream)
    ;;TODO generic function
    (sqlite3-table-mode-redraw-page)))

;;TODO separate table-mode schema-mode
(defun sqlite3-mode-send-query (query)
  "TODO"
  (interactive "sSQL: ")
  ;;TODO transaction
  (sqlite3-mode--check-table-row)
  (sqlite3-mode--execute-sql query)
  (sqlite3-table-mode-redraw-page))

(defun sqlite3-mode-open-schema-mode ()
  "TODO"
  (interactive)
  (sqlite3-mode--check-stream)
  (sqlite3-schema-mode)
  (sqlite3-schema-mode-draw-view)
  (set-buffer-modified-p nil)
  ;;TODO preserve schema view opened icon.
  ;;TODO defcustom
  (run-hooks 'sqlite3-schema-mode-hook))

(defun sqlite3-mode--new-context ()
  (unless sqlite3-mode--context
    (setq sqlite3-mode--context
          (list
           :stream nil
           :transaction nil))))

(defun sqlite3-mode-ref (key)
  (plist-get sqlite3-mode--context key))

(defun sqlite3-mode-set (key value)
  (plist-put sqlite3-mode--context key value))

(defun sqlite3-mode--after-kill-buffer ()
  (when (sqlite3-mode-ref :stream)
    (sqlite3-stream-close (sqlite3-mode-ref :stream)))
  (sqlite3-table-mode--cleanup-timer))

(defun sqlite3-mode--sync-modtime ()
  (set-visited-file-modtime
   (nth 5 (file-attributes buffer-file-name))))

;;TODO separate mode-line-format each mode
(defun sqlite3-mode-setup-mode-line ()
  (setq mode-line-process
        '((:eval
           (when (and (eq major-mode 'sqlite3-table-mode)
                      (sqlite3-table-mode-ref :table-name))
             (concat " ["
                     (propertize (sqlite3-table-mode-ref :table-name)
                                 'face 'sqlite3-mode-table-face)
                     ":"
                     (let ((max (sqlite3-table-mode-ref :view :max-page)))
                       (if (and (numberp max) (zerop max))
                           "(No Data)"
                         (format "%d/%s"
                                 (1+ (sqlite3-table-mode-ref :source :page))
                                 (or max "Unknown"))))
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
                (propertize "No Process" 'face 'shadow)))))))))

(defun sqlite3-mode--to-text (datum)
  (cond
   ((stringp datum)
    (let ((oneline (or
                    (and (string-match "^\\([^\n]+\\)" datum)
                         (match-string 1 datum))
                    datum)))
      (replace-regexp-in-string "\t" "\\\\t" oneline)))
   ((eq datum :null) "null")
   (t "")))

(defun sqlite3-mode--calculate-width (data)
  ;; decide list length by header line
  (loop with all-width = (make-list (length (car data))
                                    sqlite3-mode--cell-min-width)
        for row in data
        do (loop for datum in row
                 for pair on all-width
                 for idx from 0
                 do (let* ((text (sqlite3-mode--to-text datum))
                           (wid (string-width text)))
                      (setcar pair (max (car pair) wid))))
        finally return all-width))

(defconst sqlite3--rowid-columns
  '("_ROWID_" "ROWID" "OID"))

(defun sqlite3-mode-property-region (point property &optional restrict-line)
  (let ((val (get-text-property point property)))
    (and val
         (let* ((start (previous-single-property-change
                        point property
                        nil (or (and restrict-line (line-beginning-position))
                                (point-min))))
                (end (next-single-property-change
                      point property
                      nil (or (and restrict-line (line-end-position))
                              (point-max)))))
           (unless (eq (get-text-property start property) val)
             (setq start (point)))
           (unless (eq (get-text-property (1- end) property) val)
             (setq end (point)))
           (cons start end)))))

(defun sqlite3-mode--propertize-background-header (string)
  (let ((end (length string)))
    (add-text-properties 0 end
                         `(
                           face sqlite3-header-background
                                tab-separator t)
                         string)
    string))

(defvar sqlite3-mode-header-column-separator
  (let ((sep " "))
    (sqlite3-mode--propertize-background-header sep)
    (propertize sep 'display
                (list 'space :width 1)))
  "String used to separate tabs.")

(defun sqlite3-mode--put-error (msg)
  (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
    (overlay-put ov 'sqlite3-error-row-p t)
    (overlay-put ov 'sqlite3-error-message msg)
    (overlay-put ov 'face 'sqlite3-error-line-face)))

(defun sqlite3-mode--get-error ()
  (loop for o in (overlays-in (line-beginning-position) (line-end-position))
        if (overlay-get o 'sqlite3-error-row-p)
        return (overlay-get o 'sqlite3-error-message)))

(defun sqlite3-mode--clear-error ()
  (remove-overlays (line-beginning-position) (line-end-position)
                   'sqlite3-error-row-p t))

;;TODO generic ?
(defun sqlite3-mode--check-table-row ()
  (let ((errs (sqlite3--filter
               (lambda (o)
                 (overlay-get o 'sqlite3-error-row-p))
               (overlays-in (point-min) (point-max)))))
    (cond
     ((null errs) t)
     ((y-or-n-p "Non saved errors are exists. Really continue? ") t)
     (t (signal 'quit nil)))))

;;TODO hack function make obsolete later
(defun sqlite3-mode-open-table (table)
  (interactive
   (let ((table (sqlite3-mode--read-table-name)))
     (list table)))
  (sqlite3-mode--check-stream)
  (sqlite3-table-mode)
  (sqlite3-table-mode--load-schema table)
  (let ((source (copy-sequence (sqlite3-table-mode-ref :source))))
    (sqlite3-table-mode--draw-page source)
    ;; redraw header forcibly
    (sqlite3-table-mode--delayed-draw-header t)))

(defvar sqlite3-mode-read-table-history nil)
(defun sqlite3-mode--read-table-name ()
  (sqlite3-mode--check-stream)
  ;;TODO accept subquery?
  ;;   -> read-only view.
  (let ((completion-ignore-case t))
    (completing-read
     "Table: "
     (sqlite3-tables (sqlite3-mode-ref :stream))
     nil t nil 'sqlite3-mode-read-table-history)))

(defun sqlite3-mode--execute-sql (sql)
  (sqlite3-mode--check-stream)
  (sqlite3-stream-execute-sql (sqlite3-mode-ref :stream) sql))

(defun sqlite3-mode--check-stream ()
  "Check current buffer's database file is opend by sqlite."
  (let ((stream (sqlite3-mode-ref :stream)))
    (unless (and stream
                 (eq (process-status stream) 'run))
      (setq stream (sqlite3-stream-open buffer-file-name))
      (sqlite3-mode-set :stream stream))))

(defun sqlite3-mode-query (query &optional ommit-header)
  (sqlite3-mode--check-stream)
  (let* ((stream (sqlite3-mode-ref :stream))
         (data (sqlite3-stream-execute-query stream query)))
    (if ommit-header
        (cdr data)
      data)))

(defun sqlite3-mode-stream-status ()
  (let ((stream (sqlite3-mode-ref :stream)))
    (cond
     ((null stream) 'exit)
     ((not (eq (process-status stream) 'run)) 'exit)
     ((with-current-buffer (process-buffer stream)
        (sqlite3-prompt-p))
      (cond
       ((sqlite3-mode-ref :transaction)
        'transaction)
       (t
        'prompt)))
     (t 'querying))))

(defun sqlite3-mode--transaction-begin ()
  (run-hooks 'sqlite3-mode-before-transaction-hook)
  (sqlite3-mode--execute-sql "BEGIN")
  (sqlite3-mode-set :transaction t))

(defun sqlite3-mode--transaction-rollback ()
  (sqlite3-mode--execute-sql "ROLLBACK")
  (sqlite3-mode-set :transaction nil)
  (sqlite3-mode-safe-run-hooks 'sqlite3-mode-after-transaction-hook))

(defun sqlite3-mode--transaction-commit ()
  (sqlite3-mode--execute-sql "COMMIT")
  (sqlite3-mode-set :transaction nil)
  (sqlite3-mode-safe-run-hooks 'sqlite3-mode-after-transaction-hook))

(defun sqlite3-mode-safe-run-hooks (hook)
  (dolist (f (and (boundp hook)
                  (symbol-value hook)))
    (condition-case err
        (funcall f)
      (error
       (message "Sqlite3 Error: %s" err)
       (sit-for 0.5)))))

;;;
;;; sqlite3-table-mode
;;;

(defvar sqlite3-table-mode-map nil)

(unless sqlite3-table-mode-map

  (let ((map (make-sparse-keymap)))

    (set-keymap-parent map sqlite3-mode-map)

    (define-key map "\C-c\C-d" 'sqlite3-table-mode-delete-row)
    (define-key map "\C-c\C-k" 'sqlite3-table-mode-shrink-column)
    (define-key map "\C-c\C-l" 'sqlite3-table-mode-widen-column)
    (define-key map "\C-c\C-j" 'sqlite3-table-mode-jump-to-page)
    (define-key map "\C-c\C-n" 'sqlite3-table-mode-new-row)
    (define-key map "\C-c\ew" 'sqlite3-table-mode-copy-cell)
    (define-key map "\C-c\C-y" 'sqlite3-table-mode-paste-cell)
    (define-key map "\C-c>" 'sqlite3-table-mode-forward-page)
    (define-key map "\C-c<" 'sqlite3-table-mode-backward-page)
    (define-key map "F" 'sqlite3-table-mode-forward-page)
    (define-key map "B" 'sqlite3-table-mode-backward-page)
    (define-key map "\C-i" 'sqlite3-table-mode-forward-cell)
    (define-key map "\e\C-i" 'sqlite3-table-mode-backward-cell)
    (define-key map "\C-m" 'sqlite3-table-mode-start-edit)
    (define-key map "v" 'sqlite3-table-mode-view-cell)
    (define-key map "h" 'sqlite3-table-mode-previous-column)
    (define-key map "l" 'sqlite3-table-mode-next-column)
    (define-key map "k" 'sqlite3-table-mode-previous-row)
    (define-key map "j" 'sqlite3-table-mode-next-row)
    (define-key map "S" 'sqlite3-mode-open-schema-mode)

    ;; TODO keybinding `#' `%'
    (define-key map "#" (make-sparse-keymap))
    (define-key map "#s" 'sqlite3-table-mode-easy-sort)
    (define-key map "#c" 'sqlite3-table-mode-clear-sort)
    (define-key map "%" (make-sparse-keymap))
    (define-key map "%f" 'sqlite3-table-mode-easy-filter)
    (define-key map "%c" 'sqlite3-table-mode-clear-filter)

    (setq sqlite3-table-mode-map map)))

(defvar sqlite3-table-mode--context nil)
(make-variable-buffer-local 'sqlite3-table-mode--context)

(define-derived-mode sqlite3-table-mode sqlite3-mode "Sqlite3 Table"
  "Sqlite3 table view mode"
  ;;TODO clear when schema-view
  (setq revert-buffer-function
        'sqlite3-table-mode-revert)
  (add-hook 'post-command-hook
            'sqlite3-table-mode--post-command nil t)
  (add-hook 'pre-command-hook
            'sqlite3-table-mode--pre-command nil t)
  (cond
   ((null sqlite3-use-highlight-line))
   ((require 'hl-line nil t)
    (hl-line-mode 1))
   (t
    ;; forcibly disable the customize variable
    (setq sqlite3-use-highlight-line nil)))
  (sqlite3-table-mode--new-context)
  (use-local-map sqlite3-table-mode-map)
  (unless sqlite3-table-mode--popup-timer
    (setq sqlite3-table-mode--popup-timer
          (run-with-idle-timer
           1 t 'sqlite3-table-mode-popup-contents))))

(defun sqlite3-table-mode-view-cell ()
  "View current cell with opening subwindow."
  (interactive)
  (let ((value (sqlite3-table-mode-current-value)))
    (unless value
      (error "No cell is here"))
    (let ((buf (sqlite3-table-mode--create-cell-buffer value)))
      (display-buffer buf))))

(defun sqlite3-table-mode-new-row ()
  "Add new row after the cursor."
  (interactive)
  (when sqlite3-table-mode--highlight-overlay
    (move-overlay sqlite3-table-mode--highlight-overlay
                  (point-max) (point-max)))
  (forward-line 0)
  (let* ((num (length (sqlite3-table-mode-ref :view :columns)))
         (row (cons nil (make-list num nil)))
         (inhibit-read-only t))
    (insert "\n")
    (forward-line -1)
    (sqlite3-table-mode--insert-row row)
    (forward-line 0)))

(defun sqlite3-table-mode-delete-row ()
  "Delete current row."
  (interactive)
  (when (y-or-n-p "Really delete this row? ")
    (unless (eq (sqlite3-mode-stream-status) 'transaction)
      (sqlite3-mode--transaction-begin))
    (sqlite3-table-mode--update-with-handler
     (let* ((row (get-text-property (point) 'sqlite3-mode-row))
            (rowid (plist-get row :rowid))
            (sql (sqlite3-table-mode--delete-qhsql rowid)))
       (message "Deleting...")
       ;; not a query, wait until prompt.
       (sqlite3-mode-query sql)))
    (let ((inhibit-read-only t))
      (delete-region (line-beginning-position)
                     (line-beginning-position 2)))))

(defvar sqlite3-table-mode--killed nil)
(defun sqlite3-table-mode-copy-cell ()
  "Copy cell."
  (interactive)
  (let ((cell (get-text-property (point) 'sqlite3-mode-cell)))
    (unless cell
      (error "No cell is here"))
    (let* ((value (sqlite3-table-mode--cell-value cell))
           (text (or (and (stringp value) value) "")))
      ;; To save the :null value use the elisp variable.
      (setq sqlite3-table-mode--killed value)
      (kill-new text)))
  (message "Current cell is saved."))

(defun sqlite3-table-mode-paste-cell ()
  "Insert kill-ring to current cell."
  (interactive)
  (sqlite3-table-mode--call/edit-cell
   (lambda (cell)
     (let ((text (current-kill 0)))
       (if (and (equal text "")
                (eq sqlite3-table-mode--killed :null))
           :null
         text)))))

(defun sqlite3-table-mode-start-edit ()
  "Edit current cell with opening subwindow."
  (interactive)
  (when (plusp (recursion-depth))
    (error "%s"
           (substitute-command-keys
            (concat 
             "Other recursive edit is working. "
             "Type \\[abort-recursive-edit] to quit previous recursive edit"))))
  (sqlite3-table-mode--call/edit-cell
   (lambda (cell)
     (let ((value (sqlite3-table-mode--cell-value cell)))
       (sqlite3-table-mode-open-edit-window value)))))

(defun sqlite3-table-mode-shrink-column (&optional arg)
  "Shrink current column"
  (interactive "p")
  (sqlite3-table-mode--resize-column (* -1 arg)))

(defun sqlite3-table-mode-widen-column (&optional arg)
  "Widen current column"
  (interactive "p")
  (sqlite3-table-mode--resize-column arg))

(defun sqlite3-table-mode-jump-to-page (page)
  "Jump to selected PAGE"
  (interactive
   (list (read-number "Page: ")))
  (sqlite3-table-mode--before-move-page)
  (sqlite3-table-mode--move-page
   (1- page) "No such page"))

(defun sqlite3-table-mode-forward-page (&optional arg)
  "Forward page."
  (interactive "p")
  (sqlite3-table-mode--before-move-page)
  (sqlite3-table-mode--move-page
   (+ (sqlite3-table-mode-ref :source :page) arg)
   "No more next page"))

(defun sqlite3-table-mode-backward-page (&optional arg)
  "Backward page."
  (interactive "p")
  (when (= (sqlite3-table-mode-ref :source :page) 0)
    (error "This is a first page"))
  (sqlite3-table-mode--before-move-page)
  (sqlite3-table-mode--move-page
   (- (sqlite3-table-mode-ref :source :page) arg)
   "No more previous page"))

(defun sqlite3-table-mode-next-row (&optional arg)
  "Goto next line of row."
  (interactive "p")
  (sqlite3-table-mode--move-line arg)
  ;;TODO next page
  )

(defun sqlite3-table-mode-previous-row (&optional arg)
  "Goto previous line of row."
  (interactive "p")
  (sqlite3-table-mode--move-line (- arg))
  ;;TODO prev page
  )

(defun sqlite3-table-mode-next-column ()
  "Goto next column."
  (interactive)
  (let ((next (sqlite3-table-mode--next-cell t)))
    (when next
      (goto-char next))))

(defun sqlite3-table-mode-previous-column ()
  "Goto previous column."
  (interactive)
  (let ((prev (sqlite3-table-mode--previous-cell (point) t)))
    (when prev
      (goto-char prev))))

(defun sqlite3-table-mode-forward-cell ()
  "Forward cell over the row."
  (interactive)
  (let ((next (sqlite3-table-mode--next-cell)))
    (when next
      (goto-char next))))

(defun sqlite3-table-mode-backward-cell ()
  "Backward cell over the row."
  (interactive)
  (let ((prev (sqlite3-table-mode--previous-cell (point))))
    (when prev
      (goto-char prev))))

;;TODO name
(defun sqlite3-table-mode-easy-sort (&optional desc)
  (interactive "P")
  (let ((cell (get-text-property (point) 'sqlite3-mode-cell)))
    (unless cell
      (error "No column is here"))
    (let* ((source (copy-sequence (sqlite3-table-mode-ref :source)))
           (column (plist-get cell :column))
           (order (plist-get source :order))
           (name (plist-get column :name))
           (appended (format "%s %s" name (if desc "DESC" "ASC")))
           (new-order(if order
                         (concat order " , " appended)
                       appended)))
      (plist-put source :order new-order)
      (sqlite3-table-mode--draw-page source))))

(defun sqlite3-table-mode-clear-sort (&optional all)
  (interactive "P")
    ;;TODO currently clear all
  (sqlite3-table-mode-set nil :source :order)
  (sqlite3-table-mode-redraw-page))

(defun sqlite3-table-mode-easy-filter ()
  (interactive)
  (let* ((cell (get-text-property (point) 'sqlite3-mode-cell))
         (column (plist-get cell :column)))
    (unless cell
      (error "No column is here"))
    (let* ((source (copy-sequence (sqlite3-table-mode-ref :source)))
           (where (plist-get source :where))
           (name (plist-get column :name))
           ;;TODO show current where
           (str (read-string (format "WHERE %s " name)))
           (appended (format "%s %s" name str))
           (new-where (if where
                          (concat where " AND " appended)
                        appended)))
      (plist-put source :where new-where)
      (plist-put source :page 0)
      ;;TODO current editing row
      ;;TODO restore old where if redraw failed.
      (sqlite3-table-mode--draw-page source))))

;; TODO
(defun sqlite3-table-mode-clear-filter (&optional all)
  (interactive "P")
  ;;TODO currently clear all
  (let ((source (copy-sequence (sqlite3-table-mode-ref :source))))
    (plist-put source :where nil)
    (sqlite3-table-mode--draw-page source)))

;;TODO
(defun sqlite3-table-mode-isearch ()
  (interactive)
  (let* ((columns (sqlite3-table-mode-ref :view :columns))
         (source (sqlite3-table-mode-ref :source))
         (text "")
         (orig-where (or (plist-get source :where) ""))
         done)
    (while (not done)
      (let ((c (read-char (format "isearch: %s" text))))
        (setq text (concat text (char-to-string c)))
        ;; TODO quote text % _
        (let* ((like (format "%%%s%%" text))
               (src (copy-sequence source))
               (filters (cons 'or
                              (mapcar
                               (lambda (col)
                                 (list col "like" like))
                               columns))))
          (plist-put src 
                     :where (sqlite3-table-mode--compile-filters filters))
          (sqlite3-table-mode--draw-page src))))))

(defun sqlite3-table-mode--new-context ()
  (unless sqlite3-table-mode--context
    (setq sqlite3-table-mode--context
          (list
           :table-name nil
           :table-schema nil
           :table-rowid nil
           :view (list :max-page nil
                       :page-row sqlite3-mode--default-page-rows
                       :columns nil)
           :source (list :order nil :where nil :page 0)))))

(defun sqlite3-table-mode-ref (&rest keys)
  (loop with context = sqlite3-table-mode--context
        for key in keys
        while context
        do (setq context (plist-get context key))
        finally return context))

;;TODO rename
(defun sqlite3-table-mode-set2 (key value)
  (plist-put sqlite3-table-mode--context key value))

(defun sqlite3-table-mode-set (value &rest keys)
  (let* ((rev (reverse keys))
         (last (car rev))
         (path (nreverse (cdr rev))))
    (plist-put (apply 'sqlite3-table-mode-ref path) last value)))

(defun sqlite3-table-mode--call/edit-cell (proc)
  (let ((cell (get-text-property (point) 'sqlite3-mode-cell)))
    (unless cell
      (error "No cell is here"))
    ;; verify before start editing although
    ;; start transaction after change value.
    (unless (verify-visited-file-modtime (current-buffer))
      (error "Database was modified after open"))
    (let ((pos (point-marker))
          (value (sqlite3-table-mode--cell-value cell))
          ;; call external function.
          (new (funcall proc cell)))
      (unless (eq (get-text-property pos 'sqlite3-mode-cell) cell)
        (error "Table buffer was modified"))
      (unless (equal value new)
        (unless (eq (sqlite3-mode-stream-status) 'transaction)
          (sqlite3-mode--transaction-begin))
        (let ((inhibit-read-only t))
          (goto-char pos)
          (sqlite3-table-mode--replace-current-cell new))))))

(defvar sqlite3-table-mode--popup-timer nil)

(defun sqlite3-table-mode--cleanup-timer ()
  (when sqlite3-table-mode--popup-timer
    (loop for b in (buffer-list)
          if (with-current-buffer b
               (derived-mode-p 'sqlite3-mode))
          return t
          finally (progn
                    (cancel-timer sqlite3-table-mode--popup-timer)
                    (setq sqlite3-table-mode--popup-timer nil)))))

(defun sqlite3-table-mode--cell-value (cell)
  (or
   (plist-get cell :edit-value)
   (plist-get cell :source-value)))

(defun sqlite3-table-mode-current-value ()
  (let ((cell (get-text-property (point) 'sqlite3-mode-cell)))
    (sqlite3-table-mode--cell-value cell)))

(defun sqlite3-table-mode-popup-contents ()
  (save-match-data
    (when (and (eq major-mode 'sqlite3-table-mode)
               ;; suppress tooltip if last command were C-g
               (not (eq last-command 'keyboard-quit)))
      (let ((cell (get-text-property (point) 'sqlite3-mode-cell)))
        (when (plist-get cell :truncated)
          (let ((value (sqlite3-table-mode--cell-value cell)))
            (when value
              (sqlite3-table-mode-tooltip-show value))))))))

(defvar sqlite3-table-mode--cell-buffer " *Sqlite3 Cell* ")

(defun sqlite3-table-mode--create-cell-buffer (value)
  (let ((buf (get-buffer-create sqlite3-table-mode--cell-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (cond
         ((stringp value)
          (setq sqlite3-cell-mode--null nil)
          (insert value))
         ((eq :null value)
          (setq sqlite3-cell-mode--null t))))
      (sqlite3-cell-mode-setup)
      (setq buffer-undo-list nil)
      (set-buffer-modified-p nil))
    buf))

(defun sqlite3-table-mode-open-edit-window (value)
  (let* ((config (current-window-configuration))
         (buf (sqlite3-table-mode--create-cell-buffer value)))
    (pop-to-buffer buf)
    (message "%s"
             (substitute-command-keys
              (concat "Type \\[exit-recursive-edit] to finish the edit."
                      "Type \\[abort-recursive-edit] to cancel the edit.")))
    (unwind-protect
        (progn
          (recursive-edit)
          (let ((new-value (sqlite3-cell-mode-value)))
            new-value))
      (set-window-configuration config))))

(defun sqlite3-table-mode-tooltip-show (text)
  ;; show tooltip at cursor point.
  ;; Unable calculate exactly absolute coord but almost case is ok.
  ;;TODO consider `x-max-tooltip-size'
  (let* ((xy (sqlite3-table-mode-tooltip-absolute-coordinate (point)))
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

(defun sqlite3-table-mode-tooltip-absolute-coordinate (point)
  (let* ((posn (posn-at-point point))
         (xy (posn-x-y posn))
         (x (+ (sqlite3-table-mode-tooltip-frame-posn 'top)
               (car xy)))
         (y (truncate
             (+ (sqlite3-table-mode-tooltip-frame-posn 'left)
                (cdr xy)
                ;; FIXME calculate fringe of bar roughly..
                (* (or (and (boundp 'tool-bar-mode)
                            tool-bar-mode tool-bar-images-pixel-height) 0)
                   1.5)
                (* (or (and (boundp 'menu-bar-mode)
                            menu-bar-mode (frame-char-height)) 0)
                   1.5)))))
    (cons x y)))

(defun sqlite3-table-mode-tooltip-frame-posn (prop)
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

;;
;; `sqlite3-table-mode' inner functions
;;

;;TODO rename commit? transit?
(defun sqlite3-table-mode--before-move-page ()
  (sqlite3-table-mode--apply-changes)
  (sqlite3-mode--check-table-row))

(defun sqlite3-table-mode--resize-column (arg)
  (let* ((col (sqlite3-table-mode--column-index))
         (column (nth col (sqlite3-table-mode-ref :view :columns)))
         (size (+ (plist-get column :width) arg))
         (modified (buffer-modified-p)))
    (plist-put column :width (max size sqlite3-mode--cell-min-width))
    (save-excursion
      (let ((inhibit-read-only t))
        (goto-char (point-min))
        (while (not (eobp))
          (loop repeat col
                do (sqlite3-table-mode-next-column))
          (sqlite3-table-mode--replace-current-cell
           (sqlite3-table-mode-current-value))
          (forward-line 1))))
    (set-buffer-modified-p modified)
    (setq sqlite3-table-mode--previous-hscroll nil)))

(defvar sqlite3-table-mode--moved-column nil)
(defun sqlite3-table-mode--move-line (arg)
  (let ((col (if (memq last-command
                       '(sqlite3-table-mode-previous-row
                         sqlite3-table-mode-next-row))
                 sqlite3-table-mode--moved-column
               (current-column))))
    (setq sqlite3-table-mode--moved-column col)
    (let ((rest (forward-line arg)))
      (move-to-column col)
      (zerop rest))))

(defun sqlite3-table-mode--pre-command ()
  (condition-case err
      (progn
        (sqlite3-table-mode--pre-handle-rowid))
    (error
     (message "%s" err))))

(defun sqlite3-table-mode--post-command ()
  (condition-case err
      (progn
        (sqlite3-table-mode--post-change-row)
        (sqlite3-table-mode--highlight-selected)
        (sqlite3-table-mode--show-cell-after-move)
        (sqlite3-table-mode--delayed-draw-header))
    (error
     (message "%s" err))))

(defvar sqlite3-table-mode--processing-row nil)
(make-variable-buffer-local 'sqlite3-table-mode--processing-row)

(defun sqlite3-table-mode--pre-handle-rowid ()
  (setq sqlite3-table-mode--processing-row
        (get-text-property (point) 'sqlite3-mode-row)))

(defun sqlite3-table-mode--post-change-row ()
  (when (and sqlite3-table-mode--processing-row
             (not (eq sqlite3-table-mode--processing-row
                      (get-text-property (point) 'sqlite3-mode-row))))
    (sqlite3-table-mode--apply-changes)
    (let ((msg (sqlite3-mode--get-error)))
      (when msg
        (if (current-message)
            (message "%s %s" (current-message) msg)
          (message "%s" msg))))))

(defmacro sqlite3-table-mode--update-with-handler (&rest form)
  "Update current row with FORM."
  `(condition-case err
       (progn
         ,@form
         (sqlite3-mode--clear-error))
     ;;TODO FIXME
     (error
      (sqlite3-mode--put-error (format "%s" (cdr err)))
      (signal (car err) (cdr err)))))

(defun sqlite3-table-mode--sync-row (point row)
  ;; FIXME when table have _rowid_, oid, rowid all meta columns.
  (let* ((new-rowid (sqlite3-table-mode--new-rowid row))
         (query (format "SELECT %s, * FROM %s WHERE %s = %s"
                        (sqlite3-table-mode-ref :table-rowid)
                        (sqlite3-table-mode-ref :table-name)
                        (sqlite3-table-mode-ref :table-rowid)
                        new-rowid))
         (data (sqlite3-mode-query query t)))
    (save-excursion
      (goto-char point)
      (let ((inhibit-read-only t))
        (delete-region (line-beginning-position) (line-end-position))
        (sqlite3-table-mode--insert-row (car data))))))

(defun sqlite3-table-mode--new-rowid (row)
  (let* ((schema (sqlite3-table-mode-ref :table-schema))
         (keys (sqlite3--filter (lambda (x) (nth 5 x)) schema)))
    (cond
     ((or (/= (length keys) 1)
          ;;TODO only INTEGER? NUMERIC?
          (not (equal (nth 2 (car keys)) "INTEGER")))
      ;; ROWID
      (car row))
     (t
      ;; single INTEGER primary key is used as ROWID
      (let ((pair (assoc (nth 1 (car keys)) row)))
        (if (and pair (nth 2 pair))
            ;; primary key value
            (nth 2 pair)
          (car row)))))))

(defun sqlite3-table-mode--row-is-modified (row)
  (loop for (name source edit) in (cdr row)
        unless (or (null edit) (equal source edit))
        return t))

(defun sqlite3-table-mode--show-cell-after-move ()
  (when (get-buffer-window sqlite3-table-mode--cell-buffer)
    (let ((value (sqlite3-table-mode-current-value)))
      (when value
        (sqlite3-table-mode--create-cell-buffer value)))))

(defvar sqlite3-table-mode--highlight-overlay nil)
(make-variable-buffer-local 'sqlite3-table-mode--highlight-overlay)

(defun sqlite3-table-mode--highlight-selected ()
  (let ((ov (or sqlite3-table-mode--highlight-overlay
                (let ((tmp (make-overlay (point-max) (point-max))))
                  (overlay-put tmp 'face 'sqlite3-selected-face)
                  tmp))))
    (cond
     ((memq ov (overlays-at (point))))
     ((get-text-property (point) 'sqlite3-mode-cell (current-buffer))
      (let* ((region (sqlite3-table-mode--cell-region (point)))
             (start (car region))
             (end (cdr region)))
        (move-overlay ov start end)
        (setq sqlite3-table-mode--highlight-overlay ov)))
     (t
      (move-overlay ov (point-max) (point-max))))))

(defun sqlite3-table-mode--cell-region (point)
  (sqlite3-mode-property-region point 'sqlite3-mode-cell t))


(defun sqlite3-table-mode--previous-cell (point &optional current-line)
  (let ((region (sqlite3-table-mode--cell-region point)))
    (cond
     ((null region)
      (previous-single-property-change
       point 'sqlite3-mode-cell nil
       (if current-line (line-beginning-position) (point-min))))
     ((eq (car region) (point-min))
      (point-min))
     (t
      (sqlite3-table-mode--previous-cell (1- (car region)) current-line)))))

(defun sqlite3-table-mode--next-cell (&optional current-line)
  (let* ((pos (point))
         (region (sqlite3-table-mode--cell-region pos))
         (next (next-single-property-change
                (or (cdr region) pos)
                'sqlite3-mode-cell nil)))
    (if (and current-line
             (>= next (line-end-position)))
        nil
      next)))

(defun sqlite3-table-mode--truncate-text (width text)
  (truncate-string-to-width text width nil ?\s t))

(defun sqlite3-table-mode--apply-changes ()
  (save-excursion
    (let* ((row (sqlite3-table-mode--convert-row
                 sqlite3-table-mode--processing-row))
           (found (sqlite3-table-mode--goto-row
                   sqlite3-table-mode--processing-row)))
      (cond
       ((not found))
       ((null (car row))
        (sqlite3-table-mode--update-with-handler
         (let ((sql (sqlite3-table-mode--insert-sql row)))
           (message "Inserting...")
           (sqlite3-mode-query sql)     ; no read. wait until prompt.
           (let* ((last (sqlite3-mode-query "SELECT LAST_INSERT_ROWID()"))
                  (rowid (caar last)))
             (sqlite3-table-mode--sync-row found (cons rowid (cdr row))))
           (message "Inserting... Done.")))
        (setq sqlite3-table-mode--processing-row nil))
       ((sqlite3-table-mode--row-is-modified row)
        (sqlite3-table-mode--update-with-handler
         (let ((sql (sqlite3-table-mode--update-sql row)))
           (message "Updating...")
           (sqlite3-mode-query sql)     ; no read. wait until prompt.
           (sqlite3-table-mode--sync-row found row)
           (message "Updating... Done.")))
        (setq sqlite3-table-mode--processing-row nil))
       (t
        (sqlite3-mode--clear-error))))))

(defun sqlite3-table-mode--goto-row (search)
  (let ((first (point))
        (col (current-column)))
    (goto-char (point-min))
    (loop while (not (eobp))
          if (let ((row (get-text-property (point) 'sqlite3-mode-row)))
               (eq search row))
          return (progn (move-to-column col) (point))
          do (forward-line 1)
          finally (progn (goto-char first) nil))))

(defun sqlite3-table-mode--convert-row (row)
  (cons
   (plist-get row :rowid)
   (loop for cell in (plist-get row :cells)
         collect (let ((col (plist-get cell :column)))
                   (list
                    (plist-get col :name)
                    (plist-get cell :source-value)
                    (plist-get cell :edit-value))))))

(defvar sqlite3-table-mode--previous-hscroll nil)
(make-variable-buffer-local 'sqlite3-table-mode--previous-hscroll)

(defun sqlite3-table-mode--delayed-draw-header (&optional force)
  (when force
    (setq sqlite3-table-mode--previous-hscroll nil))
  ;; In the `post-command-hook', `window-hscroll' function still return
  ;; previous value. Although after calling `scroll-right' return correct value.
  (run-with-timer 0.1 nil 'sqlite3-table-mode--draw-header))

(defun sqlite3-table-mode--draw-header ()
  (with-local-quit
    (unless (and sqlite3-table-mode--previous-hscroll
                 (eq sqlite3-table-mode--previous-hscroll (window-hscroll)))
      (cancel-function-timers 'sqlite3-table-mode--draw-header)
      (let* ((disp-headers
              (loop with hscroll = (window-hscroll)
                    ;;  set t after first displaying column in window
                    with flag
                    for col in (sqlite3-table-mode-ref :view :columns)
                    ;; add `sqlite3-mode-header-column-separator' width
                    sum (1+ (plist-get col :width)) into right
                    if (< hscroll right)
                    collect (let ((name (plist-get col :name))
                                  (wid (plist-get col :width)))
                              (unless flag
                                (setq wid (- right hscroll 1)))
                              (setq flag t)
                              (cond
                               ((< wid sqlite3-mode--cell-min-width)
                                ;; Beginning of line header may have too short
                                ;;  length of name.
                                (make-string wid ?\s))
                               (t
                                (propertize
                                 (sqlite3-table-mode--truncate-text
                                  wid name)
                                 'face 'sqlite3-mode-column-face))))))
             (filler (make-string (frame-width) ?\s))
             (tail (sqlite3-mode--propertize-background-header filler))
             (separator sqlite3-mode-header-column-separator)
             (left (car (window-inside-edges))))
        (setq header-line-format
              (and disp-headers
                   (list
                    ;;FIXME after change examples 
                    ;; `scroll-bar-mode' or `linum-mode'.
                    (make-list left separator)
                    (mapconcat 'identity disp-headers separator)
                    tail)))
        (setq sqlite3-table-mode--previous-hscroll (window-hscroll))
        (force-mode-line-update)))))

(defun sqlite3-table-mode--insert-row (row)
  ;; (car row) is ROWID
  (let ((rowobj (list :rowid (car row) :cells nil))
        (cells nil))
    (loop for v in (cdr row)
          for i from 0
          do (progn
               (when (> i 0)
                 (insert " "))
               (let ((cell (sqlite3-table-mode--insert-cell v i nil)))
                 (setq cells (cons cell cells))
                 (plist-put cell :source-value v))))
    (plist-put rowobj :cells (nreverse cells))
    (put-text-property
     (line-beginning-position) (line-end-position)
     'sqlite3-mode-row rowobj)))

(defun sqlite3-table-mode--insert-cell (value index &optional cell)
  (let* ((start (point))
         (column (nth index (sqlite3-table-mode-ref :view :columns)))
         (wid (plist-get column :width))
         (truncated (sqlite3-table-mode--truncate-insert value wid))
         (cell (or cell
                   (list :edit-value nil :truncated truncated
                         :column column))))
    (let ((end (point)))
      (put-text-property start end 'sqlite3-mode-cell cell)
      cell)))

(defun sqlite3-table-mode--truncate-insert (value width)
  "Insert VALUE after point restricted by WIDTH."
  (let* ((pos-beg (point))
         (text (sqlite3-mode--to-text value))
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
                  (let ((start (max pos-beg
                                    (- (point) sqlite3-mode--cell-min-width))))
                    (delete-region start end))
                  (insert (make-string (- next-column (current-column)) ?\.))
                  t)
                 ((not (equal text value)) t)
                 (t nil))))
          ;; visualize NULL value
          (when (eq value :null)
            (put-text-property pos-beg (point) 'face 'sqlite3-null-face))
          truncated)))))

(defun sqlite3-table-mode--column-index ()
  (let* ((curr (get-text-property (point) 'sqlite3-mode-cell))
         (prev (sqlite3-table-mode--previous-cell (point) t))
         (cell (get-text-property
                (max prev (line-beginning-position))
                'sqlite3-mode-cell))
         (column (plist-get cell :column))
         (index (plist-get column :index)))
    (if (eq curr cell)
        0
      (1+ index))))

(defun sqlite3-table-mode--replace-current-cell (value)
  (let* ((pos (point))                  ;save position
         (region (sqlite3-table-mode--cell-region pos)))
    (unless region
      (error "Not a cell"))
    (let* ((cell (get-text-property pos 'sqlite3-mode-cell))
           (column (plist-get cell :column))
           (index (plist-get column :index))
           (row (get-text-property pos 'sqlite3-mode-row))
           ;; save rest of line with properties
           (rest (buffer-substring (cdr region) (line-end-position))))
      (delete-region (car region) (line-end-position))
      (sqlite3-table-mode--insert-cell value index cell)
      (plist-put cell :edit-value value)
      (put-text-property (line-beginning-position) (line-end-position)
                         'sqlite3-mode-row row)
      (insert rest))
    ;; restore previous position
    (goto-char pos)))

;;TODO make generic function
(defun sqlite3-table-mode-redraw-page ()
  (cond
   ((eq major-mode 'sqlite3-table-mode)
    (let ((start (window-start))
          (pos (point))
          (source (sqlite3-table-mode-ref :source)))
      (sqlite3-table-mode--draw-page source t)
      (goto-char pos)
      (set-window-start (selected-window) start)))
   (t (error "TODO"))))

(defun sqlite3-table-mode--delay-max-page (buffer)
  (with-local-quit
    (cancel-function-timers 'sqlite3-table-mode--delay-max-page)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((count (sqlite3-table-mode-max-page)))
          (sqlite3-table-mode-set count :view :max-page))))))

(defun sqlite3-table-mode-max-page ()
  (let* ((query (format
                 (concat
                  "SELECT ROUND((COUNT(*) / %s) + 0.5)"
                  " FROM %s "
                  " WHERE %s")
                 (sqlite3-table-mode-ref :view :page-row)
                 (sqlite3-table-mode-ref :table-name)
                 (or (sqlite3-table-mode-ref :source :where) "1 = 1")))
         (data (sqlite3-mode-query query t))
         (max (caar data)))
    (and (string-match "^\\([0-9]+\\)" max)
         (string-to-number (match-string 1 max)))))

(defun sqlite3-table-mode--schema-rowid (schema)
  (loop for r in sqlite3--rowid-columns
        unless (loop for x in schema
                     if (equal r (upcase (nth 1 x)))
                     return x)
        return r
        finally (error "Unable take valid ROWID column")))

(defun sqlite3-table-mode--clear-page ()
  (sqlite3-table-mode-set nil :view :max-page)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (remove-overlays (point-min) (point-max))))

(defun sqlite3-table-mode--move-page (page error-message)
  (let ((new (copy-sequence (sqlite3-table-mode-ref :source))))
    (plist-put new :page page)
    (sqlite3-table-mode--draw-page new)
    (cond
     ((equal page (sqlite3-table-mode-ref :source :page))
      ;; succeeded
      ;; redraw header forcibly
      (sqlite3-table-mode--delayed-draw-header t))
     (t
      (ding)
      (message "%s" error-message)))))

(defun sqlite3-table-mode--load-schema (name)
  (let* ((schema (sqlite3-table-mode--schema name))
         (rowid-name (sqlite3-table-mode--schema-rowid schema)))
    (sqlite3-table-mode-set2 :table-name name)
    (sqlite3-table-mode-set2 :table-schema schema)
    (sqlite3-table-mode-set2 :table-rowid rowid-name)))

(defun sqlite3-table-mode--schema (table)
  (or
   (and (equal (sqlite3-table-mode-ref :table-name) table)
        (sqlite3-table-mode-ref :table-schema))
   (sqlite3-table-schema (sqlite3-mode-ref :stream) table)))

;;TODO refactor
;;todo remove force
(defun sqlite3-table-mode--draw-page (source &optional force)
  ;; sync mtime with disk file.
  ;; to detect database modifying
  ;; between reading from disk and beginning of transaction.
  (sqlite3-mode--sync-modtime)
  (save-excursion
    (let* ((name (sqlite3-table-mode-ref :table-name))
           (schema (sqlite3-table-mode-ref :table-schema))
           (rowid-name (sqlite3-table-mode-ref :table-rowid))
           (page-row (or (sqlite3-table-mode-ref :view :page-row)
                         sqlite3-mode--default-page-rows))
           (page (or (plist-get source :page) 0))
           (where (or (plist-get source :where) "1 = 1"))
           (order (plist-get source :order))
           (order-by (or (and order (format "ORDER BY %s" order)) ""))
           (query (format
                   (concat "SELECT %s, *"
                           " FROM %s"
                           " WHERE %s"
                           " %s"
                           " LIMIT %s OFFSET %s * %s")
                   rowid-name
                   name where order-by
                   page-row page-row
                   page))
           (data (sqlite3-mode-query query)))
      (cond
       (data
        (sqlite3-table-mode--clear-page)
        (sqlite3-table-mode--set-header data schema)
        (let ((inhibit-read-only t))
          ;; ignore header row
          (dolist (row (cdr data))
            (sqlite3-table-mode--insert-row row)
            (insert "\n"))
          (unless(memq (sqlite3-mode-stream-status) '(transaction))
            (set-buffer-modified-p nil)))
        (setq buffer-read-only t)
        (run-with-idle-timer
         1 nil 'sqlite3-table-mode--delay-max-page
         (current-buffer)))
       ((> (plist-get source :page) 0)
        (plist-put source :page (1- (plist-get source :page))))
       (t
        (sqlite3-table-mode--clear-page)
        (sqlite3-table-mode--set-header nil schema)
        (sqlite3-table-mode-set 0 :view :max-page)))
      (sqlite3-table-mode-set source :source))))

(defun sqlite3-table-mode--set-header (data &optional schema)
  (let* ((lis (or data
                  (list
                   (cons
                    "ROWID"                 ;dummy
                    (loop for def in schema
                          collect (nth 1 def))))))
         (width-def (sqlite3-mode--calculate-width lis))
         (headers (car lis))
         (columns (loop for max in (cdr width-def)
                        for hdr in (cdr headers)
                        for idx from 0
                        collect (list :name hdr
                                      :index idx
                                      :initial-max max
                                      :width (min max 30)))))
    (sqlite3-table-mode-set columns :view :columns)))

;; ORDERS ::= ORDER

;; ORDER ::= (COLUMN TODO)

(defun sqlite3-table-mode--compile-orders (orders)
  (mapconcat
   'sqlite3-table-mode--compile-order
   orders
   ", "))

(defun sqlite3-table-mode--compile-order (order)
  (let ((column (car order))
        (todo (cadr order)))
    (concat (plist-get column :name) " " todo)))

;; FILTERS ::= (AND FILTER ...) | (OR FILTER ...)

;; FILTER ::= (COLUMN OPERATOR) | (COLUMN OPERATOR EXP ...) | FILTERS

;;TODO number and string (quote)

(defconst sqlite3-table-mode--filter-operators
  '(
    ("is null" "IS NULL")
    ("isnot null" "IS NOT NULL")
    ("=" "=" value)
    ("<=" "<=" value)
    ("<" "<" value)
    (">=" ">=" value)
    (">" ">" value)
    ("like" "LIKE" value)
    ("between" "BETWEEN" value "AND" value)
    ;;TODO
    ))

(defun sqlite3-table-mode--read-filter ()
  (let* ((alist sqlite3-table-mode--filter-operators)
         (op (completing-read "TODO: " alist))
         (table (assoc-string op alist)))
    (loop for def in (cdr table)
          collect (cond
                   ((stringp def) def)
                   ((eq def 'value)
                    ;;TODO number | string | column
                    (read-string "Value: "))
                   (t (error "Not supported"))))))

(defun sqlite3-table-mode--compile-filters (filters)
  (concat
   "("
   (mapconcat
    'sqlite3-table-mode--compile-filter
    (cdr filters)
    (cond ((eq (car filters) 'or) " OR ")
          ((eq (car filters) 'and) " AND ")))
   ")"))

(defun sqlite3-table-mode--compile-filter (filter)
  (cond
   ((memq (car filter) '(or and))
    (sqlite3-table-mode--compile-filters filter))
   ((and (listp filter) (= (length filter) 2))
    (let ((column (car filter))
          (operator (cadr filter)))
      (concat "(" (plist-get column :name) " " operator ")")))
   ((and (listp filter) (> (length filter) 2))
    (let ((column (car filter))
          (operator (cadr filter))
          (exps (cddr filter)))
      (concat "(" (plist-get column :name) " " operator " "
              (mapconcat 'sqlite3-format-value exps " ")
              ")")))
   (t
    (error "Invalid filter %s" filter))))

(defun sqlite3-table-mode--update-sql (row)
  (format "UPDATE %s SET %s WHERE %s = %s;"
          (sqlite3-table-mode-ref :table-name)
          (mapconcat
           (lambda (x)
             (format "%s = %s"
                     (car x)
                     (sqlite3-format-value (cdr x))))
           (loop for (name source edit) in (cdr row)
                 if edit
                 collect (cons name edit))
           ", ")
          (sqlite3-table-mode-ref :table-rowid)
          (car row)))

(defun sqlite3-table-mode--insert-sql (row)
  (let (columns values)
    (loop for (name source edit) in (cdr row)
          do (setq columns (cons name columns)
                   values (cons (or edit "") values)))
    (format "INSERT INTO %s (%s) VALUES (%s);"
            (sqlite3-table-mode-ref :table-name)
            (mapconcat 'identity columns ", ")
            (mapconcat
             (lambda (x) (sqlite3-format-value x))
             values ", "))))

(defun sqlite3-table-mode--delete-qhsql (rowid)
  (format "DELETE FROM %s WHERE %s = %s;"
          (sqlite3-table-mode-ref :table-name)
          (sqlite3-table-mode-ref :table-rowid) rowid))

(defun sqlite3-table-mode-revert (&rest dummy)
  (sqlite3-table-mode-redraw-page))

;;;
;;; sqlite3-schema-mode
;;;

(defconst sqlite3-schema-mode--close-icon "[+]")
(defconst sqlite3-schema-mode--open-icon "[-]")

(defvar sqlite3-schema-mode-map nil)

(unless sqlite3-schema-mode-map

  (let ((map (make-sparse-keymap)))

    (set-keymap-parent map sqlite3-mode-map)

    (define-key map "\C-m" 'sqlite3-schema-mode-toggle-item)
    (define-key map " " 'sqlite3-schema-mode-toggle-item)
    (define-key map "V" 'sqlite3-schema-mode-open-table)

    (define-key map "k" 'sqlite3-schema-mode-previous-line)
    (define-key map "j" 'sqlite3-schema-mode-next-line)
    (define-key map "p" 'sqlite3-schema-mode-previous-line)
    (define-key map "n" 'sqlite3-schema-mode-next-line)

    (setq sqlite3-schema-mode-map map)))

(define-derived-mode sqlite3-schema-mode sqlite3-mode "Sqlite3 Schema"
  "Sqlite3 schema view mode"
  (use-local-map sqlite3-schema-mode-map)
  (setq revert-buffer-function 'sqlite3-schema-mode-revert))

(defun sqlite3-schema-mode-open-table ()
  (interactive)
  (let ((item (get-text-property (point) 'sqlite3-schema-item)))
    (unless item
      (error "No item is here"))
    (cond
     ((eq (plist-get item :type) 'table)
      (let ((name (plist-get item :name)))
        (sqlite3-mode-open-table name)))
     ;;TODO
     (t (error "Not supported %s" (plist-get item :type))))))

(defun sqlite3-schema-mode-toggle-item ()
  (interactive)
  (let ((item (get-text-property (point) 'sqlite3-schema-item)))
    (unless item
      (error "No item is here"))
    (let ((region (sqlite3-mode-property-region
                   (point) 'sqlite3-schema-item))
          (child (plist-get item :child))
          (type (plist-get item :type))
          (inhibit-read-only t)
          (modifiedp (buffer-modified-p)))
      (cond
       ((and child (not (overlay-get child 'invisible)))
        (overlay-put child 'invisible t)
        (sqlite3-schema-mode--set-close region))
       ((overlayp child)
        (overlay-put child 'invisible nil)
        (sqlite3-schema-mode--set-open region))
       (t
        (sqlite3-mode--check-stream)
        (let ((ov (cond
                   ((eq type 'table-heading)
                    (sqlite3-schema--draw-tables))
                   ((eq type 'table)
                    (sqlite3-schema--draw-table item))
                   ;; TODO
                   (t (error "Not supported %s" type)))))
          (plist-put item :child ov))
        (sqlite3-schema-mode--set-open region)))
      (set-buffer-modified-p modifiedp))))

(defun sqlite3-schema-mode-next-line ()
  (interactive)
  (forward-line 1))

(defun sqlite3-schema-mode-previous-line ()
  (interactive)
  (forward-line -1))

(defun sqlite3-schema-mode-draw-view ()
  (sqlite3-mode--sync-modtime)
  (save-excursion
    (remove-overlays (point-min) (point-max))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (loop for (name type) in '(("Table" table-heading)
                                 ("Index" index-heading)
                                 ("Trigger" trigger-heading))
            do (let ((start (point)))
                 (insert (format "%s%s\n"
                                 sqlite3-schema-mode--close-icon
                                 (propertize name 
                                             'face 'sqlite3-mode-table-face)))
                 (put-text-property
                  start (point)
                  'sqlite3-schema-item (list :type type))
                 (insert "\n"))))))

(defun sqlite3-schema-mode-revert (&rest dummy)
  (sqlite3-mode-open-schema-mode))

(defun sqlite3-schema-mode--switch-icon (start icon)
  (let ((first (point))
        save-point)
    (save-excursion
      (goto-char start)
      (unless (looking-at "[ \t]*\\(\\[[-+]\\]\\)")
        (error "No icon is here"))
      (let* ((start (match-beginning 1))
             (end (match-end 1))
             (props (text-properties-at start)))
        (replace-match icon nil nil nil 1)
        ;; copy properties to icon text
        (set-text-properties start end props)
        (when (and (<= start first) (<= first end))
          (setq save-point t))))
    (when save-point
      (goto-char first))))

(defun sqlite3-schema-mode--set-open (region)
  (sqlite3-schema-mode--switch-icon
   (car region) sqlite3-schema-mode--open-icon))

(defun sqlite3-schema-mode--set-close (region)
  (sqlite3-schema-mode--switch-icon
   (car region) sqlite3-schema-mode--close-icon))

(defun sqlite3-schema--draw-tables ()
  (save-excursion
    (let ((tables (sqlite3-tables (sqlite3-mode-ref :stream))))
      (forward-line 2)
      (loop with start = (point)
            for tbl in tables
            do (let ((start (point))
                     (table (list :type 'table :name tbl)))
                 (sqlite3-schema-mode--draw-line
                  1
                  (format "%s%s\n"
                          sqlite3-schema-mode--close-icon
                          (propertize tbl 'face 'sqlite3-mode-table-face)))
                 (put-text-property
                  start (point)
                  'sqlite3-schema-item table))
            finally return (make-overlay start (point))))))

(defun sqlite3-schema--draw-table (parent)
  (save-excursion
    (let* ((name (plist-get parent :name))
           (schema (or (plist-get parent :schema)
                       (let ((s (sqlite3-schema-mode--table-schema name)))
                         (plist-put parent :schema s)
                         s))))
      (forward-line 1)
      (let* ((headers '("NAME" "TYPE" "NOT NULL" "DEFAULT" "KEY"))
             (start (point))
             (data (cons headers schema))
             (width-def (sqlite3-mode--calculate-width data))
             (hdrs (loop for h in headers
                     for w in width-def
                     collect (let ((name 
                                    (truncate-string-to-width h w nil ?\s)))
                               (propertize
                                name
                                'face 'sqlite3-header-background)))))
        (insert "\n")
        (sqlite3-schema-mode--draw-line
         2
         (mapconcat 'identity hdrs " "))
        (loop for (name type notnull default primaryp) in schema
              do (progn
                   (sqlite3-schema-mode--draw-line
                    2
                    (sqlite3-schema--table-column
                     width-def name type notnull default primaryp))))
        ;; column items are branch of the view.
        (put-text-property start (point) 'sqlite3-schema-item parent)
        (make-overlay start (point))))))

(defun sqlite3-schema--table-column (def &rest values)
  (let ((texts (loop for w in def
                     for v in values
                     collect (truncate-string-to-width
                              (sqlite3-mode--to-text v) w nil ?\s))))
    (mapconcat
     'identity
     (cons
      (propertize (car texts) 'face 'sqlite3-mode-column-face)
      (cdr texts)) " ")))

(defconst sqlite3-schema-mode-indent-level 2)

(defun sqlite3-schema-mode--draw-line (level line)
  (insert (make-string (* level sqlite3-schema-mode-indent-level) ?\s))
  (insert line)
  (insert "\n"))

;; TODO rename sqlite3-schema-view (?)
(defun sqlite3-schema-mode--table-schema (name)
  (loop for (idx name type notnull default primaryp)
        in (sqlite3-table-schema
            (sqlite3-mode-ref :stream) name)
        collect (list name type
                      (or (and notnull "yes") "no")
                      (or default "no")
                      (or (and primaryp "yes") "no"))))

;;;
;;; Sqlite3 binary mode
;;;

(defvar sqlite3-binary-mode-map nil)
(unless sqlite3-binary-mode-map
  (let ((map (make-sparse-keymap)))

    (suppress-keymap map)

    (define-key map "\C-c\C-c" 'sqlite3-mode-toggle-view)

    (setq sqlite3-binary-mode-map map)))

(define-minor-mode sqlite3-binary-mode
  ""
  nil nil sqlite3-binary-mode-map)

(defun sqlite3-mode-toggle-view ()
  "Toggle sqlite3 view <-> binary view"
  (interactive)
  (if (sqlite3-mode-binary-view-p)
      (sqlite3-view-mode)
    (sqlite3-mode-binary-view)))

(defun sqlite3-mode-binary-view ()
  (let ((magic-mode-alist
         (delq nil (mapcar
                    (lambda (elt)
                      (unless (eq (cdr elt) 'sqlite3-view-mode)
                        elt))
                    magic-mode-alist)))
        (read-only buffer-read-only))
    (find-alternate-file buffer-file-name)
    (when read-only
      (setq buffer-read-only t))
    (sqlite3-binary-mode 1)))

(defun sqlite3-mode-binary-view-p ()
  (save-excursion
    (goto-char (point-min))
    (looking-at sqlite3-file-header-regexp)))

;;;
;;; Sqlite3 cell mode
;;;

;;TODO display schema TYPE. Do Not prohibit input TYPE.

(defvar sqlite3-cell-mode-map nil)
(unless sqlite3-cell-mode-map

  (let ((map (make-sparse-keymap)))

    (define-key map "\C-c\C-t" 'sqlite3-cell-mode-toggle-null)
    (define-key map "\C-c\C-c" 'exit-recursive-edit)
    (define-key map "\C-x\C-s" 'exit-recursive-edit)
    (define-key map "\C-c\C-k" 'abort-recursive-edit)

    (setq sqlite3-cell-mode-map map)))

(defun sqlite3-cell-mode-setup ()
  (setq mode-line-process
        `((:eval
           (and (eq (sqlite3-cell-mode-value) :null)
                (propertize " null" 'face 'sqlite3-null-face)))))
  (setq mode-name "Sqlite3 Cell Edit")
  (use-local-map sqlite3-cell-mode-map))

(defvar sqlite3-cell-mode--null nil)
(defun sqlite3-cell-mode-toggle-null ()
  (interactive)
  (cond
   ((null sqlite3-cell-mode--null)
    (erase-buffer)
    (setq sqlite3-cell-mode--null t)
    (message "Now cell value is NULL"))
   (t
    (setq sqlite3-cell-mode--null nil)))
  (set-buffer-modified-p t))

(defun sqlite3-cell-mode-value ()
  (cond
   ((> (buffer-size) 0)
    (buffer-string))
   (sqlite3-cell-mode--null :null)
   (t "")))

;;;
;;; Sqlite3 stream
;;;

(defmacro sqlite3--with-process (proc &rest form)
  (declare (indent 1))
  `(let ((buf (process-buffer proc)))
     (when (buffer-live-p buf)
       (with-current-buffer buf
         ,@form))))

(defvar sqlite3-stream-coding-system 'utf-8)

(defun sqlite3-stream-open (file)
  (unless (executable-find sqlite3-program)
    (error "%s not found" sqlite3-program))
  (let* ((buf (sqlite3-stream--create-buffer))
         (proc (start-process "Sqlite3 Stream" buf
                              sqlite3-program
                              "-header"
                              "-interactive"
                              "-init" (sqlite3--init-file)
                              "-csv" file)))
    (set-process-coding-system
     proc sqlite3-stream-coding-system sqlite3-stream-coding-system)
    (process-put proc 'sqlite3-stream-process-p t)
    (process-put proc 'sqlite3-stream-filename file)
    (set-process-filter proc 'sqlite3-stream--filter)
    (set-process-sentinel proc 'sqlite3-stream--sentinel)
    (sqlite3-stream--wait proc)
    proc))

(defun sqlite3-stream-close (stream)
  (let ((proc stream))
    (unless (process-get proc 'sqlite3-stream-process-p)
      (error "Not a sqlite3 process"))
    (when (eq (process-status proc) 'run)
      (with-timeout (5 (kill-process proc))
        (process-send-string proc ".quit\n")
        (while (eq (process-status proc) 'run)
          (sleep-for 0.1))))
    ;; delete process forcibly
    (delete-process stream)))

(defun sqlite3-stream--create-buffer ()
  (generate-new-buffer " *Sqlite3 work* "))

(defun sqlite3-stream--parse-error ()
  (save-excursion
    (goto-char (point-min))
    ;;FIXME this error output to stderr. Separate stderr to other file??
    ;;     Altough rarely happens, worrying about confusing stdout/stderr 
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
      (funcall sqlite3-stream--filter-function proc))))

(defun sqlite3-stream--sentinel (proc event)
  (sqlite3--with-process proc
    (unless (eq (process-status proc) 'run)
      (kill-buffer (current-buffer)))))

(defvar sqlite3-stream--filter-function nil
  "This function called while receiving data from sqlite3 command.")

(defvar sqlite3-stream--csv-accumulation nil
  "Only synchronous use.")

(defun sqlite3-stream--csv-filter (proc)
  (let* ((raw (sqlite3--read-csv-with-deletion))
         (null (process-get proc 'sqlite3-null-value))
         (data (loop for row in raw
                     collect (loop for datum in row
                                   collect (if (equal datum null)
                                               :null
                                             datum)))))
    (setq sqlite3-stream--csv-accumulation
          (append sqlite3-stream--csv-accumulation data))))

(defun sqlite3-temp-null (query)
  (loop with key = (format "%s:%s" (current-time) query)
        with hash = (md5 key)
        for i from 0 below (length hash) by 2
        concat (let* ((hex (substring hash i (+ i 2)))
                      (c (string-to-number hex 16)))
                 (char-to-string c))
        into res
        finally return
        ;; md5 hex fold to base64 area
        (let ((b64 (base64-encode-string res t)))
          ;; sqlite3 command nullvalue assigned to 20 chars.
          (substring b64 0 19))))

(defun sqlite3-stream-execute-query (stream query)
  "Pass STREAM and QUERY to `sqlite3-stream-execute-sql'
"
  (let ((nullvalue (sqlite3-temp-null query)))
    ;; handling NULL text
    (sqlite3-stream--send-command
     stream (format ".nullvalue '%s'\n" nullvalue))
    (process-put stream 'sqlite3-null-value nullvalue)
    (unwind-protect
        (progn
          ;; send synchrounous variables.
          (setq sqlite3-stream--filter-function
                'sqlite3-stream--csv-filter)
          (unwind-protect
              (progn
                ;; reset accumulate variable
                (setq sqlite3-stream--csv-accumulation nil)
                (sqlite3-stream-execute-sql stream query)
                ;; wait until prompt is displayed.
                ;; filter function handling csv data.
                (sqlite3-stream--wait stream))
            (setq sqlite3-stream--filter-function nil)))
      ;; reset nullvalue
      (sqlite3-stream--send-command stream ".nullvalue ''\n")
      (process-put stream 'sqlite3-null-value nil)))
  sqlite3-stream--csv-accumulation)

(defun sqlite3-stream--send-command (stream command)
  "Send COMMAND to STREAM with omitting check the COMMAND error."
  (sqlite3-stream--wait stream)
  (let ((buf (process-buffer stream)))
    (with-current-buffer buf
      ;; clear all text contains prompt.
      (erase-buffer))
    (process-send-string stream command))
  (sqlite3-stream--wait stream))

(defvar sqlite3-stream--error nil)
(make-variable-buffer-local 'sqlite3-stream--error)

(defun sqlite3-stream-execute-sql (stream sql)
  "Send SQL to sqlite3 STREAM. (currently STREAM is a process object)
This function check syntax error of QUERY.

SQL is a sql statement that can have not statement end (`;').
 Do Not have multiple statements.

Examples:
Good: SELECT * FROM table1;
Good: SELECT * FROM table1
Good: SELECT * FROM table1\n
 Bad: SELECT * FROM table1; SELECT * FROM table2;
"
  ;; wait until previous sql was finished.
  (sqlite3-stream--wait stream)
  (let* ((proc stream)
         (buf (process-buffer proc)))
    (with-current-buffer buf
      ;; clear all text contains prompt.
      (erase-buffer)
      (setq sqlite3-stream--error nil)
      (process-send-string proc sql)
      (cond
       ((not (string-match ";[ \t\n]*\\'" sql))
        (process-send-string proc ";\n"))
       ((not (string-match "\n\\'" sql))
        (process-send-string proc "\n")))
      ;; only check syntax error.
      (while (and (eq (process-status proc) 'run)
                  (not (sqlite3-prompt-p))
                  (null sqlite3-stream--error))
        (sqlite3-sleep 0.1))
      (when (stringp sqlite3-stream--error)
        (error "%s" sqlite3-stream--error))
      t)))

(defun sqlite3-stream--wait (proc)
  (let ((buf (process-buffer proc)))
    (with-current-buffer buf
      (while (and (eq (process-status proc) 'run)
                  (not (sqlite3-prompt-p)))
        (sqlite3-sleep 0.1)))))

(defun sqlite3-sleep (seconds)
  ;; Other code affect to buffer while `sleep-for'.
  ;; TODO timer? filter? I can't get clue.
  (save-excursion
    ;; Achieve like a asynchronously behavior (ex: draw mode line)
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

(defun sqlite3-prompt-p ()
  (save-excursion
    (goto-char (point-max))
    (forward-line 0)
    ;; when executed sql contains newline, continue prompt displayed
    ;; before last prompt "sqlite> "
    (looking-at "^\\( *\\.\\.\\.> \\)*sqlite> \\'")))

(defun sqlite3--read-csv-with-deletion ()
  "Read csv data from current point. Delete csv data if read was succeeded."
  (let (pcsv--eobp res)
    (condition-case nil
        (while (not (eobp))
          (let ((start (point))
                (l (sqlite3--read-csv-line)))
            (delete-region start (point))
            (setq res (cons l res))))
      ;; finish the reading
      (invalid-read-syntax nil))
    (nreverse res)))

(defun sqlite3--read-csv-line ()
  (let ((first (point))
        (line (pcsv-read-line)))
    ;; end of line is not a newline. means ouput is progressing.
    (unless (bolp)
      (goto-char first)
      (signal 'invalid-read-syntax nil))
    line))

(defun sqlite3-format-value (object)
  (cond
   ((stringp object)
    (concat
     "'"
     (replace-regexp-in-string "'" "''" object)
     "'"))
   ((numberp object)
    (prin1-to-string object))
   ((eq object :null) "null")
   (t
    (error "Not a supported type %s" object))))

(defun sqlite3-tables (stream)
  (sqlite3-objects stream "table"))

(defun sqlite3-indexes (stream)
  (sqlite3-objects stream "index"))

(defun sqlite3-triggers (stream)
  (sqlite3-objects stream "trigger"))

(defun sqlite3-objects (stream type)
  (let* ((query
          (format "SELECT name FROM sqlite_master WHERE type='%s'" type))
         (data (sqlite3-stream-execute-query stream query)))
    (loop for row in (cdr data)
          collect (car row))))

(defun sqlite3-table-schema (stream table)
  "Get TABLE information in FILE.
Elements of the item list are:
0. cid
1. name
2. type
3. not null
4. default_value
5. primary key"
  (loop for row in (cdr
                    (sqlite3-stream-execute-query
                     stream (format "PRAGMA table_info(%s)" table)))
        collect (list
                 (string-to-number (nth 0 row))
                 (downcase (nth 1 row))
                 (upcase (nth 2 row))
                 (equal (nth 3 row) "1")
                 (nth 4 row)
                 (equal (nth 5 row) "1"))))

(defun sqlite3-killing-emacs ()
  (dolist (proc (process-list))
    (when (process-get proc 'sqlite3-stream-process-p)
      (condition-case err
          (sqlite3-stream-close proc)
        (error (message "Sqlite3: %s" err))))))

(add-hook 'kill-emacs-hook 'sqlite3-killing-emacs)

(defun sqlite3-unload-function ()
  (remove-hook 'kill-emacs-hook 'sqlite3-killing-emacs))

;;;
;;; Synchronous utilities
;;;

(defmacro sqlite3--call/stream (file proc)
  (declare (indent 1))
  `(let* ((inhibit-redisplay t)         ; like a synchronously function
          (stream (sqlite3-stream-open file)))
     (unwind-protect
         (funcall ,proc stream)
       (sqlite3-stream-close stream))))

(defun sqlite3-file-read-table (file table &optional where order)
  "Read TABLE data from sqlite3 FILE.
WHERE and ORDER is string that is passed through to sql query.
"
  (sqlite3--call/stream file
    (lambda (stream)
      (sqlite3-stream-execute-query
       stream (format "SELECT * FROM %s WHERE %s %s"
                      table
                      (or where "1 = 1")
                      (or (and order
                               (concat "ORDER BY " order))
                          ""))))))

(defun sqlite3-file-tables (file)
  "sqlite3 FILE tables"
  (sqlite3--call/stream file
    (lambda (stream)
      (sqlite3-tables stream))))

(defun sqlite3-file-table-columns (file table)
  "sqlite3 FILE TABLE columns"
  (loop for (r1 col . ignore) in (sqlite3-file-table-schema file table)
        collect col))

(defun sqlite3-file-table-schema (file table)
  "See `sqlite3-table-schema'"
  (sqlite3--call/stream file
    (lambda (stream)
      (sqlite3-table-schema stream table))))

(defun sqlite3-plist-merge (src dest)
  (loop for props on src by 'cddr
        do (let ((name (car props))
                 (val (cadr props)))
             (plist-put dest name val)))
  dest)

(defun sqlite3--filter (filter list)
  (loop for o in list
        if (funcall filter o)
        collect o))



;;;; TODO TESTING

;;TODO non used
(defun sqlite3-mode--faced-insert (face &rest args)
  (let ((start (point)))
    (apply 'insert args)
    (put-text-property start (point) 'face face)))

;;TODO non used
(defun sqlite3-mode--clone-cond ()
  (copy-sequence sqlite3-table-mode--context))

;; TODO :table :page :order :where

(provide 'sqlite3)

;;; sqlite3.el ends here
