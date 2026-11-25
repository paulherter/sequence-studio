# Sourced by bash scripts (also by sh/zsh scripts that only call the functions). Every delete of a path that comes from a
# variable goes through here (2026-11-20: an empty `$D` made `cd $D; find $D -delete` run in HOME and wipe it).
#   safe_delete <path> <allowed-root>...           removes the path (file, link or tree) only if strictly below a root
#   safe_delete_contents <path> <allowed-root>...  empties a directory, keeps the directory itself
#   safe_tmpdir <prefix>                           mktemp -d below the temp root; prints the path or exits the script
# Refused (message on stderr, return 1, nothing deleted): empty, not absolute, contains `..`, resolves (symlinks followed)
# to / or $HOME or a parent of $HOME, or is not strictly below an allowed root. Roots get the same checks.

_sd_resolve() { # <path>: prints the physical path (symlinks followed; a missing leaf is kept as is)
  local p=$1 n=0 t d
  while [ -L "$p" ] && [ $n -lt 20 ]; do
    t=$(readlink "$p") || return 1
    case "$t" in /*) p=$t ;; *) p=$(dirname "$p")/$t ;; esac
    n=$((n+1))
  done
  if [ -d "$p" ]; then (cd -P -- "$p" 2>/dev/null && pwd -P)
  else
    d=$(dirname "$p")
    if [ -d "$d" ]; then printf '%s/%s\n' "$(cd -P -- "$d" 2>/dev/null && pwd -P)" "$(basename "$p")"; else printf '%s\n' "$p"; fi
  fi
}

_sd_check_abs() { # <label> <path>: lexical checks shared by paths and roots
  case "$2" in
    '') echo "safe_delete: refused, $1 is empty" >&2; return 1 ;;
    /*) ;;
    *) echo "safe_delete: refused, $1 is not absolute: $2" >&2; return 1 ;;
  esac
  case "/$2/" in */../*) echo "safe_delete: refused, $1 contains '..': $2" >&2; return 1 ;; esac
  return 0
}

_sd_forbidden() { # <label> <resolved>: / , HOME, parents of HOME
  local r=$2 h
  h=$(_sd_resolve "${HOME:-/nonexistent-home}") || h=${HOME:-}
  if [ "$r" = / ] || [ -z "$r" ]; then echo "safe_delete: refused, $1 resolves to /" >&2; return 1; fi
  if [ "$r" = "$h" ] || [ "$r" = "${HOME:-}" ]; then echo "safe_delete: refused, $1 is HOME: $r" >&2; return 1; fi
  case "$h/" in "$r"/*) echo "safe_delete: refused, $1 is a parent of HOME: $r" >&2; return 1 ;; esac
  return 0
}

_sd_check() { # <path> <root>... : returns 0 and sets _SD_RESOLVED when the delete is allowed
  local path=${1-} root rr r ok=1
  [ $# -ge 2 ] || { echo "safe_delete: refused, no allowed root given" >&2; return 1; }
  shift
  _sd_check_abs path "$path" || return 1
  r=$(_sd_resolve "$path") || { echo "safe_delete: refused, cannot resolve $path" >&2; return 1; }
  _sd_forbidden path "$r" || return 1
  for root in "$@"; do
    _sd_check_abs root "$root" || return 1
    rr=$(_sd_resolve "$root") || return 1
    _sd_forbidden root "$rr" || return 1
    case "$r" in "$rr"/?*) ok=0 ;; esac
  done
  if [ $ok -ne 0 ]; then echo "safe_delete: refused, $path (-> $r) is not strictly below an allowed root: $*" >&2; return 1; fi
  _SD_RESOLVED=$r
  return 0
}

safe_delete() { # <path> <root>...
  _sd_check "$@" || return 1
  [ -e "$1" ] || [ -L "$1" ] || return 0
  rm -rf -- "$1"
}

safe_delete_contents() { # <dir> <root>...
  _sd_check "$@" || return 1
  [ -d "$1" ] || return 0
  find -- "$1" -mindepth 1 -delete
}

safe_tmpdir() { # <prefix>
  local root d r tr
  root=${TMPDIR:-/tmp}
  d=$(mktemp -d "${root%/}/${1:-sq}.XXXXXX") || { echo "safe_tmpdir: mktemp failed" >&2; exit 1; }
  r=$(_sd_resolve "$d"); tr=$(_sd_resolve "$root")
  case "$d" in ''|/) echo "safe_tmpdir: bad result '$d'" >&2; exit 1 ;; esac
  case "$r" in "$tr"/?*) ;; *) echo "safe_tmpdir: $d is not below $root" >&2; exit 1 ;; esac
  printf '%s\n' "$d"
}

safe_abspath() { # <path>: prints the absolute path (parent folder created and resolved); for an OUT folder a script deletes later
  local p=${1-} d
  case "$p" in '') echo "safe_abspath: empty path" >&2; return 1 ;; esac
  case "/$p/" in */../*) echo "safe_abspath: '..' in $p" >&2; return 1 ;; esac
  case "$p" in /*) ;; *) p=$PWD/$p ;; esac
  d=$(dirname "$p"); mkdir -p -- "$d" || return 1
  printf '%s/%s\n' "$(cd -P -- "$d" && pwd -P)" "$(basename "$p")"
}
