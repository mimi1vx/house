#!/bin/sh
# Fail when a Makefile *-check gate has no home in CI or vice versa.
# Scans Makefile check recipes plus workflow run: text, so a reformatted
# run: block still counts as long as it names `make <target>`.
# Transitive coverage: rust-abi-check via rust-check, house-vm-check via
# vm-check, smp-check via smp-check-8 (which calls it with SMP_N=8).
set -eu
cd "$(dirname "$0")/.."

ALL=$(grep -oE '^[a-z0-9-]+-check:' Makefile | tr -d ':' | sort -u)
FROM_MAKE=$(grep -oE '\$\(MAKE\) [a-z0-9-]+-check' Makefile | awk '{print $2}' | sort -u)
FROM_WORKFLOWS=$(grep -hoE 'make [a-z0-9-]+-check(-8)?' .github/workflows/check.yml .github/workflows/nightly.yml 2>/dev/null | awk '{print $2}' | sed 's/^make //' | sort -u || true)
COVERED_FMT=$(printf '%s\n%s\n' "$FROM_MAKE" "$FROM_WORKFLOWS" | sort -u)

# Expand transitive aliases into the covered set.
COVERED="$COVERED_FMT"
case "$COVERED" in
*rust-check*) COVERED=$(printf '%s\nrust-abi-check\n' "$COVERED" | sort -u) ;;
esac
case "$COVERED" in
*vm-check*) COVERED=$(printf '%s\nhouse-vm-check\n' "$COVERED" | sort -u) ;;
esac
case "$COVERED" in
*smp-check-8*) COVERED=$(printf '%s\nsmp-check\n' "$COVERED" | sort -u) ;;
esac
# `make check-tcg` in check.yml covers every check-tcg leg.
case "$COVERED" in
*check-tcg*) COVERED=$(printf '%s\n%s\n' "$COVERED" "$FROM_MAKE" | sort -u) ;;
esac

fail=0
for t in $ALL; do
	if ! printf '%s\n' "$COVERED" | grep -qx "$t"; then
		echo "gate-coverage: $t has no home in check/check-tcg/nightly.yml" >&2
		fail=1
	fi
done

# Inverse: a workflow leg naming a target that does not exist rots green.
for t in $FROM_WORKFLOWS; do
	case "$t" in
	check-tcg | check) continue ;;
	*-check-8)
		base=$(printf '%s' "$t" | sed 's/-8$//')
		if ! printf '%s\n' "$ALL" | grep -qx "$base"; then
			# smp-check-8 wraps smp-check; allow it when the base exists.
			echo "gate-coverage: nightly names $t with no Makefile target" >&2
			fail=1
		fi
		continue
		;;
	esac
	if ! printf '%s\n' "$ALL" | grep -qx "$t"; then
		echo "gate-coverage: workflow names missing target $t" >&2
		fail=1
	fi
done

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "gate-coverage: ok"
