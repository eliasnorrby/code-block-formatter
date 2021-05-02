#!/usr/bin/env bash

# Format code blocks in markdown files.

SUPPORTED_LANGUAGES='yaml,javascript'
ERROR_PATTERN='^[[:space:]]*\[error\] stdin:'

# defaults
# LANGUAGES='yaml,javascript'
LANGUAGES='yaml'
SEARCHPATH='.'

ERROR="Bad usage, see ${0##*/} -h"

read -r -d "" USAGE <<EOF
Short description

Usage: ${0##*/} [-lph] <command>

Commands:
  format        Format files
  fix           Fix errors in files
  analyze       Display info about blocks in files

Options:
  -l LANGUAGES  Process blocks with specified languages (comma-separated) (Default: "$LANGUAGES")
  -p PATH       Path to files (Default: '.')
  -h            Show usage

Example:
  ${0##*/} -l yaml,javascript,typescript format

EOF

if [ "$1" = "--help" ]; then
  echo "$USAGE" && exit 0
fi

while getopts l:p:h opt; do
  case $opt in
    l) LANGUAGES=$OPTARG                   ;;
    p) SEARCHPATH=$OPTARG                        ;;
    h) echo "$USAGE" && exit 0             ;;
    *) echo "$ERROR" && exit 1             ;;
  esac
done

CMD=${*:$OPTIND:1}

OTHER_ARGS=${*:$OPTIND+1}

if [ -n "$OTHER_ARGS" ]; then
  echo "ERROR: Unprocessed positional arguments: $OTHER_ARGS"
  exit 1
fi

shift

setup() {
  L_PATTERN=$(lang_list_to_regexp)
}

lang_list_to_regexp() {
  validate_languages
  echo "($(tr ',' '|' <<<"$LANGUAGES"))"
}

validate_languages() {
  for language in $(tr ',' ' ' <<<"$LANGUAGES" | xargs); do
    if ! [ "${SUPPORTED_LANGUAGES#*$language}" != "${SUPPORTED_LANGUAGES}" ]; then
      echo_e "Usupported language: $language"
      exit 1
    fi
  done
}

# get line number from grep ouput
line_number() {
  cut -d ":" -f 1
}

# given a line number, a file and a pattern, return the next line on which
# pattern occurs, or nothing if there is no match
find_next_pattern() {
  local start=$1 file=$2 pattern=$3 relative

  relative=$(sed -n "$start,\$p" "$file" | grep -E "$pattern" -m 1 -n | line_number)

  [ -n "$relative" ] && echo "$((start + relative - 1))"
}

# call find_next_pattern with code black starting pattern
find_next_block_start() {
  local start=$1 file=$2

  find_next_pattern "$start" "$file" '^[[:space:]]*```'"$L_PATTERN"'[[:space:]]*$'
}

# call find_next_pattern with code black ending pattern
find_next_block_end() {
  local start=$1 file=$2

  find_next_pattern "$start" "$file" '^[[:space:]]*```[[:space:]]*$'
}

# call find_next_pattern with error pattern
find_next_error() {
  local start=$1 file=$2

  find_next_pattern "$start" "$file" "$ERROR_PATTERN"
}

# print file contents between two line number, inclusively
print_between() {
  local start=$1 end=$2 file=$3
  sed -n "${start},${end}p" "$file"
}

print_between_non_inclusive() {
  local start=$1 end=$2 file=$3
  start=$((start + 1))
  end=$((end - 1))

  print_between "$start" "$end" "$file"
}

# format stdin with prettier
format() {
  local parser=$1
  shift
  prettier --parser "$parser" --print-width 200 "$@"
}

remove_indent() {
  local indent=$1
  sed "s/^${indent}//"
}

prepend_indent() {
  local indent=$1
  sed "s/^/${indent}/"
}

get_block_language() {
  local line=$1 file=$2
  sed "${line}q;d" "$file" | cut -d '`' -f 4 | xargs
}

language_to_parser() {
  local language=$1
  case $language in
    javascript)
      echo "babel"
      ;;
    *)
      echo "$language"
      ;;
  esac
}

get_parser() {
  local line=$1 file=$2
  language_to_parser "$(get_block_language "$line" "$file")"
}

# given a starting line number and file, attempt to format the contents of the
# next code block
handle_block() {
  local start=$1 file=$2 blockstart blockend indent parser

  blockstart=$(find_next_block_start "$start" "$file")
  blockend=$(find_next_block_end "$start" "$file")

  indent=$(sed "${blockstart}q;d" "$file" | grep -o '^[[:space:]]*')

  parser=$(get_parser "$blockstart" "$file")

  print_block() {
    print_between_non_inclusive "$blockstart" "$blockend" "$file"
  }

  format_block() {
    print_block | remove_indent "$indent" | format "$parser" "$@"
  }

  block_has_error() {
    print_block | grep "$ERROR_PATTERN" >/dev/null 2>&1
  }

  prettier_can_handle_block() {
    format_block > /dev/null 2>&1
  }

  block_is_properly_formatted() {
    format_block --check >/dev/null 2>&1
  }

  update_block() {
    format_block | prepend_indent "$indent" > formatted
    write_to_block "$blockstart" "$blockend" "$file" formatted
    write_result "CHANGED"
  }

  write_result() {
    echo "Block at $blockstart: $1"
  }

  write_error_to_block() {
    2>&1 format_block | head -1 > error
    sed -i.bak "${blockstart}r error" "$file"

    write_result "ERROR"
    rm "$file".bak
    rm error
  }

  if prettier_can_handle_block; then
    if block_is_properly_formatted; then
      write_result "OK"
      return
    fi
    update_block
    return
  fi

  if block_has_error; then
    write_result "SKIPPING (has error)"
    return
  fi
  write_error_to_block
}

