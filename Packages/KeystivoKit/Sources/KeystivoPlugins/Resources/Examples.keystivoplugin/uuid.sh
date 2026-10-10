#!/bin/zsh
# "list" mode: print JSON {"items": [...]}; each item may carry an action.
print -n '{"items": ['
for i in 1 2 3 4 5; do
  id=$(uuidgen)
  [[ $i -gt 1 ]] && print -n ','
  print -n "{\"title\": \"$id\", \"subtitle\": \"Copy to clipboard\", \"icon\": \"doc.on.doc\", \"action\": {\"type\": \"copy\", \"value\": \"$id\"}}"
done
print ']}'
