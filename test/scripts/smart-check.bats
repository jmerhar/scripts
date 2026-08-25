#!/usr/bin/env bats
#
# smart-check reads disks, so the failure that matters is a wrong verdict: a fleet reported as healthy
# because the data was never actually read, or a failing drive passed over because its attribute was not
# on some list. The findings logic is therefore tested against documents shaped exactly as smartctl emits
# them, including the two cases measured on real hardware — a device type that returns a document with
# nothing in it, and an exit status that is non-zero precisely because a disk is failing.
#
# smartctl is a double written here rather than a shared stub: it answers per device, and the privilege
# escalation has to pass its output back rather than swallow it.

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/system/smart-check/smart-check.sh"

  CONFIG_FILE="$BATS_TEST_TMPDIR/smart.conf"
  export CONFIG_FILE
  : > "$CONFIG_FILE"

  SMARTCTL_BIN="$BATS_TEST_TMPDIR/smartctl-double"
  SUDO_BIN="$BATS_TEST_TMPDIR/sudo-passthrough"
  export SMARTCTL_BIN SUDO_BIN
  printf '#!/usr/bin/env bash\nexec "$@"\n' > "$SUDO_BIN"
  chmod +x "$SUDO_BIN"
  DOCS="$BATS_TEST_TMPDIR/docs"
  mkdir -p "$DOCS"
  smartctl_double
}

