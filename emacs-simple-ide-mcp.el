;;; emacs-simple-ide-mcp.el --- MCP HTTP server for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 hgonzale

;; Author: hgonzale <1747263+hgonzale@users.noreply.github.com>
;; Maintainer: hgonzale <1747263+hgonzale@users.noreply.github.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (simple-httpd "1.5.1"))
;; Keywords: tools, mcp, lsp
;; URL: https://github.com/hgonzale/emacs-simple-ide-mcp

;;; Commentary:

;; Starts an HTTP MCP server on localhost:7777, allowing Claude to interact
;; with the running Emacs instance: open files, navigate symbols, query LSP
;; diagnostics, and show Magit views.
;;
;; Usage: (require 'emacs-simple-ide-mcp)
;; The server starts automatically in interactive sessions.

;;; Code:

(require 'simple-httpd)
(require 'json)
(require 'imenu)

;; Declare external functions used conditionally at runtime.
(declare-function xref-item-location       "xref")
(declare-function xref-item-summary        "xref")
(declare-function xref-location-group      "xref")
(declare-function xref-location-line       "xref")
(declare-function xref-backend-references  "xref")
(declare-function flycheck-error-line      "flycheck")
(declare-function flycheck-error-column    "flycheck")
(declare-function flycheck-error-level     "flycheck")
(declare-function flycheck-error-message   "flycheck")
(declare-function flycheck-error-checker   "flycheck")
(declare-function magit-diff-range         "magit-diff")
(declare-function magit-diff-buffer-file   "magit-diff")
(declare-function magit-status             "magit")
(defvar flycheck-current-errors)

;;; ─── Configuration ───────────────────────────────────────────────────────────

(defvar emacs-simple-ide-mcp-port 7777
  "Port on which the Emacs MCP HTTP server listens.")

;;; ─── Tool schemas ────────────────────────────────────────────────────────────

(defconst emacs-simple-ide-mcp--tools
  (list
   '((name . "open_file")
     (description . "Open a file in Emacs, optionally at a specific line and column. Raises the Emacs frame.")
     (inputSchema . ((type . "object")
                     (properties . ((path . ((type . "string")
                                             (description . "Absolute path to the file")))
                                    (line . ((type . "number")
                                             (description . "Line number, 1-indexed (optional)")))
                                    (col  . ((type . "number")
                                             (description . "Column number, 1-indexed (optional)")))))
                     (required . ["path"]))))
   '((name . "list_symbols")
     (description . "List symbols (functions, classes, variables) in a file using imenu.")
     (inputSchema . ((type . "object")
                     (properties . ((path . ((type . "string")
                                             (description . "Absolute path to the file")))))
                     (required . ["path"]))))
   '((name . "find_definition")
     (description . "Find the definition of a symbol via LSP/xref.")
     (inputSchema . ((type . "object")
                     (properties . ((symbol       . ((type . "string")
                                                     (description . "Symbol name to look up")))
                                    (context_file . ((type . "string")
                                                     (description . "File where the symbol appears")))))
                     (required . ["symbol" "context_file"]))))
   '((name . "find_references")
     (description . "Find all references to a symbol via LSP/xref.")
     (inputSchema . ((type . "object")
                     (properties . ((symbol       . ((type . "string")
                                                     (description . "Symbol name to look up")))
                                    (context_file . ((type . "string")
                                                     (description . "File where the symbol appears")))))
                     (required . ["symbol" "context_file"]))))
   '((name . "get_diagnostics")
     (description . "Get flycheck diagnostics for a file (errors, warnings, info).")
     (inputSchema . ((type . "object")
                     (properties . ((path . ((type . "string")
                                             (description . "Absolute path to the file (optional, uses current buffer if omitted)")))))
                     (required . []))))
   '((name . "show_diff")
     (description . "Show a git diff in Magit. Provide file for a single-file diff, or base+target for a range diff.")
     (inputSchema . ((type . "object")
                     (properties . ((file   . ((type . "string")
                                               (description . "File to diff (optional)")))
                                    (base   . ((type . "string")
                                               (description . "Base ref, e.g. HEAD~1 (optional)")))
                                    (target . ((type . "string")
                                               (description . "Target ref, e.g. HEAD (optional)")))))
                     (required . []))))
   '((name . "show_status")
     (description . "Show git repository status in Magit.")
     (inputSchema . ((type . "object")
                     (properties . ((repo . ((type . "string")
                                             (description . "Repository path (optional, defaults to default-directory)")))))
                     (required . []))))
   '((name . "eval")
     (description . "Evaluate an Emacs Lisp expression and return the result.")
     (inputSchema . ((type . "object")
                     (properties . ((expression . ((type . "string")
                                                   (description . "Emacs Lisp expression to evaluate")))))
                     (required . ["expression"])))))
  "MCP tool schema list.")

