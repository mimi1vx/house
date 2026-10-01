#!/bin/sh
# Report which clippy lints fire per file once blanket allows are stripped.
# Copies the workspace to a scratch dir so the working tree stays untouched.
set -eu
cd "$(dirname "$0")/.."
SCRATCH=${TMPDIR:-/tmp}/house-clippy-inventory-$$
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
cp -a rust "$SCRATCH/rust"
cp -a rust-toolchain.toml "$SCRATCH/" 2>/dev/null || true
grep -rl 'allow(clippy::all)' "$SCRATCH/rust/crates" --include='*.rs' | while read -r f; do
  sed -i '/allow(clippy::all)/d' "$f"
done
echo "stripped; remaining blanket allows:"
grep -rn 'allow(clippy::all)' "$SCRATCH/rust/crates" --include='*.rs' || echo "(none left)"
RUNNER=${RUNNER:-container}
$RUNNER run --platform linux/arm64 --rm -v "$SCRATCH":/tmp/inv -v house-target:/tmp/inv/rust/target -v house-cargo:/cargo-home -e CARGO_HOME=/cargo-home -w /tmp/inv house-port:latest bash -c '
set -eu
cargo clippy --manifest-path rust/Cargo.toml --target aarch64-unknown-none --message-format=json 2>/tmp/stderr.txt > /tmp/out.json || true
python3 -c "
import json,collections
files=collections.defaultdict(set)
for line in open(\"/tmp/out.json\"):
  try: m=json.loads(line)
  except: continue
  if m.get(\"reason\")!=\"compiler-message\": continue
  code=(m.get(\"message\",{}).get(\"code\") or {}).get(\"code\")
  if not code or not code.startswith(\"clippy::\"): continue
  spans=m.get(\"message\",{}).get(\"spans\",[])
  fn=spans[0].get(\"file_name\",\"?\") if spans else \"?\"
  files[fn].add(code)
for fn in sorted(files):
  print(fn+\": \"+\", \".join(sorted(files[fn])))
"
'
rm -rf "$SCRATCH"
