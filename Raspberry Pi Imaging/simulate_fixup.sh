#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Pre-eject proof that the firstrun.sh boot chain will actually fire.
#
# WHY THIS EXISTS
#   Three provisioning attempts failed because files were verified as "present
#   and well-formed" without ever checking the system would ACT on them. This
#   harness replays the image's own initramfs fixup against your real files, so
#   a broken chain is caught while the card is still in the reader.
#
# USAGE
#   ./simulate_fixup.sh /d          # /d = mounted FAT32 boot partition (Git Bash)
#   ./simulate_fixup.sh /mnt/boot   # Linux
#
# Exit status 0 = chain verified, safe to eject. Non-zero = DO NOT BOOT.
# ---------------------------------------------------------------------------
set -uo pipefail

BOOT="${1:?usage: $0 <path-to-mounted-boot-partition>}"
CMDLINE="$BOOT/cmdline.txt"
FIRSTRUN="$BOOT/firstrun.sh"
FAIL=0

note() { printf '  %-58s %s\n' "$1" "$2"; }
bad()  { note "$1" "FAIL"; FAIL=1; }

echo "=== simulating initramfs fixup against $BOOT ==="
echo

for f in "$CMDLINE" "$FIRSTRUN"; do
  [ -f "$f" ] || { echo "MISSING: $f"; exit 2; }
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp "$CMDLINE"  "$TMP/cmdline.txt"
cp "$FIRSTRUN" "$TMP/firstrun.sh"

# --- 0. hygiene ------------------------------------------------------------
echo "0. file hygiene"
if [ "$(tr -dc '\r' < "$TMP/firstrun.sh" | wc -c)" -gt 0 ]; then bad "firstrun.sh has CRLF line endings"
else note "firstrun.sh is LF-only" "ok"; fi

if [ "$(wc -l < "$TMP/cmdline.txt")" -ne 1 ]; then bad "cmdline.txt must be exactly one line"
else note "cmdline.txt is a single line" "ok"; fi

if bash -n "$TMP/firstrun.sh" 2>/dev/null; then note "firstrun.sh parses as bash" "ok"
else bad "firstrun.sh has a syntax error"; fi

if [ "$(tail -1 "$TMP/firstrun.sh")" = "rm -f /boot/firstrun.sh" ]; then
  note "last line is 'rm -f /boot/firstrun.sh'" "ok"
else
  bad "last line MUST be 'rm -f /boot/firstrun.sh' (got: $(tail -1 "$TMP/firstrun.sh"))"
fi
echo

# --- 1. does the fixup trigger? -------------------------------------------
echo "1. fixup trigger (image greps /proc/cmdline for this exact string)"
if grep -q 'systemd\.run=/boot/firstrun\.sh' "$TMP/cmdline.txt"; then
  note "hook present as literal /boot/firstrun.sh" "ok"
else
  bad "hook absent or uses /boot/firmware/ - script will NEVER run"
fi
echo

# --- 2. replay the fixup's exact sed operations ---------------------------
echo "2. replaying fixup"
sed -i 's|/boot/|/boot/firmware/|g' "$TMP/cmdline.txt"
sed -n -i '/rm.*firstrun\.sh$/q;p'  "$TMP/firstrun.sh"
cat >> "$TMP/firstrun.sh" <<'EOF'
rm -f /boot/firmware/firstrun.sh
sed -i 's| systemd\.[^ ]*||g' /boot/firmware/cmdline.txt
exit 0
EOF

RESULT_PATH=$(grep -o 'systemd.run=[^ ]*' "$TMP/cmdline.txt" || true)
note "systemd.run resolves to" "${RESULT_PATH:-<none>}"
[ "$RESULT_PATH" = "systemd.run=/boot/firmware/firstrun.sh" ] || bad "unexpected post-fixup path"

ROOTARG=$(grep -o 'root=PARTUUID=[^ ]*' "$TMP/cmdline.txt" || true)
note "root= preserved as" "${ROOTARG:-<none>}"
[ -n "$ROOTARG" ] || bad "root= was lost by the fixup"
echo

# --- 3. post-fixup script still sane? -------------------------------------
echo "3. post-fixup script"
if bash -n "$TMP/firstrun.sh" 2>/dev/null; then note "still parses as bash" "ok"
else bad "post-fixup script has a syntax error"; fi

# The truncation cuts at /rm.*firstrun\.sh$/ - make sure it did not eat config.
for k in set_hostname userconf authorized_keys; do
  if grep -q "$k" "$TMP/firstrun.sh"; then note "survived truncation: $k" "ok"
  else bad "truncation removed: $k"; fi
done
grep -q 'systemctl enable ssh' "$TMP/firstrun.sh" && note "survived truncation: enable ssh" "ok" || bad "truncation removed: enable ssh"
echo

# --- 4. must not re-trigger on later boots --------------------------------
echo "4. idempotence"
if grep -q 'systemd\.run=/boot/firstrun\.sh' "$TMP/cmdline.txt"; then
  bad "would re-trigger the fixup on every boot"
else
  note "will not re-trigger" "ok"
fi
echo

# --- 5. leftovers that indicate a stale approach ---------------------------
echo "5. stale artefacts"
if [ -f "$BOOT/custom.toml" ]; then
  echo "  WARNING: custom.toml present. Trixie IGNORES it (0 references in rootfs)."
  echo "           Remove it - it will mislead the next person, not provision the Pi."
fi
echo

if [ "$FAIL" -eq 0 ]; then
  echo "=== CHAIN VERIFIED - safe to eject ==="
else
  echo "=== CHAIN BROKEN - DO NOT BOOT THIS CARD ==="
fi
exit "$FAIL"
