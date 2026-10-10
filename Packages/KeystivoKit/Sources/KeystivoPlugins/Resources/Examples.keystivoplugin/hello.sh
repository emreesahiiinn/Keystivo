#!/bin/zsh
# "silent" mode: the first line of stdout is shown as a confirmation.
name=${KEYSTIVO_QUERY:-there}
case "$KEYSTIVO_LANGUAGE" in
  tr) echo "Merhaba, $name! 👋" ;;
  de) echo "Hallo, $name! 👋" ;;
  *)  echo "Hello, $name! 👋" ;;
esac
