#!/bin/sh
# fsdb2vcd.sh - thin wrapper around Verdi's fsdb2vcd / fsdb2vcd64 converter.
#
# This wrapper ONLY converts FSDB -> VCD. It does NOT slice by time or scope.
#
# To cut a large FSDB down first, use fsdbextract.sh (FSDB -> FSDB, the Realtek
# Verdi FAQ "FsdbExtraction" path), THEN convert the small slice here:
#   1) sh fsdbextract.sh top.fsdb -bt 100ns -et 200ns -s /tb/dut -level 0 -o slice.fsdb +grid
#   2) sh fsdb2vcd.sh    slice.fsdb -o slice.vcd
#   3) python3 compare.py slice.vcd --clk ... --sig ... golden.hex --t0 N --t1 N
# Slicing in the FSDB domain keeps the data compressed, so this step unpacks
# only the small window instead of the whole waveform (a full FSDB->VCD can
# blow up ~8x; see DEPLOYMENT_GUIDE.md #1).
#
# fsdb2vcd is a Verdi (Synopsys) utility, NOT a vcs command and NOT the Verdi
# GUI. It runs directly in the shell. Requires a Verdi install on PATH.
#
# Usage:
#   ./fsdb2vcd.sh input.fsdb [output.vcd]      # convert
#   ./fsdb2vcd.sh input.fsdb -o out.vcd        # convert (explicit output)
#
# Default output: <input-basename>.vcd (in current directory).
# Run 'fsdb2vcd -l input.fsdb' first to inspect scopes/timescale.
#
# If you only need VCD for inspection, you usually do NOT need this at all:
# add `$dumpfile("dump.vcd"); $dumpvars(0, tb);` to the testbench and compile
# with `vcs -debug_access+all` to get VCD natively (no Verdi license needed).

set -e

_usage() {
    cat >&2 <<'EOF'
Usage:  fsdb2vcd.sh <input.fsdb> [-o <output.vcd> | <output.vcd>]

Converts FSDB -> VCD (no slicing).

Positional:
  input.fsdb           FSDB file to convert
  output.vcd           (optional) output VCD file

Options:
  -o <file>            output VCD path (overrides positional)
  --help               show this message

To slice by TIME or SCOPE, extract FIRST, then convert:
  sh fsdbextract.sh in.fsdb -bt 100ns -et 200ns -s /tb/dut -level 0 -o slice.fsdb +grid
  sh fsdb2vcd.sh    slice.fsdb -o slice.vcd

Environment:
  fsdb2vcd64 or fsdb2vcd must be on PATH (Verdi installation).
EOF
}

# ─────────────────────────────────────────────────────────────
#  parse arguments
# ─────────────────────────────────────────────────────────────

IN=""
OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        -o)
            shift; OUT="$1"
            ;;
        --bt|--et|--scope|-bt|-et|-s)
            # Slicing is NOT this tool's job. Redirect to the correct path
            # instead of silently passing unverified flags to the converter.
            echo "ERROR: fsdb2vcd.sh does not slice by time/scope ('$1')." >&2
            echo "       Slice the FSDB FIRST with fsdbextract.sh, then convert:" >&2
            echo "         sh fsdbextract.sh <in.fsdb> -bt <t>ns -et <t>ns -s /scope -level 0 -o slice.fsdb +grid" >&2
            echo "         sh fsdb2vcd.sh    slice.fsdb -o slice.vcd" >&2
            echo "       (run 'fsdbextract' with no args, or 'sh fsdbextract.sh -h', for full options)" >&2
            exit 2
            ;;
        --help|-h)
            _usage; exit 0
            ;;
        --*|-*)
            echo "ERROR: unknown option '$1'" >&2
            _usage; exit 2
            ;;
        *)
            if [ -z "$IN" ]; then
                IN="$1"
            elif [ -z "$OUT" ]; then
                OUT="$1"
            else
                echo "ERROR: unexpected positional '$1'" >&2
                _usage; exit 2
            fi
            ;;
    esac
    shift
done

if [ -z "$IN" ]; then
    echo "ERROR: no input FSDB specified." >&2
    _usage; exit 2
fi

# Default output path: strip .fsdb, append .vcd, always in CWD for clarity.
if [ -z "$OUT" ]; then
    OUT="$(basename "$IN" .fsdb).vcd"
fi

# ─────────────────────────────────────────────────────────────
#  locate binary
# ─────────────────────────────────────────────────────────────

# Prefer fsdb2vcd64 for large files; fall back to fsdb2vcd.
BIN="$(command -v fsdb2vcd64 || command -v fsdb2vcd || true)"

if [ -z "$BIN" ]; then
    echo "ERROR: fsdb2vcd not found on PATH." >&2
    echo "       Set up Verdi first, e.g.:" >&2
    echo "         export VERDI_HOME=/tools/synopsys/verdi/<ver>" >&2
    echo "         export PATH=\$VERDI_HOME/bin:\$PATH" >&2
    echo "       (or 'module load verdi' per your CAD environment)" >&2
    exit 127
fi

# ─────────────────────────────────────────────────────────────
#  exec  (pure convert: positional + -o, no slicing flags)
# ─────────────────────────────────────────────────────────────

echo "[fsdb2vcd] $BIN $IN -o $OUT" >&2
"$BIN" "$IN" -o "$OUT"
echo "[fsdb2vcd] wrote $OUT" >&2
