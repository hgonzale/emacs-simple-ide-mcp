# emacs-simple-ide-mcp

An MCP server that runs inside a live Emacs session, giving Claude direct access to your editor: open files, navigate symbols, query LSP, and trigger Magit views.

Listens on `http://localhost:7777/mcp`.

## Tools

| Tool | Description |
|------|-------------|
| `open_file` | Open a file at an optional line/column and raise the frame |
| `list_symbols` | List symbols in a file via imenu |
| `find_definition` | Jump to a symbol's definition via LSP/xref |
| `find_references` | Find all references to a symbol via LSP/xref |
| `get_diagnostics` | Return flycheck errors and warnings for a file |
| `show_diff` | Show a git diff in Magit |
| `show_status` | Show git status in Magit |
| `eval` | Evaluate an Emacs Lisp expression and return the result |

## Requirements

- Emacs 29+
- [`simple-httpd`](https://github.com/skeeto/emacs-web-server)
- `flycheck`, `magit`, and an LSP server are optional but unlock their respective tools

## Installation

### MELPA

Once the package is on MELPA:

```emacs-lisp
(use-package emacs-simple-ide-mcp
  :ensure t)
```

### MELPA (straight.el)

```emacs-lisp
(straight-use-package 'emacs-simple-ide-mcp)
```

### Doom Emacs

`packages.el`:
```emacs-lisp
(package! emacs-simple-ide-mcp
  :recipe (:host github :repo "hgonzale/emacs-simple-ide-mcp"))
```

`config.el`:
```emacs-lisp
(use-package! emacs-simple-ide-mcp)
```

The server starts automatically when Emacs loads the package interactively.

## License

BSD 2-Clause. See [LICENSE](LICENSE).
