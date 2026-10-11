# Sourced at the end of ~/.bashrc by scripts/setup-completion.sh.
# Bash owns input editing and completion; tmux keeps its own key tables.
[[ $- == *i* ]] || return 0
((BASH_VERSINFO[0] >= 4)) || return 0

if [[ ! ${BLE_VERSION-} ]]; then
  for _beck_ble_script in \
    "${XDG_DATA_HOME:-${HOME}/.local/share}/blesh/ble.sh" \
    /usr/share/blesh/ble.sh /usr/local/share/blesh/ble.sh; do
    if [[ -r ${_beck_ble_script} ]]; then
      source "${_beck_ble_script}" --attach=none || return
      break
    fi
  done
  unset _beck_ble_script
fi
[[ ${BLE_VERSION-} ]] || return 0

# Shell Vim modes edit the current command while tmux stays in INPUT.
# Escape enters shell Normal mode; C-o is an additional direct entry.
# Keep the inline mode label muted on the terminal's default background.
ble-face -d beck_vim_mode 'fg=#a6a69c'
function ble/widget/beck/discard-input {
  if [[ ${_ble_decode_keymap-} == vi_nmap ]]; then
    ble/widget/vi_nmap/insert-mode
  fi
  ble/widget/discard-line
}
function ble/prompt/backslash:beck:vim-mode {
  declare -F ble/keymap:vi/script/get-mode >/dev/null || return 0
  local mode label
  ble/keymap:vi/script/get-mode
  ble/prompt/unit/add-hash '$_ble_edit_overwrite_mode,$_ble_keymap_vi_single_command_overwrite'
  case ${mode} in
    *[vV]*|*$'\x16'*) label=VISUAL ;;
    *[sS]*|*$'\x13'*) label=SELECT ;;
    R|$'\x12') label=REPLACE ;;
    i) label=INSERT ;;
    n|in) label=NORMAL ;;
    c) label=COMMAND ;;
    *) return 0 ;;
  esac
  ble/prompt/process-prompt-string '\g{face:beck_vim_mode}'"[${label}]"'\g{none}'
}
function beck/vim-prompt {
  # Append the mode to the context row after Starship renders. Keep it inside
  # PS1 so terminal reflow tracks it with the rest of the prompt on resize.
  bleopt prompt_rps1=
  if [[ ${PS1} != *'\q{beck:vim-mode}'* ]]; then
    if [[ ${PS1} == *$'\n'* ]]; then
      PS1=${PS1/$'\n'/' \q{beck:vim-mode}'$'\n'}
    else
      PS1+='\q{beck:vim-mode} '
    fi
  fi
}
function beck/search-current {
  local direction=$1 needle=${2:-$_ble_keymap_vi_search_needle}
  local ARG FLAG REG; ble/keymap:vi/get-arg 1
  if [[ ! ${needle} ]]; then
    ble/widget/.bell 'no previous search'
    return 0
  fi
  _ble_keymap_vi_search_needle=${needle}
  _ble_keymap_vi_search_obackward=0
  [[ ${direction} != - ]] || _ble_keymap_vi_search_obackward=1
  _ble_keymap_vi_search_ohistory=0
  ble/keymap:vi/search/clear-matched
  local original_index search_direction beg end
  while ((ARG > 0)); do
    original_index=${_ble_edit_ind}
    search_direction=B
    if [[ ${direction} == + ]]; then
      search_direction=+
      _ble_edit_ind=$((_ble_edit_ind + 1))
    fi
    if ! ble-edit/isearch/search "${needle}" "${search_direction}:regex"; then
      # Wrap inside this command; do not replace it with a history entry.
      _ble_edit_ind=0
      [[ ${direction} != - ]] || _ble_edit_ind=$((${#_ble_edit_str} + 1))
      if ! ble-edit/isearch/search "${needle}" "${search_direction}:regex"; then
        _ble_edit_ind=${original_index}
        ble/widget/.bell 'search: not found'
        break
      fi
    fi
    _ble_edit_ind=${beg}
    _ble_edit_mark=$((end - 1))
    _ble_keymap_vi_search_activate=vi_search
    ((ARG--))
  done
  ble/keymap:vi/adjust-command-mode
}
function ble/widget/beck/search-forward {
  ble/widget/vi-command/search-forward
  _ble_keymap_vi_cmap_accept_hook='beck/search-current +'
  return 147
}
function ble/widget/beck/search-backward {
  ble/widget/vi-command/search-backward
  _ble_keymap_vi_cmap_accept_hook='beck/search-current -'
  return 147
}
function ble/widget/beck/search-repeat {
  local direction=+ backward=${_ble_keymap_vi_search_obackward:-0}
  [[ ${1:-} != reverse ]] || backward=$((1 - backward))
  ((backward == 0)) || direction=-
  # N reverses this movement without changing the original search direction.
  local _ble_keymap_vi_search_obackward=${_ble_keymap_vi_search_obackward:-0}
  beck/search-current "${direction}"
}
function beck/input-keymap {
  ble-bind -m vi_imap -f C-o vi_imap/normal-mode
  # Submit multiline input too, including after returning from Normal mode.
  # Alt+Enter retains ble.sh's explicit newline insertion in Insert mode.
  local enter_key
  for enter_key in C-m RET; do
    ble-bind -m vi_imap -f "${enter_key}" accept-line
    ble-bind -m vi_nmap -f "${enter_key}" vi_nmap/accept-line
    ble-bind -m vi_imap -f "M-${enter_key}" newline
  done
  ble-bind -m vi_nmap -f / beck/search-forward
  ble-bind -m vi_nmap -f '?' beck/search-backward
  ble-bind -m vi_nmap -f n beck/search-repeat
  ble-bind -m vi_nmap -f N 'beck/search-repeat reverse'
  # Resume typing from a visual selection without changing command text.
  ble-bind -m vi_xmap -f i vi_nmap/insert-mode
  # Keep the usual shell shortcut for abandoning input in either editing mode.
  ble-bind -m vi_imap -f C-c beck/discard-input
  ble-bind -m vi_nmap -f C-c beck/discard-input
  # Prompt dependency hashes update the tag without rerunning PRECMD.
  bleopt keymap_vi_mode_update_prompt= prompt_vi_mode_indicator=
}
blehook/eval-after-load keymap_vi beck/input-keymap
set -o vi
bleopt default_keymap=vi
_beck_mode_prompt_registered=
for _beck_prompt_hook in "${PROMPT_COMMAND[@]}"; do
  [[ ${_beck_prompt_hook} != beck/vim-prompt ]] || _beck_mode_prompt_registered=1
done
[[ ${_beck_mode_prompt_registered} ]] || PROMPT_COMMAND+=(beck/vim-prompt)
unset _beck_mode_prompt_registered _beck_prompt_hook

# Retain the user's existing programmable completions. Load the standard
# collection when their bashrc has not already done so.
if ! declare -F _completion_loader >/dev/null && ! declare -F _comp_load >/dev/null; then
  if [[ -r /usr/share/bash-completion/bash_completion ]]; then
    source /usr/share/bash-completion/bash_completion
  elif [[ -r /etc/bash_completion ]]; then
    source /etc/bash_completion
  fi
fi

# Carapace adds command-specific candidates and descriptions when installed.
# Do not download tools or execute arbitrary --help commands during input.
if command -v carapace >/dev/null 2>&1 && [[ ! ${_beck_carapace_loaded-} ]]; then
  if _beck_carapace_script=$(carapace _carapace bash); then
    source /dev/stdin <<<"${_beck_carapace_script}" || return
    _beck_carapace_loaded=1
  fi
  unset _beck_carapace_script
fi

function beck/completion-theme {
  local theme_fg=default theme_selection='#3a3d3f'
  local theme_muted='#a6a69c' theme_focus='#a6e22e' theme_info='#66d9ef'
  local theme_string='#e6db74' theme_accent='#ae81ff' theme_error='#f92672'
  local palette_text palette_index
  local -a palette_values palette_roles=(theme_fg theme_selection
    theme_muted theme_focus theme_info theme_string theme_accent theme_error)
  # Read the same roles tmux uses, once at shell startup. Outside tmux, use the
  # default Monokai palette shared with Neovim's Pmenu/PmenuSel highlights.
  if [[ ${TMUX-} && ${TMUX_PANE-} ]] && command -v tmux >/dev/null 2>&1; then
    if palette_text=$(tmux -N -S "${TMUX%%,*}" display-message -p -t "${TMUX_PANE}" \
      '#{@beck_default_fg}|#{@beck_default_cursor}|#{@beck_default_muted}|#{@beck_default_green}|#{@beck_default_cyan}|#{@beck_default_yellow}|#{@beck_default_purple}|#{@beck_default_red}' 2>/dev/null); then
      IFS='|' read -r -a palette_values <<<"${palette_text}"
      for palette_index in "${!palette_roles[@]}"; do
        if [[ ${palette_values[palette_index]-} =~ ^#[[:xdigit:]]{6}$ ||
          ${palette_roles[palette_index]} == theme_fg && ${palette_values[palette_index]-} == default ]]; then
          printf -v "${palette_roles[palette_index]}" '%s' "${palette_values[palette_index]}"
        fi
      done
    fi
  fi

  ble-face "auto_complete=fg=${theme_muted}"
  ble-face -s beck_vim_mode "fg=${theme_muted}"
  ble-face "menu_complete_selected=fg=${theme_fg},bg=${theme_selection},bold"
  ble-face "menu_complete_match=fg=${theme_focus},bold"
  ble-face "menu_desc_default=fg=${theme_muted}"
  ble-face "menu_filter_fixed=fg=${theme_fg},bold"
  ble-face "menu_filter_input=fg=${theme_fg},bg=${theme_selection},bold"
  ble-face "region=fg=${theme_fg},bg=${theme_selection}"
  ble-face "syntax_command=fg=${theme_focus}" "command_builtin=fg=${theme_focus}"
  ble-face "command_file=fg=${theme_focus}" "command_function=fg=${theme_focus}"
  ble-face "command_alias=fg=${theme_info}" "command_keyword=fg=${theme_error}"
  ble-face "syntax_quoted=fg=${theme_string}" "syntax_quotation=fg=${theme_string}"
  ble-face "syntax_comment=fg=${theme_muted}" "syntax_varname=fg=${theme_info}"
  ble-face "syntax_error=fg=${theme_error},underline"
  ble-face "syntax_escape=fg=${theme_accent}" "syntax_param_expansion=fg=${theme_info}"
  ble-face "syntax_glob=fg=${theme_accent}" "syntax_brace=fg=${theme_accent}"
  ble-face "argument_option=fg=${theme_info}" "filename_directory=fg=${theme_info}"
  ble-face "filename_other=fg=${theme_fg}" "filename_executable=fg=${theme_focus}"
}

function beck/complete-load {
  bleopt complete_auto_complete=1 complete_auto_history=1 complete_auto_delay=150
  bleopt complete_menu_complete=1 complete_menu_style=desc complete_menu_maxlines=10
  # Ambiguous syntax should produce a menu, not an arbitrary inline choice.
  bleopt complete_auto_complete_opts+=syntax-unique
  # Keep ordinary Tab completion and menu cycling outside the suggestion map.
  # Support both encodings because terminals normally send C-i for Tab.
  ble-bind -m auto_complete -f C-i 'auto_complete/@end insert-word'
  ble-bind -m auto_complete -f TAB 'auto_complete/@end insert-word'
  beck/completion-theme
}
blehook/eval-after-load complete beck/complete-load
[[ ${_ble_attached-} ]] || ble-attach