;;; ─── Tool availability ───────────────────────────────────────────────────────

(defun emacs-simple-ide-mcp--available-tools ()
  "Return tool schemas filtered to those whose dependencies are loaded."
  (seq-filter
   (lambda (tool)
     (pcase (alist-get 'name tool)
       ((or "show_diff" "show_status") (featurep 'magit))
       ("get_diagnostics"              (featurep 'flycheck))
       (_                              t)))
   emacs-simple-ide-mcp--tools))

;;; ─── Tool implementations ────────────────────────────────────────────────────

(defun emacs-simple-ide-mcp--open-file (args)
  "Open a file in Emacs with optional line/col navigation.
ARGS is an alist with keys: path (required), line, col."
  (let* ((path (alist-get 'path args))
         (line (alist-get 'line args))
         (col  (alist-get 'col  args)))
    (unless path (error "Path is required"))
    (find-file (expand-file-name path))
    (when line
      (goto-char (point-min))
      (forward-line (1- (max 1 line))))
    (when (and col (> col 1))
      (move-to-column (1- col)))
    (raise-frame)
    (when (display-graphic-p)
      (x-focus-frame nil))
    (format "Opened %s%s" path
            (if line (format " at line %d" line) ""))))

(defun emacs-simple-ide-mcp--collect-imenu-names (index prefix)
  "Recursively collect symbol name strings from an imenu INDEX.
PREFIX is prepended to each name to reflect nesting."
  (let (names)
    (dolist (item index)
      (unless (equal (car item) "*Rescan*")
        (if (imenu--subalist-p item)
            (setq names (append names
                                (emacs-simple-ide-mcp--collect-imenu-names
                                 (cdr item)
                                 (concat prefix (car item) "/"))))
          (push (concat prefix (car item)) names))))
    (nreverse names)))

(defun emacs-simple-ide-mcp--list-symbols (args)
  "List imenu symbols in a file.
ARGS is an alist with key: path (required)."
  (let ((path (alist-get 'path args)))
    (unless path (error "Path is required"))
    (with-current-buffer (find-file-noselect (expand-file-name path))
      (let ((index (condition-case nil
                       (imenu--make-index-alist t)
                     (error nil))))
        (if index
            (mapconcat #'identity
                       (emacs-simple-ide-mcp--collect-imenu-names index "")
                       "\n")
          "No symbols found (imenu not supported for this file type)")))))

(defun emacs-simple-ide-mcp--format-xref (item)
  "Format an xref ITEM as a location string."
  (condition-case nil
      (let* ((loc  (xref-item-location item))
             (file (xref-location-group loc))
             (line (xref-location-line  loc))
             (sum  (xref-item-summary   item)))
        (format "%s:%d  %s" file line sum))
    (error (format "%s" item))))

(defun emacs-simple-ide-mcp--find-xref (args method)
  "Find definitions or references for the symbol named in ARGS.
METHOD is \\=`:def\\=' or \\=`:ref\\='."
  (let* ((symbol-name  (alist-get 'symbol       args))
         (context-file (alist-get 'context_file args)))
    (unless symbol-name  (error "Symbol is required"))
    (unless context-file (error "Context_file is required"))
    (with-current-buffer (find-file-noselect (expand-file-name context-file))
      (save-excursion
        (goto-char (point-min))
        (when (search-forward symbol-name nil t)
          (goto-char (match-beginning 0)))
        (let* ((backend (xref-find-backend))
               (lsp-active (or (bound-and-true-p lsp-mode)
                               (bound-and-true-p eglot--managed-mode)))
               (items   (condition-case nil
                            (if (eq method :def)
                                (xref-backend-definitions backend symbol-name)
                              (xref-backend-references backend symbol-name))
                          (error nil))))
          (cond
           (items
            (mapconcat #'emacs-simple-ide-mcp--format-xref items "\n"))
           (lsp-active
            (if (eq method :def)
                (format "No definition found for %s" symbol-name)
              (format "No references found for %s" symbol-name)))
           (t
            "No LSP server active for this buffer. Configure lsp-mode or eglot for accurate results.")))))))

(defun emacs-simple-ide-mcp--find-definition (args)
  "Find definition of symbol in ARGS via xref."
  (emacs-simple-ide-mcp--find-xref args :def))

(defun emacs-simple-ide-mcp--find-references (args)
  "Find references to symbol in ARGS via xref."
  (emacs-simple-ide-mcp--find-xref args :ref))

(defun emacs-simple-ide-mcp--get-diagnostics (args)
  "Get flycheck diagnostics for a file.
ARGS is an alist with optional key: path."
  (unless (featurep 'flycheck)
    (error "Flycheck is not available"))
  (let* ((path (alist-get 'path args))
         (buf  (if (and path (not (equal path "")))
                   (find-file-noselect (expand-file-name path))
                 (current-buffer))))
    (with-current-buffer buf
      (cond
       ((not (bound-and-true-p flycheck-mode))
        "flycheck-mode is not enabled in this buffer")
       ((null flycheck-current-errors)
        "No diagnostics")
       (t
        (mapconcat
         (lambda (err)
           (format "%d:%d [%s] %s  (%s)"
                   (or (flycheck-error-line   err) 0)
                   (or (flycheck-error-column err) 0)
                   (flycheck-error-level   err)
                   (flycheck-error-message err)
                   (flycheck-error-checker err)))
         flycheck-current-errors
         "\n"))))))

(defun emacs-simple-ide-mcp--show-diff (args)
  "Show a git diff in Magit.
ARGS is an alist with optional keys: file, base, target."
  (unless (require 'magit nil t)
    (error "Magit is not available"))
  (let* ((file   (alist-get 'file   args))
         (base   (alist-get 'base   args))
         (target (alist-get 'target args)))
    (cond
     ((and base target)
      (magit-diff-range (format "%s..%s" base target)))
     (file
      (with-current-buffer (find-file-noselect (expand-file-name file))
        (magit-diff-buffer-file)))
     (t
      (magit-diff-range "HEAD~1..HEAD")))
    (raise-frame)
    "Showing diff in Magit"))

(defun emacs-simple-ide-mcp--eval (args)
  "Evaluate an Emacs Lisp expression from ARGS and return the result."
  (let* ((expr (alist-get 'expression args)))
    (unless expr (error "Expression is required"))
    (format "%S" (eval (read expr) t))))

(defun emacs-simple-ide-mcp--show-status (args)
  "Show git status in Magit.
ARGS is an alist with optional key: repo."
  (unless (require 'magit nil t)
    (error "Magit is not available"))
  (let ((repo (alist-get 'repo args)))
    (magit-status (if (and repo (not (equal repo "")))
                      repo
                    default-directory))
    (raise-frame)
    "Showing status in Magit"))

;;; ─── JSON-RPC 2.0 ────────────────────────────────────────────────────────────

(defun emacs-simple-ide-mcp--ok (id result)
  "Return a JSON-RPC success response with ID and RESULT."
  `((jsonrpc . "2.0") (id . ,id) (result . ,result)))

(defun emacs-simple-ide-mcp--err (id code msg)
  "Return a JSON-RPC error response with ID, error CODE, and MSG."
  `((jsonrpc . "2.0") (id . ,id)
    (error . ((code . ,code) (message . ,msg)))))

(defun emacs-simple-ide-mcp--call-tool (name args)
  "Dispatch a tool call by NAME with ARGS; return a text string."
  (cond
   ((string= name "open_file")       (emacs-simple-ide-mcp--open-file       args))
   ((string= name "list_symbols")    (emacs-simple-ide-mcp--list-symbols    args))
   ((string= name "find_definition") (emacs-simple-ide-mcp--find-definition args))
   ((string= name "find_references") (emacs-simple-ide-mcp--find-references args))
   ((string= name "get_diagnostics") (emacs-simple-ide-mcp--get-diagnostics args))
   ((string= name "show_diff")       (emacs-simple-ide-mcp--show-diff       args))
   ((string= name "show_status")     (emacs-simple-ide-mcp--show-status     args))
   ((string= name "eval")            (emacs-simple-ide-mcp--eval            args))
   (t (error "Unknown tool: %s" name))))

(defun emacs-simple-ide-mcp--dispatch (req)
  "Dispatch JSON-RPC request REQ (alist); return response alist or nil."
  (let* ((method (alist-get 'method req))
         (id     (alist-get 'id     req))
         (params (alist-get 'params req)))
    (condition-case err
        (cond
         ((string= method "initialize")
          (emacs-simple-ide-mcp--ok id
            `((protocolVersion . "2024-11-05")
              (capabilities    . ((tools . ((listChanged . :json-false)))))
              (serverInfo      . ((name . "emacs-simple-ide-mcp") (version . "1.0.0"))))))
         ;; Notifications — no response
         ((or (string= method "initialized")
              (string= method "notifications/initialized"))
          nil)
         ((string= method "tools/list")
          (emacs-simple-ide-mcp--ok id `((tools . ,(apply #'vector (emacs-simple-ide-mcp--available-tools))))))
         ((string= method "tools/call")
          (let* ((name      (alist-get 'name      params))
                 (tool-args (alist-get 'arguments params))
                 (text      (emacs-simple-ide-mcp--call-tool name tool-args)))
            (emacs-simple-ide-mcp--ok id
              `((content  . [((type . "text") (text . ,text))])
                (isError  . :json-false)))))
         (id
          (emacs-simple-ide-mcp--err id -32601 (format "Method not found: %s" method)))
         (t nil))
      (error
       (when id
         (emacs-simple-ide-mcp--err id -32603 (error-message-string err)))))))

;;; ─── HTTP handler ────────────────────────────────────────────────────────────

(defun httpd/mcp (proc _path _query request)
  "Handle MCP HTTP requests at /mcp.
PROC is the network process; REQUEST is the parsed header alist."
  (let* ((json-object-type 'alist)
         (json-array-type  'list)
         (json-key-type    'symbol)
         (body     (cadr (assoc "Content" request)))
         (req      (condition-case nil
                       (json-read-from-string (or body ""))
                     (error nil)))
         (response (when req (emacs-simple-ide-mcp--dispatch req)))
         (response-json (if response
                            (let ((json-encoding-pretty-print nil))
                              (json-encode response))
                          "null")))
    (with-httpd-buffer proc "application/json"
      (insert response-json))))

;;; ─── Server control ──────────────────────────────────────────────────────────

(defun emacs-simple-ide-mcp-start ()
  "Start the Emacs MCP HTTP server on `emacs-simple-ide-mcp-port'."
  (interactive)
  (setq httpd-port emacs-simple-ide-mcp-port
        httpd-root "/tmp")
  (condition-case nil (httpd-stop) (error nil))
  (httpd-start)
  (message "emacs-simple-ide-mcp: server started on http://localhost:%d/mcp" emacs-simple-ide-mcp-port))

(defun emacs-simple-ide-mcp-stop ()
  "Stop the Emacs MCP HTTP server."
  (interactive)
  (httpd-stop)
  (message "emacs-simple-ide-mcp: server stopped"))

(unless noninteractive
  (emacs-simple-ide-mcp-start))

(provide 'emacs-simple-ide-mcp)
;;; emacs-simple-ide-mcp.el ends here