# given a starting line number and a file, edit the next code block using
# $EDITOR
edit_block() {
  local start=$1 file=$2 blockstart blockend tmpfile editor=${EDITOR:-vim}

  if [ "$editor" = "vim" ] || [ "$editor" = "nvim" ]; then
    edit() {
      "$editor" +'set ft=yaml' "$1"
    }
  else
    edit() {
      "$editor" "$1"
    }
  fi

  blockstart=$(find_next_block_start "$start" "$file")
  blockend=$(find_next_block_end "$start" "$file")

  tmpfile=$(mktemp)

  print_between_non_inclusive "$blockstart" "$blockend" "$file" > "$tmpfile"

  edit "$tmpfile"

  write_to_block "$blockstart" "$blockend" "$file" "$tmpfile"
}

# given boundaries of a codeblock, a target file and a source file, overwrite
# the contents of the codeblock in the target file with the contents of the
# source file
write_to_block() {
  local blockstart=$1 blockend=$2 file=$3 fromfile=$4

  sed -i.bak "$((blockstart + 1)),$((blockend - 1))d" "$file"
  sed -i.bak "${blockstart}r $fromfile" "$file"
  rm "$file".bak
  rm "$fromfile"
}

# given a file, attempt to format all code blocks
format_file() {
  local file=$1 next
  next=$(find_next_block_start 1 "$file")

  while [ -n "$next" ]; do
    handle_block "$next" "$file"
    next=$(find_next_block_start "$((next + 1))" "$file")
  done
}

# given a file, allow user to edit each erronous code block and attempt to
# format again
process_errors() {
  local file=$1 next new_next blockstart
  next=$(find_next_error 1 "$file")

  while [ -n "$next" ]; do
    # [error] is inside the block
    blockstart=$((next - 1))
    edit_block "$blockstart" "$file"
    handle_block "$blockstart" "$file"
    new_next=$(find_next_error "$next" "$file")

    if [ "$new_next" = "$next" ]; then
      next=$(handle_persistent_error "$file" "$next" "$new_next")
    else
      next=$new_next
    fi
  done
}

# echo to stderr
echo_e() {
  echo "$@" >&2
}

# prompt user for how to proceed when a code block edit does not resolve an
# error and return $next based on the choice
handle_persistent_error() {
  local file=$1 next=$2 new_next=$3 blockstart choice
  local prompt_msg=" Edit again? [y/s/i/q] (yes/skip/ignore/quit) "
  local choice_regexp='([yY]|[sS]|[iI]|[qQ])'

  blockstart=$((next - 1))

  echo_e ">> Block at line $blockstart still has errors."

  read -p "$prompt_msg" -n 1 -r choice
  echo_e
  while [[ ! $choice =~ $choice_regexp ]]; do
    echo_e "Please type y or s or i or q"
    read -p "$prompt_msg" -n 1 -r choice
    echo_e
  done

  case $choice in
    [yY])
      next=$new_next
      ;;
    [nS])
      next=$(find_next_error "$((new_next + 1))" "$file")
      ;;
    [iI])
      sed -i.bak "${next}d" "$file" && rm "${file}.bak"
      next=$(find_next_error "$next" "$file")
      ;;
    [qQ])
      exit 0
      ;;
    *)
      echo_e "Invalid choice: $choice"
      exit 1
      ;;
  esac
  echo "$next"
}

# get number of code blocks in file
num_blocks() {
  grep -E '^[[:space:]]*```'"$L_PATTERN"'[[:space:]]*$' "$1" -c
}

# get number of erronous code blocks in file
num_errors() {
  grep '\[error\] stdin:' "$1" -c
}

# given a list of files, format the code blocks within them
process_files() {
  local files=$1 blocks

  for file in $files; do
    blocks=$(num_blocks "$file")
    if [ "$blocks" != 0 ]; then
      echo "About to format $file with $blocks code blocks"
      format_file "$file"
    fi
  done
}

# given a list of files, process erronous code blocks within them
process_files_errors() {
  local files=$1
  for file in $files; do
    if [ "$(num_errors "$file")" -gt 0 ]; then
      echo "About to process $(num_errors "$file") errors in $file"
      read -p "OK?" -r
      process_errors "$file"
    fi
  done
}

# given a path, find matching files
find_files() {
  local pattern='*.md'
  if [ -d "$SEARCHPATH" ]; then
    find "$SEARCHPATH" -type f -name "$pattern"
  elif [ -f "$SEARCHPATH" ]; then
    echo "$SEARCHPATH"
  else
    echo "Bad path: $SEARCHPATH"
    exit 1
  fi
}

find_and_format_files() {
  local files
  files=$(find_files)
  process_files "$files"


  echo "Done!"
}

find_and_format_errors() {
  local files errors
  files=$(find_files)

  errors=$(grep -Ec "$ERROR_PATTERN" $files | grep -v ':0$')

  if [ -z "$errors" ] || [ "$errors" = 0 ]; then
    echo "No errors to fix"
    return 0
  fi

  echo "Errors:"
  echo "$errors"

  process_files_errors "$files"
}

analyze() {
  echo "To be implemented"
}

setup

[ -z "$CMD" ] && echo "No command specified, see ${0##*/} -h" && exit 1

case $CMD in
  format)
    find_and_format_files "$@"
    ;;
  fix)
    find_and_format_errors "$@"
    ;;
  analyze)
    analyze "$@"
    ;;
  *)
    echo "Invalid command: $CMD"
    echo "See ${0##*/} -h"
    exit 1
    ;;
esac
