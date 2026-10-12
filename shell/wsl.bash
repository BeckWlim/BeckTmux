# Optional early Bash loader: keep Windows filesystem scans out of Linux input.
[[ $- == *i* && -r /proc/sys/kernel/osrelease ]] || return 0
IFS= read -r _beck_wsl_release < /proc/sys/kernel/osrelease
if [[ ${_beck_wsl_release,,} != *microsoft* ]]; then
  unset _beck_wsl_release
  return 0
fi
unset _beck_wsl_release

# Retain the removed directories across nested shells for explicit `win` calls.
# Split with builtins, preserving empty components (the current directory).
_beck_wsl_remaining=${PATH}
_beck_wsl_linux_path=
_beck_wsl_separator=
while :; do
  _beck_wsl_entry=${_beck_wsl_remaining%%:*}
  case ${_beck_wsl_entry} in
    /mnt/[a-zA-Z]|/mnt/[a-zA-Z]/*)
      if [[ :${BECK_WSL_WINDOWS_PATH-}: != *":${_beck_wsl_entry}:"* ]]; then
        BECK_WSL_WINDOWS_PATH=${BECK_WSL_WINDOWS_PATH:+${BECK_WSL_WINDOWS_PATH}:}${_beck_wsl_entry}
      fi
      ;;
    *)
      _beck_wsl_linux_path+=${_beck_wsl_separator}${_beck_wsl_entry}
      _beck_wsl_separator=:
      ;;
  esac
  [[ ${_beck_wsl_remaining} == *:* ]] || break
  _beck_wsl_remaining=${_beck_wsl_remaining#*:}
done
export PATH=${_beck_wsl_linux_path}
export BECK_WSL_WINDOWS_PATH
unset _beck_wsl_remaining _beck_wsl_linux_path _beck_wsl_separator _beck_wsl_entry

win() {
  if (($# == 0)); then
    printf 'Usage: win COMMAND [ARGUMENT...]\n' >&2
    return 2
  fi
  PATH="${PATH}${BECK_WSL_WINDOWS_PATH:+:${BECK_WSL_WINDOWS_PATH}}" command "$@"
}
