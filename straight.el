;;; straight.el --- Next-generation package manager. -*- lexical-binding: t -*-

;; Copyright (C) 2017 Radon Rosborough

;; Author: Radon Rosborough <radon.neon@gmail.com>
;; Homepage: https://github.com/raxod502/straight.el
;; Keywords: extensions
;; Created: 1 Jan 2017

;;; Commentary:

;; straight.el is a next-generation package manager for Emacs. It
;; clones packages into your ~/.emacs.d and handles byte-compilation,
;; autoload generation, and load path management. Dependency
;; management, powerful tools for managing your packages in bulk, and
;; out-of-the-box compatibility with MELPA and EmacsMirror are also
;; included.

;; straight.el improves on other package managers in several ways.
;; Most importantly, it offers first-class support for easily
;; modifying packages and contributing your changes upstream. It also
;; supports complete reproducibility for your configuration by writing
;; a lockfile with the versions of all your packages. Alternatively,
;; straight.el will work with manually managed packages, if you prefer
;; to merge in packages as subtrees.

;; Please see https://github.com/raxod502/straight.el for more
;; information.

;;; Code:

;; To see the outline of this file, run M-x outline-minor-mode and
;; then press C-c @ C-t. To also show the top-level functions and
;; variable declarations in each section, run M-x occur with the
;; following query: ^;;;;* \|^(

;;;; Libraries

;; For `if-let', `when-let', `hash-table-keys', `string-join',
;; `string-trim', etc.
(require 'subr-x)

;; For `cl-destructuring-bind', `cl-some', `cl-letf', `cl-position',
;; `cl-subseq', etc.
(require 'cl-lib)

;;;; Functions from other packages

(defvar use-package-defaults)
(defvar use-package-ensure-function)
(defvar use-package-keywords)
(defvar use-package-pre-ensure-function)

(declare-function magit-status-internal "magit-status")
(declare-function use-package-as-symbol "use-package")
(declare-function use-package-only-one "use-package")
(declare-function use-package-process-keywords "use-package")

;;;; Customization variables

(defgroup straight nil
  "Next-generation, purely functional package manager for the Emacs hacker."
  :group 'applications
  :prefix "straight-")

(defcustom straight-arrow
  (if (char-displayable-p ?→) " → " " -> ")
  "The string to use for an arrow in messages."
  :type 'string
  :group 'straight)

(defcustom straight-profiles
  '((nil . "default.el"))
  "Alist mapping package profile names to version lockfile names.
The profile names should be symbols, and the filenames should not
contain any directory components. Profiles later in the list take
precedence."
  :type '(alist :key-type symbol :value-type string)
  :group 'straight)

(defcustom straight-current-profile nil
  "Symbol identifying the current package profile.
This symbol should have an entry in `straight-profiles'. If you
wish to take advantage of the multiple-profile system, you should
bind this variable to different symbols using `let' over
different parts of your init-file."
  :type 'symbol
  :group 'straight)

(defcustom straight-default-vc 'git
  "VC backend to use by default, if a recipe has no `:type'.
Functions named like `straight-vc-TYPE-clone', etc. should be
defined, where TYPE is the value of this variable."
  :type 'symbol
  :group 'straight)

(defcustom straight-recipe-repositories nil
  "List of recipe repositories to find recipes in.
These are used when you provide only a package name, rather than
a full recipe, to `straight-use-package' or
`straight-use-recipes'. The order in this list determines the
precedence. Functions named like `straight-recipes-NAME-list',
etc. should be defined, where NAME is any element of this list."
  :type '(list symbol)
  :group 'straight)

(defcustom straight-recipe-overrides nil
  "Alist specifying recipes to override those provided explicitly.
The keys are symbols naming profiles, and the values are lists of
MELPA-style package recipes. Because the car of a MELPA-style
recipe is the package name as a symbol, this is actually an alist
whose keys are symbols naming packages."
  :type '(alist :key-type symbol :value-type
           (alist :key-type symbol :value-type
             (plist :key-type symbol :value-type sexp)))
  :group 'straight)

(defcustom straight-enable-package-integration t
  "Whether to enable \"integration\" with package.el.
This means that `package-enable-at-startup' is disabled, and
advices are put on `package--ensure-init-file' and
`package--save-selected-packages' to prevent package.el from
modifying the init-file."
  :type 'boolean
  :group 'straight)

(defcustom straight-enable-use-package-integration t
  "Whether to enable integration with `use-package'.
This means that a new `:recipe' handler is added, the normalizer
for `:ensure' is overridden, and `use-package-ensure-function'
and `use-package-pre-ensure-function' are set. The net effect is
that `:ensure' uses straight.el instead of package.el by
default."
  :type 'boolean
  :group 'straight)

;;;; Utility functions
;;;;; Association lists

(defun straight--normalize-alist (alist &optional test)
  "Return copy of ALIST with duplicate keys removed.
The value for a duplicated key will be the last one in ALIST.
Duplicates are tested with TEST, which must be accepted by the
`make-hash-table' function and which defaults to `eq'. The order
of the entries that are kept will be the same as in ALIST."
  (let ((hash (make-hash-table :test (or test #'eq)))
        (new-alist ()))
    (dolist (entry (reverse alist))
      (unless (gethash (car entry) hash)
        (push entry new-alist)
        (puthash (car entry) t hash)))
    new-alist))

(defun straight--alist-set (key val alist &optional symbol)
  "Set property KEY to VAL in ALIST. Return new alist.
This creates the association if it is missing, and otherwise sets
the cdr of the first matching association in the list. It does
not create duplicate associations. By default, key comparison is
done with `equal'. However, if SYMBOL is non-nil, then `eq' is
used instead.

This method may mutate the original alist, but you still need to
use the return value of this method instead of the original
alist, to ensure correct results."
  ;; See [1] for the genesis of this method, which should really be
  ;; built in.
  ;;
  ;; [1]: https://emacs.stackexchange.com/q/33892/12534
  (if-let ((pair (if symbol (assq key alist) (assoc key alist))))
      (setcdr pair val)
    (push (cons key val) alist))
  alist)

;;;;; Property lists

(defmacro straight--with-plist (plist props &rest body)
  "Binding from PLIST the given PROPS, eval and return BODY.
PROPS is a list of symbols. Each one is converted to a keyword
and then its value is looked up in the PLIST and bound to the
symbol for the duration of BODY."
  (declare (indent 2))
  (let ((plist-sym (make-symbol "plist")))
    `(let* ((,plist-sym ,plist)
            ,@(mapcar (lambda (prop)
                        `(,prop
                          (plist-get
                           ,plist-sym
                           ,(intern (concat ":" (symbol-name prop))))))
                      props))
       ,@body)))

(defmacro straight--put (plist prop value)
  "Make copy of PLIST with key PROP mapped to VALUE, and re-set it.
PLIST must be a literal symbol naming a plist variable. PROP and
VALUE are evaluated."
  `(progn
     (setq ,plist (copy-sequence ,plist))
     (setq ,plist (plist-put ,plist ,prop ,value))))

(defmacro straight--remq (plist props)
  "Make copy of PLIST with keys PROPS removed, and re-set it.
PLIST must be a literal symbol naming a plist variable. PROPS is
evaluated and should result in a list. Key comparison is done
with `eq'."
  ;; The following subroutine is adapted from [1].
  ;;
  ;; [1]: https://lists.gnu.org/archive/html/help-gnu-emacs/2015-08/msg00019.html
  (let ((props-sym (make-symbol "props")))
    `(let ((,props-sym ,props))
       (setq ,plist
             (cl-loop for (prop val) on ,plist by #'cddr
                      unless (memq prop ,props-sym)
                      collect prop and collect val)))))

;;;;; Hash tables

(defun straight--insert (n key value table)
  "Associate index N in KEY with VALUE in hash table TABLE.
TABLE should be a hash whose values are lists. This function will
set the Nth entry of the list mapped to KEY in TABLE to VALUE. If
the list does not have an Nth entry, it will be padded with nils
so that it does, before the setting happens. The TABLE will be
modified and returned."
  (let ((list (gethash key table)))
    (if (>= n (length list))
        (puthash key
                 (append list
                         (make-list (- n (length list)) nil)
                         (list value))
                 table)
      (setcar (nthcdr n list) value))
    table))

(defvar straight--not-present 'straight--not-present
  "Value used as a default argument to `gethash'.")

(defvar straight--not-present-paranoid 'straight--not-present-paranoid
  "Value used as a default argument to `gethash'.
Why do we need this? Because whoever wrote the Elisp hash table
API didn't actually know how to write hash table APIs.")

(defun straight--checkhash (key table &optional paranoid)
  "Return non-nil if KEY is present in hash TABLE.
If PARANOID is non-nil, ensure correctness even for hash tables
that may contain `straight--not-present' as a value."
  (and (eq (gethash key table straight--not-present) straight--not-present)
       (or paranoid
           (eq (gethash key table straight--not-present-paranoid)
               straight--not-present-paranoid))))

;;;;; Strings

(cl-defun straight--uniquify (prefix taken)
  "Generate a string with PREFIX that is not in list TAKEN.
This is done by trying PREFIX-1, PREFIX-2, etc. if PREFIX is
already in TAKEN."
  (if (member prefix taken)
      (let ((n 1))
        (while t
          (let ((candidate (format "%s-%d" prefix n)))
            (if (member candidate taken)
                (cl-incf n)
              (cl-return-from straight--uniquify candidate)))))
    prefix))

;;;;; Functions

(defmacro straight--functionp (object)
  "Non-nil if OBJECT, an unquoted symbol, is bound to a function.
However, if OBJECT evaluates to its own symbol value or t, then
return nil. This is useful for allowing a function to be called
with nil, non-nil, or a function object, without worrying about
the non-nil value being interpreted as a function: just call the
function with the quoted name of the argument, or use t."
  (let ((object-sym (make-symbol "object")))
    `(let ((,object-sym ,object))
       (and (not (memq ,object-sym '(,object t)))
            (functionp ,object-sym)))))

;;;;; Messaging

(defmacro straight--with-progress (task &rest body)
  "Displaying TASK as a progress indicator, eval and return BODY.
Display \"TASK...\", eval BODY, display \"TASK...done\", and
return the result of evaluating BODY. If TASK is nil, no messages
are displayed. TASK can also be a cons, whose car and cdr are
used as the TASK for the beginning and end messages
respectively. (Either the car or cdr, or both, can be nil.) See
also `straight--progress-begin' and `straight--progress-end'."
  (declare (indent 1))
  (let ((task-sym (make-symbol "gensym--task"))
        (task-car-sym (make-symbol "gensym--task-car"))
        (task-cdr-sym (make-symbol "gensym--task-cdr")))
    `(let* ((,task-sym ,task)
            (,task-car-sym (if (listp ,task-sym)
                               (car ,task-sym)
                             ,task-sym))
            (,task-cdr-sym (if (listp ,task-sym)
                               (cdr ,task-sym)
                             ,task-sym)))
       (prog2
           (when ,task-car-sym
             (message "%s..." ,task-car-sym))
           (progn
             ,@body)
         (when ,task-cdr-sym
           (message "%s...done" ,task-cdr-sym))))))

(defun straight--progress-begin (message)
  "Display a MESSAGE indicating ongoing progress.
The MESSAGE is postpended with \"...\" and then passed to
`message'. See also `straight--with-progress' and
`straight--progress-end'."
  (message "%s..." message))

(defun straight--progress-end (message)
  "Display a MESSAGE indicating completed progress.
The MESSAGE is postpended with \"...done\" and then passed to
`message'. See also `straight--with-progress' and
`straight--progress-begin'."
  (message "%s...done" message))

(defvar straight--echo-area-dirty nil
  "Non-nil if a progress message has been wiped from the echo area.
This is used as an internal bookkeeping variable to determine if
a progress message has been bumped out of the echo area by
another message, and needs to be redisplayed.")

(defun straight--warn (message &rest args)
  "Display a warning from `straight'. Return nil.
The warning message is obtained by passing MESSAGE and ARGS to
`format'."
  (ignore
   (display-warning 'straight (apply #'format message args))))

;;;;; Paths

(defun straight--dir (&rest segments)
  "Get a subdirectory of the straight.el directory.
The SEGMENTS are path segments which are concatenated with
slashes and postpended to the straight directory.

\(straight--dir \"build\" \"esup\")
=> \"~/.emacs.d/straight/build/esup/\""
  (expand-file-name
   (apply 'concat user-emacs-directory
          (mapcar (lambda (segment)
                    ;; So let me tell you of a fun story. It begins
                    ;; with an innocuous:
                    ;;
                    ;; (delete-directory
                    ;;   (straight--dir "repos" local-repo)
                    ;;   'recursive)
                    ;;
                    ;; Except -- plot twist! -- it turns out that
                    ;; local-repo is accidentally nil. So we just
                    ;; deleted all your repositories. Let's try not to
                    ;; do that, mkay?
                    (unless segment
                      (error "Nil path segment"))
                    (concat segment "/"))
                  (cons "straight" segments)))))

(defun straight--file (&rest segments)
  "Get a file in the straight.el directory.
The SEGMENTS are path segments with are concatenated with slashes
and postpended to the straight directory.

\(straight--file \"build\" \"esup\" \"esup-autoloads.el\")
=> \"~/.emacs.d/straight/build/esup/esup-autoloads.el\""
  (expand-file-name
   (substring (apply 'straight--dir segments) 0 -1)))

(defun straight--autoload-file-name (package)
  "Get the bare filename of the autoload file for PACKAGE.
PACKAGE should be a string. The filename does not include the
directory component."
  (format "%s-autoloads.el" package))

;;;;; External processes

(defvar straight--default-directory nil
  "Overrides value of `default-directory'.
This is used because `default-directory' is buffer-local, which
means binding it for the duration of a recursive edit causes fun
side-effects like random buffers permanently forgetting which
directory they're in, and straight.el executing Git commands
against the wrong repositories.

If you set this to something other than nil, you may be eaten by
a grue.")

(defun straight--check-call (command &rest args)
  "Call COMMAND with ARGS, returning non-nil if it succeeds.
If the COMMAND exits with a non-zero return code, return nil. If
the COMMAND does not exist, or if another error occurs, throw an
error."
  (let ((default-directory (or straight--default-directory
                               default-directory)))
    (= 0 (apply #'call-process command nil nil nil args))))

(defun straight--get-call-raw (command &rest args)
  "Call COMMAND with ARGS, returning its stdout and stderr as a string.
If the command fails, throw an error."
  (with-temp-buffer
    (let ((default-directory (or straight--default-directory
                                 default-directory)))
      (unless (= 0 (apply #'call-process command
                          nil '(t t) nil args))
        (error "Command failed: %s %s (output: %S) (default-directory: %S)"
               command (string-join args " ")
               (buffer-string) default-directory)))
    (buffer-string)))

(defun straight--get-call (command &rest args)
  "Call COMMAND with ARGS, returning its stdout and stderr as a string.
Return a string with whitespace trimmed from both ends. If the
command fails, throw an error."
  (string-trim (apply #'straight--get-call-raw command args)))

;;;;; Interactive popup windows

(defun straight-popup-raw (prompt actions)
  "Display PROMPT and allow user to choose between one of several ACTIONS.
PROMPT is a string, generally a complete sentence. ACTIONS is a
list of lists (KEY DESC FUNC ARGS...). KEY is a string
identifying the key that triggers this action; it is passed to
`kbd'. DESC is a description string to be displayed in the popup.
If it is nil, the action and its binding is not displayed in the
popup, although it still takes effect. If the user selects an
action, its FUNC is called with ARGS and the popup is dismissed.
The return value of `straight-popup-raw' is the return value of
FUNC.

ACTIONS later in the list take precedence over earlier ones with
regard to keybindings."
  (let ((keymap (make-sparse-keymap))
        (func nil)
        (prompt (concat prompt "\n"))
        (max-length (apply #'max (mapcar #'length (mapcar #'car actions)))))
    (unless (assoc "C-g" actions)
      (nconc actions '(("C-g" "Cancel" keyboard-quit))))
    (dolist (action actions)
      (cl-destructuring-bind (key desc func . args) action
        (when desc
          ;; I would welcome a better way to pad strings in Elisp,
          ;; because this is kind of horrifying.
          (setq prompt
                (format
                 (format "%%s\n %%%ds %%s" max-length)
                 prompt key desc)))
        (define-key keymap (kbd key)
          (lambda ()
            (interactive)
            (apply func args)))))
    (setq prompt (concat prompt "\n\n"))
    (let ((max-mini-window-height 1.0)
          (cursor-in-echo-area t))
      (when minibuffer-auto-raise
        (raise-frame (window-frame (minibuffer-window))))
      (while (not func)
        (setq func (lookup-key keymap (vector (read-key prompt))))))
    (funcall func)))

(defmacro straight-popup (prompt &rest actions)
  "Same as `straight-popup-raw', but with reduced need for quoting.
PROMPT is still evaluated at runtime. So are all elements of
ACTIONS, except for FUNC, which is wrapped in a `lambda'
automatically, and ARGS, which are superfluous and therefore
instead used as additional forms to place in the `lambda' after
FUNC."
  (declare (indent defun))
  `(straight-popup-raw
    ,prompt
    (list
     ,@(mapcar
        (lambda (action)
          (cl-destructuring-bind (key desc . args) action
            `(list ,key ,desc (lambda () ,@args))))
        actions))))

(defun straight-are-you-sure (&optional prompt)
  "Display a popup asking the user to confirm their questionable actions.
PROMPT has a sensible default; otherwise it is a string. Return
non-nil if the user confirms; nil if they abort."
  (straight-popup (or prompt "Are you sure?")
    ("y" "Yes, proceed" t)
    ("n" "No, abort" nil)))

;;;;; Transactions

(defvar straight--transaction-depth 0
  "Number of transactions currently executing.
You can nest transactions, so it's important to keep track of the
depth.")

(defvar straight--transaction-alist nil
  "Alist of actions being executed in the current transaction.
See `straight--transaction-exec'. The cars are their IDs, and the
cdrs are their END-FUNCs.")

(defun straight--transaction-p ()
  "Return non-nil if we are currently within a transaction.
This means that we are guaranteed to be able to perform cleanup
after all operations are complete, and we expect to benefit from
optimizing for a number of operations being performed in
sequence."
  (> straight--transaction-depth 0))

(defun straight--transaction-exec (id &optional begin-func end-func)
  "Execute an action within a transaction.
ID is a symbol that acts as a unique identifier of the action
within the transaction. Only the first BEGIN-FUNC and END-FUNC
with a given ID are used within a transaction. BEGIN-FUNC is
invoked immediately, and END-FUNC is executed at the end of the
transaction. These functions wrap the transaction, so the
END-FUNCs are invoked in reverse order to the BEGIN-FUNCs. If
either BEGIN-FUNC or END-FUNC is nil or omitted, it acts as a
no-op, but the ID is still registered to block future exec
calls."
  (unless (straight--transaction-p)
    (error "Can't `straight--transaction-exec' when not in transaction"))
  (unless (assq id straight--transaction-alist)
    ;; Make sure to return the actual function value, and not the
    ;; current contents of the transaction alist, using `prog1'.
    (prog1 (when begin-func
             (funcall begin-func))
      ;; Push to start of list. At the end, we'll read forward, thus
      ;; in reverse order.
      (push (cons id end-func) straight--transaction-alist))))

(defun straight-begin-transaction ()
  "Begin a transaction. See `straight--transaction-p'.
If you call this function, you *must* call
`straight-finalize-transaction' after all of your operations
have been performed, even if there was an error."
  (setq straight--transaction-depth (1+ straight--transaction-depth)))

(defun straight-finalize-transaction ()
  "Finalize a transaction. See `straight--transaction-p'."
  (unless (<= straight--transaction-depth 0)
    (setq straight--transaction-depth (1- straight--transaction-depth))
    ;; Do the error-prone operations last, so that we don't leave the
    ;; transaction active.
    (when (= straight--transaction-depth 0)
      (let ((alist straight--transaction-alist))
        (setq straight--transaction-alist nil)
        (dolist (end-func (mapcar #'cdr alist))
          (when end-func
            (funcall end-func)))))))

(defmacro straight-transaction (&rest body)
  "Eval BODY within transaction. Return value is result of last form in BODY."
  (declare (indent defun))
  `(progn
     (straight-begin-transaction)
     (unwind-protect (progn ,@body)
       (straight-finalize-transaction))))

(defun straight-interactive-transaction ()
  "Start a recursive edit within a transaction."
  (interactive)
  (straight-transaction
    (recursive-edit)))

;;;; Version control

(defun straight-vc (method type &rest args)
  "Call a VC backend method.
METHOD is a symbol naming a backend method, like symbol `clone'.
TYPE is a symbol naming a VC backend, like symbol `git'. ARGS are
passed to the method.

For example:
   (straight-vc \\='check-out-commit \\='git ...)
=> (straight-vc-git-check-out-commit ...)"
  (let ((func (intern (format "straight-vc-%S-%S"
                              type method))))
    (apply func args)))

(defun straight-vc-clone (recipe)
  "Clone the local repository specified by straight.el-style RECIPE.
If a commit is specified in one of the lockfiles, attempt to
check out that revision. If this fails, signal a warning.

This method sets `straight--default-directory' to the repos
directory and delegates to the relevant `straight-vc-TYPE-clone'
method, where TYPE is the `:type' specified in RECIPE. If the
repository already exists, throw an error."
  (straight--with-plist recipe
      (type local-repo)
    (let ((straight--default-directory (straight--dir "repos"))
          (commit nil))
      (when (file-exists-p (straight--dir "repos" local-repo))
        (error "Repository already exists: %S" local-repo))
      ;; We're reading the lockfiles inline here, instead of caching
      ;; them like we do with the build cache. The reason is that
      ;; reading the lockfiles appears to be much faster than reading
      ;; the build cache, and also time is not really a concern if
      ;; we're already going to be cloning a repository.
      (dolist (spec straight-profiles)
        (cl-destructuring-bind (_profile . versions-lockfile) spec
          (let ((lockfile-path (straight--file "versions" versions-lockfile)))
            (when-let ((versions-alist (ignore-errors
                                         (with-temp-buffer
                                           (insert-file-contents-literally
                                            lockfile-path)
                                           (read (current-buffer))))))
              (when-let ((frozen-commit
                          (cdr (assoc local-repo versions-alist))))
                (setq commit frozen-commit))))))
      (straight-vc 'clone type recipe commit))))

(defun straight-vc-normalize (recipe)
  "Normalize the local repository specified by straight.el-style RECIPE.
The meaning of normalization is backend-defined, but typically
involves validating repository configuration and cleaning the
working directory.

This method sets `straight--default-directory' to the local
repository directory and delegates to the relevant
`straight-vc-TYPE-normalize' method, where TYPE is the `:type'
specified in RECIPE."
  (straight--with-plist recipe
      (local-repo type)
    (let ((straight--default-directory (straight--dir "repos" local-repo)))
      (straight-vc 'normalize type recipe))))

(defun straight-vc-pull-from-remote (recipe)
  "Pull from the primary remote for straight.el-style RECIPE.

This method sets `straight--default-directory' to the local
repository directory and delegates to the relevant
`straight-vc-TYPE-pull-from-remote' method, where TYPE is the
`:type' specified in RECIPE."
  (straight--with-plist recipe
      (local-repo type)
    (let ((straight--default-directory (straight--dir "repos" local-repo)))
      (straight-vc 'pull-from-remote type recipe))))

(defun straight-vc-pull-from-upstream (recipe)
  "Pull from the upstream remote for straight.el-style RECIPE.
If there is no upstream configured, this method does nothing.

This method sets `straight--default-directory' to the local
repository directory and delegates to the relevant
`straight-vc-TYPE-pull-from-upstream' method, where TYPE is the
`:type' specified in RECIPE."
  "Using straight.el-style RECIPE, pull from upstream if configured."
  (straight--with-plist recipe
      (local-repo type)
    (let ((straight--default-directory (straight--dir "repos" local-repo)))
      (straight-vc 'pull-from-upstream type recipe))))

(defun straight-vc-push-to-remote (recipe)
  "Push to the primary remote for straight.el-style RECIPE, if necessary.

This method sets `straight--default-directory' to the local
repository directory and delegates to the relevant
`straight-vc-TYPE-pull-from-remote' method, where TYPE is the
`:type' specified in RECIPE."
  (straight--with-plist recipe
      (local-repo type)
    (let ((straight--default-directory (straight--dir "repos" local-repo)))
      (straight-vc 'push-to-remote type recipe))))

(defun straight-vc-check-out-commit (type local-repo commit)
  "Using VC backend TYPE, in LOCAL-REPO, check out COMMIT.
TYPE is a symbol like symbol `git', etc. LOCAL-REPO is a string
naming a local package repository. The interpretation of COMMIT
is defined by the backend, but it should be compatible with
`straight-vc-get-commit'.

This method sets `straight--default-directory' to the local
repository directory and delegates to the relevant
`straight-vc-TYPE-check-out-commit'."
  (let ((straight--default-directory (straight--dir "repos" local-repo)))
    (straight-vc 'check-out-commit type local-repo commit)))

(defun straight-vc-get-commit (type local-repo)
  "Using VC backend TYPE, in LOCAL-REPO, return current commit.
TYPE is a symbol like symbol `git', etc. LOCAL-REPO is a string
naming a local package repository. The type of object returned is
defined by the backend, but it should be compatible with
`straight-vc-check-out-commit'.

This method sets `straight--default-directory' to the local
repository directory and delegates to the relevant
`straight-vc-TYPE-get-commit' method."
  (let ((straight--default-directory (straight--dir "repos" local-repo)))
    (straight-vc 'get-commit type local-repo)))

(defun straight-vc-local-repo-name (recipe)
  "Generate a repository name from straight.el-style RECIPE.
If a repository name cannot be generated, return nil. This is
used for the default value of `:local-repo'. If nil is returned,
the package name is used instead.

This method sets `straight--default-directory' to the local
repository directory and delegates to the relevant
`straight-vc-TYPE-local-repo-name' method, where TYPE is the
`:type' specified in RECIPE."
  (straight--with-plist recipe
      (type)
    (straight-vc 'local-repo-name type recipe)))

(defun straight-vc-keywords (type)
  "Return a list of keywords used by the VC backend TYPE.
This does include the `:type' keyword itself.

This method simply delegates to the relevant
`straight-vc-TYPE-keywords' method."
  (straight-vc 'keywords type))

;;;;; Git

(defcustom straight-vc-git-default-branch "master"
  "The default value for `:branch' when `:type' is symbol `git'."
  :type 'string
  :group 'straight)

(defcustom straight-vc-git-primary-remote "origin"
  "The remote name to use for the primary remote."
  :type 'string
  :group 'straight)

(defcustom straight-vc-git-upstream-remote "upstream"
  "The remote name to use for the upstream remote."
  :type 'string
  :group 'straight)

(defcustom straight-vc-git-default-protocol 'https
  "The default protocol to use for auto-generated URLs.
This affects the URLs used when `:host' is `github', `gitlab', or
`bitbucket'. It does not cause manually specified URLs to be
translated.

This may be either `https' or `ssh'."
  :type '(choice (const :tag "HTTPS" https)
                 (const :tag "SSH" ssh))
  :group 'straight)

(defcustom straight-vc-git-force-protocol nil
  "If non-nil, treat HTTPS and SSH URLs as incompatible.
This means that operations like `straight-normalize-package' will
re-set the remote URLs for packages whose recipes have non-nil
`:host' values, if they are using a different protocol than the
one specified in `straight-vc-git-default-protocol'."
  :type 'boolean
  :group 'straight)

;;;;;; Utility functions

(defun straight-vc-git--popup-raw (prompt actions)
  "Same as `straight-popup-raw', but specialized for vc-git methods.
Two additional actions are inserted at the end of the list: \"e\"
for Dired and recursive edit, and \"g\" for Magit and recursive
edit. Otherwise, PROMPT and ACTIONS are as for
`straight-popup-raw'."
  (straight-popup-raw
   prompt
   (append
    actions
    '(("e" "Dired and open recursive edit"
       (lambda ()
         (dired (or straight--default-directory default-directory))
         (recursive-edit)))
      ("g" "Magit and open recursive edit"
       (lambda ()
         (magit-status-internal
          (or straight--default-directory default-directory))
         (recursive-edit)))))))

(defmacro straight-vc-git--popup (prompt &rest actions)
  "Same as `straight-popup', but specialized for vc-git methods.
Two additional actions are inserted at the end of the list: \"e\"
for Dired and recursive edit, and \"g\" for Magit and recursive
edit. Otherwise, PROMPT and ACTIONS are as for
`straight-popup'."
  (declare (indent defun))
  `(straight-popup
     ,prompt
     ,@actions
     ("e" "Dired and open recursive edit"
      (dired (or straight--default-directory default-directory))
      ;; Don't mess up recursive straight.el operations. The wonderful
      ;; thing about using our own variable is that since it's not
      ;; buffer-local, a recursive binding to nil is actually able to
      ;; undo the effects of the ambient binding.
      (let ((straight--default-directory nil))
        (recursive-edit)))
     ("g" "Magit and open recursive edit"
      (magit-status-internal
       (or straight--default-directory default-directory))
      (let ((straight--default-directory nil))
        (recursive-edit)))))

(defun straight-vc-git--encode-url (repo host &optional protocol)
  "Generate a URL from a REPO depending on the value of HOST and PROTOCOL.
REPO is a string which is either a URL or something of the form
\"username/repo\", like \"raxod502/straight.el\". If HOST is one
of the symbols `github', `gitlab', or `bitbucket', then REPO is
transformed into a standard SSH URL for the corresponding
service; otherwise, HOST should be nil, and in that case REPO is
returned unchanged. PROTOCOL must be either `https' or `ssh'; if
it is omitted, it defaults to `straight-vc-git-default-protocol'.
See also `straight-vc-git--decode-url'."
  (pcase host
    ('nil repo)
    ((or 'github 'gitlab 'bitbucket)
     (let ((domain (pcase host
                     ('bitbucket "bitbucket.org")
                     (_ (format "%s.com" host)))))
       (pcase (or protocol straight-vc-git-default-protocol)
         ('https
          (format "https://%s/%s.git" domain repo))
         ('ssh
          (format "git@%s:%s.git" domain repo))
         (_ (error "Unknown protocol: %S" protocol)))))
    (_ (error "Unknown value for host: %S" host))))

(defun straight-vc-git--decode-url (url)
  "Separate a URL into a REPO, HOST, and PROTOCOL, returning a list of them.
All common forms of HTTPS and SSH URLs are accepted for GitHub,
GitLab, and Bitbucket. If one is recognized, then HOST is one of
the symbols `github', `gitlab', or `bitbucket', and REPO is a
string of the form \"username/repo\". Otherwise HOST is nil and
REPO is just URL. In any case, PROTOCOL is either `https', `ssh',
or nil (if the protocol cannot be determined, which happens when
HOST is nil). See also `straight-vc-git--encode-url'."
  (let ((protocol nil)
        (matched t))
    (or (and (string-match
              "^git@\\(.+?\\):\\(.+?\\)\\(?:\\.git\\)?$"
              url)
             (setq protocol 'ssh))
        (and (string-match
              "^ssh://git@\\(.+?\\)/\\(.+?\\)\\(?:\\.git\\)?$"
              url)
             (setq protocol 'ssh))
        (and (string-match
              "^https://\\(.+?\\)/\\(.+?\\)\\(?:\\.git\\)?$"
              url)
             (setq protocol 'https))
        ;; We have to take care of this case separately because if
        ;; `string-match' doesn't actually match anything, then
        ;; `match-string' has undefined behavior.
        (setq matched nil))
    (pcase (and matched (match-string 1 url))
      ("github.com" (list (match-string 2 url) 'github protocol))
      ("gitlab.com" (list (match-string 2 url) 'gitlab protocol))
      ("bitbucket.org" (list (match-string 2 url) 'bitbucket protocol))
      (_ (list url nil nil)))))

(defun straight-vc-git--urls-compatible-p (url1 url2)
  "Return non-nil if URL1 and URL2 can be treated as equivalent.
This means that `straight-vc-git--decode-url' returns the same
for both (but if `straight-vc-git-force-protocol' is nil, then
the returned protocol is allowed to differ). For example, HTTPS
and SSH URLs for the same repository are equivalent (unless
`straight-vc-git-force-protocol' is non-nil), and it does not
matter if a GitHub URL is suffixed with .git or not."
  (let ((spec1 (straight-vc-git--decode-url url1))
        (spec2 (straight-vc-git--decode-url url2)))
    (if straight-vc-git-force-protocol
        (equal spec1 spec2)
      ;; Only compare the first two elements; ignore the third, which
      ;; is the protocol.
      (equal (cl-subseq spec1 0 2)
             (cl-subseq spec2 0 2)))))

(defun straight-vc-git--list-remotes ()
  "Return a list of Git remotes as strings for the current directory.
Do not suppress unexpected errors."
  ;; Git remotes cannot have whitespace, thank goodness.
  (split-string (straight--get-call "git" "remote") "\n"))

;;;;;; Validation functions

(cl-defun straight-vc-git--validate-remote (local-repo remote desired-url)
  "Validate that LOCAL-REPO has REMOTE set to DESIRED-URL or equivalent.
All three arguments are strings. The URL of the REMOTE does not
necessarily need to match DESIRED-URL; it just has to satisfy
`straight-vc-git--urls-compatible-p'."
  ;; Always return nil unless we use `cl-return-from'.
  (ignore
   (if-let ((actual-url (condition-case nil
                            (straight--get-call
                             "git" "remote" "get-url" remote)
                          (error nil))))
       (if (straight-vc-git--urls-compatible-p
            actual-url desired-url)
           ;; This is the only case where we return non-nil.
           (cl-return-from straight-vc-git--validate-remote t)
         (let ((new-remote (straight--uniquify
                            remote
                            (straight-vc-git--list-remotes))))
           (straight-vc-git--popup
             (format "In repository %S, remote %S has URL
  %S
but recipe specifies a URL of
  %S"
                     local-repo remote actual-url desired-url)
             ("r" (format (concat "Rename remote %S to %S, "
                                  "re-create %S with correct URL, and fetch")
                          remote new-remote remote)
              (straight--get-call
               "git" "remote" "rename" remote new-remote)
              (straight--get-call
               "git" "remote" "add" remote desired-url)
              (straight--get-call
               "git" "fetch" remote))
             ("R" (format (concat "Rename remote %S manually, re-create "
                                  "it with correct URL, and fetch")
                          remote)
              (straight--get-call
               "git" "remote" "rename" remote
               (read-string "Enter new remote name: "))
              (straight--get-call
               "git" "remote" "add" remote desired-url)
              (straight--get-call
               "git" "fetch" remote))
             ("d" (format (concat "Delete remote %S, re-create it "
                                  "with correct URL, and fetch")
                          remote)
              (when (straight-are-you-sure
                     (format "Really delete remote %S?" remote))
                (straight--get-call
                 "git" "remote" "remove" remote)
                (straight--get-call
                 "git" "remote" "add" remote desired-url)
                (straight--get-call
                 "git" "fetch" remote)))
             ("D" (format (concat "Delete remote %S, re-create it "
                                  "with manually set URL, and fetch")
                          remote)
              (when (straight-are-you-sure
                     (format "Really delete remote %S?" remote))
                (straight--get-call
                 "git" "remote" "remove" remote)
                (straight--get-call
                 "git" "remote" "add" remote
                 (read-string "Enter new remote URL: "))
                (straight--get-call
                 "git" "fetch" remote))))))
     ;; General policy is that if we make any modifications
     ;; whatsoever, then validation fails. You never know when you
     ;; might run into a weird edge case of Git and have an operation
     ;; unexpectedly violate a previously established assumption.
     (straight--get-call
      "git" "remote" "add" remote desired-url))))

(defun straight-vc-git--validate-remotes (recipe)
  "Validate that repository for RECIPE has remotes set correctly.
RECIPE is a straight.el-style plist.

This means the primary remote and (if :upstream is provided)
upstream remote have their URLs set to the same as what is
specified in the RECIPE. The URLs do not necessarily need to
match exactly; they just have to satisfy
`straight-vc-git--urls-compatible-p'."
  (straight--with-plist recipe
      (local-repo repo host)
    (let ((desired-url (straight-vc-git--encode-url repo host)))
      (and (straight-vc-git--validate-remote
            local-repo straight-vc-git-primary-remote desired-url)
           (or (not (plist-member recipe :upstream))
               (straight--with-plist (plist-get recipe :upstream)
                   (repo host)
                 (let (;; NB: this is a different computation than
                       ;; above.
                       (desired-url (straight-vc-git--encode-url repo host)))
                   (straight-vc-git--validate-remote
                    local-repo straight-vc-git-upstream-remote
                    desired-url))))))))

(defun straight-vc-git--validate-nothing-in-progress (local-repo)
  "Validate that no merge conflict is active in LOCAL-REPO.
LOCAL-REPO is a string."
  (let ((conflicted-files
         (string-remove-suffix
          "\n"
          (straight--get-call
           "git" "ls-files" "--unmerged"))))
    (or (string-empty-p conflicted-files)
        (ignore
         (straight-vc-git--popup
           ;; FIXME: handle rebases, maybe [1] is helpful?
           ;;
           ;; [1]: https://stackoverflow.com/q/3921409/3538165
           (format "Repository %S has a merge conflict:\n%S"
                   local-repo
                   (string-join
                    (mapcar (lambda (line)
                              (concat "  " line))
                            (split-string conflicted-files "\n"))
                    "\n"))
           ("a" "Abort merge"
            (straight--get-call "git" "merge" "--abort")))))))

(cl-defun straight-vc-git--validate-worktree (local-repo)
  "Validate that LOCAL-REPO has a clean worktree.
LOCAL-REPO is a string."
  (let ((status (straight--get-call-raw
                 "git" "-c" "status.branch=false"
                 "status" "--short")))
    (if (string-empty-p status)
        (cl-return-from straight-vc-git--validate-worktree t)
      (straight-vc-git--popup
        (format "Repository %S has a dirty worktree:\n\n%s"
                local-repo
                (string-join
                 (mapcar (lambda (line)
                           (concat "  " line))
                         (split-string status "\n"))
                 "\n"))
        ("z" "Stash changes"
         (let ((msg (read-string "Optional stash message: ")))
           (if (string-empty-p msg)
               (straight--get-call
                "git" "stash" "push" "--include-untracked")
             (straight--get-call
              "git" "stash" "save" "--include-untracked" msg))))
        ("d" "Discard changes"
         (when (straight-are-you-sure
                (format "Discard all local changes permanently?"))
           (and (straight--get-call "git" "reset" "--hard")
                (straight--get-call "git" "clean" "-ffd"))))))))

(cl-defun straight-vc-git--validate-head (local-repo branch &optional ref)
  "Validate that LOCAL-REPO has BRANCH checked out.
If REF is non-nil, instead validate that BRANCH is ahead of REF.
Any untracked files created by checkout will be deleted without
confirmation, so this function should only be run after
`straight-vc-git--validate-worktree' has passed."
  (ignore
   (let* ((cur-branch (straight--get-call
                       "git" "rev-parse" "--abbrev-ref" "HEAD"))
          (head-detached-p (string= cur-branch "HEAD"))
          (ref-name (or ref "HEAD"))
          (quoted-ref-name (if ref (format "%S" ref) "HEAD")))
     (cond
      ((and ref
            (not (straight--check-call
                  "git" "rev-parse" ref)))
       (error "Branch %S does not exist" ref))
      ((and (null ref) (string= branch cur-branch))
       (cl-return-from straight-vc-git--validate-head t))
      ((and (null ref) head-detached-p)
       (straight-vc-git--popup
         (format "In repository %S, HEAD is even with branch %S, but detached."
                 local-repo branch)
         ("a" (format "Attach HEAD to branch %S" branch)
          (straight--get-call "git" "checkout" branch))))
      (t
       (let ((ref-ahead-p (straight--check-call
                           "git" "merge-base" "--is-ancestor"
                           branch ref-name))
             (ref-behind-p (straight--check-call
                            "git" "merge-base" "--is-ancestor"
                            ref-name branch)))
         (when (and ref ref-behind-p)
           (cl-return-from straight-vc-git--validate-head t))
         (straight-vc-git--popup-raw
          (concat
           (format "In repository %S, " local-repo)
           (if ref
               (cond
                (ref-behind-p
                 (cl-return-from straight-vc-git--validate-head t))
                (ref-ahead-p
                 (format "branch %S is behind %S" branch ref))
                (t (format "branch %S has diverged from %S" branch ref)))
             (let ((on-branch (if head-detached-p ""
                                (format " (on branch %S)"
                                        cur-branch))))
               (cond
                (ref-ahead-p
                 (format "HEAD%s is ahead of branch %S" on-branch branch))
                (ref-behind-p
                 (format "HEAD%s is behind branch %S" on-branch branch))
                (t (format "HEAD%s has diverged from branch %S"
                           on-branch branch))))))
          ;; Here be dragons! Watch the quoting very carefully in
          ;; order to get the lexical scoping to work right, and don't
          ;; confuse this syntax with the syntax of the
          ;; `straight-popup' macro.
          `(,@(when ref-ahead-p
                `(("f" ,(format "Fast-forward branch %S to %s"
                                branch quoted-ref-name)
                   ,(lambda ()
                      (straight--get-call
                       "git" "reset" "--hard" ref-name)))))
            ,@(when (and ref-behind-p (null ref))
                `(("f" ,(format "Fast-forward HEAD to branch %S" branch)
                   ,(lambda ()
                      (straight--get-call
                       "git" "checkout" branch)))))
            ,@(unless (or ref-ahead-p ref-behind-p)
                `(("m" ,(format "Merge %S to branch %S" quoted-ref-name branch)
                   ,(lambda ()
                      (if ref
                          (straight--check-call
                           "git" "merge" ref)
                        (let ((orig-head
                               (straight--get-call
                                "git" "rev-parse" "HEAD")))
                          (straight--get-call
                           "git" "checkout" branch)
                          ;; Merge might not succeed, so don't throw
                          ;; on error.
                          (straight--check-call
                           "git" "merge" orig-head)))))
                  ("r" ,(format "Reset branch %S to %s"
                                branch quoted-ref-name)
                   ,(lambda ()
                      (straight--get-call
                       "git" "reset" "--hard" ref-name)))
                  ,@(unless ref
                      `(("c" ,(format "Reset HEAD to branch %S" branch)
                         ,(lambda ()
                            (straight--get-call
                             "git" "checkout" branch)))))
                  ,(if ref
                       `("R" ,(format "Rebase branch %S onto %S" branch ref)
                         ,(lambda ()
                            ;; Rebase might fail, don't throw on
                            ;; error.
                            (straight--check-call
                             "git" "rebase" ref branch)))
                     `("R" ,(format (concat "Rebase HEAD onto branch %S "
                                            "and fast-forward %S to HEAD")
                                    branch branch)
                       ,(lambda ()
                          ;; If the rebase encounters a conflict, no
                          ;; sweat: the possibility of a fast-forward
                          ;; will be detected elsewhere in this
                          ;; function the next time around. But we
                          ;; might as well finish the job if we can.
                          (and (straight--check-call
                                "git" "rebase" branch)
                               (straight--get-call
                                "git" "reset" "--hard" ref-name)))))))))))))))

(cl-defun straight-vc-git--pull-from-remote-raw (recipe remote remote-branch)
  "Using straight.el-style RECIPE, pull from REMOTE.
REMOTE is a string. REMOTE-BRANCH is the branch in REMOTE that is
used; it should be a string that is not prefixed with a remote
name."
  (straight--with-plist recipe
      (local-repo branch)
    (let ((branch (or branch straight-vc-git-default-branch))
          (already-fetched nil))
      (while t
        (and (straight-vc-git--validate-local recipe)
             (or already-fetched
                 (progn
                   (straight--get-call
                    "git" "fetch" remote)
                   (setq already-fetched t)))
             (straight-vc-git--validate-head
              local-repo branch (format "%s/%s" remote remote-branch))
             (cl-return-from straight-vc-git--pull-from-remote-raw t))))))

(cl-defun straight-vc-git--validate-head-pushed (recipe)
  "Validate that in RECIPE's local repo, main branch is behind primary remote."
  (ignore
   (straight--with-plist recipe
       (local-repo branch)
     (let* ((branch (or branch straight-vc-git-default-branch))
            (ref (format "%s/%s" straight-vc-git-primary-remote branch)))
       (when (straight--check-call
              "git" "merge-base" "--is-ancestor"
              branch ref)
         (cl-return-from straight-vc-git--validate-head-pushed t))
       (straight-vc-git--popup
         (format "In repository %S, branch %S has commits unpushed to %S."
                 local-repo branch ref)
         ("p" "Pull and then push"
          (unless (condition-case _
                      (ignore
                       (straight-vc-git--pull-from-remote-raw
                        recipe straight-vc-git-primary-remote branch))
                    (quit t))
            (when (straight-are-you-sure
                   (format "Really push to %S in %S?" ref local-repo))
              ;; If push fails, fall back to higher-level error handling
              ;; to allow the user the option to skip, come back later,
              ;; etc. I think it's foolish to allow force-pushing; the
              ;; user can do that manually if they *really* want to.
              (straight--get-call
               "git" "push" straight-vc-git-primary-remote
               (format "refs/heads/%s:refs/heads/%s" branch branch))))))))))

(defun straight-vc-git--validate-local (recipe)
  "Validate that local repository for RECIPE is as expected.
This means that the remote URLs are set correctly; there is no
merge currently in progress; the worktree is pristine; and the
primary :branch is checked out. The reason for \"local\" in the
name of this function is that no network communication is done
with the remotes."
  (straight--with-plist recipe
      (local-repo branch)
    (let ((branch (or branch straight-vc-git-default-branch)))
      (and (straight-vc-git--validate-remotes recipe)
           (straight-vc-git--validate-nothing-in-progress local-repo)
           (straight-vc-git--validate-worktree local-repo)
           (straight-vc-git--validate-head local-repo branch)))))

;;;;;; API

(defun straight-vc-git-clone (recipe commit)
  "Clone local REPO for straight.el-style RECIPE, checking out COMMIT.
COMMIT is a 40-character SHA-1 Git hash. If it cannot be checked
out, signal a warning. If COMMIT is nil, check out the branch
specified in RECIPE instead. If that fails, signal a warning."
  (straight--with-plist recipe
      (local-repo repo host branch upstream nonrecursive)
    (let ((success nil)
          (repo-dir (straight--dir "repos" local-repo))
          (url (straight-vc-git--encode-url repo host))
          (branch (or branch straight-vc-git-default-branch)))
      (unwind-protect
          (progn
            (straight--get-call
             "git" "clone" "--origin"
             straight-vc-git-primary-remote
             "--no-checkout" url local-repo)
            (let ((straight--default-directory nil)
                  (default-directory repo-dir))
              (when commit
                (unless (straight--check-call
                         "git" "checkout" commit)
                  (straight--warn
                   "Could not check out commit %S in repository %S"
                   commit local-repo)
                  ;; We couldn't check out the commit, best to proceed
                  ;; as if we weren't given one.
                  (setq commit nil)))
              (unless commit
                (unless (straight--check-call
                         "git" "checkout" branch)
                  (straight--warn
                   "Could not check out branch %S of repository %S"
                   branch local-repo)
                  ;; Since we passed --no-checkout, we need to
                  ;; explicitly check out *something*, even if it's
                  ;; not the right thing.
                  (straight--get-call "git" "checkout" "HEAD")))
              (unless nonrecursive
                (straight--get-call
                 "git" "submodule" "update" "--init" "--recursive"))
              (when upstream
                (straight--with-plist upstream
                    (repo host)
                  (let ((url (straight-vc-git--encode-url repo host)))
                    (straight--get-call
                     "git" "remote" "add"
                     straight-vc-git-upstream-remote url)
                    (straight--get-call
                     "git" "fetch" straight-vc-git-upstream-remote)))))
            (setq success t))
        ;; Make cloning an atomic operation.
        (unless success
          (when (file-exists-p repo-dir)
            (delete-directory repo-dir 'recursive)))))))

(cl-defun straight-vc-git-normalize (recipe)
  "Using straight.el-style RECIPE, make the repository locally sane.
This means that its remote URLs are set correctly; there is no
merge currently in progress; its worktree is pristine; and the
primary :branch is checked out."
  (while t
    (and (straight-vc-git--validate-local recipe)
         (cl-return-from straight-vc-git-normalize t))))

(cl-defun straight-vc-git-pull-from-remote (recipe &optional from-upstream)
  "Using straight.el-style RECIPE, pull from a remote.
If FROM-UPSTREAM is non-nil, pull from the upstream remote,
unless no :upstream is configured, in which case do nothing. Else
pull from the primary remote."
  (straight--with-plist recipe
      (branch upstream)
    (unless (and from-upstream (null upstream))
      (let* ((remote (if from-upstream
                         straight-vc-git-upstream-remote
                       straight-vc-git-primary-remote))
             (branch (or branch straight-vc-git-default-branch))
             (remote-branch
              (if from-upstream
                  (or (plist-get upstream :branch)
                      straight-vc-git-default-branch)
                branch)))
        (straight-vc-git--pull-from-remote-raw
         recipe remote remote-branch)))))

(defun straight-vc-git-pull-from-upstream (recipe)
  "Using straight.el-style RECIPE, pull from upstream.
If no upstream is configured, do nothing."
  (straight-vc-git-pull-from-remote
   recipe straight-vc-git-upstream-remote))

(cl-defun straight-vc-git-push-to-remote (recipe)
  "Using straight.el-style RECIPE, push to primary remote, if necessary."
  (while t
    (and (straight-vc-git--validate-local recipe)
         (straight-vc-git--validate-head-pushed recipe)
         (cl-return-from straight-vc-git-push-to-remote t))))

(cl-defun straight-vc-git-check-out-commit (local-repo commit)
  "In LOCAL-REPO, check out COMMIT.
LOCAL-REPO is a string naming a local package repository. COMMIT
is a 40-character string identifying a Git commit."
  (while t
    (and (straight-vc-git--validate-nothing-in-progress local-repo)
         (straight-vc-git--validate-worktree local-repo)
         (straight--get-call "git" "checkout" commit)
         (cl-return-from straight-vc-git-check-out-commit))))

(defun straight-vc-git-get-commit (_local-repo)
  "Return the current commit for the current local repository.
This is a 40-character string identifying the current position of
HEAD in the Git repository."
  (straight--get-call "git" "rev-parse" "HEAD"))

(defun straight-vc-git-local-repo-name (recipe)
  "Generate a repository name from straight.el-style RECIPE.
For the GitHub, GitLab, and Bitbucket hosts, the repository name
is used as-is. Otherwise, an attempt is made to extract the
repository name from the URL. This may still fail, and nil is
then returned."
  (straight--with-plist recipe
      (repo host)
    (if host
        (replace-regexp-in-string
         "^.+/" "" repo)
      ;; The following is a half-hearted attempt to turn arbitrary
      ;; URLs into reasonable repository names.
      (let ((regexp "^.*/\\(.+\\)\\.git$"))
        ;; If this regexp does not match, just return nil.
        (when (string-match regexp repo)
          (match-string 1 repo))))))

(defun straight-vc-git-keywords ()
  "Return a list of keywords used by the VC backend for Git."
  '(:repo :host :branch :nonrecursive :upstream))

;;;; Fetching repositories

(defun straight--repository-is-available-p (recipe)
  "Determine if the repository for the RECIPE exists locally."
  (straight--with-plist recipe
      (local-repo)
    (file-exists-p (straight--dir "repos" local-repo))))

(defun straight--clone-repository (recipe &optional cause)
  "Clone the repository for the RECIPE, erroring if it already exists.
CAUSE is a string indicating the reason this repository is being
cloned."
  (straight--with-plist recipe
      (package local-repo)
    (make-directory (straight--dir "repos") 'parents)
    (straight--with-progress
        (concat cause (when cause straight-arrow)
                (format "Cloning %s" local-repo)
                ;; If this `member' check fails, then it means the
                ;; repository has a name that is substantially
                ;; different than the package name, and the user might
                ;; be confused about why we are cloning it.
                (unless (member local-repo
                                (list
                                 package
                                 (format "%s.el" package)
                                 (format "emacs-%s" package)))
                  (format " (for %s)" package)))
      (straight-vc-clone recipe))
    ;; We messed up the echo area.
    (setq straight--echo-area-dirty t)))

;;;; Recipe handling
;;;;; Declaration of caches

(defvar straight--recipe-cache (make-hash-table :test #'equal)
  "Hash table listing known recipes by package.
The keys are strings naming packages, and the values are the last
known recipe for that package. This is used for detecting
conflicting recipes for the same package; managing the build
cache and versions lockfile; and getting a list of all packages
in use.")

(defvar straight--repo-cache (make-hash-table :test #'equal)
  "Hash table listing known recipes by repository.
The keys are strings naming repositories, and the values are the
last known recipe that referenced the corresponding repository.
This is used for detecting conflicts (when multiple packages are
versioned in the same repository, but are specified with
incompatible recipes) and for silently adjusting recipes drawn
from recipe repositories so as to avoid conflicts.")

(defvar straight--profile-cache (make-hash-table :test #'equal)
  "Hash table mapping packages to lists of profiles.
The keys are strings naming packages, and the values are lists of
symbols identifying package profiles. These symbols are the
values that you bind `straight-current-profile' to, and they
should each have an entry in `straight-profiles'.")

(defun straight--reset-caches ()
  "Reset caches other than the build cache and success cache.
This means `straight--recipe-cache', `straight--repo-cache', and
`straight--profile-cache'. (We don't ever want to reset the build
cache since it is a totally separate system from the caches
employed by `straight--convert-recipe', and we don't ever want to
reset the success cache since that would mean the user would
receive a duplicate message if they called `straight-use-package'
interactively, reloaded their init-file, and then called
`straight-use-package' on the same package again.)"
  (setq straight--recipe-cache (make-hash-table :test #'equal))
  (setq straight--repo-cache (make-hash-table :test #'equal))
  (setq straight--profile-cache (make-hash-table :test #'equal)))

(defvar straight--profile-cache-valid nil
  "Non-nil if `straight--profile-cache' accurately reflects the init-file.
The function `straight-freeze-versions' will be reluctant to
create a version lockfile if this variable is nil. This variable
is set to non-nil in the bootstrap code, and set back to nil when
`straight-use-package' is invoked outside of init.")

(defvar straight--functional-p nil
  "Non-nil if package operations are guaranteed to be functional.
This means they faithfully represent the contents of the
init-file. If package operations are performed when this variable
is nil, then `straight--profile-cache-valid' is set to nil.")

(defun straight-mark-transaction-as-init ()
  "Mark the current transaction as a complete loading of the init-file."
  (straight--transaction-exec
   'init
   (lambda ()
     (setq straight--profile-cache-valid t)
     (setq straight--functional-p t))
   (lambda ()
     (setq straight--functional-p nil))))

(defvar straight-treat-as-init nil
  "Non-nil if straight.el should pretend like initial init is in progress.
This variable is designed for cases when your init-file is first
loaded after init has completed, for some reason (e.g. if you are
profiling it using `esup'). To use it, bind it to non-nil for the
duration of loading your init-file, and then make sure to call
`straight-finalize-transaction'")

;;;;; Recipe repositories

(defvar straight--recipe-repository-stack nil
  "A list of recipe repositories that are currently being searched.
This is used to detect and prevent an infinite recursion when
searching for recipe repository recipes in other recipe
repositories.

If you set this to something other than nil, beware of
velociraptors.")

(defun straight-recipes (method name cause &rest args)
  "Call a recipe backend method.
METHOD is a symbol naming a backend method, like symbol
`retrieve'. NAME is a symbol naming the recipe repository, like
symbol `melpa'.

If the package repository is not available, clone it. If the
package cannot be found, return nil. CAUSE is a string explaining
why the recipe repository might need to be cloned.

ARGS are passed to the method.

This function sets `default-directory' appropriately, handles
cloning the repository if necessary, and then delegates to the
appropriate `straight-recipes-NAME-METHOD' function.

For example:
   (straight-recipes \\='retrieve \\='melpa ...)
=> (straight-recipes-melpa-retrieve ...)"
  (unless (memq name straight--recipe-repository-stack)
    (let ((straight--recipe-repository-stack
           (cons name straight--recipe-repository-stack)))
      (straight-use-package name)
      (let ((recipe (straight--convert-recipe name cause)))
        (straight--with-plist recipe
            (local-repo)
          (let ((default-directory (straight--dir "repos" local-repo))
                (func (intern (format "straight-recipes-%S-%S"
                                      name method))))
            (apply func args)))))))

(defun straight-recipes-retrieve (package &optional sources cause)
  "Look up a PACKAGE recipe in one or more SOURCES.
PACKAGE should be a symbol, and SOURCES should be a list that is
a subset of `straight-recipe-repositories'. (If it is omitted, it
defaults to allowing all sources in
`straight-recipe-repositories'.) If the recipe is not found in
any of the provided sources, return nil. CAUSE is a string
indicating the reason recipe repositories might need to be
cloned."
  (let* (;; If `sources' is omitted, allow all sources.
         (sources (or sources straight-recipe-repositories))
         ;; Update the `cause' to explain why repositories might be
         ;; getting cloned.
         (cause (concat cause (when cause straight-arrow)
                        (format "Looking for %s recipe" package))))
    (cl-dolist (source sources)
      (when-let ((recipe (straight-recipes 'retrieve source cause package)))
        (cl-return recipe)))))

(defun straight-recipes-list (&optional sources cause)
  "List recipes available in one or more SOURCES.
PACKAGE should be a symbol, and SOURCES should be a list that is
a subset of `straight-recipe-repositories'. (If it is omitted, it
defaults to allowing all sources in
`straight-recipe-repositories'.)

CAUSE is a string indicating why recipe repositories might need
to be cloned.

Return a list of package names as strings."
  (let ((sources (or sources straight-recipe-repositories))
        (recipes ()))
    (dolist (source sources (sort (delete-dups recipes)
                                  #'string-lessp))
      (let ((cause (concat cause (when cause straight-arrow)
                           (format "Listing %S recipes" source))))
        (setq recipes (nconc recipes (straight-recipes
                                      'list source cause)))))))

;;;;;; MELPA

(defun straight-recipes-melpa-retrieve (package)
  "Look up a PACKAGE recipe in MELPA.
PACKAGE should be a symbol. If the package has a recipe listed in
MELPA that uses one of the Git fetchers, return it; otherwise
return nil."
  (with-temp-buffer
    (condition-case nil
        (progn
          (insert-file-contents-literally
           (concat "recipes/" (symbol-name package)))
          (let ((melpa-recipe (read (current-buffer)))
                (plist ()))
            (cl-destructuring-bind (name . melpa-plist) melpa-recipe
              (straight--put plist :type 'git)
              (when-let ((files (plist-get melpa-plist :files)))
                (straight--put plist :files files))
              (pcase (plist-get melpa-plist :fetcher)
                ('git (straight--put plist :repo (plist-get melpa-plist :url)))
                ((or 'github 'gitlab)
                 (straight--put plist :host (plist-get melpa-plist :fetcher))
                 (straight--put plist :repo (plist-get melpa-plist :repo)))
                ;; This error is caught by `condition-case', no need
                ;; for a message.
                (_ (error "")))
              (cons name plist))))
      (error nil))))

(defun straight-recipes-melpa-list ()
  "Return a list of recipes available in MELPA, as a list of strings."
  (directory-files "recipes" nil "^[^.]" 'nosort))

;;;;;; EmacsMirror

(defun straight-recipes-emacsmirror-retrieve (package)
  "Look up a PACKAGE recipe in Emacsmirror.
PACKAGE should be a symbol. If the package is available from
Emacsmirror, return a MELPA-style recipe; otherwise return nil."
  ;; Try to get the URL for the submodule. If it doesn't exist,
  ;; return nil. This will work both for packages in the mirror
  ;; and packages in the attic.
  (when-let ((url (condition-case nil
                      (straight--get-call
                       "git" "config" "--file" ".gitmodules"
                       "--get" (format "submodule.%s.url"
                                       (symbol-name package)))
                    (error nil))))
    (and (not (string-empty-p url))
         ;; For the sake of elegance, we convert Github URLs to
         ;; use the `github' fetcher, if possible. At the time of
         ;; this writing, there are no Gitlab URLs (which makes
         ;; sense, since all the repositories should be hosted on
         ;; github.com/emacsmirror).
         (cl-destructuring-bind (repo host _protocol)
             (straight-vc-git--decode-url url)
           (if host
               `(,package :type git :host ,host
                          :repo ,repo)
             `(,package :type git :repo ,repo))))))

(defun straight-recipes-emacsmirror-list ()
  "Return a list of recipes available in EmacsMirror, as a list of strings."
  (append
   (directory-files "mirror" nil "^[^.]" 'nosort)
   (directory-files "attic" nil "^[^.]" 'nosort)))

;;;;; Recipe conversion

;; `cl-defun' creates a block so we can use `cl-return-from'.
(cl-defun straight--convert-recipe (melpa-style-recipe &optional cause)
  "Convert a MELPA-STYLE-RECIPE to a normalized straight.el recipe.
Recipe repositories specified in `straight-recipe-repositories'
may be cloned and searched for recipes if the MELPA-STYLE-RECIPE
is just a package name; otherwise, the MELPA-STYLE-RECIPE should
be a list and it is modified slightly to conform to the internal
straight.el recipe format. CAUSE is a string indicating the
reason recipe repositories might need to be cloned.

Return nil if MELPA-STYLE-RECIPE was just a symbol, and no recipe
could be found for it, and package.el indicates that the package
is built in to Emacs (e.g. the \"emacs\" package). This is used
for dependency resolution."
  ;; Firstly, if the recipe is only provided as a package name, and
  ;; we've already converted it before, then we should just return the
  ;; previous result. This has nothing to do with efficiency; it's
  ;; actually to reduce conflicts. There are a couple of common cases:
  ;;
  ;; 1. I'm overriding the standard recipe for a package with a custom
  ;;    recipe, and then loading a second package that requires the
  ;;    first one as a dependency. In that case, loading the second
  ;;    package will cause the first package to be loaded again,
  ;;    without any special information provided about its
  ;;    recipe (i.e. the recipe is supposed to be looked up by
  ;;    `straight--convert-recipe' in the recipe repositories). But
  ;;    that will cause a conflict, since a different recipe was
  ;;    already provided. This problem is solved by the following two
  ;;    lines of code. (Note, though, that there is still a conflict
  ;;    if you load the second package before its custom-recipe
  ;;    dependency, as should be expected.)
  ;;
  ;; 2. I'm loading two different features from the same package with
  ;;    `use-package', and providing a non-standard recipe for the
  ;;    package. For example, this comes up when you need to load both
  ;;    `tex-site' and `tex' from your fork of `auctex'. It's
  ;;    inconvenient to specify your custom recipe in both
  ;;    `use-package' declarations, but with the following two lines
  ;;    of code, you can specify your custom recipe in the first
  ;;    `use-package' declaration and then specify only `auctex' as
  ;;    the recipe in the second `use-package' declaration.
  ;;
  ;; 3. I'm using `straight-rebuild-package' or
  ;;    `straight-rebuild-all', which both call `straight-use-package'
  ;;    with just the package name and expect this not to introduce
  ;;    conflicts.
  (or (and (symbolp melpa-style-recipe)
           (gethash (symbol-name melpa-style-recipe) straight--recipe-cache))
      (let* (;; It's important to remember whether the recipe was
             ;; provided explicitly, or if it was just given as a
             ;; package name (meaning that the recipe needs to be
             ;; looked up in a recipe repository, i.e. something in
             ;; `straight-recipe-repositories'). Why, you ask? It's so
             ;; that we can be a little more tolerant of conflicts in
             ;; certain cases -- see the comment below, before the
             ;; block of code that runs when `recipe-specified-p' is
             ;; nil.
             (recipe-specified-p (listp melpa-style-recipe))
             ;; Now we normalize the provided recipe so that it is
             ;; still a MELPA-style recipe, but it is guaranteed to be
             ;; a list. This is the part where the recipe repositories
             ;; are consulted, if necessary.
             (full-melpa-style-recipe
              (if recipe-specified-p
                  melpa-style-recipe
                (or (straight-recipes-retrieve
                     ;; Second argument is the sources list, defaults
                     ;; to all known sources.
                     melpa-style-recipe nil cause)
                    (progn
                      ;; We don't want package.el unless this branch
                      ;; is triggered. Since we're loading it
                      ;; dynamically, we need to do `eval-and-compile'
                      ;; to silence the byte-compiler.
                      (eval-and-compile
                        (require 'package))
                      (if (package-built-in-p melpa-style-recipe)
                          (cl-return-from straight--convert-recipe)
                        (error (concat "Could not find package %S "
                                       "in recipe repositories: %S")
                               melpa-style-recipe
                               straight-recipe-repositories)))))))
        ;; MELPA-style recipe format is a list whose car is the
        ;; package name as a symbol, and whose cdr is a plist.
        (cl-destructuring-bind (package . plist) full-melpa-style-recipe
          ;; Recipes taken from recipe repositories would not normally
          ;; have `:local-repo' specified. But if the recipe was
          ;; specified manually, then you can specify `:local-repo' to
          ;; override the default value (which is determined according
          ;; to the selected VC backend).
          (straight--with-plist plist
              (local-repo type)
            ;; The normalized recipe format will have the package name
            ;; as a string, not a symbol.
            (let ((package (symbol-name package)))
              ;; Note that you can't override `:package'. That would
              ;; just be silly.
              (straight--put plist :package package)
              ;; If no `:type' is specified, use the default.
              (unless type
                (straight--put plist :type straight-default-vc))
              ;; This `unless' allows overriding `:local-repo' in a
              ;; manual recipe specification.
              (unless local-repo
                (straight--put
                 plist :local-repo
                 (or (straight-vc-local-repo-name plist)
                     ;; If no sane repository name can be generated,
                     ;; just use the package name.
                     package)))
              ;; This code is here to deal with complications that can
              ;; arise with manual recipe specifications when multiple
              ;; packages are versioned in the same repository.
              ;;
              ;; Specifically, let's suppose packages `swiper' and
              ;; `ivy' are both versioned in repository "swiper", and
              ;; let's suppose that I load both of them in my
              ;; init-file (`ivy' first and then `swiper'). Now
              ;; suppose that I discover a bug in `ivy' and fix it in
              ;; my fork, so that (until my fix is merged) I need to
              ;; provide an explicit recipe in my init-file's call to
              ;; `straight-use-package' for `ivy', in order to use my
              ;; fork. That will cause a conflict, because the recipe
              ;; for `swiper' is automatically taken from MELPA, and
              ;; it does not point at my fork, but instead at the
              ;; official repository. To fix the problem, I would have
              ;; to specify my fork in the recipe for `swiper' (and
              ;; also `counsel', a third package versioned in the same
              ;; repository). That violates DRY and is a pain.
              ;;
              ;; Instead, this code makes it so that if a recipe has
              ;; been automatically retrieved from a recipe repository
              ;; (for example, MELPA or Emacsmirror), and the
              ;; `:local-repo' specified in that recipe has already
              ;; been used for another package, then the configuration
              ;; for that repository will silently be copied over, and
              ;; everything should "just work".
              ;;
              ;; Note that this weird edge case is totally unrelated
              ;; to the weird edge cases discussed earlier (in the
              ;; first comment of this function), and has to be
              ;; handled in a totally different way. It's surprising
              ;; how complicated recipe specification turns out to be.
              (unless recipe-specified-p
                (straight--with-plist plist
                    (local-repo)
                  ;; Here we are checking to see if there is already a
                  ;; formula with the same `:local-repo'. This is one
                  ;; of the primary uses of `straight--repo-cache'.
                  (when-let (original-recipe (gethash local-repo
                                                      straight--repo-cache))
                    ;; Remove all VC-specific attributes from the
                    ;; recipe we got from the recipe repositories.
                    (straight--remq
                     plist (cons :type
                             (straight-vc-keywords
                              ;; To determine which keywords to remove
                              ;; from `plist', we want to use the VC
                              ;; backend specified for that same
                              ;; recipe. This is important in case the
                              ;; recipe repository and the existing
                              ;; recipe specify different values for
                              ;; `:type'.
                              (plist-get plist :type))))
                    ;; Now copy over all the VC-specific attributes
                    ;; from the existing recipe.
                    (dolist (keyword
                             (cons :type
                               (straight-vc-keywords
                                ;; Same logic as above. This time
                                ;; we're using the VC backend
                                ;; specified by the original recipe.
                                (plist-get original-recipe :type))))
                      (when-let ((value (plist-get original-recipe keyword)))
                        (straight--put plist keyword value))))))
              ;; Return the newly normalized recipe.
              plist))))))

(defun straight--get-overridden-recipe (package)
  "Given a PACKAGE symbol, check if it has an overridden recipe.
This means an entry in `straight-recipe-overrides'. If one is
found, return it as a MELPA-style recipe. Otherwise, return
nil."
  (let ((recipe nil))
    (cl-dolist (profile (mapcar #'car straight-profiles))
      (when-let ((recipes (alist-get profile straight-recipe-overrides)))
        (when-let ((overridden-recipe (assoc package recipes)))
          (setq recipe overridden-recipe))))
    recipe))

;;;;; Recipe registration

(defvar straight--build-keywords
  '(:local-repo :files)
  "Keywords that affect how a file is built locally.
If the values for any of these keywords change, then package
needs to be rebuilt. See also `straight-vc-keywords'.")

(defun straight--register-recipe (recipe)
  "Make the various caches aware of RECIPE.
RECIPE should be a straight.el-style recipe plist."
  (straight--with-plist recipe
      (package local-repo type)
    ;; Step 1 is to check if the given recipe conflicts with an
    ;; existing recipe for a *different* package with the *same*
    ;; repository.
    (when-let ((existing-recipe (gethash local-repo straight--repo-cache)))
      ;; Avoid signalling two warnings when you change the recipe for
      ;; a single package. We already get a warning down below in Step
      ;; 2, no need to show another one here. Only signal a warning
      ;; here when the packages are actually *different* packages that
      ;; share the same repository.
      (unless (equal (plist-get recipe :package)
                     (plist-get existing-recipe :package))
        ;; Only the VC-specific keywords are relevant for this.
        (cl-dolist (keyword (cons :type (straight-vc-keywords type)))
          ;; Note that it doesn't matter which recipe we get `:type'
          ;; from. If the two are different, then the first iteration
          ;; of this loop will terminate with a warning, as desired.
          (unless (equal (plist-get recipe keyword)
                         (plist-get existing-recipe keyword))
            ;; We're using a warning rather than an error here, because
            ;; it's very frustrating if your package manager simply
            ;; refuses to install a package for no good reason. Note
            ;; that since we update `straight--repo-cache' and
            ;; `straight--recipe-cache' at the end of this method, this
            ;; warning will only be displayed once per recipe
            ;; modification.
            (straight--warn (concat "Packages %S and %S have incompatible "
                                    "recipes (%S cannot be both %S and %S)")
                            (plist-get existing-recipe :package)
                            package
                            keyword
                            (plist-get existing-recipe keyword)
                            (plist-get recipe keyword))
            (cl-return)))))
    ;; Step 2 is to check if the given recipe conflicts with an
    ;; existing recipe for the *same* package.
    (when-let ((existing-recipe (gethash package straight--recipe-cache)))
      (cl-dolist (keyword
                  (cons :type
                    (append straight--build-keywords
                            ;; As in Step 1, it doesn't matter which
                            ;; recipe we get `:type' from.
                            (straight-vc-keywords type))))
        (unless (equal (plist-get recipe keyword)
                       (plist-get existing-recipe keyword))
          ;; Same reasoning as with the previous warning.
          (straight--warn (concat "Package %S has two incompatible "
                                  "recipes (%S cannot be both %S and %S)")
                          package
                          keyword
                          (plist-get existing-recipe keyword)
                          (plist-get recipe keyword))
          (cl-return))))
    ;; Step 3, now that we've signaled any necessary warnings, is to
    ;; actually update the caches. Just FYI, `straight--build-cache'
    ;; is updated later (namely, at build time -- which may be quite a
    ;; while later, or never, depending on the values of NO-CLONE and
    ;; NO-BUILD that were passed to `straight-use-package'.
    (puthash package recipe straight--recipe-cache)
    (puthash local-repo recipe straight--repo-cache)
    (cl-pushnew straight-current-profile
                (gethash package straight--profile-cache)
                ;; Profiles are symbols and can be compared more
                ;; efficiently using `eq'.
                :test #'eq)
    ;; If we've registered a new package, then we no longer know that
    ;; the set of registered packages actually corresponds to the
    ;; packages requested in the init-file. (For instance, this could
    ;; be an interactive call.) But we're OK if this operation is
    ;; guaranteed to be functional (e.g. because we're currently
    ;; loading the init-file).
    (unless straight--functional-p
      (setq straight--profile-cache-valid nil))))

(defun straight--map-repos (func)
  "Call FUNC for each local repository referenced in the known recipes.
FUNC is passed one argument, the straight.el-style recipe plist.
It is called once for every local repository (i.e. each distinct
value of `:local-repo'). This means that if multiple packages are
versioned in the same local repository, then all but one of them
will be omitted."
  ;; Remember that `straight--repo-cache' only has the most recent
  ;; recipe that specified each `:local-repo'.
  (dolist (recipe (hash-table-values straight--repo-cache))
    (funcall func recipe)))

(defun straight--map-repo-packages (func)
  "Call FUNC for each local repository referenced in the known recipes.
The function FUNC is passed one argument, the name (as a string)
of one of the packages using the local repository."
  (straight--map-repos
   (lambda (recipe)
     (straight--with-plist recipe
         (package)
       (funcall func package)))))

;;;; Checking for package modifications
;;;;; Build cache

(defvar straight--build-cache nil
  "Hash table keeping track of information about built packages, or nil.
The keys are strings naming packages, and the values are lists of
length three. The first entry is a timestamp identifying the last
time the package was successfully built; the second entry is a
list of the dependencies of the package, as strings; and the
third entry is the straight.el-normalized recipe plist for the
package. This information is used to determine whether or not a
package needs to be rebuilt.

The value of this variable is persisted in the file
build-cache.el.")

(defvar straight--eagerly-checked-packages nil
  "List of packages that will be checked eagerly for modifications.
This list is read from the build cache, and is originally
generated at the end of an init from the keys of
`straight--profile-cache'.")

(defun straight--load-build-cache ()
  "Load the build cache from build-cache.el into `straight--build-cache'.
If build-cache.el does not both exist and contain a valid Elisp
hash table with the appropriate `:test', then
`straight--build-cache' is set to an empty hash table."
  (with-temp-buffer
    (ignore-errors
      ;; Using `insert-file-contents-literally' avoids
      ;; `find-file-hook', etc.
      (insert-file-contents-literally
       (straight--file "build-cache.el")))
    (setq straight--build-cache
          (or (ignore-errors
                (let ((table (read (current-buffer))))
                  (cl-assert (hash-table-p table))
                  (cl-assert (eq (hash-table-test table) #'equal))
                  table))
              ;; The keys are package names as *strings*.
              (make-hash-table :test #'equal)))
    (setq straight--eagerly-checked-packages
          (or (ignore-errors
                (let ((list (read (current-buffer))))
                  (cl-assert (listp list))
                  (cl-assert (cl-every #'stringp list))
                  list))))))

(defun straight--save-build-cache ()
  "Write the build cache from `straight--build-cache' into build-cache.el."
  (with-temp-file (straight--file "build-cache.el")
    (print straight--build-cache (current-buffer))
    (print (hash-table-keys straight--profile-cache) (current-buffer))))

;;;;; Bulk checking

(defvar straight--cached-package-modifications (make-hash-table :test #'equal)
  "Hash table indicating the modification status of cached packages.
Valid for the duration of a single transaction. It is a hash
table whose keys are local repository names as strings and whose
values are booleans indicating whether the repositories have been
modified since their last builds.")

(defun straight--cache-package-modifications ()
  "Compute `straight--cached-package-modifications'."
  (let (;; Keep track of which local repositories we've processed
        ;; already. This table maps repo names to booleans.
        (repos (make-hash-table :test #'equal))
        ;; The systematically generated arguments for find(1).
        (args nil))
    (dolist (package straight--eagerly-checked-packages)
      (when-let (build-info (gethash package straight--build-cache))
        ;; Don't use `cl-destructuring-bind', as that will
        ;; error out on a list of insufficient length. We
        ;; want to be robust in the face of a malformed build
        ;; cache.
        (let ((mtime (nth 0 build-info))
              (recipe (nth 2 build-info)))
          (straight--with-plist recipe
              (local-repo)
            (when local-repo
              (unless (gethash local-repo repos)
                (if mtime
                    ;; The basic idea of the find(1) command here is
                    ;; that it is composed of a series of disjunctive
                    ;; clauses, one for each repository. The first
                    ;; clause matches anything named ".git" at a depth
                    ;; of two, so that the Git directories are
                    ;; ignored. Then each subsequent clause matches
                    ;; and prints anything in a particular repository
                    ;; that has an mtime greater than the last build
                    ;; time for that repository.
                    ;;
                    ;; Just FYI, this find(1) command is compatible
                    ;; with both GNU and BSD find. But not apparently
                    ;; with busybox/find, see [1].
                    ;;
                    ;; [1]: https://github.com/raxod502/straight.el/issues/78
                    (setq args (append (list "-o"
                                             "-path"
                                             (format "./%s/*" local-repo)
                                             "-newermt"
                                             mtime
                                             "-print")
                                       args))
                  ;; If no mtime is specified, it means the package
                  ;; definitely needs to be (re)built. Probably there
                  ;; was an error and we couldn't finish building the
                  ;; package, but we wrote the build cache anyway.
                  (puthash
                   local-repo t straight--cached-package-modifications))
                ;; Don't create duplicate entries in the find(1)
                ;; command for this local repository.
                (puthash local-repo t repos)))))))
    ;; The preamble to the find(1) command, which comes before the
    ;; repository-specific subparts (see above).
    (setq args (append (list "." "-name" ".git" "-prune")
                       args))
    (with-temp-buffer
      (let ((default-directory (straight--dir "repos")))
        (let ((return (apply #'call-process "find" nil '(t t) nil args)))
          ;; find(1) always returns zero unless there was some kind of
          ;; error.
          (unless (= 0 return)
            (error "Command failed: find %s:\n%s"
                   (string-join (mapcar #'shell-quote-argument args) " ")
                   (buffer-string))))
        (maphash (lambda (local-repo _)
                   (goto-char (point-min))
                   (when (re-search-forward
                          (format "^\\./%s/" (regexp-quote local-repo))
                          nil 'noerror)
                     (puthash
                      local-repo t straight--cached-package-modifications)))
                 repos)))))

(defun straight--uncache-package-modifications ()
  "Reset `straight--cached-package-modifications'."
  (setq straight--cached-package-modifications
        (make-hash-table :test #'equal)))

;;;;; Individual checking

(defun straight--package-might-be-modified-p (recipe)
  "Check whether the package for the given RECIPE might be modified.
This is done by using find(1) to recursively check the mtimes of
all files in the package's local repository."
  (straight--with-plist recipe
      (package local-repo)
    (let* (;; `build-info' is a list of length three containing the
           ;; timestamp of the last build, the list of dependencies,
           ;; and the recipe plist, in that order.
           (build-info (gethash package straight--build-cache))
           (last-mtime (nth 0 build-info))
           (last-recipe (nth 2 build-info)))
      (or (null build-info)
          ;; Rebuild if relevant parts of the recipe have changed.
          (cl-dolist (keyword straight--build-keywords nil)
            (unless (equal (plist-get recipe keyword)
                           (plist-get last-recipe keyword))
              (cl-return t)))
          (progn
            ;; This method should always be called from a transaction.
            ;; We'll get an error from `straight--transaction-exec' if
            ;; that's somehow not the case.
            (straight--transaction-exec
             'bulk-find
             #'straight--cache-package-modifications
             #'straight--uncache-package-modifications)
            (if (straight--checkhash
                 local-repo straight--cached-package-modifications)
                ;; Use the cached modification status if we've computed
                ;; one.
                (gethash local-repo straight--cached-package-modifications)
              ;; `last-mtime' should always be a string but you never
              ;; know.
              (or (not (stringp last-mtime))
                  (with-temp-buffer
                    (let* ((default-directory
                             (straight--dir "repos" local-repo))
                           ;; This find(1) command ignores the .git
                           ;; directory, and prints the names of any
                           ;; files or directories with a newer mtime
                           ;; than the one specified.
                           (args `("." "-name" ".git" "-prune"
                                   "-o" "-newermt" ,last-mtime "-print"))
                           (return (apply #'call-process "find"
                                          nil '(t t) nil args)))
                      (unless (= 0 return)
                        (error "Command failed: find %s:\n%s"
                               (string-join
                                (mapcar #'shell-quote-argument args)
                                " ")
                               (buffer-string)))
                      ;; If anything was printed, the package has
                      ;; (maybe) been modified.
                      (> (buffer-size) 0))))))))))

;;;; Building packages
;;;;; Files directive processing

(defvar straight-default-files-directive
  '("*.el" "*.el.in" "dir"
    "*.info" "*.texi" "*.texinfo"
    "doc/dir" "doc/*.info" "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
    (:exclude ".dir-locals.el" "test.el" "tests.el" "*-test.el" "*-tests.el"))
  "Default value for the `:files' directive in recipes.
It is also spliced in at any point where the `:default' keyword
is used in a `:files' directive.")

(defun straight--expand-files-directive-internal (files src-dir prefix)
  "Expand FILES directive in SRC-DIR with path PREFIX.
FILES is a list that can be used for the `:files' directive in a
recipe. SRC-DIR is an absolute path to the directory relative to
which wildcards are to be expanded. PREFIX is a string, either
empty or ending with a slash, that should be prepended to all
target paths.

The return value is a cons cell of a list of mappings and a list
of exclusions. The mappings are of the same form that is returned
by `straight--expand-files-directive', while the exclusions are
analogous except that they are only cars, and do not include
destinations."
  (unless (listp files)
    (error "Invalid :files directive: %S" files))
  (let ((mappings ())
        (exclusions ()))
    ;; We have to do some funny business to get `:defaults' splicing
    ;; and wildcard expansion to work, hence `while' instead of
    ;; `dolist'.
    (while files
      ;; Pop off the first spec. We might add some new specs back in
      ;; later on.
      (let ((spec (car files)))
        (setq files (cdr files))
        (cond
         ((eq spec :defaults)
          (setq files (append straight-default-files-directive files)))
         ;; Replace string-only specs with a bunch of conses that have
         ;; already been wildcard-expanded.
         ((stringp spec)
          (setq files
                ;; Function `nconc' doesn't mutate its last argument.
                ;; We use it for efficiency over `append'.
                (nconc
                 (mapcar
                  (lambda (file)
                    ;; Here we are using `file-name-nondirectory' to
                    ;; achieve a default of linking to the root
                    ;; directory of the target, but possibly with a
                    ;; prefix if one was created by an enclosing list.
                    (cons file (concat prefix (file-name-nondirectory file))))
                  (file-expand-wildcards spec))
                 files)))
         ;; The only other possibilities were already taken care of.
         ((not (consp spec))
          (error "Invalid entry in :files directive: %S" spec))
         ((eq (car spec) :exclude)
          (cl-destructuring-bind
              (rec-mappings . rec-exclusions)
              (straight--expand-files-directive-internal
               (cdr spec) src-dir prefix)
            ;; We still want to make previously established mappings
            ;; subject to removal, but this time we're inverting the
            ;; meaning of the sub-list so that its mappings become our
            ;; exclusions.
            (setq mappings (cl-remove-if
                            (lambda (mapping)
                              (member (car mapping) rec-mappings))
                            mappings))
            ;; Same as above. Mappings become exclusions. We drop the
            ;; actual exclusions of the `:exclude' sub-list, since
            ;; they are only supposed to apply to which elements
            ;; actually get excluded (a double exclusion does not make
            ;; an inclusion, at least here).
            (dolist (mapping rec-mappings)
              (push (car mapping) exclusions))))
         ;; Check if this is a proper list, rather than just a cons
         ;; cell.
         ((consp (cdr spec))
          ;; If so, the car should be a path prefix. We don't accept
          ;; `defaults' here obviously.
          (unless (stringp (car spec))
            (error "Invalid sub-list head in :files directive: %S" (car spec)))
          (cl-destructuring-bind
              ;; "rec" stands for "recursive".
              (rec-mappings . rec-exclusions)
              (straight--expand-files-directive-internal
               (cdr spec) src-dir (concat prefix (car spec) "/"))
            ;; Any previously established mappings are subject to
            ;; removal from the `:exclude' clauses inside the
            ;; sub-list, if any.
            (setq mappings (cl-remove-if
                            (lambda (mapping)
                              (member (car mapping) rec-exclusions))
                            mappings))
            ;; We have to do this after the `cl-remove-if' above,
            ;; since otherwise the mappings established within the
            ;; sub-list after the `:exclude' clauses there would also
            ;; be subject to removal.
            (dolist (mapping rec-mappings)
              ;; This is the place where mappings generated further
              ;; down are propagated all the way up to the top (unless
              ;; they get hit by a `cl-remove-if').
              (push mapping mappings))
            ;; The exclusions might also apply to some more mappings
            ;; that were established in higher-level sub-lists.
            (dolist (exclusion rec-exclusions)
              (push exclusion exclusions))))
         ((or (not (stringp (car spec)))
              (not (stringp (cdr spec))))
          (error "Invalid entry in :files directive: %S" spec))
         (t
          ;; Filter out nonexistent files silently. This only matters
          ;; when mappings are specified explicitly with cons cells,
          ;; since `file-expand-wildcards' will only report extant
          ;; files, even if there are no wildcards to expand.
          (when (file-exists-p (car spec))
            ;; This is the only place where mappings are actually
            ;; generated in the first place.
            (push spec mappings))))))
    ;; We've been using `push' to stick stuff onto the fronts of our
    ;; lists, so we need to reverse them. Not that it should matter
    ;; too much.
    (cons (reverse mappings) (reverse exclusions))))

(defun straight-expand-files-directive (files src-dir dest-dir)
  "Expand FILES directive mapping from SRC-DIR to DEST-DIR.
SRC-DIR and DEST-DIR are absolute paths; the intention is that
symlinks are created in DEST-DIR pointing to SRC-DIR (but this
function does not do that). Return a list of cons cells
representing the mappings from SRC-DIR to DEST-DIR. The paths in
the cons cells are absolute.

FILES is a list, or nil. Each element of FILES can be a string, a
cons cell, a list, or the symbol `:defaults'.

If an entry is a string, then it is expanded into a (possibly
empty) list of extant files in SRC-DIR using
`file-expand-wildcards'. Each of these files corresponds to a
link from the file in SRC-DIR to a file with the same name (sans
directory) in DEST-DIR.

If an entry is a cons cell, then it is taken as a literal mapping
from a file in SRC-DIR to a file in DEST-DIR (the directory is
not removed). In this case, wildcard expansion does not take
place.

If an entry is a list, then it must begin with either a string or
the symbol `:exclude'.

If the list begins with a string, then the remainder of the list
is expanded as a top-level FILES directive, except that all
target paths have the first element of the list prepended to
then. In other words, this form specifies further links to be
placed within a particular subdirectory of DEST-DIR.

If the list begins with the symbol `:exclude', then the remainder
of the list is expanded as a top-level FILES directive, except
that all previously defined links pointing to any files in the
resulting list are removed. Note that this means any links
specified previously in the current list are subject to removal,
and also any links specified previously at any higher-level list,
but not any links specified afterwards in the current list, or
any higher-level list. Note also that `:exclude' can be nested:
in this case the inner `:exclude' results in some files being
excluded from the outer `:exclude', meaning that they will not
actually be excluded.

If the entry is the symbol `:default', then the value of
`straight-default-files-directive' is spliced into the enclosing
list to replace `:default'.

If FILES is nil, it defaults to
`straight-default-files-directive'.

If two links are specified that take the same source path to
different target paths, the one that is specified textually later
in FILES will win.

Note that this specification is quite similar to the one used by
the MELPA recipe repository, with some minor differences:

* MELPA recipes do not support cons cells to rename files or
  specify explicit subdirectories

* MELPA recipes do not support putting `:default' anywhere except
  as the first element of the top-level list

* When using `:exclude' in a MELPA recipe, the current DEST-DIR
  prefix created by enclosing lists is not respected.

* Whenever a *.el.in file is linked in a MELPA recipe, the target
  of the link is named as *.el.

* When using `:exclude' in a MELPA recipe, only links defined in
  the current list are subject to removal, and not links defined
  in higher-level lists."
  ;; We bind `default-directory' here so we don't have to do it
  ;; repeatedly in the recursive section.
  (let* ((default-directory src-dir)
         (result (straight--expand-files-directive-internal
                  (or files straight-default-files-directive)
                  src-dir ""))
         ;; We can safely discard the exclusions in the cdr of
         ;; `result', since any mappings that should have been
         ;; subject to removal have already had the exclusions
         ;; applied to them.
         (mappings (car result)))
    (straight--normalize-alist
     (mapcar (lambda (mapping)
               (cl-destructuring-bind (src . dest) mapping
                 ;; Make the paths absolute.
                 (cons (concat src-dir src)
                       (concat dest-dir dest))))
             mappings)
     ;; Keys are strings.
     #'equal)))

;;;;; Symlinking

(defun straight--symlink-package (recipe)
  "Symlink the package for the given RECIPE into the build directory.
This deletes any existing files in the relevant subdirectory of
the build directory, creating a pristine set of symlinks."
  (straight--with-plist recipe
      (package local-repo files)
    ;; Remove the existing built package, if necessary.
    (let ((dir (straight--dir "build" package)))
      (when (file-exists-p dir)
        (delete-directory dir 'recursive)))
    ;; Make a new directory for the built package.
    (make-directory (straight--dir "build" package) 'parents)
    ;; Do the linking.
    (dolist (spec (straight-expand-files-directive
                   files
                   (straight--dir "repos" local-repo)
                   (straight--dir "build" package)))
      (cl-destructuring-bind (repo-file . build-file) spec
        (make-directory (file-name-directory build-file) 'parents)
        (make-symbolic-link repo-file build-file)))))

;;;;; Dependency management

(defun straight--process-dependencies (dependencies)
  "Normalize a package.el-style list of DEPENDENCIES.
Each dependency is a list of length two containing a symbol
naming a package and a string naming the minimum version
required (see the Package-Requires header in a
package.el-compliant Elisp package). The return value is a list
of strings naming the packages that are mentioned in the
dependency list."
  (mapcar #'symbol-name (mapcar #'car dependencies)))

(defun straight--compute-dependencies (package)
  "Register the dependencies of PACKAGE in `straight--build-cache'.
PACKAGE should be a string naming a package. Note that this
function does *not* return the dependency list; see
`straight--get-dependencies' for that. (The reason these two
functions are separate is because dependencies are computed at
package build time, but they are retrieved later (when we are
activating autoloads, and may not have even built the package on
this run of straight.el)."
  (let ((dependencies
         ;; There are actually two ways of specifying a package in
         ;; Emacs. The first is to include a file called
         ;; <PACKAGE-NAME>-pkg.el which contains a data structure with
         ;; a bunch of information (including the dependency alist).
         ;; The second is to put the information as headers in the
         ;; preamble of the file <PACKAGE-NAME>.el. We account for
         ;; both of them here.
         (or (condition-case nil
                 (with-temp-buffer
                   (insert-file-contents-literally ; bypass `find-file-hook'
                    (straight--file
                     "build" package
                     (format "%s-pkg.el" package)))
                   (straight--process-dependencies
                    (eval (nth 4 (read (current-buffer))))))
               (error nil))
             (condition-case nil
                 (with-temp-buffer
                   (insert-file-contents-literally ; bypass `find-file-hook'
                    (straight--file
                     "build" package
                     (format "%s.el" package)))
                   ;; Who cares if the rest of the header is
                   ;; well-formed? Maybe package.el does, but all we
                   ;; really need is the dependency alist. If it's
                   ;; missing or malformed, we just assume the package
                   ;; has no dependencies.
                   (re-search-forward "^;; Package-Requires: ")
                   (straight--process-dependencies
                    (read (current-buffer))))
               (error nil)))))
    (straight--insert 1 package dependencies straight--build-cache)))

(defun straight--get-dependencies (package)
  "Get the dependencies of PACKAGE from `straight--build-cache'.
PACKAGE should be a string naming a package. This assumes that
they were previously registered in the build cache by
`straight--compute-dependencies'."
  (nth 1 (gethash package straight--build-cache)))

;;;;; Autoload generation

(defun straight--generate-package-autoloads (recipe)
  "Generate autoloads for the symlinked package specified by RECIPE.
RECIPE should be a straight.el-style plist. See
`straight--autoload-file-name'. Note that this function only
modifies the build folder, not the original repository."
  ;; The `eval-and-compile' here is extremely important. If you take
  ;; it out, then straight.el will fail with a mysterious error and
  ;; then cause Emacs to segfault if you start it with --debug-init.
  ;; This happens because if you take out `eval-and-compile', then
  ;; `autoload' will not be loaded at byte-compile time, and therefore
  ;; `generated-autoload-file' is not defined as a variable. Thus
  ;; Emacs generates bytecode corresponding to a lexical binding of
  ;; `generated-autoload-file', and then chokes badly when
  ;; `generated-autoload-file' turns into a dynamic variable at
  ;; runtime.
  (eval-and-compile
    (require 'autoload))
  (straight--with-plist recipe
      (package)
    (let (;; The full path to the autoload file.
          (generated-autoload-file
           (straight--file
            "build" package
            (straight--autoload-file-name package)))
          ;; The following bindings are in
          ;; `package-generate-autoloads'. Presumably this is for a
          ;; good reason, so I just copied them here. It's a shame
          ;; that Emacs activates so many random features even when
          ;; you are accessing files programmatically.
          (noninteractive t)
          (backup-inhibited t)
          (version-control 'never)
          ;; Tell Emacs to shut up.
          (message-log-max nil) ; no *Messages*
          (inhibit-message t)) ; no echo area
      ;; Actually generate the autoload file.
      (update-directory-autoloads
       (straight--dir "build" package))
      ;; And for some reason Emacs leaves a newly created buffer lying
      ;; around. Let's kill it.
      (when-let ((buf (find-buffer-visiting generated-autoload-file)))
        (kill-buffer buf)))))

;;;;; Byte-compilation

(defun straight--byte-compile-package (recipe)
  "Byte-compile files for the symlinked package specified by RECIPE.
RECIPE should be a straight.el-style plist. Note that this
function only modifies the build folder, not the original
repository."
  ;; We need to load `bytecomp' so that the `symbol-function'
  ;; assignments below are sure to work. Since we byte-compile this
  ;; file, we need to `require' the feature at compilation time too.
  (eval-and-compile
    (require 'bytecomp))
  (straight--with-plist recipe
      (package)
    ;; These two `let' forms try very, very hard to make
    ;; byte-compilation an invisible process. Lots of packages have
    ;; byte-compile warnings; I don't need to know about them and
    ;; neither do straight.el users.
    (cl-letf (;; Prevent Emacs from asking the user to save all their
              ;; files before compiling.
              ((symbol-function #'save-some-buffers) #'ignore)
              ;; Die, byte-compile log, die!!!
              ((symbol-function #'byte-compile-log-1) #'ignore)
              ((symbol-function #'byte-compile-log-file) #'ignore)
              ((symbol-function #'byte-compile-log-warning) #'ignore))
      (let (;; Suppress messages about byte-compilation progress.
            (byte-compile-verbose nil)
            ;; Suppress messages about byte-compilation warnings.
            (byte-compile-warnings nil)
            ;; Suppress the remaining messages.
            (inhibit-message t)
            (message-log-max nil))
        ;; Note that there is in fact no `byte-compile-directory'
        ;; function.
        (byte-recompile-directory
         (straight--dir "build" package)
         0 'force)))))

;;;;; Cache handling

(defun straight--finalize-build (recipe)
  "Update `straight--build-cache' to reflect a successful build of RECIPE.
RECIPE should be a straight.el-style plist. The build mtime and
recipe in `straight--build-cache' for the package are updated."
  (straight--with-plist recipe
      (package)
    (let (;; This time format is compatible with:
          ;;
          ;; * BSD find shipped with macOS >=10.11
          ;; * GNU find >=4.4.2
          (mtime (format-time-string "%F %T%z")))
      (straight--insert 0 package mtime straight--build-cache))
    (straight--insert 2 package recipe straight--build-cache)))

;;;;; Main entry point

(defun straight--build-package (recipe &optional cause)
  "Build the package specified by the RECIPE.
This includes symlinking the package files into the build
directory, building dependencies, generating the autoload file,
byte-compiling, and updating the build cache. It is assumed that
the package repository has already been cloned.

RECIPE is a straight.el-style plist. CAUSE is a string indicating
the reason this package is being built."
  (straight--with-plist recipe
      (package)
    (let ((task (concat cause (when cause straight-arrow)
                        (format "Building %s" package))))
      (straight--with-progress task
        (straight--symlink-package recipe)
        ;; The following function call causes the dependency list to
        ;; be written to the build cache. To prevent this from being
        ;; overwritten when any dependencies are built, we have to
        ;; rely on the fact that `straight-use-package' runs this code
        ;; within a transaction.
        (straight--compute-dependencies package)
        ;; Before we (possibly) build the dependencies, we need to set
        ;; this flag so that we know if our progress message will need
        ;; to be redisplayed afterwards (before autoload generation
        ;; and byte-compilation).
        (setq straight--echo-area-dirty nil)
        ;; Yes, we do the following logic twice. Once here and again
        ;; in `straight-use-package'. Why? We need to do it here
        ;; because the dependencies need to be available before this
        ;; package can be byte-compiled. But the normal case is that
        ;; packages are already going to be built, so this code path
        ;; will not be hit and therefore autoloads will not be
        ;; generated for the dependencies in that situation if we
        ;; don't do it again in `straight-use-package'.
        (when-let ((dependencies (straight--get-dependencies package)))
          (dolist (dependency dependencies)
            ;; The implicit meaning of the first argument to
            ;; `straight-use-package' here is that the default recipes
            ;; (taken from one of the recipe repositories) are used
            ;; for dependencies. (Well, maybe. See all the weird edge
            ;; cases and exceptions in `straight--convert-recipe'.)
            ;;
            ;; Note that the second and third arguments are always
            ;; nil. This means that dependencies will always be
            ;; eagerly cloned and built, if we got to building this
            ;; package.
            (straight-use-package (intern dependency) nil nil task))
          ;; We might need to redisplay the progress message from
          ;; `straight--with-progress' up above.
          (when straight--echo-area-dirty
            (straight--progress-begin task)))
        (straight--generate-package-autoloads recipe)
        (straight--byte-compile-package recipe)
        ;; This won't get called if there is an error.
        (straight--finalize-build recipe))
      ;; We messed up the echo area.
      (setq straight--echo-area-dirty t))))

;;;; Loading packages

(defun straight--add-package-to-load-path (recipe)
  "Add the package specified by RECIPE to the `load-path'.
RECIPE is a straight.el-style plist. It is assumed that the
package has already been built."
  (straight--with-plist recipe
      (package)
    (add-to-list 'load-path (straight--dir "build" package))))

(defun straight--activate-package-autoloads (recipe)
  "Evaluate the autoloads for the package specified by RECIPE.
This means that the functions with autoload cookies in the
package are now autoloaded and calling them will `require' the
package. It is assumed that the package has already been built.

RECIPE is a straight.el-style plist."
  (straight--with-plist recipe
      (package)
    (let ((autoloads (straight--file
                      "build" package (straight--autoload-file-name package))))
      ;; If the autoloads file doesn't exist, don't throw an error. It
      ;; seems that in Emacs 26, an autoloads file is not actually
      ;; written if there are no autoloads to generate (although this
      ;; is unconfirmed), so this is especially important in that
      ;; case.
      (when (file-exists-p autoloads)
        (load autoloads nil 'nomessage)))))

;;;; Interactive helpers
;;;;; Package selection

(defun straight--select-package (message &optional for-build)
  "Use `completing-read' to select a package.
MESSAGE is displayed as the prompt; it should not end in
punctuation or whitespace. If FOR-BUILD is non-nil, then only
packages that have a nil `:no-build' property are considered."
  (completing-read
   (concat message ": ")
   (let ((packages ()))
     (maphash (lambda (package recipe)
                (unless (and for-build (plist-get recipe :no-build))
                  (push package packages)))
              straight--recipe-cache)
     packages)
   (lambda (_) t)
   'require-match))

;;;;; Bookkeeping

(defvar straight--success-cache (make-hash-table :test #'equal)
  "Hash table containing successfully built packages as keys.
The keys are package names as strings; the values are
meaningless, and all non-nil.")

(defvar straight--packages-to-rebuild nil
  "Hash table of packages for which to force a rebuild.
The keys are package names as strings; the values are
meaningless, and all non-nil. When not let-bound, this variable
is nil. When `straight-use-package' is invoked for any of these
packages, they will be rebuilt even if they have not changed. The
special value `:all' is equivalent to a list of all possible
packages. See also `straight-rebuild-package'.")

(defvar straight--packages-not-to-rebuild nil
  "Hash table of packages for which rebuild forcing does not apply.
The keys are package names as strings; the values are
meaningless, and all non-nil. When not let-bound, this variable
is nil. Any packages in this list are immune to the effects of
`straight--packages-to-rebuild', even if it is set to `:all'.
This is used to prevent building dependencies twice when
`straight-rebuild-package' or `straight-rebuild-all' is
invoked.")

(defun straight--get-versions ()
  "Read version lockfiles and return merged alist of saved versions.
The alist maps repository names as strings to versions, whose
interpretations are defined by the relevant VC backend."
  (let ((versions ()))
    (dolist (spec straight-profiles)
      (cl-destructuring-bind (_profile . versions-lockfile) spec
        (let ((lockfile-path (straight--file "versions" versions-lockfile)))
          (when-let ((versions-alist (ignore-errors
                                       (with-temp-buffer
                                         (insert-file-contents-literally
                                          lockfile-path)
                                         (read (current-buffer))))))
            (dolist (spec versions-alist)
              (cl-destructuring-bind (local-repo . commit) spec
                (setq versions (straight--alist-set
                                local-repo commit versions))))))))
    versions))

;;;;; Interactive mapping

(cl-defun straight--map-repos-interactively (func &optional predicate action)
  "Apply function FUNC for all local repositories, interactively.
FUNC is passed the name of one of the packages drawn from each
local repository, as a string. If FUNC throws an error or a quit
signal, the user is asked about what to do. They can choose to
skip the repository and come back to it later, cancel its
processing entirely, or halt the entire operation (skipping the
processing of all pending repositories). The return value of this
function is the list of recipes for repositories that were not
processed.

PREDICATE, if provided, is passed the package name as a string,
and should return a non-nil value to indicate that the package
should actually be processed.

ACTION is an optional string that describes the action being
performed on each repository, to be used for progress messages.
The default value is \"Processing\"."
  (let ((next-repos ())
        (skipped-repos ())
        (canceled-repos ()))
    (straight--map-repos
     (lambda (recipe)
       (push recipe next-repos)))
    (while t
      (cond
       (next-repos
        (let ((recipe (car next-repos)))
          (straight--with-plist recipe
              (package local-repo)
            (if (or (null predicate)
                    (funcall predicate package))
                (straight--with-progress
                    (format "%s repository %S"
                            (or action "Processing")
                            local-repo)
                  (cl-block loop
                    (while t
                      (straight-popup
                        (if-let ((err
                                  (condition-case-unless-debug e
                                      (progn
                                        (funcall func package)
                                        (setq next-repos (cdr next-repos))
                                        (cl-return-from loop))
                                    (error e)
                                    (quit nil))))
                            (format (concat "While processing repository %S, "
                                            "an error occurred:\n\n  %S")
                                    local-repo (error-message-string err))
                          (format (concat "Processing of repository %S paused "
                                          "at your request.")
                                  local-repo))
                        ("SPC" "Go back to processing this repository")
                        ("s" (concat "Skip this repository for now and "
                                     "come back to it later")
                         (push recipe skipped-repos)
                         (setq next-repos (cdr next-repos))
                         (cl-return-from loop))
                        ("c" (concat "Cancel processing of this "
                                     "repository; move on and do not "
                                     "come back to it later")
                         (push recipe canceled-repos)
                         (setq next-repos (cdr next-repos))
                         (cl-return-from loop))
                        ("e" "Dired and open recursive edit"
                         (dired (straight--dir "repos" local-repo))
                         (recursive-edit))
                        ("C-g" (concat "Stop immediately and do not process "
                                       "more repositories")
                         (keyboard-quit))))))
              (setq next-repos (cdr next-repos))))))
       (skipped-repos
        (setq next-repos skipped-repos)
        (setq skipped-repos ()))
       (t (cl-return-from straight--map-repos-interactively
            canceled-repos))))))

;;;; User-facing functions
;;;;; Recipe acquiry

;;;###autoload
(defun straight-get-recipe (&optional sources action)
  "Interactively select a recipe from one of the recipe repositories.
All recipe repositories in `straight-recipe-repositories' will
first be cloned. After the recipe is selected, it will be copied
to the kill ring. With a prefix argument, first prompt for a
recipe repository to search. Only that repository will be
cloned.

From Lisp code, SOURCES should be a subset of the symbols in
`straight-recipe-repositories'. Only those recipe repositories
are cloned and searched. If it is nil or omitted, then the value
of `straight-recipe-repositories' is used. ACTION may be
`copy' (copy recipe to the kill ring), `insert' (insert at
point), or nil (no action, just return it)."
  (interactive (list
                (when current-prefix-arg
                  (list
                   (intern
                    (completing-read
                     "Which recipe repository? "
                     straight-recipe-repositories
                     nil
                     'require-match))))
                'copy))
  (let ((sources (or sources straight-recipe-repositories)))
    (let* ((package (intern
                     (completing-read
                      "Which recipe? "
                      (straight-recipes-list sources)
                      (lambda (_) t)
                      'require-match)))
           ;; No need to provide a `cause' to
           ;; `straight-recipes-retrieve'; it should not be printing
           ;; any messages.
           (recipe (straight-recipes-retrieve package sources)))
      (unless recipe
        (user-error "Recipe for %S is malformed" package))
      (pcase action
        ('insert (insert (format "%S" recipe)))
        ('copy (kill-new (format "%S" recipe))
               (message "Copied \"%S\" to kill ring" recipe))
        (_ recipe)))))

;;;;; Package registration

;;;###autoload
(cl-defun straight-use-package
    (melpa-style-recipe &optional no-clone no-build cause interactive)
  "Register, clone, build, and activate a package and its dependencies.
This is the main entry point to the functionality of straight.el.

MELPA-STYLE-RECIPE is either a symbol naming a package, or a list
whose car is a symbol naming a package and whose cdr is a
property list containing e.g. `:type', `:local-repo', `:files',
and VC backend specific keywords.

First, the package recipe is registered with straight.el. If
NO-CLONE is a function, then it is called with two arguments: the
package name as a string, and a boolean value indicating whether
the local repository for the package is available. In that case,
the return value of the function is used as the value of NO-CLONE
instead. In any case, if NO-CLONE is non-nil, then processing
stops here.

Otherwise, the repository is cloned, if it is missing. If
NO-BUILD is a function, then it is called with one argument: the
package name as a string. In that case, the return value of the
function is used as the value of NO-BUILD instead. In any case,
if NO-BUILD is non-nil, then processing halts here. Otherwise,
the package is built and activated. Note that if the package
recipe has a non-nil `:no-build' entry, then NO-BUILD is ignored
and processing always stops before building and activation
occurs.

CAUSE is a string explaining the reason why
`straight-use-package' has been called. It is for internal use
only, and is used to construct progress messages. INTERACTIVE is
non-nil if the function has been called interactively. It is for
internal use only, and is used to determine whether to show a
hint about how to install the package permanently.

Return non-nil if package was actually installed, and nil
otherwise (this can only happen if NO-CLONE is non-nil)."
  (interactive (list (straight-get-recipe) nil nil nil 'interactive))
  (straight-transaction
    ;; If `straight--convert-recipe' returns nil, the package is
    ;; built-in. No need to go any further.
    (if-let ((recipe (straight--convert-recipe
                      (or
                       (straight--get-overridden-recipe
                        (if (listp melpa-style-recipe)
                            (car melpa-style-recipe)
                          melpa-style-recipe))
                       melpa-style-recipe)
                      cause)))
        (straight--with-plist recipe
            (package local-repo)
          (unless local-repo
            (cl-return-from straight-use-package nil))
          ;; We need to register the recipe before building the
          ;; package, since the ability of `straight--convert-recipe'
          ;; to deal properly with dependencies versioned in the same
          ;; repository of their parent package will break unless the
          ;; caches are updated before we recur to the dependencies.
          ;;
          ;; Furthermore, we need to register it before executing the
          ;; transaction block, since otherwise conflicts between
          ;; recipes cannot be detected (the transaction block will
          ;; only be run once for any given package in a transaction).
          (straight--register-recipe recipe)
          (straight--transaction-exec
           (intern (format "use-package-%s" package))
           (lambda ()
             (let (;; Check if the package has been successfully
                   ;; built. If not, and this is an interactive call,
                   ;; we'll want to display a helpful hint message
                   ;; (see below). We have to check this here, before
                   ;; the package is actually built.
                   (already-registered
                    (gethash package straight--success-cache))
                   (available
                    (straight--repository-is-available-p recipe)))
               ;; Possibly abort based on NO-CLONE.
               (when (if (straight--functionp no-clone)
                         (funcall no-clone package available)
                       no-clone)
                 (cl-return-from straight-use-package nil))
               ;; If we didn't abort, ensure the repository is cloned.
               (unless available
                 ;; We didn't decide to abort, and the repository
                 ;; still isn't available. Make it available.
                 (straight--clone-repository recipe cause))
               ;; Possibly abort based on NO-BUILD.
               (when (or
                      ;; Remember that `no-build' can come both from
                      ;; the arguments to `straight-use-package' and
                      ;; from the actual recipe.
                      (plist-get recipe :no-build)
                      (if (straight--functionp no-build)
                          (funcall no-build package)
                        no-build))
                 (cl-return-from straight-use-package nil))
               ;; Multi-file packages will need to be on the
               ;; `load-path' in order to byte-compile properly.
               (straight--add-package-to-load-path recipe)
               (straight--transaction-exec
                'build-cache
                #'straight--load-build-cache
                #'straight--save-build-cache)
               (when (or
                      ;; This clause provides support for
                      ;; `straight-rebuild-package' and
                      ;; `straight-rebuild-all'.
                      (and
                       straight--packages-to-rebuild
                       (or (eq straight--packages-to-rebuild :all)
                           (gethash package straight--packages-to-rebuild))
                       (not (gethash
                             package straight--packages-not-to-rebuild))
                       ;; The following form returns non-nil, so it
                       ;; doesn't affect the `and' logic.
                       (puthash package t straight--packages-not-to-rebuild))
                      (straight--package-might-be-modified-p recipe))
                 (straight--build-package recipe cause))
               ;; Here we are not actually trying to build the
               ;; dependencies, but activate their autoloads. (See the
               ;; comment in `straight--build-package' about this
               ;; code.)
               (dolist (dependency (straight--get-dependencies package))
                 ;; There are three interesting things here. Firstly,
                 ;; the recipe used is just the name of the
                 ;; dependency. This causes the default recipe to be
                 ;; looked up, unless one of the special cases in
                 ;; `straight--convert-recipe' pops up. Secondly, the
                 ;; values of NO-BUILD and NO-CLONE are always nil. If
                 ;; the user has agreed to clone and build a package,
                 ;; we assume that they also want to clone and build
                 ;; all of its dependencies. Finally, we don't bother
                 ;; to update `cause', since we're not expecting any
                 ;; messages to be displayed here (all of the
                 ;; dependencies should have already been cloned [if
                 ;; necessary] and built back by
                 ;; `straight--build-package').
                 (straight-use-package (intern dependency) nil nil cause))
               ;; Only make the package available after everything is
               ;; kosher.
               (straight--activate-package-autoloads recipe)
               ;; In interactive use, tell the user how to install
               ;; packages permanently.
               (when (and interactive (not already-registered))
                 (message
                  (concat "If you want to keep %s, put "
                          "(straight-use-package %s%S) "
                          "in your init-file.")
                  package "'" (intern package)))
               ;; The package was installed successfully.
               (puthash package t straight--success-cache)
               t)))
          ;; Return non-nil for built-in packages.
          t))))

;;;###autoload
(defun straight-register-package (melpa-style-recipe)
  "Register a package without cloning, building, or activating it.
This function is equivalent to calling `straight-use-package'
with a non-nil argument for NO-CLONE. It is provided for
convenience. MELPA-STYLE-RECIPE is as for
`straight-use-package'."
  (straight-use-package melpa-style-recipe 'no-clone))

;;;###autoload
(defun straight-use-package-no-build (melpa-style-recipe)
  "Register and clone a package without building it.
This function is equivalent to calling `straight-use-package'
with nil for NO-CLONE but a non-nil argument for NO-BUILD. It is
provided for convenience. MELPA-STYLE-RECIPE is as for
`straight-use-package'."
  (straight-use-package melpa-style-recipe nil 'no-build))

;;;###autoload
(defun straight-use-package-lazy (melpa-style-recipe)
  "Register, build, and activate a package if it is already cloned.
This function is equivalent to calling `straight-use-package'
with symbol `lazy' for NO-CLONE. It is provided for convenience.
MELPA-STYLE-RECIPE is as for `straight-use-package'."
  (straight-use-package
   melpa-style-recipe
   ;; Don't clone the package if it's not available.
   (lambda (_package available)
     (not available))))

;;;###autoload
(defun straight-use-recipes (melpa-style-recipe)
  "Register a recipe repository using MELPA-STYLE-RECIPE.
This registers the recipe and builds it if it is already cloned.
Note that you probably want the recipe for a recipe repository to
include a non-nil `:no-build' property, to unconditionally
inhibit the build phase.

This function also adds the recipe repository to
`straight-recipe-repositories', at the end of the list."
  (straight-use-package-lazy melpa-style-recipe)
  (add-to-list 'straight-recipe-repositories
               (if (listp melpa-style-recipe)
                   (car melpa-style-recipe)
                 melpa-style-recipe)
               'append))

;;;;; Recipe overrides

;;;###autoload
(defun straight-override-recipe (melpa-style-recipe)
  "Register MELPA-STYLE-RECIPE as a recipe override.
This puts it in `straight-recipe-overrides', depending on the
value of `straight-current-profile'."
  (setf (alist-get
         (car melpa-style-recipe)
         (alist-get straight-current-profile straight-recipe-overrides))
        (cdr melpa-style-recipe)))

;;;;; Rebuilding packages

;;;###autoload
(defun straight-check-package (package)
  "Rebuild a PACKAGE if it has been modified.
PACKAGE is a string naming a package. Interactively, select
PACKAGE from the known packages in the current Emacs session
using `completing-read'. See also `straight-rebuild-package' and
`straight-check-all'."
  (interactive (list (straight--select-package "Check package" 'for-build)))
  (straight-use-package (intern package)))

;;;###autoload
(defun straight-check-all ()
  "Rebuild any packages that have been modified.
See also `straight-rebuild-all' and `straight-check-package'.
This function should not be called during init."
  (interactive)
  (straight-transaction
    (dolist (package (hash-table-keys straight--recipe-cache))
      (straight-use-package (intern package)))))

;;;###autoload
(defun straight-rebuild-package (package &optional recursive)
  "Rebuild a PACKAGE.
PACKAGE is a string naming a package. Interactively, select
PACKAGE from the known packages in the current Emacs session
using `completing-read'. With prefix argument RECURSIVE, rebuild
all dependencies as well. See also `straight-check-package' and
`straight-rebuild-all'."
  (interactive
   (list
    (straight--select-package "Rebuild package" 'for-build)
    current-prefix-arg))
  (let ((straight--packages-to-rebuild
         (if recursive
             :all
           (let ((table (make-hash-table :test #'equal)))
             (puthash package t table)
             table)))
        ;; Because we bind this here, the table will be deleted and
        ;; the variable reset to nil when we break out of the let. No
        ;; need to clear the hash explicitly.
        (straight--packages-not-to-rebuild
         (make-hash-table :test #'equal)))
    (straight-use-package (intern package))))

;;;###autoload
(defun straight-rebuild-all ()
  "Rebuild all packages.
See also `straight-check-all' and `straight-rebuild-package'."
  (interactive)
  (let ((straight--packages-to-rebuild :all)
        (straight--packages-not-to-rebuild
         (make-hash-table :test #'equal)))
    (straight-transaction
      (dolist (package (hash-table-keys straight--recipe-cache))
        (straight-use-package (intern package))))))

;;;;; Cleanup

;;;###autoload
(defun straight-prune-build ()
  "Prune the build cache and build directory.
This means that only packages that were built in the last init
run and subsequent interactive session will remain; other
packages will have their build mtime information discarded and
their build directory deleted."
  (interactive)
  (straight-transaction
    (straight--transaction-exec
     'build-cache
     #'straight--load-build-cache
     #'straight--save-build-cache)
    (dolist (package (hash-table-keys straight--build-cache))
      (unless (gethash package straight--profile-cache)
        (remhash package straight--build-cache)))
    (dolist (package (directory-files
                      (straight--dir "build")
                      nil nil 'nosort))
      ;; So, let me tell you a funny story. Once upon a time I didn't
      ;; have this `string-match-p' condition. But Emacs helpfully
      ;; returns . and .. from the call to `list-directory', resulting
      ;; in the entire build directory and its parent directory also
      ;; being deleted. Fun fun fun.
      (unless (or (string-match-p "^\\.\\.?$" package)
                  (gethash package straight--profile-cache))
        (delete-directory (straight--dir "build" package) 'recursive)))))

;;;;; Normalization, pushing, pulling

;;;###autoload
(defun straight-normalize-package (package)
  "Normalize a PACKAGE's local repository to its recipe's configuration.
PACKAGE is a string naming a package. Interactively, select
PACKAGE from the known packages in the current Emacs session
using `completing-read'."
  (interactive (list (straight--select-package "Normalize package")))
  (let ((recipe (gethash package straight--recipe-cache)))
    (straight-vc-normalize recipe)))

;;;###autoload
(defun straight-normalize-all (&optional predicate)
  "Normalize all packages. See `straight-normalize-package'.
Return a list of recipes for packages that were not successfully
normalized. If multiple packages come from the same local
repository, only one is normalized.

PREDICATE, if provided, filters the packages that are normalized.
It is called with the package name as a string, and should return
non-nil if the package should actually be normalized."
  (interactive)
  (straight--map-repos-interactively #'straight-normalize-package
                                     predicate))

;;;###autoload
(defun straight-pull-package (package &optional from-upstream)
  "Try to pull a PACKAGE from the primary remote.
PACKAGE is a string naming a package. Interactively, select
PACKAGE from the known packages in the current Emacs session
using `completing-read'. With prefix argument FROM-UPSTREAM, pull
not just from primary remote but also from configured upstream."
  (interactive (list (straight--select-package "Pull package")
                     current-prefix-arg))
  (let ((recipe (gethash package straight--recipe-cache)))
    (and (straight-vc-pull-from-remote recipe)
         (when from-upstream
           (straight-vc-pull-from-upstream recipe)))))

;;;###autoload
(defun straight-pull-all (&optional from-upstream predicate)
  "Try to pull all packages from their primary remotes.
With prefix argument FROM-UPSTREAM, pull not just from primary
remotes but also from configured upstreams.

Return a list of recipes for packages that were not successfully
pulled. If multiple packages come from the same local repository,
only one is pulled.

PREDICATE, if provided, filters the packages that are normalized.
It is called with the package name as a string, and should return
non-nil if the package should actually be normalized."
  (interactive "P")
  (straight--map-repos-interactively
   (lambda (package)
     (straight-pull-package package from-upstream))
   predicate))

;;;###autoload
(defun straight-push-package (package)
  "Push a PACKAGE to its primary remote, if necessary.
PACKAGE is a string naming a package. Interactively, select
PACKAGE from the known packages in the current Emacs session
using `completing-read'."
  (interactive (list (straight--select-package "Push package")))
  (let ((recipe (gethash package straight--recipe-cache)))
    (straight-vc-push-to-remote recipe)))

;;;###autoload
(defun straight-push-all (&optional predicate)
  "Try to push all packages to their primary remotes.

Return a list of recipes for packages that were not successfully
pushed. If multiple packages come from the same local repository,
only one is pushed.

PREDICATE, if provided, filters the packages that are normalized.
It is called with the package name as a string, and should return
non-nil if the package should actually be normalized."
  (interactive)
  (straight--map-repos-interactively #'straight-push-package
                                     predicate))

;;;;; Lockfile management

(cl-defun straight--ensure-profile-cache-valid ()
  "Ensure that `straight--profile-cache' reflects the init-file correctly.
If not, prompt the user to reload the init-file in a transaction."
  (when straight--profile-cache-valid
    (cl-return-from straight--ensure-profile-cache-valid t))
  (unless (y-or-n-p "Caches are outdated, reload init-file? ")
    (cl-return-from straight--ensure-profile-cache-valid nil))
  (straight-transaction
    (straight-mark-transaction-as-init)
    (message "Reloading %S..." user-init-file)
    (load user-init-file nil 'nomessage)
    (message "Reloading %S...done" user-init-file))
  (when straight--profile-cache-valid
    (cl-return-from straight--ensure-profile-cache-valid t))
  (error "Caches are still outdated; something is seriously wrong"))

;;;###autoload
(defun straight-freeze-versions (&optional force)
  "Write version lockfiles for currently activated packages.
This implies first pushing all packages that have unpushed local
changes. If the package management system has been used since the
last time the init-file was reloaded, offer to fix the situation
by reloading the init-file again. If FORCE is
non-nil (interactively, if a prefix argument is provided), skip
all checks and write the lockfile anyway.

Multiple lockfiles may be written (one for each profile),
according to the value of `straight-profiles'."
  (interactive "P")
  (when (or force
            (progn
              (straight--ensure-profile-cache-valid)
              (let ((unpushed-recipes
                     (straight-push-all
                      (lambda (package)
                        (straight--repository-is-available-p
                         (gethash package straight--recipe-cache))))))
                (or
                 (null unpushed-recipes)
                 (straight-are-you-sure
                  (format (concat "The following packages were not pushed:"
                                  "\n\n  %s\n\nReally write lockfiles?")
                          (string-join
                           (mapcar (lambda (recipe)
                                     (plist-get recipe :local-repo))
                                   unpushed-recipes)
                           ", ")))))))
    (let ((versions-alist (straight--get-versions)))
      (straight--map-repos
       (lambda (recipe)
         (straight--with-plist recipe
             (local-repo package)
           (unless (or (assoc local-repo versions-alist)
                       (straight--repository-is-available-p recipe))
             (straight-use-package package))))))
    (dolist (spec straight-profiles)
      (cl-destructuring-bind (profile . versions-lockfile) spec
        (let ((versions-alist nil)
              (lockfile-directory (straight--dir "versions"))
              (lockfile-path (straight--file "versions" versions-lockfile)))
          (straight--map-repos
           (lambda (recipe)
             (straight--with-plist recipe
                 (package local-repo type)
               (when (memq profile (gethash package straight--profile-cache))
                 (push (cons local-repo
                             (or (cdr (assoc local-repo versions-alist))
                                 (straight-vc-get-commit type local-repo)))
                       versions-alist)))))
          (setq versions-alist
                (cl-sort versions-alist #'string-lessp :key #'car))
          (make-directory lockfile-directory 'parents)
          (with-temp-file lockfile-path
            (insert
             (format
              ;; When the recipe format is updated, this version
              ;; keyword will be updated. It tells install.el which
              ;; version of straight.el to use to interpret the recipe
              ;; that must be used to clone straight.el itself. I'm
              ;; using planets in the Solar System, for diversity (and
              ;; because using consecutive integers would make it
              ;; confusing when somebody else made a fork of the
              ;; project and needed to fork the version sequence as
              ;; well).
              ;;
              ;; The version keyword comes after the versions alist so
              ;; that you can ignore it if you don't need it.
              "(%s)\n:venus\n"
              (mapconcat
               (apply-partially #'format "%S")
               versions-alist
               "\n "))))
          (message "Wrote %s" lockfile-path))))))

;;;###autoload
(defun straight-thaw-versions ()
  "Read version lockfiles and restore package versions to those listed."
  (interactive)
  (let ((versions-alist (straight--get-versions)))
    (straight--map-repos-interactively
     (lambda (package)
       (let ((recipe (gethash package straight--recipe-cache)))
         (when (straight--repository-is-available-p recipe)
           (straight--with-plist recipe
               (type local-repo)
             ;; We can't use `alist-get' here because that uses
             ;; `eq', and our hash-table keys are strings.
             (when-let ((commit (cdr (assoc local-repo versions-alist))))
               (straight-vc-check-out-commit
                type local-repo commit)))))))))

;;;; package.el "integration"

(when straight-enable-package-integration

  ;; Don't load package.el after init finishes.
  (setq package-enable-at-startup nil)

  ;; Prevent package.el from modifying the init-file.
  (eval-and-compile
    (defalias 'straight--advice-neuter-package-ensure-init-file #'ignore
      "Prevent package.el from modifying the init-file.
This is an `:override' advice for `package--ensure-init-file'.")
    (defun straight--package-save-selected-packages (&optional value)
      "Set and save `package-selected-packages' to VALUE.
But don't mess with the init-file."
      (when value
        (setq package-selected-packages value)))
    (defalias 'straight--advice-neuter-package-save-selected-packages
      #'straight--package-save-selected-packages
      "Prevent package.el from modifying the init-file.
This is an `:override' advice for
`package--save-selected-packages'."))
  (advice-add #'package--ensure-init-file :override
              #'straight--advice-neuter-package-ensure-init-file)
  (advice-add #'package--save-selected-packages :override
              #'straight--advice-neuter-package-save-selected-packages))

;;;; use-package integration

(when straight-enable-use-package-integration

  (with-eval-after-load 'use-package

    ;; Make it so that `:ensure' uses `straight-use-package' instead of
    ;; `package-install'.
    (eval-and-compile
      (defun straight-use-package-ensure-function
          (name ensure state context &optional only-if-installed)
        "Value for `use-package-ensure-function' that uses straight.el.
The meanings of args NAME, ENSURE, STATE, CONTEXT are the same as
in `use-package-ensure-function' (which see). ONLY-IF-INSTALLED
is a nonstandard argument that indicates the package should use
lazy installation."
        (when ensure
          (let ((recipe (or (and (not (eq ensure t)) ensure)
                            (plist-get state :recipe)
                            name)))
            (straight-use-package
             recipe
             (lambda (package available)
               (cond
                ;; If available, go ahead.
                (available nil)
                ;; When doing lazy installation, don't clone if not
                ;; available.
                (only-if-installed t)
                ;; In cases where installation should be automatic, do
                ;; it.
                ((memq context '(:byte-compile :ensure
                                 :config :pre-ensure
                                 :interactive))
                 nil)
                ;; Otherwise, prompt the user.
                (t
                 ;; Value of NO-CLONE has a meaning that is the
                 ;; opposite of ONLY-IF-INSTALLED.
                 (not
                  (y-or-n-p
                   (format "Install package %S? " package))))))))))

      (defun straight-use-package-pre-ensure-function
          (name ensure state)
        "Value for `use-package-pre-ensure-function' that uses straight.el.
The meanings of args NAME, ENSURE, STATE are the same as in
`use-package-pre-ensure-function'."
        (straight-use-package-ensure-function
         name ensure state :pre-ensure 'only-if-installed)))

    ;; Set the package management functions.
    (setq use-package-ensure-function
          #'straight-use-package-ensure-function)
    (setq use-package-pre-ensure-function
          #'straight-use-package-pre-ensure-function)

    ;; Register aliases for :ensure. Aliases later in the list will
    ;; override those earlier. (But there is no legitimate reason to
    ;; use more than one in a `use-package' declaration, at least in
    ;; sane situations.) The reason we also handle `:ensure' is
    ;; because the default value of `use-package-normalize/:ensure' is
    ;; not flexible enough to handle recipes like we need it to.
    (dolist (keyword '(:recipe :ensure))

      ;; Insert the keyword just before `:ensure'.
      (unless (member keyword use-package-keywords)
        (setq use-package-keywords
              (let* ((pos (cl-position :ensure use-package-keywords))
                     (head (cl-subseq use-package-keywords 0 pos))
                     (tail (cl-subseq use-package-keywords pos)))
                (append head (list keyword) tail))))

      ;; Define the normalizer for the keyword.
      (eval
       `(defun ,(intern (format "use-package-normalize/%S" keyword))
            (name-symbol keyword args)
          (use-package-only-one (symbol-name keyword) args
            (lambda (label arg)
              (if (keywordp (car-safe arg))
                  (cons name-symbol arg)
                arg)))))

      ;; Define the handler. We don't need to do this for `:ensure'.
      (unless (eq keyword :ensure)
        (eval
         `(defun ,(intern (format "use-package-handler/%S" keyword))
              (name keyword recipe rest state)
            (use-package-process-keywords
              name rest (plist-put state :recipe recipe))))))))

;;;; Closing remarks

(provide 'straight)

;;; straight.el ends here

;; Local Variables:
;; checkdoc-symbol-words: ("top-level")
;; outline-regexp: ";;;;* "
;; End:
