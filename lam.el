;;; lam.el --- llm-agent-mode  -*- lexical-binding: t -*-

;;; Commentary:

;; Copyright (C) 2025
;; Author: Lin Min <mavenlin@gmail.com>
;; Keywords: llm, ai, lam, streaming
;; Version: 1.0.0
;; Package-Requires: ((emacs "29.1"))

(require 'comint)
(require 'pp)
(require 'polymode)
(require 'json)
(require 'markdown-mode)

;;; Code:
;;; Configurable Variables

(defvar lam-base-url nil
  "Base URL for the LLM API endpoint.
This should be the root URL without trailing slash. The `/chat/completions'
endpoint will be appended automatically.")

(defvar lam-key nil
  "API key for authentication with the LLM service.
This key is used in the Authorization header for API requests.
Ensure this key has appropriate permissions for chat completions.")

(defvar lam-model nil
  "Model identifier to use for LLM requests.
This should be a valid model name supported by the configured API endpoint.")

(defvar lam--system-message "You're the best agent in the world because you have access to emacs.
You can generate emacs-lisp in backtick code blocks and annotate it with 'emacs-lisp', and it will gets executed and the result will be returned to you.
Generate only one code block at a time."
  "Buffer-local variable to store context information.")

;;; Process and marker utilities

(defvar-local lam-process nil
  "The process associated with the current lam buffer.")

;;; The function to make requests to a openai compatible api end point via curl

(defun lam-stream-request (messages filter sentinel &optional prefix)
  "Make a streaming chat completion request to the configured LLM API.
MESSAGES should be a list of message objects for the chat completion.
FILTER is a function called with process and output string for handling
streaming data.
SENTINEL is a function called when the process changes state (e.g., finishes).
PREFIX is an optional string to prepend as an assistant message.

The function constructs a curl command to make a streaming POST request
to the API endpoint. Response data is processed in real-time through
the provided FILTER function.

Logs request details to the *lam-log* buffer for debugging.

Returns the process object created by `make-process'.

Signals an error if `lam-key' is not configured."
  (interactive)
  ;; Validate required configuration
  (unless lam-key
    (error "API key is not set. Please set the variable `lam-key`"))

  ;; Prepare request parameters
  (let* ((model lam-model)
         ;; Add prefix as assistant message if provided
         (messages (if prefix
                       (add-to-list 'messages (lam--create-message "assistant" prefix) t)
                     messages))
         ;; Construct API endpoint URL
         (url (concat (string-trim-right lam-base-url "/") "/chat/completions"))
         ;; Encode request payload as JSON
         (data (json-encode
                `((:model . ,model)
                  (:messages . ,messages)
                  (:stream . t))))
         ;; Build curl command arguments
         (curl-args `("-N"  ; Disable buffering for streaming
                      "-H" ,(format "Content-Type: %s" "application/json")
                      "-H" ,(format "Authorization: Bearer %s" lam-key)
                      "-d" ,data
                      ,url)))

    ;; Log request details for debugging
    (let ((log-buffer (get-buffer-create "*lam-log*")))
      (with-current-buffer log-buffer
        (goto-char (point-max))
        (insert (format "\n[%s] Request to %s with model %s\nData: %s\n"
                        (current-time-string) url model data))))

    ;; Start the streaming process
    (make-process
     :name "lam-curl"
     :command (cons "curl" curl-args)
     :buffer nil
     :filter filter
     :sentinel sentinel)))


;;; local variables to store context of the user/llm/emacs interaction session
(defvar-local lam--context nil
  "Buffer-local variable to store context information.")
(defvar-local lam--curr-branch 0
  "Buffer-local variable to store context information.")
(defvar-local lam--curr-id 0
  "Id of message.")

;; Functions to manage the chat history
(defun lam--create-message (role content)
  "Create a message object with ROLE and CONTENT."
  (list
   (cons :role role)
   (cons :content content)))

(defun lam--create-entry (id role content step branch &optional prefix)
  "Create a context entry.
With ID, ROLE, CONTENT, STEP, BRANCH and optional PREFIX."
  (let ((entry (list :id id
                     :role role
                     :content content
                     :step step
                     :branch branch)))
    (if prefix
        (plist-put entry :prefix prefix)
      entry)))

(defun lam--context-push (role content &optional prefix)
  "Push a new context entry.
with ROLE and CONTENT onto the context, optionally with PREFIX."
  (let ((step (length lam--context))
        (branch lam--curr-branch)
        (id lam--curr-id))
    (add-to-list 'lam--context (lam--create-entry id role content step branch prefix) t)
    (setq lam--curr-id (1+ lam--curr-id))))

(defun lam--context-kill-from (step)
  "Create a new branch from the current context at STEP."
  (setq lam--curr-branch (1+ lam--curr-branch))
  (setq lam--context (seq-subseq lam--context 0 step)))

(defun lam--messages ()
  "Convert the current context to a list of message objects."
  ;; for all entries in lam--context, create a list of messages
  (let ((messages (list (lam--create-message "system" lam--system-message))))
    (append messages (mapcar (lambda (entry)
                               (let* ((raw-role (plist-get entry :role))
                                      (role (if (string= raw-role "llm") "assistant" "user"))
                                      (content (plist-get entry :content)))
                                 (lam--create-message role content)))
                             lam--context))))

;; lam-base-mode
;; Adoped from ielm-mode originally written by
;; David Smith <maa036@lancaster.ac.uk>

(defgroup lam nil
  "Interaction mode for Emacs Lisp."
  :group 'lisp)

(defcustom lam-prompt-read-only t
  "If non-nil, the lam prompt is read only."
  :type 'boolean
  :version "22.1")

(defcustom lam-prompt "> "
  "Prompt used in lam."
  :type 'string)

(defvar lam-prompt-internal "> "
  "Stored value of `lam-prompt' in the current buffer.")

(defcustom lam-history-file-name
  (locate-user-emacs-file "lam-history.eld")
  "If non-nil, name of the file to read/write IELM input history."
  :type '(choice (const :tag "Disable input history" nil)
          file)
  :version "30.1")

(defcustom lam-base-mode-hook nil
  "Hooks to be run when `lam-base-mode' is started."
  :type 'hook)


(defvar lam-header
  "*** Welcome to llm-agent-mode (lam) ***\n"
  "Message to display when Lam is started.")

(defvaralias 'lam-base-mode-map 'lam-map)
(defvar-keymap lam-map
  :doc "Keymap for IELM mode."
  "RET"     #'lam-return
  "C-j"     #'lam-send-input
  "DEL"     #'backward-delete-char-untabify)

(defvar lam-font-lock-keywords
  '(("\\(^─── [0-9]+: .+ ───$\\)"
     (1 font-lock-keyword-face))
    ("\\(^───$\\)"
     (1 font-lock-comment-face)))
  "Additional expressions to highlight in lam buffers.")

(defun lam-complete-filename nil
  "Dynamically complete filename before point, if in a string."
  (when (nth 3 (parse-partial-sexp comint-last-input-start (point)))
    (comint-filename-completion)))

(defun lam-return ()
  "Create a newline."
  (interactive)
  (newline))

(defvar lam-input)

(defun lam-input-sender (_proc input)
  "Function to send INPUT to llm-agent-mode."
  ;; Just sets the variable lam-input, which is in the scope of
  ;; `lam-send-input's call.
  (setq lam-input input))

(defun lam-send-input ()
  "Evaluate the Emacs Lisp expression after the prompt."
  (interactive)
  (let (lam-input)                     ; set by lam-input-sender
    (comint-send-input)                 ; update history, markers etc.
    (lam-eval-input lam-input)))

;;; Evaluation

(defun lam-standard-output-impl (process)
  "Return a function to use for `standard-output' while in lam eval.
PROCESS is the process to which output should be sent
The returned function takes one character as input.  Passing nil
to this function instead of a character flushes the output
buffer.  Passing t appends a terminating newline if the buffer is
nonempty, then flushes the buffer."
  ;; Use an intermediate output buffer because doing redisplay for
  ;; each character we output is too expensive.  Set up a flush timer
  ;; so that users don't have to wait for whole lines to appear before
  ;; seeing output.
  (let* ((output-buffer nil)
         (flush-timer nil)
         (flush-buffer
          (lambda ()
            (comint-output-filter
             process
             (apply #'string (nreverse output-buffer)))
            (redisplay)
            (setf output-buffer nil)
            (when flush-timer
              (cancel-timer flush-timer)
              (setf flush-timer nil)))))
    (lambda (char)
      (let (flush-now)
        (cond ((and (eq char t) output-buffer)
               (push ?\n output-buffer)
               (setf flush-now t))
              ((characterp char)
               (push char output-buffer)))
        (if flush-now
            (funcall flush-buffer)
          (unless flush-timer
            (setf flush-timer (run-with-timer 0.1 nil flush-buffer))))))))


(defvar-local lam-active-worker nil
  "The process associated with the current lam eval.")

(defun lam-llm-request-filter (stream proc string)
  "Process the streaming output from the `curl` process.
STREAM is the buffer to use as stdout.
PROC is the process producing the output.
STRING is the new output data.
This function is called by Emacs whenever new data is available."
  ;; Add the new string data to our partial data buffer
  (when (string-prefix-p "data: " string)
    (let* ((json-string (substring string 6))
           (data (condition-case nil
                     (json-read-from-string json-string)
                   (error nil))))
      (when data
        (when (assoc 'choices data)
          (let* ((choices (cdr (assoc 'choices data)))
                 (choice (aref choices 0))
                 (delta (cdr (assoc 'delta choice)))
                 (content (cdr (assoc 'content delta))))
            (when content
              (princ content stream))))))))

;; callback function
(defun lam-llm-request-sentinel (buffer stream beg prefix proc event)
  "Handle end of llm request process.
BUFFER is the buffer associated with llm-agent-mode.
STREAM is the buffer to use as stdout.
BEG is the position in BUFFER where the llm response started.
PREFIX is an optional string to prepend as an assistant message.
PROC is the process producing the output.
EVENT is a string describing the end of process state."
  (with-current-buffer buffer
    (if (string= event "finished\n")
        ;; normal exit
        (progn
          (princ "\n───" stream)
          (funcall stream t)
          ;; get text from beg to current pm, and add to context
          (let* ((end (marker-position (lam-pm)))
                 (content (buffer-substring-no-properties beg (- end 5))))
            (lam--context-push "llm" content prefix))
          (comint-output-filter (get-buffer-process buffer) lam-prompt-internal))
      ;; otherwise an error occurred
      ;; clean up the head and report error
      (progn
        ;; flush any remaining output
        (funcall stream t)
        ;; delete the current incomplete step
        (save-excursion
          (goto-char (point-max))
          (let ((beg
                 (if (re-search-backward "^───$" nil t)
                     (progn
                       (forward-line 1)
                       (point))
                   (if (re-search-backward "^─── [0-9]+:" nil t)
                       (point) nil))))
            (let ((inhibit-read-only t))
              (delete-region beg (point-max)))
            (lam-set-pm (point-max))))
        (message "LLM request error: %s" event)
        (comint-output-filter (get-buffer-process buffer) lam-prompt-internal)))))

(defun lam-parse-fenced-code-blocks (text)
  "Parse TEXT and return a list of (type content) pairs for each fenced code block.
Handles indented code blocks by preserving relative indentation within blocks."
  (let ((result '())
        (lines (split-string text "\n" t))
        (in-block nil)
        (block-type nil)
        (block-content '())
        (block-indent nil))

    (dolist (line lines)
      (cond
       ;; Starting a fenced code block
       ((and (not in-block)
             (string-match "^\\([ \t]*\\)```\\(.*\\)$" line))
        (setq in-block t
              block-indent (match-string 1 line)
              block-type (string-trim (match-string 2 line))
              block-content '())
        ;; If no language specified, use empty string
        (when (string-empty-p block-type)
          (setq block-type "")))

       ;; Ending a fenced code block
       ((and in-block
             (string-match (concat "^" (regexp-quote block-indent) "```\\s-*$") line))
        (setq in-block nil)
        (push (list block-type (string-join (reverse block-content) "\n")) result)
        (setq block-type nil
              block-content '()
              block-indent nil))

       ;; Inside a fenced code block
       (in-block
        (let ((content-line line))
          ;; Remove the block's base indentation if present
          (when (and block-indent (not (string-empty-p block-indent)))
            (if (string-prefix-p block-indent line)
                (setq content-line (substring line (length block-indent)))
              ;; If line has less indentation than expected, keep as-is
              (setq content-line line)))
          (push content-line block-content)))))

    ;; Handle unclosed block
    (when in-block
      (push (list block-type (string-join (reverse block-content) "\n")) result))

    (reverse result)))


(defun lam-eval-and-capture (code-string)
  "Evaluate CODE-STRING and capture any error and its backtrace."
  (let ((result nil)
        (error-message nil)
        (backtrace nil))
    (condition-case err
        (setq result (eval (car (read-from-string code-string))))
      (error
       (setq error-message (prin1-to-string err))
       (let ((backtrace-output (with-temp-buffer
                                 (backtrace)
                                 (buffer-string))))
         (setq backtrace backtrace-output))))
    (list :result result
          :error error-message
          :backtrace backtrace)))


(defun lam-proceed (base-buffer stream &optional prefix)
  "Proceed to the next step in the interaction.
BASE-BUFFER is the buffer associated with llm-agent-mode.
STREAM is the object to use as stdout.
PREFIX is an optional string to append as an assistant message."
  (with-current-buffer base-buffer
    (let ((role (plist-get (car (last lam--context)) :role))
          (ret-value nil))
      (if (string= role "llm")
          ;; extract the code block from the content
          (let* ((content (plist-get (car (last lam--context)) :content))
                 (results (lam-parse-fenced-code-blocks content))
                 (last-block (car (last results)))
                 (code-type (car last-block))
                 (code-content (cadr last-block)))
            (when (or (string= code-type "emacs-lisp") (string= code-type "elisp"))
              ;; The following code could have changed the current buffer.
              ;; because we don't know what the llm could be writing in the code-content.
              ;; therefore we need switch back to the original buffer.
              (setq ret-value
                    (lam-eval-and-capture code-content))

              (with-current-buffer base-buffer
                (let ((to-print (prin1-to-string ret-value)))
                  (princ (format "─── %s: emacs ───" (length lam--context)) stream)
                  (funcall stream t)
                  (princ to-print stream)
                  (princ "\n───" stream)
                  (funcall stream t)
                  (lam--context-push "emacs" to-print)
                  (lam-proceed base-buffer stream)))))
        ;; else the previous step is not llm, we should send things to llm
        (progn
          (princ (format "─── %s: llm ───" (length lam--context)) stream)
          (funcall stream t)
          (let* ((messages (lam--messages))
                 (beg (marker-position (lam-pm)))
                 (filter (lambda (proc event) (lam-llm-request-filter stream proc event)))
                 (sentinel (lambda (proc event) (lam-llm-request-sentinel base-buffer stream beg prefix proc event))))
            (when prefix
              (princ prefix stream))
            (when (process-live-p lam-active-worker)
              (kill-process lam-active-worker))
            (setq lam-active-worker
                  (lam-stream-request messages filter sentinel prefix))))))))


(defun lam-eval-input (input-string)
  "Evaluate INPUT-STRING in the context of llm-agent-mode."
  (let ((stream (lam-standard-output-impl lam-process))
        (input-string (substring-no-properties input-string)))
    (when (not (string= input-string ""))
      (let* ((head (format "─── %s: user ───\n" (length lam--context)))
             (tail "\n───\n"))
        (princ (concat head input-string tail) stream))
      (lam--context-push "user" input-string))
    (let ((buffer (pm-base-buffer)))
      (lam-proceed buffer stream))))


(defun lam-pm nil
  ;; Return the process mark of the current buffer.
  (process-mark (get-buffer-process (pm-base-buffer))))

(defun lam-set-pm (pos)
  ;; Set the process mark in the current buffer to POS.
  (set-marker (process-mark (get-buffer-process (pm-base-buffer))) pos))

;;; Input fontification

(defcustom lam-fontify-input-enable t
  "Enable fontification of input in lam buffers.
This variable only has effect when creating an lam buffer.  Use
the command `comint-fontify-input-mode' to toggle fontification
of input in an already existing lam buffer."
  :type 'boolean
  :safe 'booleanp
  :version "29.1")

(defcustom lam-indirect-setup-hook nil
  "Hook run in an indirect buffer for input fontification.
Input fontification and indentation of an IELM buffer, if
enabled, is performed in an indirect buffer, whose indentation
and syntax highlighting are set up with `emacs-lisp-mode'.  In
addition to `comint-indirect-setup-hook', run this hook with the
indirect buffer as the current buffer after its setup is done.
This can be used to further customize fontification and other
behavior of the indirect buffer."
  :type 'hook
  :version "29.1")

(defun lam-indirect-setup-hook ()
  "Run `lam-indirect-setup-hook'."
  (run-hooks 'lam-indirect-setup-hook))

;;; Input history

(defvar lam--exit nil
  "Function to call when Emacs is killed.")

(defun lam--input-history-writer (buf)
  "Return a function writing IELM input history to BUF."
  (lambda ()
    (with-current-buffer buf
      (comint-write-input-ring))))

;;; Major mode

(define-derived-mode lam-base-mode comint-mode "LAM"
  "Major mode for interactively evaluating Emacs Lisp expressions.
Uses the interface provided by `comint-mode' (which see).

If, at the start of evaluation, `standard-output' is t (the
                                                        default), `standard-output' is set to a special function that
causes output to be directed to the lam buffer.
`standard-output' is restored after evaluation unless explicitly
set to a different value during evaluation.  You can use (princ
                                                          VALUE) or (pp VALUE) to write to the lam buffer.

The behavior of IELM may be customized with the following variables:

* Entry to this mode runs `comint-mode-hook' and `lam-base-mode-hook'
(in that order).

Customized bindings may be defined in `lam-map', which currently contains:
\\{lam-map}"

  :after-hook
  (and (null comint-use-prompt-regexp)
       lam-fontify-input-enable
       (comint-fontify-input-mode))

  (setq comint-prompt-regexp (concat "^" (regexp-quote lam-prompt)))
  (setq-local paragraph-separate "\\'")
  (setq-local paragraph-start comint-prompt-regexp)
  (setq comint-input-sender 'lam-input-sender)
  (setq comint-process-echoes nil)
  (dolist (f '(lam-complete-filename
               comint-replace-by-expanded-history))
    (add-hook 'completion-at-point-functions f nil t))
  (setq-local lam-prompt-internal lam-prompt)
  (setq-local comint-prompt-read-only lam-prompt-read-only)
  (setq comint-get-old-input 'lam-get-old-input)
  (setq-local comint-completion-addsuffix '("/" . ""))
  ;; Useful for `hs-minor-mode'.

  ;; font-lock support
  (setq-local font-lock-defaults '(lam-font-lock-keywords nil nil nil))

  (add-hook 'comint-indirect-setup-hook
            #'lam-indirect-setup-hook 'append t)
  (setq comint-indirect-setup-function #'emacs-lisp-mode)

  ;; Input history
  (setq-local comint-input-ring-file-name lam-history-file-name)
  (setq-local lam--exit (lam--input-history-writer (current-buffer)))
  (setq-local kill-buffer-hook
              (lambda ()
                (funcall lam--exit)
                (remove-hook 'kill-emacs-hook lam--exit)))
  (unless noninteractive
    (add-hook 'kill-emacs-hook lam--exit))
  (comint-read-input-ring t)

  ;; set up outline minor mode for folding
  (setq-local outline-regexp "^─── [0-9]+:")
  (outline-minor-mode 1)

  ;; A dummy process to keep comint happy. It will never get any input
  (unless (comint-check-proc (pm-base-buffer))
    ;; Was cat, but on non-Unix platforms that might not exist, so
    ;; use hexl instead, which is part of the Emacs distribution.
    (condition-case nil
        (start-process "lam" (current-buffer) hexl-program-name)
      (file-error (start-process "lam" (current-buffer) "cat")))
    (setq-local lam-process (get-buffer-process (current-buffer)))
    (set-process-query-on-exit-flag lam-process nil)
    (goto-char (point-max))

    ;; Add a silly header
    (insert (substitute-command-keys lam-header))
    (lam-set-pm (point-max))
    (unless comint-use-prompt-regexp
      (let ((inhibit-read-only t))
        (add-text-properties
         (point-min) (point-max)
         '(rear-nonsticky t field output inhibit-line-move-field-capture t))))
    (comint-output-filter lam-process lam-prompt-internal)
    (set-marker comint-last-input-start (lam-pm))
    (set-process-filter (get-buffer-process (current-buffer)) 'comint-output-filter)))

(defun lam-get-old-input nil
  ;; Return the previous input surrounding point
  (save-excursion
    (beginning-of-line)
    (unless (looking-at-p comint-prompt-regexp)
      (re-search-backward comint-prompt-regexp))
    (comint-skip-prompt)
    (buffer-substring (point) (progn (forward-sexp 1) (point)))))

;; Above are the basic functionality adopted from ielm.el for the host mode
;; Below are lam specific functions

(defun lam-abort-request ()
  "Abort the current llm request if any."
  (interactive)
  (let* ((active-worker
          (buffer-local-value 'lam-active-worker (pm-base-buffer))))
    (when (process-live-p active-worker)
      (kill-process active-worker))
    ))

(defun lam-current-step ()
  "Return the current step information as a plist."
  (save-excursion
    (let ((beg nil)
          (end nil)
          (step nil)
          (content nil))
      (when (or (search-backward-regexp "^─" nil t) (looking-at-p "^─"))
        (when (looking-at "^─── \\([0-9]+\\):")
          (setq step (match-string 1))
          (forward-line 1)
          (setq beg (point))
          (when (search-forward-regexp "^───$" nil t)
            (forward-line 0)
            (setq end (1- (point))) ;; \n
            (setq content (buffer-substring-no-properties beg end))
            (list :step step :content content :beg beg :end end )))))))


(defun lam-end-of-previous-step (step)
  "Return the position at the end of the previous step before STEP."
  (save-excursion
    (goto-char (point-min))
    (if (search-forward (concat "─── " step ":") nil t)
        (progn
          (forward-line 0)
          (if (re-search-backward "^───\n" nil t)
              (progn
                (forward-line 1)
                (point))
            (point)))
      (progn (message "Step %s not found" step)
             nil))))


(defun lam-kill-from-step (step)
  "Kill all step from STEP to the end."
  ;; before killing the steps
  ;; we ensure that any running task is killed
  (if (process-live-p lam-active-worker)
      (kill-process lam-active-worker))
  (let ((beg (lam-end-of-previous-step step))
        (end (point-max))
        (inhibit-read-only t))
    (with-current-buffer (pm-base-buffer)
      (lam--context-kill-from (string-to-number step))
      (replace-region-contents beg end (lambda () ""))
      (lam-set-pm end))))

(defun lam-kill-steps ()
  "Kill all step from the current step to the end."
  (interactive)
  (let ((step-info (lam-current-step)))
    (if step-info
        (let ((step (plist-get step-info :step)))
          (with-current-buffer (pm-base-buffer)
            ;; popup to confirm
            (when (yes-or-no-p (format "Do you want to kill all steps >= %s?" step))
              (lam-kill-from-step step)
              (comint-output-filter
               (get-buffer-process (current-buffer))
               lam-prompt-internal)
              (goto-char (point-max)))))
      (kill-line))))

(defun lam-edit-llm-step ()
  "Copy the current markdown chunk to a new buffer for editing."
  (interactive)
  (let ((step-info (lam-current-step)))
    (if step-info
        (let* ((step (plist-get step-info :step))
               (content (plist-get step-info :content))
               (base-buf (pm-base-buffer))
               (edit-buffer (get-buffer-create "*lam-edit-llm*")))
          (with-current-buffer edit-buffer
            (erase-buffer)
            (insert content)
            (markdown-mode)
            (goto-char (point-min))
            (setq-local lam--step step)
            (setq-local lam--buffer base-buf)
            (define-key (current-local-map) (kbd "C-c C-c")
                        #'lam-edit-send-back)
            (define-key (current-local-map) (kbd "C-c C-k")
                        #'lam-edit-abort))
          (pop-to-buffer edit-buffer))
      (message "Error this shouldn't happen"))))

(defun lam-edit-send-back ()
  "Send edited content back by explicitly reading buffer-local variables."
  (interactive)
  ;; This is the robust way: explicitly read the values from the current
  ;; (edit) buffer's local variables into lexically-scoped variables.
  (let* ((orig-buf lam--buffer)
         (step lam--step)
         (prefix (buffer-string))
         (process (get-buffer-process orig-buf))
         (stream (lam-standard-output-impl process)))
    ;; Now, perform the action with these validated variables.
    (when (buffer-live-p orig-buf)
      ;; Switch context to the original buffer to perform the modification.
      (with-current-buffer orig-buf
        (lam-kill-from-step step)
        (goto-char (point-max))
        (lam-proceed orig-buf stream prefix)))
    ;; Finally, kill the edit buffer we are currently in.
    (kill-buffer (current-buffer))))

(defun lam-edit-abort ()
  "Send edited content back by explicitly reading buffer-local variables."
  (interactive)
  (kill-buffer (current-buffer)))

;; Additional modes for polymode

;; Define host and inner mode key maps
(defvar lam-term-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Bind the 'e' key to our new edit function.
    (define-key map (kbd "RET") #'lam-show-tmux-in-vterm)
    map)
  "Keymap for lam markdown innermode.")

(defvar lam-llm-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Bind the 'e' key to our new edit function.
    (define-key map (kbd "e") #'lam-edit-llm-step)
    map)
  "Keymap for lam markdown innermode.")

(defvar lam-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'outline-toggle-children)
    (define-key map (kbd "C-c C-c") #'lam-abort-request)
    (define-key map (kbd "C-k") #'lam-kill-steps)
    map)
  "Keymap for `lam-mode`.")


;; Derive host & llm mode from comint-mode and markdown-mode respectively
(define-derived-mode lam-term-mode comint-mode "lam-term"
  "A comint mode with special keybindings for lam."
  (use-local-map lam-term-mode-map))

(define-derived-mode lam-llm-mode markdown-mode "lam-llm"
  "A markdown mode with special keybindings for lam."
  (use-local-map lam-llm-mode-map))

;; Define polymode for lam
(define-hostmode lam-hostmode
  :mode 'lam-base-mode)

(define-innermode lam-llm-innermode
  :mode 'lam-llm-mode
  :head-matcher "^─── [0-9]+: llm ───\n"
  :tail-matcher "^───$"
  :head-mode 'host
  :tail-mode 'host)

(define-innermode lam-term-innermode
  :mode 'lam-term-mode
  :head-matcher "^─── [0-9]+: terminal (%[0-9]+) ───\n"
  :tail-matcher "^───$"
  :head-mode 'host
  :tail-mode 'host)

(define-polymode lam-mode
  :hostmode 'lam-hostmode
  :innermodes '(lam-llm-innermode
                lam-term-innermode)
  :keymap lam-mode-map)

;;; User command

;;;###autoload
(defun lam (&optional buf-name)
  "Start an llm-agent-mode buffer named BUF-NAME."
  (interactive)
  (let (old-point
        (buf-name (or buf-name "*lam*")))
    (unless (comint-check-proc buf-name)
      (with-current-buffer (get-buffer-create buf-name)
        (unless (zerop (buffer-size)) (setq old-point (point)))
        (lam-mode)
        (setq-local trusted-content :all)))
    (pop-to-buffer-same-window buf-name)
    (when old-point (push-mark old-point))))

(provide 'lam)

;;; lam.el ends here
