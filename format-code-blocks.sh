#!/usr/bin/env bash

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

  find_next_pattern "$start" "$file" '^[[:space:]]*```ya?ml[[:space:]]*$'
}

# call find_next_pattern with code black ending pattern
find_next_block_end() {
  local start=$1 file=$2

  find_next_pattern "$start" "$file" '^[[:space:]]*```[[:space:]]*$'
}

# call find_next_pattern with error pattern
find_next_error() {
  local start=$1 file=$2

  find_next_pattern "$start" "$file" '^\[error\] stdin:'
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
  prettier --parser yaml --print-width 200 "$@"
}

# format stdin with ruamel.yaml
format_ruamel() {
  python -c 'import sys;from ruamel.yaml import YAML;yaml=YAML();yaml.dump(yaml.load(sys.stdin),sys.stdout)'
}

remove_indent() {
  local indent=$1
  sed "s/^${indent}//"
}

prepend_indent() {
  local indent=$1
  sed "s/^/${indent}/"
}

# given a starting line number and file, attempt to format the contents of the
# next code block
update_block() {
  local start=$1 file=$2 blockstart blockend indent

  blockstart=$(find_next_block_start "$start" "$file")
  blockend=$(find_next_block_end "$start" "$file")

  indent=$(sed "${blockstart}q;d" "$file" | grep -o '^[[:space:]]*')

  format_block() {
    print_between_non_inclusive "$blockstart" "$blockend" "$file" | remove_indent "$indent" | format "$@"
  }

  format_block_ruamel() {
    print_between_non_inclusive "$blockstart" "$blockend" "$file" | format_ruamel
  }

  format_check() {
    format_block --check
  }

  if format_block > /dev/null 2>&1; then
    if format_check > /dev/null 2>&1; then
      echo "Block at $blockstart: OK"
      return
    fi

    format_block | prepend_indent "$indent" > formatted
    # format_block_ruamel > formatted

    write_to_block "$blockstart" "$blockend" "$file" formatted

    echo "Block at $blockstart: CHANGED"
    return
  fi

  2>&1 format_block | head -1 > error
  sed -i.bak "${blockstart}r error" "$file"

  echo "Block at $blockstart: ERROR"
  rm "$file".bak
  rm error
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
    update_block "$next" "$file"
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
    update_block "$blockstart" "$file"
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
  grep -E '^[[:space:]]*```ya?ml[[:space:]]*$' "$1" -c
}

# get number of erronous code blocks in file
num_errors() {
  grep '\[error\] stdin:' "$1" -c
}

# given a list of files, format the code blocks within them
process_files() {
  local files=$1

  for file in $files; do
    echo "About to format $file with $(num_blocks "$file") yaml blocks"
    # read -p "Enter to continue" -r
    format_file "$file"
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

# given a path and a pattern, find matching files
find_files() {
  local searchpath=$1 pattern=$2
  find "$searchpath" -type f -name "$pattern"
}

find_and_format_files() {
  local searchpath=${1:-.} pattern=${2:-'*.md'} files
  files=$(find_files "$searchpath" "$pattern")
  process_files "$files"


  echo "Done!"
}

find_and_format_errors() {
  local searchpath=${1:-.} pattern=${2:-'*.md'} files errors
  files=$(find_files "$searchpath" "$pattern")

  errors=$(grep -c '\[error\] stdin:' $files | grep -v ':0$')

  [ -z "$errors" ] || [ "$errors" = 0 ] && return 0

  echo "Errors:"
  echo "$errors"

  process_files_errors "$files"
}

analyze() {
  echo "To be implemented"
}

cmd=$1
shift

case $cmd in
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
    echo "Invalid command: $cmd"
    echo "See ${0##*/} -h"
    exit 1
    ;;
esac