########################################
# Writes the smartctl double: --scan lists whatever scan file says, and a device query prints the
# document filed under its name, or nothing when there is none.
#
# Exits 4 after printing, which is what smartctl does when a disk is failing — the status must not be
# read as evidence that the read failed.
########################################
smartctl_double() {
  cat > "$SMARTCTL_BIN" <<EOF
#!/usr/bin/env bash
printf 'smartctl %s\n' "\$*" >> "$STUB_CALLS"
if [[ "\$*" == *--scan* ]]; then
  [[ -f "$DOCS/scan" ]] && cat "$DOCS/scan"
  exit 0
fi
device=""
dtype=""
prev=""
for arg in "\$@"; do
  if [[ "\${prev}" == "-d" ]]; then dtype="\${arg}"; fi
  if [[ "\${arg}" == /dev/* ]]; then device="\${arg}"; fi
  prev="\${arg}"
done
name="\$(basename "\${device}")"
[[ -n "\${dtype}" ]] && name="\${name}.\${dtype}"
if [[ -f "$DOCS/\${name}.json" ]]; then
  cat "$DOCS/\${name}.json"
  exit 4
fi
exit 2
EOF
  chmod +x "$SMARTCTL_BIN"
}

########################################
# Files a device document, as smartctl would print it.
# Arguments:
#   name: Document name — a device basename, optionally suffixed with .<type>.
#   passed: true or false for the overall SMART verdict.
#   temp: Current temperature.
#   Remaining arguments are attributes as "id:name:value:thresh:raw".
########################################
device_doc() {
  local name="$1" passed="$2" temp="$3"
  shift 3
  local json="{\"model_name\":\"Test Disk 1TB\",\"serial_number\":\"SER-${name}\",\"rotation_rate\":5400"
  json+=",\"smart_status\":{\"passed\":${passed}},\"temperature\":{\"current\":${temp}}"
  json+=",\"ata_smart_attributes\":{\"table\":["
  local first=true spec id attr value thresh raw
  for spec in "$@"; do
    IFS=':' read -r id attr value thresh raw <<<"$spec"
    [[ "$first" == true ]] || json+=','
    first=false
    json+="{\"id\":${id},\"name\":\"${attr}\",\"value\":${value},\"worst\":${value},\"thresh\":${thresh},\"raw\":{\"value\":${raw}}}"
  done
  json+="]}}"
  printf '%s\n' "$json" > "$DOCS/${name}.json"
}

########################################
# Files a healthy disk document under the given name.
########################################
healthy_doc() {
  device_doc "$1" true 40 5:Reallocated_Sector_Ct:100:10:0 197:Current_Pending_Sector:100:0:0 198:Offline_Uncorrectable:100:0:0
}

########################################
# Files what smartctl --scan prints, one "path -d type" line per argument pair.
########################################
scan_lists() {
  : > "$DOCS/scan"
  local entry
  for entry in "$@"; do
    printf '%s # comment\n' "$entry" >> "$DOCS/scan"
  done
}

# --- The findings themselves ---------------------------------------------------------------------

@test "a healthy disk yields no findings" {
  healthy_doc sda
  run_snippet "$SCRIPT" "findings_for \"\$(cat '$DOCS/sda.json')\""
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "a reallocated sector is a failure" {
  device_doc sda true 40 5:Reallocated_Sector_Ct:100:10:8
  run_snippet "$SCRIPT" "findings_for \"\$(cat '$DOCS/sda.json')\""
  [[ "$output" == *"fail"* ]]
  [[ "$output" == *"8 reallocated sector(s)"* ]]
}

@test "a sector pending reallocation is a failure" {
  device_doc sda true 40 197:Current_Pending_Sector:100:0:3
  run_snippet "$SCRIPT" "findings_for \"\$(cat '$DOCS/sda.json')\""
  [[ "$output" == *"3 sector(s) pending reallocation"* ]]
}

@test "the drive's own failed verdict is a failure" {
  device_doc sda false 40 5:Reallocated_Sector_Ct:100:10:0
  run_snippet "$SCRIPT" "findings_for \"\$(cat '$DOCS/sda.json')\""
  [[ "$output" == *"reports its SMART status as FAILED"* ]]
}

# A fixed list of attribute ids goes out of date silently; the thresholds ship with the drive.
@test "any attribute at its own failure threshold is a failure, named or not" {
  device_doc sda true 40 194:Some_Vendor_Attribute:30:40:1234
  run_snippet "$SCRIPT" "findings_for \"\$(cat '$DOCS/sda.json')\""
  [[ "$output" == *"Some_Vendor_Attribute (id 194) is at 30, at or below the failure threshold of 40"* ]]
}

@test "an attribute with no threshold set is not judged against one" {
  device_doc sda true 40 9:Power_On_Hours:95:0:20789
  run_snippet "$SCRIPT" "findings_for \"\$(cat '$DOCS/sda.json')\""
  [ "$output" = "" ]
}

@test "solid-state wear is reported from whichever attribute the drive carries" {
  device_doc ssd1 true 40 177:Wear_Leveling_Count:15:0:1008
  run_snippet "$SCRIPT" "findings_for \"\$(cat '$DOCS/ssd1.json')\""
  [[ "$output" == *"solid-state wear: 15% of rated life left"* ]]
  device_doc ssd2 true 40 231:SSD_Life_Left:12:0:500
  run_snippet "$SCRIPT" "findings_for \"\$(cat '$DOCS/ssd2.json')\""
  [[ "$output" == *"12% of rated life left"* ]]
}

@test "wear above the threshold is not reported" {
  device_doc ssd true 40 177:Wear_Leveling_Count:58:0:1008
  run_snippet "$SCRIPT" "findings_for \"\$(cat '$DOCS/ssd.json')\""
  [ "$output" = "" ]
}

@test "interface CRC errors are a warning that names the cable" {
  device_doc sda true 40 199:UDMA_CRC_Error_Count:99:0:8
  run_snippet "$SCRIPT" "findings_for \"\$(cat '$DOCS/sda.json')\""
  [[ "$output" == *"8 interface CRC error(s)"* ]]
  [[ "$output" == *"usually the cable"* ]]
}

@test "the CRC threshold can be raised to quieten a known history" {
  device_doc sda true 40 199:UDMA_CRC_Error_Count:99:0:8
  run_snippet "$SCRIPT" "_crc_max=10; findings_for \"\$(cat '$DOCS/sda.json')\""
  [ "$output" = "" ]
}

@test "a temperature above the threshold is a warning" {
  device_doc sda true 71 5:Reallocated_Sector_Ct:100:10:0
  run_snippet "$SCRIPT" "findings_for \"\$(cat '$DOCS/sda.json')\""
  [[ "$output" == *"running at 71C"* ]]
}

@test "an NVMe drive's own health log is read" {
  printf '%s\n' '{"model_name":"NVMe Disk","serial_number":"N1","smart_status":{"passed":true},"nvme_smart_health_information_log":{"critical_warning":1,"media_errors":4,"percentage_used":95}}' > "$DOCS/nvme0.json"
  run_snippet "$SCRIPT" "findings_for \"\$(cat '$DOCS/nvme0.json')\""
  [[ "$output" == *"NVMe critical warning 1"* ]]
  [[ "$output" == *"4 NVMe media error(s)"* ]]
  [[ "$output" == *"5% of rated life left"* ]]
}

# --- Reading the devices -------------------------------------------------------------------------

@test "a named device is examined and reported healthy" {
  healthy_doc sda
  run_script "$SCRIPT" /dev/sda
  [ "$status" -eq 0 ]
  [[ "$output" == *"/dev/sda: Test Disk 1TB"* ]]
  [[ "$output" == *"nothing to report"* ]]
  [[ "$output" == *"1 device(s) examined, all healthy."* ]]
}

# smartctl's exit status is a bit field, and a failing disk sets one of its bits.
@test "a non-zero smartctl status is not read as a failed read" {
  device_doc sda false 40 5:Reallocated_Sector_Ct:100:10:9
  run_script "$SCRIPT" /dev/sda
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILING"* ]]
  [[ "$output" != *"Could not read SMART data"* ]]
}

@test "every scanned device is examined" {
  scan_lists "/dev/sda -d scsi" "/dev/sdb -d scsi"
  healthy_doc sda
  healthy_doc sdb
  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 device(s) examined"* ]]
}

# Measured on real hardware: the type the scan suggests returns a document with no model and no
# attributes, while auto-detection returns everything. Trusting the suggestion reports a fleet as fine
# without having read any of it.
@test "auto-detection is used first, and the scanned type only as a fallback" {
  scan_lists "/dev/sda -d scsi"
  # Only the type-qualified document exists, so the plain query returns nothing and the retry succeeds.
  healthy_doc sda.scsi
  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 device(s) examined"* ]]
  run bash -c "grep -c 'smartctl .*-d scsi' '$STUB_CALLS'"
  [ "$output" = "1" ]
}

@test "a device that answers nothing usable is counted as unreadable, not healthy" {
  scan_lists "/dev/sdz -d scsi"
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not read SMART data from /dev/sdz"* ]]
  [[ "$output" == *"1 unreadable"* ]]
}

# A document that parses but describes no drive is exactly what an unsupported device type produces.
@test "a document with no drive in it is not accepted" {
  printf '%s\n' '{"smartctl":{"exit_status":2},"device":{"type":"scsi"}}' > "$DOCS/sda.json"
  run_script "$SCRIPT" /dev/sda
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not read SMART data"* ]]
}

@test "a disk reachable by two paths is examined once" {
  scan_lists "/dev/sda -d scsi" "/dev/sdb -d scsi"
  healthy_doc sda
  # The same serial under a second name is the same drive.
  sed 's/SER-sdb/SER-sda/' "$DOCS/sda.json" > "$DOCS/sdb.json"
  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 device(s) examined"* ]]
}

@test "warnings alone exit 2, so a monitor can tell them from a failure" {
  device_doc sda true 71 5:Reallocated_Sector_Ct:100:10:0
  run_script "$SCRIPT" /dev/sda
  [ "$status" -eq 2 ]
  [[ "$output" == *"1 with warnings"* ]]
}

@test "--quiet says nothing at all when every disk is healthy" {
  healthy_doc sda
  run_script "$SCRIPT" --quiet /dev/sda
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "--quiet still reports a disk with findings" {
  device_doc sda true 40 5:Reallocated_Sector_Ct:100:10:2
  run_script "$SCRIPT" --quiet /dev/sda
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILING"* ]]
}

@test "a scan that finds nothing is refused rather than reported as a clean bill" {
  scan_lists
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No SMART-capable device was found"* ]]
}

@test "the configured device list is used when none is named" {
  printf 'DEVICES=(/dev/sdb)\n' > "$CONFIG_FILE"
  healthy_doc sdb
  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/dev/sdb"* ]]
  run bash -c "grep -c -- '--scan' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "a named device overrides the configured list" {
  printf 'DEVICES=(/dev/sdb)\n' > "$CONFIG_FILE"
  healthy_doc sda
  run_script "$SCRIPT" /dev/sda
  [[ "$output" == *"/dev/sda"* ]]
}

@test "the thresholds come from the config when no option overrides them" {
  printf 'TEMP_MAX=39\n' > "$CONFIG_FILE"
  healthy_doc sda
  run_script "$SCRIPT" /dev/sda
  [ "$status" -eq 2 ]
  [[ "$output" == *"above the 39C"* ]]
}

@test "a threshold that is not a number is refused" {
  run_script "$SCRIPT" --temp warm /dev/sda
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a whole number"* ]]
}

@test "a missing smartctl is refused" {
  SMARTCTL_BIN="$BATS_TEST_TMPDIR/absent" run_script "$SCRIPT" /dev/sda
  [ "$status" -eq 1 ]
  [[ "$output" == *"Install smartmontools"* ]]
}

@test "an unknown option is refused" {
  run_script "$SCRIPT" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option '--nonsense'."* ]]
}
