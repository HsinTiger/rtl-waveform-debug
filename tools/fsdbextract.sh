#!/bin/sh
# fsdbextract.sh - thin wrapper around Verdi's fsdbextract (FSDB -> FSDB slicer).
#
# This is the CORRECT first step to cut a large FSDB down by time and/or scope,
# per the Realtek Verdi FAQ (FsdbExtraction). It slices in the FSDB domain
# (data stays compressed), so the subsequent fsdb2vcd unpacks only the small
# slice into VCD instead of the whole waveform. Slicing inside fsdb2vcd is NOT
# the supported path here -- always extract first, then convert.
#
# Pipeline (the right order):
#   1) sh fsdbextract.sh top.fsdb -bt 100ns -et 200ns -s /tb/dut -level 0 -o slice.fsdb +grid
#   2) sh fsdb2vcd.sh slice.fsdb -o slice.vcd
#   3) python3 compare.py slice.vcd --clk ... --sig ... golden.hex --t0 N --t1 N
#
# fsdbextract OPTIONS (Synopsys Verdi; this wrapper passes them through verbatim
# -- run `fsdbextract` with no args to see the binary's own help):
#   -bt <time><unit>     begin time, e.g. -bt 100ns   (UNIT REQUIRED -- unlike vcd.py)
#   -et <time><unit>     end time,   e.g. -et 200ns
#   -time_shift <t><u>   shift the time axis, e.g. -time_shift -100ns (= left 100ns)
#   -s <hier_path>       scope/signal, SLASH-separated: /tb/dut/sig  (NOT dotted)
#   -level 0|1|2         (must follow -s) 0=scope and everything below it,
#                        1=signals in scope (default), 2=scope + one level down
#   -o <file.fsdb>       output FSDB
#   +grid                run the job on the grid (recommended -- avoids OOM fails)
#
# "No match" with special chars in the path (e.g. bus bits like u1[0]):
#   - put 7 backslashes before each special char:
#       /test/u1[0]  ->  /test/u1\\\\\\\[0\\\\\\\]
#   - and wrap the whole path in escaped double quotes:
#       \"/test/u1\\\\\\\[0\\\\\\\]\"
#   This wrapper does NOT auto-escape (escaping is fragile) -- apply it yourself.
#
# Examples:
#   sh fsdbextract.sh original.fsdb -bt 100ns -et 200ns -o slice_time.fsdb +grid
#   sh fsdbextract.sh original.fsdb -s /tb/dut/phy_ud -level 0 -o slice_scope.fsdb +grid
#   sh fsdbextract.sh original.fsdb -bt 2850ns -et 3150ns -s /tb/dut -level 0 -o slice.fsdb +grid

set -e

_usage() {
    cat >&2 <<'EOF'
Usage:  fsdbextract.sh <input.fsdb> [options] -o <output.fsdb>

Cut a large FSDB by TIME and/or SCOPE (FSDB -> FSDB). Run this BEFORE fsdb2vcd.

Common options (passed straight through to Verdi's fsdbextract):
  -bt <t><unit>          begin time   (e.g. -bt 100ns ; UNIT REQUIRED)
  -et <t><unit>          end time     (e.g. -et 200ns)
  -time_shift <t><unit>  shift time axis (e.g. -time_shift -100ns = left 100ns)
  -s <hier>              scope/signal path, SLASH-separated (e.g. /tb/dut/phy_ud)
  -level 0|1|2           detail under -s (0=all below, 1=in-scope default, 2=+1 level)
  -o <out.fsdb>          output FSDB
  +grid                  run on the grid (recommended)

Special chars in a path (bus bits etc.) cause "No match": prefix each with 7
backslashes and wrap the path in escaped quotes -- see the header of this file.

Then convert the slice:  sh fsdb2vcd.sh <out.fsdb> -o <out.vcd>
EOF
}

# No args, or help requested -> show usage. (Verdi's own help also works: just
# run `fsdbextract` with no args.)
case "${1:-}" in
    ""|--help|-h|-help) _usage; exit 0 ;;
esac

BIN="$(command -v fsdbextract || true)"
if [ -z "$BIN" ]; then
    echo "ERROR: fsdbextract not found on PATH." >&2
    echo "       Set up Verdi first, e.g.:" >&2
    echo "         export VERDI_HOME=/tools/synopsys/verdi/<ver>" >&2
    echo "         export PATH=\$VERDI_HOME/bin:\$PATH" >&2
    echo "       (or 'module load verdi' per your CAD environment)" >&2
    echo "       Tip: 'fsdb2vcd -l <file.fsdb>' lists scopes to feed -s." >&2
    exit 127
fi

# Pass everything through verbatim so any backslash/quote escaping you applied
# for special-char paths is preserved. fsdbextract prints its own progress
# (and, with +grid, submits the job and returns).
echo "[fsdbextract] $BIN $*" >&2
exec "$BIN" "$@"
