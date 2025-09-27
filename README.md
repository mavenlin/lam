# LAM (LLM Agent Mode)

LAM is an Emacs mode that provides an interactive emacs panel for chatting with an llm agent, and execute the `elisp` code the agent returns with emacs. As an OS, emacs theoretically can do anything, meaning a universal space of action for the LLM agent. 

To extend the action space of the agent, theoretically you just need to describe it in the system prompt, without having to write MCPs, LLM to some extent just knows how to use `emacs` via `elisp`. And theoretically you also don't need to write any connectors to the UI components, as all the UI elements are invokable via `elisp` code.

## Overview

LAM provides a conversational interface like `claude-code` but in an emacs buffer. You type your request in the bottom prompt line, the LLM responses, and the execution results of the `elisp` code are all appended in to the chat history in the buffer. You can ask LLM to `list-buffers`, or to run a `query-replace` in one of your buffer.

## Usage

Run the command:
```
M-x lam
```
This opens a new buffer `*lam*` where you can start chatting with the LLM.

- **User input**: Type your request at the prompt line, and press `C-j`, you can type multiline input using `RET` to change line.
- **Execute code**: When LLM response is generated and shown, and if you don't like the code that LLM suggests, you can type your feedback at the prompt line. But if you like it, `C-j` without entering any text at the prompt line will cause the backtick surrounded code block to be executed. 
- **Reset to a history step**: It is handy to be able to go back to a history message and start over from there. You can simply go back to a message and press `C-k` to kill that conversation round and every round below it.
- **Edit the LLM output**: Move the cursor into the LLM generated content and press `e`, an edit buffer will popup allowing the content to be edited. It is useful if you dislike the LLM's response. In this case, change the content into a short prefix to nudge LLM into the correct direction. Press `C-c C-c` at the edit buffer once done, and then LLM will continue from your prefix. `C-c C-k` can be used to abort the edit.
- **Toggle fold/unfold**: As all the conversation details are shown in the buffer, sometimes it could be quite dense in information. Use `TAB` key to control whether a certain round of conversation should be shown/folded.
- **Cancel LLM output**: LLM output are streamed into the buffer, use `C-c C-c` at the `lam` buffer to abort the generation prematurely.

## Requirements

- Emacs 29.1 or later
- Required Emacs packages:
  - `comint`
  - `polymode`
  - `markdown-mode`
  - `json-mode`
- `curl` command-line tool for API requests

## Installation

### Doom Emacs Installation

1. **Add to your `packages.el`**:
   ```elisp
   ;; packages.el
   (package! lam
     :recipe (:host github :repo "mavenlin/lam" :files ("*.el")))
   ```

2. **Configure in your `config.el`**:
   ```elisp
   ;; config.el
   (use-package! lam
     :commands (lam)
     :config
     ;; Required configuration
     (setq lam-base-url "https://api.openai.com/v1")  ; or your API endpoint
     (setq lam-key "your-api-key-here")               ; your API key
     (setq lam-model "gpt-4")                         ; or your preferred model
   ```

### Manual Installation

1. **Clone the repository**:
   ```bash
   git clone https://github.com/your-username/lam.git ~/.emacs.d/lam
   ```

2. **Add to your Emacs configuration**:
   ```elisp
   (add-to-list 'load-path "~/.emacs.d/lam")
   (require 'lam)
   
   ;; Configuration
   (setq lam-base-url "https://api.openai.com/v1")  ; or your API endpoint
   (setq lam-key "your-api-key-here")               ; your API key
   (setq lam-model "gpt-4")                         ; or your preferred model
   ```

### Optional Settings

```elisp
;; Customize the prompt
(setq lam-prompt "> ")

;; Custom system message for the LLM
(setq lam--system-message "Your custom system prompt here")
```

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

This project is licensed GPL.
