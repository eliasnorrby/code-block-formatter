#!/usr/bin/env bash

# file=$1

# get line number from grep ouput
line_number() {
  cut -d ":" -f 1
}

# get list of line numbers where yaml code blocks start
# start_lines() {
#   grep -E '^```ya?ml' "$1" -n | line_number
# }

find_next_pattern() {
  local start=$1 file=$2 pattern=$3 relative

  relative=$(sed -n "$start,\$p" "$file" | grep -E "$pattern" -m 1 -n | line_number)

  [ -n "$relative" ] && echo "$((start + relative - 1))"
}

find_next_block_start() {
  local start=$1 file=$2

  find_next_pattern "$start" "$file" '^[[:space:]]*```ya?ml[[:space:]]*$'
}

find_next_block_end() {
  local start=$1 file=$2

  find_next_pattern "$start" "$file" '^[[:space:]]*```[[:space:]]*$'
}

find_next_error() {
  local start=$1 file=$2

  find_next_pattern "$start" "$file" '^\[error\] stdin:'
}

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

format() {
  prettier --parser yaml --print-width 200 "$@"
}

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

write_to_block() {
  local blockstart=$1 blockend=$2 file=$3 fromfile=$4

  sed -i.bak "$((blockstart + 1)),$((blockend - 1))d" "$file"
  sed -i.bak "${blockstart}r $fromfile" "$file"
  rm "$file".bak
  rm "$fromfile"
}

format_file() {
  local file=$1 next
  next=$(find_next_block_start 1 "$file")

  while [ -n "$next" ]; do
    update_block "$next" "$file"
    next=$(find_next_block_start "$((next + 1))" "$file")
  done
}

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
      echo ">> Block at line $blockstart still has errors."

      local prompt_msg=" Edit again? [y/s/i/q] (yes/skip/ignore/quit)"
      local choice
      read -p "$prompt_msg" -n 1 -r choice
      echo
      local choice_regexp='([yY]|[sS]|[iI]|[qQ])'
      while [[ ! $choice =~ $choice_regexp ]]; do
        echo "Please type y or s or i or q"
        read -p "$prompt_msg" -n 1 -r choice
        echo
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
          echo "Invalid choice: $choice"
          exit 1
          ;;
      esac
    else
      next=$new_next
    fi
  done
}

num_blocks() {
  grep -E '^[[:space:]]*```ya?ml[[:space:]]*$' "$1" -c
}

num_errors() {
  grep '\[error\] stdin:' "$1" -c
}

process_files() {
  local files=$1

  for file in $files; do
    echo "About to format $file with $(num_blocks "$file") yaml blocks"
    # read -p "Enter to continue" -r
    format_file "$file"
  done
}

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

find_files() {
  local searchpath=$1 pattern=$2
  find "$searchpath" -type f -name "$pattern"
}

main() {
  local searchpath=${1:-.} pattern=${2:-'*.md'} files
  files=$(find_files "$searchpath" "$pattern")
  process_files "$files"

  echo "Errors:"

  grep -rc '\[error\] stdin:' . | grep -v ':0$'

  read -p "Process errors?" -r

  process_files_errors "$files"

  echo "Done!"
}

main "$@"
