;;; rime.el --- Rime Input Method in Emacs.  -*- lexical-binding: t -*-

;; Copyright (C) 2021 Shi Tianshu

;; Author: Shi Tianshu
;; Package-Requires: ((emacs "26.3") (cl-lib "0.6.1"))
;; Keywords: convenience, input method

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Emacs in Rime, support multiple schemas.

;; Keybindings in Rime:
;;
;; With following configuration, you can send a serials of keybindings to Rime.
;; Since you may want them to help you with cursor navigation, candidate
;; pagination and selection.
;;
;; Currently the keybinding with Control(C-), Meta(M-) and Shift(S-) is supported.
;;
;;   (setq rime-translate-keybindings '("C-f" "C-b" "C-n" "C-p" "C-g"))
;;
;; Candidate menu style:
;;
;;   Via `rime-show-candidate'.
;;
;;   |------------+--------------------------------|
;;   | Value      | description                    |
;;   |------------+--------------------------------|
;;   | nil        | don't show candidate at all.   |
;;   | minibuffer | Display in minibuffer.         |
;;   | message    | Display with message function. |
;;   |------------+--------------------------------|
;;
;; The lighter and cursor:
;;
;; You can get a lighter via `rime-lighter', which returns you a colored `ㄓ'.
;; Put it in modeline or anywhere you want.
;;
;; You can customize with `rime-title', `rime-indicator-face' and `rime-indicator-dim-face'.
;;
;; The default soft cursor is `|' , you can customize it with `rime-cursor'.
;;
;; Temporarily ascii mode:
;;
;; If you want specific a list of rules to automatically enable ascii mode,
;; you can customize `rime-disable-predicates'.
;;
;; Following is a example to use ascii mode when cursor is after
;; alphabet character or when cursor is in code.
;;
;;   (setq rime-disable-predicates
;;         '(rime--after-alphabet-char-p
;;           rime--prog-in-code-p))
;;
;; Force enable:
;;
;; If one of `rime-disable-predicates' returns t, you can still force enable
;; the input method with `rime-force-enable'.   The effect will only last
;; for one input behavior.
;;
;; You probably want to give this command a keybinding.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'cl-lib)

;;; Stuff copied from dash.el

(defmacro -> (x &optional form &rest more)
  "Thread the expr through the forms.  Insert X as the second item
in the first form, making a list of it if it is not a list
already.  If there are more forms, insert the first form as the
second item in second form, etc."
  (declare (debug (form &rest [&or symbolp (sexp &rest form)])))
  (cond
   ((null form) x)
   ((null more) (if (listp form)
                    `(,(car form) ,x ,@(cdr form))
                  (list form x)))
   (:else `(-> (-> ,x ,form) ,@more))))

(defmacro --each-while (list pred &rest body)
  "Evaluate BODY for each item in LIST, while PRED evaluates to non-nil.
Each element of LIST in turn is bound to `it' and its index
within LIST to `it-index' before evaluating PRED or BODY.  Once
an element is reached for which PRED evaluates to nil, no further
BODY is evaluated.  The return value is always nil.
This is the anaphoric counterpart to `-each-while'."
  (declare (debug (form form body)) (indent 2))
  (let ((l (make-symbol "list"))
        (i (make-symbol "i"))
        (elt (make-symbol "elt")))
    `(let ((,l ,list)
           (,i 0)
           ,elt it it-index)
       (ignore it it-index)
       (while (and ,l (setq ,elt (pop ,l) it ,elt it-index ,i) ,pred)
         (setq it ,elt it-index ,i ,i (1+ ,i))
         ,@body))))

(defmacro --first (form list)
  "Return the first item in LIST for which FORM evals to non-nil.
Return nil if no such element is found.
Each element of LIST in turn is bound to `it' and its index
within LIST to `it-index' before evaluating FORM.
This is the anaphoric counterpart to `-first'."
  (declare (debug (form form)))
  (let ((n (make-symbol "needle")))
    `(let (,n)
       (--each-while ,list (or (not ,form)
                               (ignore (setq ,n it))))
       ,n)))

(defun -first (pred list)
  "Return the first item in LIST for which PRED returns non-nil.
Return nil if no such element is found.
To get the first item in the list no questions asked, use `car'.
Alias: `-find'.
This function's anaphoric counterpart is `--first'."
  (--first (funcall pred it) list))

(defmacro -some-> (x &optional form &rest more)
  "When expr is non-nil, thread it through the first form (via `->'),
and when that result is non-nil, through the next form, etc."
  (declare (debug ->)
           (indent 1))
  (if (null form) x
    (let ((result (make-symbol "result")))
      `(-some-> (when-let (,result ,x)
                  (-> ,result ,form))
         ,@more))))


;;; User Options

(defgroup rime nil
  "Rime Input Method in Emacs."
  :group 'leim
  :group 'convenience
  :prefix "rime-")

(defcustom rime-show-preedit t
  "If display preedit in candidate menu.

Options:
t, display in candidate menu, default behavior.
inline, display in inline text, replacing commit text preview.
nil, don't display."
  :type 'symbol
  :options '(t inline nil)
  :group 'rime)

(defcustom rime-librime-root nil
  "The path to the directory of librime.

Leave it nil if you have librime's lib and header files in the standard path.
Otherwise you should set this to where you put librime."
  :type 'string
  :group 'rime)

(defun rime--guess-emacs-module-header-root ()
  "Guess `emacs-module-module-header-root' from some known places."
  (or
   (let ((module-header (expand-file-name "emacs-module.h" (concat source-directory "src/"))))
     (when (file-exists-p module-header)
       (file-name-directory module-header)))
   (let* ((emacs-dir (getenv "emacs_dir")) ;; https://www.gnu.org/software/emacs/manual/html_node/emacs/Misc-Variables.html
          (header-file (expand-file-name "emacs-module.h" (concat emacs-dir "/include/"))))
     (when (and emacs-dir (file-exists-p header-file))
       (file-name-directory header-file)))))

(defcustom rime-emacs-module-header-root (rime--guess-emacs-module-header-root)
  "The path to the directory of Emacs module header file.

Leave it nil if you using Emacs shipped with your system.
Otherwise you should set this to the directory contains 'emacs-module.h'."
  :type 'string
  :group 'rime)

;; We need these variables to be buffer local.
(defvar rime--temporarily-ignore-predicates nil
  "Temporarily disable all predicates.

Set to t will ensure the next input will be handled by input-method.
Will be reset to nil when symbol `rime-active-mode' is disabled.")

(defvar rime-force-enable-hook nil
  "Hooks run after `rime-force-enable' is called.")

(defvar rime-force-enable-exit-hook nil
  "Hooks rum after the state of `rime-force-enable' is turned off.")

(defcustom rime-deactivate-when-exit-minibuffer t
  "If automatically deactivate input-method when exit minibuffer."
  :type 'boolean
  :group 'rime)

(defcustom rime-inline-predicates nil
  "A list of predicate functions, each receive no argument.

When one of functions in `rime-disable-predicates' return t, and
one of these functions return t, the input-method will toggle to inline mode."
  :type 'list
  :group 'rime)

(defcustom rime-disable-predicates nil
  "A list of predicate functions, each receive no argument.

If one of these functions return t, the input-method will fallback to ascii mode."
  :type 'list
  :group 'rime)

(defcustom rime-candidate-num-format-function #'rime--candidate-num-format
  "Function to format the number before each candidate."
  :type 'function
  :group 'rime)

(defcustom rime--candidate-prefix-char " "
  "Character used to separate preedit and candidates."
  :type 'string
  :group 'rime)

(defcustom rime--candidate-separator-char " "
  "Character used to spereate each candidate."
  :type 'string
  :group 'rime)

(defcustom rime-show-candidate 'minibuffer
  "How we display the candidate menu.

nil means don't display candidate at all.
`minibuffer', display canidate in minibuffer.
`message', display with function `message'.
`hover', display canidate in hover window."
  :type 'symbol
  :type '(choice
          (const :tag "None" nil)
          (const :tag "Minibuffer" minibuffer)
          (const :tag "Message" message))
  :group 'rime)

(defcustom rime-user-data-dir (locate-user-emacs-file "rime/")
  "Rime user data directory.

Defaults to `user-emacs-directory'/rime/"
  :type 'string
  :group 'rime)

(defcustom rime-share-data-dir
  (cl-case system-type
    ('gnu/linux
     (cl-some (lambda (parent)
                (let ((dir (expand-file-name "rime-data" parent)))
                  (when (file-directory-p dir)
                    dir)))
              (if (fboundp 'xdg-data-dirs)
                  (xdg-data-dirs)
                '("/usr/local/share" "/usr/share"))))
    ('darwin
     "/Library/Input Methods/Squirrel.app/Contents/SharedSupport")
    ('windows-nt
     (if (getenv "MSYSTEM_PREFIX")
         (concat (getenv "MSYSTEM_PREFIX") "/share/rime-data")
       (when (getenv "LIBRIME_ROOT")
         (expand-file-name (concat (getenv "LIBRIME_ROOT") "/share/rime-data"))))))
  "Rime share data directory."
  :type 'string
  :group 'rime)

(defvar rime--root (file-name-directory (or load-file-name buffer-file-name))
  "The path to the root of rime package.")

(defvar rime--module-path
  (concat rime--root "rime-module" module-file-suffix)
  "The path to the dynamic module.")

(defcustom rime-inline-ascii-holder nil
  "A character that used to hold the inline ascii mode.

When inline ascii is triggered, this characeter will be inserted as the
beginning of composition, the origin character follows.  Then this character
will be deleted."
  :type 'char
  :group 'rime)

(defcustom rime-inline-ascii-trigger 'shift-l
  "How to trigger into inline ascii mode."
  :type 'symbol
  :options '(shift-l shift-r control-l control-r alt-l alt-r)
  :group 'rime)

(defcustom rime-cursor "|"
  "The character used to display the soft cursor in preedit."
  :type 'string
  :group 'rime)

;;;; faces

(defface rime-preedit-face
  '((((class color) (background dark))
     (:inverse-video t))
    (((class color) (background light))
     (:inverse-video t)))
  "Face for inline preedit."
  :group 'rime)

(defface rime-indicator-face
  '((((class color) (background dark))
     (:foreground "#9256B4" :bold t))
    (((class color) (background light))
     (:foreground "#9256B4" :bold t)))
  "Face for mode-line indicator when input-method is available."
  :group 'rime)

(defface rime-indicator-dim-face
  '((((class color) (background dark))
     (:foreground "#606060" :bold t))
    (((class color) (background light))
     (:foreground "#606060" :bold t)))
  "Face for mode-line indicator when input-method is temporarily disabled."
  :group 'rime)

(defface rime-default-face
  '((((class color) (background dark))
     (:background "#333333" :foreground "#dcdccc"))
    (((class color) (background light))
     (:background "#dcdccc" :foreground "#333333")))
  "Face for default foreground and background."
  :group 'rime)

(defface rime-code-face
  '((t (:inherit font-lock-string-face)))
  "Face for code in candidate, not available in `message'."
  :group 'rime)

(defface rime-cursor-face
  '((t (:inherit default)))
  "Face for cursor in candidate menu."
  :group 'rime)

(defface rime-highlight-candidate-face
  '((t (:inherit font-lock-constant-face)))
  "Face for highlighted candidate."
  :group 'rime)

(defface rime-comment-face
  '((t (:foreground "grey60")))
  "Face for comment in candidate, not available in `message'."
  :group 'rime)

(defface rime-candidate-num-face
  '((t (:inherit font-lock-comment-face)))
  "Face for the number before each candidate, not available in `message'."
  :group 'rime)


;;; Variables

(defvar-local rime--preedit-overlay nil
  "Overlay on preedit.")

(defvar rime--module-loaded nil
  "If dynamic module is loaded.")

(defvar rime--hooks-for-clear-state
  '()
  "Hooks where we add function `rime--clear-state' to it.")

(defvar rime--current-input-key nil
  "Saved last input key.")

;;;###autoload
(defvar rime-title (char-to-string 12563)
  "The title of input method.")

(defvar rime-translate-keybindings
  '("C-f" "C-b" "C-n" "C-p" "C-g" "<left>" "<right>" "<up>" "<down>" "<prior>" "<next>" "<delete>")
  "A list of keybindings those sent to Rime during composition.

Currently only Shift, Control, Meta is supported as modifiers.
Each keybinding in this list, will be bound to `rime-send-keybinding' in `rime-active-mode-map'.")


;;; Utility functions

(defun rime--should-enable-p ()
  "If key event should be handled by input-method."
  (or rime--temporarily-ignore-predicates
      (not (seq-find 'funcall rime-disable-predicates))))

(defun rime--should-inline-ascii-p ()
  "If we should toggle to inline ascii mode."
  (seq-find 'funcall rime-inline-predicates))

(defun rime--has-composition (context)
  "If CONTEXT has a meaningful composition data."
  (not (zerop (thread-last context
                (alist-get 'composition)
                (alist-get 'length)))))

(defun rime--minibuffer-display-content (content)
  "Display CONTENT in minibuffer."
  (with-selected-window (minibuffer-window)
    (erase-buffer)
    (insert content)))

(defun rime--message-display-content (content)
  "Display CONTENT via message."
  (let ((message-log-max nil))
    (save-window-excursion
      (with-temp-message
          content
        (sit-for most-positive-fixnum)))))

(defun rime--hover-display-content (content)
  "Display CONTENT via `hover'."
  (if (string-blank-p content)
      (hover-delete-window)
    (hover-message content)))

(defun rime--minibuffer-message (string)
  "Concatenate STRING and minibuffer contents.

Used to display in minibuffer when we are using input method in minibuffer."
  (message nil)
  (unless (string-blank-p string)
    (let ((inhibit-quit t)
          point-1)
      (save-excursion
        (insert (concat "\n" string))
        (setq point-1 (point)))
      (sit-for 1000000)
      (delete-region (point) point-1)
      (when quit-flag
        (setq quit-flag nil
              unread-command-events '(7))))))

(defun rime--minibuffer-deactivate ()
  "Initializer for minibuffer when input method is enabled.

Currently just deactivate input method."
  (with-selected-window (minibuffer-window)
    (deactivate-input-method)
    (remove-hook 'minibuffer-exit-hook 'rime--minibuffer-deactivate)))

(defun rime--string-pixel-width (string)
  "Get the pixel width for STRING."
  (let ((window (selected-window))
        (remapping face-remapping-alist))
    (with-temp-buffer
      (make-local-variable 'face-remapping-alist)
      (setq face-remapping-alist remapping)
      (set-window-buffer window (current-buffer))
      (insert string)
      (let ((p (point-min))
            (w 0)
            (ft (font-at 1)))
        (while (< p (point-max))
          (setq w (+ w (or (-some-> (font-get-glyphs ft p (1+ p))
                             (aref 0)
                             (aref 4))
                           0)))
          (setq p (1+ p)))
        w))))

(defun rime--show-content (content)
  "Display CONTENT as candidate."
  (if (minibufferp)
      (rime--minibuffer-message content)
    (cl-case rime-show-candidate
      (minibuffer (rime--minibuffer-display-content content))
      (message (rime--message-display-content content))
      (hover (rime--hover-display-content content))
      (t (progn)))))

(defun rime--candidate-num-format (num)
  "Format for the number before each candidate."
  (format "%d. " num))

(defun rime--build-candidate-content ()
  "Build candidate menu content from librime context."
  (let* ((context (rime-lib-get-context))
         (candidates (alist-get 'candidates (alist-get 'menu context)))
         (composition (alist-get 'composition context))
         (preedit (alist-get 'preedit composition))
         (before-cursor (alist-get 'before-cursor composition))
         (after-cursor (alist-get 'after-cursor composition))
         ;; (commit-text-preview (alist-get 'commit-text-preview context))
         ;; (cursor-pos (alist-get 'cursor-pos composition))
         ;; (sel-start (alist-get 'sel-start composition))
         ;; (sel-end (alist-get 'sel-end composition))
         ;; (input (rime-lib-get-input))
         (menu (alist-get 'menu context))
         (highlighted-candidate-index (alist-get 'highlighted-candidate-index menu))
         (page-no (alist-get 'page-no menu))
         (idx 1)
         (result ""))
    (when (and (rime--has-composition context) candidates)
      (when (eq t rime-show-preedit)
        (when preedit
          (setq result (concat (propertize
                                (concat before-cursor)
                                'face 'rime-code-face)
                               (propertize
                                (concat rime-cursor)
                                'face 'rime-cursor-face)
                               (propertize
                                (concat after-cursor)
                                'face 'rime-code-face))))
        (when (and page-no (not (zerop page-no)))
          (setq result (concat result (format "  [%d]" (1+ page-no)))))

        (setq result (concat result rime--candidate-prefix-char)))

      (dolist (c candidates)
        (let* ((curr (equal (1- idx) highlighted-candidate-index))
               (candidates-text (concat
                                 (propertize
                                  (funcall rime-candidate-num-format-function idx)
                                  'face
                                  'rime-candidate-num-face)
                                 (if curr
                                     (propertize (car c) 'face 'rime-highlight-candidate-face)
                                   (propertize (car c) 'face 'rime-default-face))
                                 (if-let (comment (cdr c))
                                     (propertize (format " %s" comment) 'face 'rime-comment-face)
                                   ""))))
          (setq result (concat result candidates-text rime--candidate-separator-char)))
        (setq idx (1+ idx))))

    result))

(defun rime--show-candidate ()
  "Display candidate."
  (rime--show-content (rime--build-candidate-content)))

(defun rime--parse-key-event (event)
  "Translate Emacs key EVENT to Rime's format.

the car is keyCode, the cdr is mask."
  (let* ((modifiers (event-modifiers event))
         (type (event-basic-type event))
         (mask (+
                (if (member 'shift modifiers)
                    1                   ; 1 << 0
                  0)
                (if (member 'meta modifiers)
                    8                   ; 1 << 3
                  0)
                (if (member 'control modifiers)
                    4                ; 1 << 2
                  0))))
    (cons type mask)))

(defun rime--clear-overlay ()
  "Clear inline preedit overlay."
  (when (overlayp rime--preedit-overlay)
    (delete-overlay rime--preedit-overlay)
    (setq rime--preedit-overlay nil)))

(defun rime--current-preedit ()
  (if (eq rime-show-preedit 'inline)
      (thread-last (rime-lib-get-context)
        (alist-get 'composition)
        (alist-get 'preedit))
    (alist-get 'commit-text-preview (rime-lib-get-context))))

(defun rime--display-preedit ()
  "Display inline preedit."
  (let ((preedit (rime--current-preedit)))
    ;; Always delete the old overlay.
    (rime--clear-overlay)
    ;; Create the new preedit
    (when preedit
      (setq rime--preedit-overlay (make-overlay (point) (point)))
      (overlay-put rime--preedit-overlay
                   'after-string
                   (propertize
                    preedit
                    'face
                    (if (and (derived-mode-p 'org-mode 'markdown-mode)
                             (looking-at-p "[[:print:]]"))
                        'rime-preedit-face
                      (cons 'rime-preedit-face
                            (plist-get (text-properties-at
                                        (if (> (point) 1)
                                            (1- (point))
                                          (point)))
                                       'face))))))))

(defun rime--rime-lib-module-ready-p ()
  "Return if dynamic module is loaded.

If module is loaded, `rime-lib-clear-composition' should be available."
  (fboundp 'rime-lib-clear-composition))

(defun rime--redisplay (&rest _ignores)
  "Display inline preedit and candidates.
Optional argument IGNORES ignored."
  (rime--display-preedit)
  (rime--show-candidate))

(defun rime--backspace ()
  "Delete one code.

By default the input-method will not handle DEL, so we need this command."
  (interactive)
  (when (rime--rime-lib-module-ready-p)
    (let ((context (rime-lib-get-context)))
      (when (rime--has-composition context)
        (rime-lib-process-key 65288 0)
        (rime--redisplay)))
    (rime--refresh-mode-state)))

(defun rime--escape ()
  "Clear the composition."
  (interactive)
  (when (rime--rime-lib-module-ready-p)
    (let ((context (rime-lib-get-context)))
      (when (rime--has-composition context)
        (rime-lib-clear-composition)
        (rime--redisplay)))
    (rime--refresh-mode-state)))

(defun rime--return ()
  "Commit the raw input."
  (interactive)
  (when (rime--rime-lib-module-ready-p)
    (when-let ((input (rime-lib-get-input)))
      (rime--clear-overlay)
      (insert input)
      (rime-lib-clear-composition)
      (rime--redisplay))
    (rime--refresh-mode-state)))

(defun rime--ascii-mode-p ()
  "If ascii-mode is enabled."
  (rime-lib-get-option "ascii_mode"))

(defun rime--inline-ascii ()
  "Toggle inline ascii."
  (let ((key-code
         (cl-case rime-inline-ascii-trigger
           (shift-l 65505)
           (shift-r 65506)
           (control-l 65507)
           (control-r 65508)
           (alt-l 65513)
           (alt-r 65514))))
    (rime-lib-process-key key-code 0)
    (rime-lib-process-key key-code 1073741824)))

(defun rime-inline-ascii ()
  "Toggle inline ascii and redisplay."
  (interactive)
  (rime--inline-ascii)
  (rime--redisplay))

(defun rime--text-read-only-p ()
  "Return t if the text at point is read-only."
  (and (or buffer-read-only
           (get-char-property (point) 'read-only))
       (not (or inhibit-read-only
                (get-char-property (point) 'inhibit-read-only)))))

(defun rime-input-method (key)
  "Process KEY with input method."
  (setq rime--current-input-key key)
  (when (rime--rime-lib-module-ready-p)
    (if (or (rime--text-read-only-p)
            (and (not (rime--should-enable-p))
                 (not (rime--has-composition (rime-lib-get-context)))))
        (list key)
      (let ((should-inline-ascii (rime--should-inline-ascii-p))
            (inline-ascii-prefix nil))
        (when (and should-inline-ascii rime-inline-ascii-holder
                   (not (equal 32 rime--current-input-key))
                   (string-blank-p (rime-lib-get-input)))
          (rime-lib-process-key rime-inline-ascii-holder 0)
          (rime--inline-ascii)
          (setq inline-ascii-prefix t))
        (let ((handled (rime-lib-process-key key 0)))
          (with-silent-modifications
            (let* ((context (rime-lib-get-context))
                   (commit-text-preview (alist-get 'commit-text-preview context))
                   ;; (preedit (thread-last context
                   ;;            (alist-get 'composition)
                   ;;            (alist-get 'preedit)))
                   (commit (rime-lib-get-commit)))
              (unwind-protect
                  (cond
                   ((not handled)
                    (list key))
                   (commit
                    (rime--clear-overlay)
                    (mapcar 'identity commit))
                   (t
                    (when should-inline-ascii
                      (if (and (not (rime--ascii-mode-p))
                               commit-text-preview)
                          (rime--inline-ascii)
                        (when inline-ascii-prefix
                          (rime-lib-set-cursor-pos 1)
                          (rime-lib-process-key 65288 0)
                          (rime-lib-set-cursor-pos 1))))
                    (rime--redisplay)))
                (rime--refresh-mode-state)))))))))

(defun rime-send-keybinding ()
  "Send key event to librime."
  (interactive)
  (let* ((parsed (rime--parse-key-event last-input-event))
         (key-raw (car parsed))
         (key (if (numberp key-raw)
                  key-raw
                (cl-case key-raw
                  (tab #xff09)
                  (home #xff50)
                  (left #xff51)
                  (up #xff52)
                  (right #xff53)
                  (down #xff54)
                  (prior #xff55)
                  (next #xff56)
                  (delete #xffff)
                  (t key-raw))))
         (mask (cdr parsed)))
    (unless (numberp key)
      (error "Can't send this keybinding to librime"))
    (rime-lib-process-key key mask)
    (rime--redisplay)
    (rime--refresh-mode-state)))

(defun rime--clear-state ()
  "Clear composition, preedit and candidate."
  (setq rime--current-input-key nil)
  (rime-lib-clear-composition)
  (rime--display-preedit)
  (rime--show-candidate)
  (rime--refresh-mode-state))

(defun rime--clear-state-before-unrelated-command ()
  "Clear state if this command is unrelated to rime."
  (unless (or (not (symbolp this-command))
              (string-prefix-p "rime-" (symbol-name this-command))
              (string-match-p "self-insert" (symbol-name this-command)))
    (rime--clear-state)))

(defun rime--refresh-mode-state ()
  "Toggle variable `rime-active-mode' based on if context is available."
  (if (rime--has-composition (rime-lib-get-context))
      (rime-active-mode 1)
    ;; Whenever we disable `rime-active-mode', we should also unset `rime--temporarily-ignore-predicates'.
    (when rime--temporarily-ignore-predicates
      (setq rime--temporarily-ignore-predicates nil)
      (run-hooks 'rime-force-enable-exit-hook))
    (rime-active-mode -1)))

(defun rime-select-schema ()
  "Select Rime schema."
  (interactive)
  (if rime--module-loaded
      (let* ((schema-list (rime-lib-get-schema-list))
             (schema-names (mapcar 'cdr schema-list))
             (schema-name (completing-read "Schema: " schema-names))
             (schema (thread-last schema-list
                       (seq-find (lambda (s)
                                   (equal (cadr s) schema-name)))
                       (car))))
        (message "Rime schema: %s" schema-name)
        (rime-lib-select-schema schema))
    (message "Rime is not activated.")))

;;;###autoload
(defun rime-lighter ()
  "Return a lighter which can be used in mode-line.

The content is `rime-title'.

You can customize the color with `rime-indicator-face' and `rime-indicator-dim-face'."

  (if (and (equal current-input-method "rime")
           (bound-and-true-p rime-mode))
      (if (and (rime--should-enable-p)
               (not (rime--should-inline-ascii-p)))
          (propertize
           rime-title
           'face
           'rime-indicator-face)
        (propertize
         rime-title
         'face
         'rime-indicator-dim-face))
    ""))

(defun rime--build-compile-env ()
  "Build compile env string."
  (if (not module-file-suffix)
      (error "Variable `module-file-suffix' is nil")
    (list
     (if rime-librime-root
         (format "LIBRIME_ROOT=%s" (file-name-as-directory (expand-file-name rime-librime-root))))
     (if rime-emacs-module-header-root
         (format "EMACS_MODULE_HEADER_ROOT=%s" (file-name-as-directory (expand-file-name rime-emacs-module-header-root))))
     (format "MODULE_FILE_SUFFIX=%s" module-file-suffix))))

(defun rime-compile-module ()
  "Compile dynamic module."
  (interactive)
  (let ((env (rime--build-compile-env))
        (process-environment process-environment)
        (default-directory rime--root))
    (cl-loop for pair in env
             when pair
             do (add-to-list 'process-environment pair))
    (if (zerop (shell-command "make rime-module"))
        (message "Compile succeed!")
      (error "Compile Rime dynamic module failed"))))

(defun rime--load-dynamic-module ()
  "Load dynamic module."
  (if (not (file-exists-p rime--module-path))
      (error "Failed to compile dynamic module")
    (load-file rime--module-path)
    (if (rime--maybe-prompt-for-deploy)
        (progn
          (rime-lib-start (expand-file-name rime-share-data-dir)
                          (expand-file-name rime-user-data-dir))
          (setq rime--module-loaded t))
      (error "Activate Rime failed"))))

;;;###autoload
(defun rime-activate (_name)
  "Activate rime.
Argument NAME ignored."
  (unless rime--module-loaded
    (unless (file-exists-p rime--module-path)
      (rime-compile-module))
    (rime--load-dynamic-module))

  (when rime--module-loaded
    (dolist (binding rime-translate-keybindings)
      (define-key rime-active-mode-map (kbd binding) 'rime-send-keybinding))

    (rime--clear-state)
    (when (and rime-deactivate-when-exit-minibuffer (minibufferp))
      (add-hook 'minibuffer-exit-hook 'rime--minibuffer-deactivate))
    (dolist (hook rime--hooks-for-clear-state)
      (add-hook hook 'rime--clear-state nil t))
    (rime-mode 1)

    (setq-local input-method-function 'rime-input-method)
    (setq-local deactivate-current-input-method-function #'rime-deactivate)))

(defun rime-deactivate ()
  "Deactivate rime."
  (rime--clear-state)
  (dolist (hook rime--hooks-for-clear-state)
    (remove-hook hook 'rime--clear-state t))
  (rime-mode -1)
  (kill-local-variable 'input-method-function))

(defvar rime-active-mode-map
  (let ((keymap (make-sparse-keymap)))
    (define-key keymap (kbd "DEL") 'rime--backspace)
    (define-key keymap (kbd "<backspace>") 'rime--backspace)
    (define-key keymap (kbd "<return>") 'rime--return)
    (define-key keymap (kbd "RET") 'rime--return)
    (define-key keymap (kbd "<escape>") 'rime--escape)
    keymap)
  "Keymap during composition.")

(defvar rime-mode-map
  (let ((keymap (make-sparse-keymap)))
    keymap)
  "Keymap when input method is enabled.")


;;; Initializer

(defun rime--init-hook-default ()
  "Rime activate set hooks."
  (let ((keymap (copy-keymap rime-active-mode-map)))
    (setq overriding-terminal-local-map keymap))
  (add-hook 'post-self-insert-hook 'rime--redisplay nil t))

(defun rime--uninit-hook-default ()
  "Rime deactivate remove hooks."
  (setq overriding-terminal-local-map nil)
  (remove-hook 'post-self-insert-hook 'rime--redisplay))

(defun rime--init-hook-vterm ()
  "Rime initialize for vterm-mode."
  (advice-add 'vterm--redraw :after 'rime--redisplay)
  (when (bound-and-true-p vterm-mode-map)
    (define-key vterm-mode-map (kbd "<backspace>") 'rime--backspace)))

(defun rime--uninit-hook-vterm ()
  "Rime finalize for vterm-mode."
  (advice-add 'vterm--redraw :after 'rime--redisplay)
  (when (bound-and-true-p vterm-mode-map)
    (define-key vterm-mode-map (kbd "<backspace>") 'vterm-send-backspace)))

(defun rime-active-mode--init ()
  "Init for command `rime-active-mode'."
  (add-hook 'pre-command-hook #'rime--clear-state-before-unrelated-command t t)
  (cl-case major-mode
    (vterm-mode (rime--init-hook-vterm))
    (t (rime--init-hook-default))))

(defun rime-active-mode--uninit ()
  "Uninit for command `rime-active-mode'."
  (remove-hook 'pre-command-hook #'rime--clear-state-before-unrelated-command t)
  (cl-case major-mode
    (vterm-mode (rime--uninit-hook-vterm))
    (t (rime--uninit-hook-default))))

(define-minor-mode rime-active-mode
  "Mode used in composition.

Should not be enabled manually."
  nil
  nil
  nil
  (if rime-active-mode
      (rime-active-mode--init)
    (rime-active-mode--uninit)))

(define-minor-mode rime-mode
  "Mode used when input method is activated."
  nil
  nil
  rime-mode-map)

;;;###autoload
(register-input-method "rime" "euc-cn" 'rime-activate rime-title)

(defun rime--maybe-prompt-for-deploy ()
  "Prompt user to confirm the deploy action."
  (let ((user-data-dir (expand-file-name rime-user-data-dir)))
    (if (file-exists-p user-data-dir)
        t
      (yes-or-no-p
       (format "Rime will use %s as the user data directory,
first time deploy could take some time.  Continue?" user-data-dir)))))

(defun rime-deploy()
  "Deploy Rime."
  (interactive)
  (when (rime--maybe-prompt-for-deploy)
    (if (not rime--module-loaded)
        (error "You should enable rime before deploy")
      (rime-lib-finalize)
      (rime-lib-start (expand-file-name rime-share-data-dir)
                      (expand-file-name rime-user-data-dir)))))

(defun rime-sync ()
  "Sync Rime user data."
  (interactive)
  (if (not rime--module-loaded)
      (error "You should enable rime before deploy")
    (rime-lib-sync-user-data)
    (rime-deploy)))

(defun rime-force-enable ()
  "Enable temporarily ascii mode.

Will resume when finish composition."
  (interactive)
  (setq rime--temporarily-ignore-predicates t)
  (run-hooks 'rime-force-enable-hook))

(defun rime-open-configuration ()
  "Open Rime configuration file."
  (interactive)
  (find-file (expand-file-name "default.custom.yaml" rime-user-data-dir)))

(defun rime-open-schema ()
  "Open Rime SCHEMA file."
  (interactive)
  (if rime--module-loaded
      (let* ((schema-list (rime-lib-get-schema-list))
             (schema-names (mapcar 'cdr schema-list))
             (schema-name (completing-read "Schema: " schema-names)))
        (find-file (expand-file-name
                    (format "%s.custom.yaml"
                            (car (-first (lambda (arg) (equal (cadr arg) schema-name)) schema-list)))
                    rime-user-data-dir)))
    (message "Rime is not activated.")))

(require 'rime-predicates)

(provide 'rime)

;;; rime.el ends here
