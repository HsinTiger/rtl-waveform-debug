#!/bin/sh
# fsdb2vcd.sh - thin wrapper around Verdi's fsdb2vcd / fsdb2vcd64 converter.
#
# Now with --bt (begin time), --et (end time), and --scope filtering support.
#
# fsdb2vcd is a Verdi (Synopsys) utility, NOT a vcs command and NOT the Verdi
# GUI. It runs directly in the shell. Requires a Verdi install on PATH.
#
# Usage:
#   ./fsdb2vcd.sh input.fsdb [output.vcd]          # full convert (backward compat)
#   ./fsdb2vcd.sh input.fsdb -o out.vcd --bt 100 --et 500   # time slice
#   ./fsdb2vcd.sh input.fsdb -o out.vcd --scope tb.dut.phy  # scope filter
#   ./fsdb2vcd.sh input.fsdb -o out.vcd \
#       --bt 2850 --et 3150 --scope tb.dut.phy_ud            # combined
#
# Time values are in FSDB timescale units (typically nanoseconds). The wrapper
# auto-strips common suffixes (ns/us/ps/ms) so --bt 100ns works the same as
# --bt 100.  Run 'fsdb2vcd -l input.fsdb' first to check the timescale.
#
# Default output: <input-basename>.vcd (in current directory).
#
# If you only need VCD for inspection, you usually do NOT need this at all:
# add `$dumpfile("dump.vcd"); $dumpvars(0, tb);` to the testbench and compile
# with `vcs -debug_access+all` to get VCD natively (no Verdi license needed).

set -e

# ─────────────────────────────────────────────────────────────
#  helpers
# ─────────────────────────────────────────────────────────────

# Strip common time-unit suffixes so --bt 100ns and --bt 100 behave identically.
_strip_suffix() {
    printf '%s' "$1" | sed 's/[nNuUpPmM][sS]\{0,1\}$//'
}

_usage() {
    cat >&2 <<'EOF'
Usage:  fsdb2vcd.sh <input.fsdb> [options]

Positional:
  input.fsdb           FSDB file to convert
  output.vcd           (optional, after input) output VCD file

Options:
  -o <file>            output VCD path (overrides positional)
  --bt <time>          begin time (FSDB timescale units; "100ns" → "100")
  --et <time>          end time   (FSDB timescale units)
  --scope <path>       only convert signals under this hierarchy scope
                       (can be repeated for multiple scopes)
  --help               show this message

Backward-compatible:
  fsdb2vcd.sh input.fsdb [output.vcd]

Environment:
  fsdb2vcd64 or fsdb2vcd must be on PATH (Verdi installation).
EOF
}

# ─────────────────────────────────────────────────────────────
#  locate binary
# ─────────────────────────────────────────────────────────────

# Prefer fsdb2vcd64 for large files; fall back to fsdb2vcd.
BIN="$(command -v fsdb2vcd64 || command -v fsdb2vcd || true)"
BIN_BASENAME="$(basename "${BIN:-unknown}")"

if [ -z "$BIN" ]; then
    echo "ERROR: fsdb2vcd not found on PATH." >&2
    echo "       Set up Verdi first, e.g.:" >&2
    echo "         export VERDI_HOME=/tools/synopsys/verdi/<ver>" >&2
    echo "         export PATH=\$VERDI_HOME/bin:\$PATH" >&2
    echo "       (or 'module load verdi' per your CAD environment)" >&2
    exit 127
fi

# Detect the fast variant from the GTKWave contrib, which lacks time/scope options.
IS_FAST=0
case "$BIN_BASENAME" in
    *fast*) IS_FAST=1 ;;
esac

# ─────────────────────────────────────────────────────────────
#  parse arguments
# ─────────────────────────────────────────────────────────────

IN=""
OUT=""
BT=""
ET=""
SCOPES=""       # space-separated -s args for the Verdi binary
USAGE_ERR=0

while [ $# -gt 0 ]; do
    case "$1" in
        --bt)
            shift; BT="$(_strip_suffix "$1")"
            ;;
        --et)
            shift; ET="$(_strip_suffix "$1")"
            ;;
        --scope)
            shift; SCOPES="$SCOPES -s $1"
            ;;
        -o)
            shift; OUT="$1"
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
#  build the command
# ─────────────────────────────────────────────────────────────

if [ "$IS_FAST" = 1 ]; then
    # fsdb2vcd_fast (GTKWave contrib): positional only, no -o, no flags.
    if [ -n "$BT" ] || [ -n "$ET" ] || [ -n "$SCOPES" ]; then
        echo "WARNING: '$BIN_BASENAME' (the GTKWave 'fast' variant) does NOT support" >&2
        echo "         --bt/--et/--scope. These flags will be IGNORED." >&2
        echo "         To use them, set PATH to the Verdi-shipped fsdb2vcd instead." >&2
    fi
    set -- "$BIN" "$IN" "$OUT"
else
    # Standard Verdi fsdb2vcd / fsdb2vcd64.
    set -- "$BIN" "$IN" -o "$OUT"
    if [ -n "$BT" ]; then set -- "$@" -bt "$BT"; fi
    if [ -n "$ET" ]; then set -- "$@" -et "$ET"; fi
    if [ -n "$SCOPES" ]; then set -- "$@" $SCOPES; fi
fi

# ─────────────────────────────────────────────────────────────
#  exec
# ─────────────────────────────────────────────────────────────

echo "[fsdb2vcd] $*" >&2
"$@"
echo "[fsdb2vcd] wrote $OUT" >&2
