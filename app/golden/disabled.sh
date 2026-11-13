#!/system/bin/sh
# crusty: does nothing on purpose, this stub gets put in place of crestrons golden mode scripts.
# their versions (kept as <name>.crestron next to it) reformat SD partitions / reflash the internal eMMC, no thanks. see app/golden/crestInit.sh.
log -t crusty "golden: $0 $* skipped (crusty disabled it)"
exit 0
