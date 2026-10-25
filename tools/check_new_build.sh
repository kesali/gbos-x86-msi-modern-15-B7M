#!/bin/sh
# check_new_build.sh: is there a newer Googlebook OS (lapis, x86) build than the one in lapis/BUILD?
#
#   1. asks dl.google.com whether the pinned recovery.zip is still served (size compared with the sha file's record);
#   2. scrapes build ids from a third-party index (aluminium-os.com, same board page) and from cros.tech's version table;
#      neither is Google, both can lag or change layout, so treat "nothing newer" as "nothing newer that they list";
#   3. with an id as argument (a build you heard about), probes dl.google.com/.../lapis-user/<id>/recovery.zip directly.
# Prints what it found and, for a newer build, the exact steps from porting.md. Downloads nothing but headers and two HTML pages.
#   tools/check_new_build.sh [BUILD_ID]
. "$(dirname "$0")/../lapis/BUILD"
UA="gbos86-check/1"
head_of() { curl -sIL -A "$UA" --max-time 20 "$1" 2>/dev/null; }
echo "pinned: $BOARD $BUILD_ID ($VERSION)"
H=$(head_of "$URL")
case $(printf '%s' "$H" | head -1) in *200*) echo "  still served: $(printf '%s' "$H" | grep -i '^content-length\|^x-identity-content-length' | tr -d '\r' | tr '\n' ' ')";; *) echo "  NOT served any more (or no network): $(printf '%s' "$H" | head -1 | tr -d '\r')";; esac
echo "listed elsewhere:"
for src in "https://aluminium-os.com/googlebookos/googlebook-lapis/" "https://aluminium-os.com/googlebookos/"; do
  curl -s -A "$UA" --max-time 25 "$src" 2>/dev/null | grep -oE '(lapis-user/[0-9]+|[0-9]{7,9}_CL[0-9A-Z]+\.[0-9]+\.[0-9]+\.R[0-9]+)' | sort -u | sed "s#^#  $src: #"
done
curl -s -A "$UA" --max-time 25 "https://cros.tech/googlebooks/" 2>/dev/null | tr '<>' '\n\n' | grep -E 'lapis|CL[0-9A-Z]+\.[0-9]+\.[0-9]+\.R[0-9]+' | head -4 | sed 's/^/  cros.tech: /'
NEWER=
if [ -n "$1" ]; then
  U="https://dl.google.com/device/recovery/lapis-user/$1/recovery.zip"
  case $(head_of "$U" | head -1) in *200*) echo "build $1 EXISTS at $U"; [ "$1" != "$BUILD_ID" ] && NEWER=$1;; *) echo "build $1: not served";; esac
fi
# aluminium-os.com answers 403 to curl at times, so cros.tech's page (its "Latest recovery image" row carries lapis-user/<id>) is read as well
IDS=$( { curl -s -A "$UA" --max-time 25 "https://aluminium-os.com/googlebookos/googlebook-lapis/" 2>/dev/null; curl -s -A "$UA" --max-time 25 "https://cros.tech/googlebook/lapis/" 2>/dev/null; } | grep -oE 'lapis-user/[0-9]+' | sed 's#.*/##' | sort -u)
for i in $IDS; do [ "$i" -gt "$BUILD_ID" ] 2>/dev/null && NEWER="$NEWER $i"; done
if [ -n "$NEWER" ]; then
  echo; echo "NEWER build(s): $NEWER"
  echo "  1. edit lapis/BUILD (BUILD_ID, VERSION, URL) and ./build.sh  -> new lapis/parts"
  echo "  2. tools/port_build.sh --isa            (dry run: patches, anchors, instruction scan)"
  echo "  3. tools/port_build.sh --write --product; sh tools/test_port_scripts.sh"
  echo "  see porting.md"
else
  echo; echo "no build newer than $BUILD_ID found"
fi
