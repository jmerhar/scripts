# lint-args: --argjson wear_min 20 --argjson temp_max 60 --argjson crc_max 0
#
# Reads one device JSON document from smartctl and emits one line per finding, as "level<TAB>message"
# where level is fail or warn. A healthy device emits nothing.
#
# Two kinds of check. The named ones are the attributes whose raw counts mean something specific: a
# sector reallocated, a sector that cannot be read now, a sector that could not be read during a scan.
# The general one is any attribute the drive itself says has reached its failure threshold, which is what
# covers the attributes this program has never heard of — a fixed list of ids goes out of date silently,
# whereas the thresholds ship with the drive.
def attrs: [.ata_smart_attributes.table[]?];
def attr($id): (attrs | map(select(.id == $id)) | first);
def raw($id): (attr($id) | .raw.value // 0);
def named($id): (attr($id) | .name // "attribute \($id)");

def counted($id; $level; $noun):
  if (attr($id) != null and raw($id) > 0) then
    "\($level)\t\(raw($id)) \($noun) (\(named($id)))"
  else empty end;

# The remaining life of a solid-state drive, as the percentage its own wear attribute reports. Three
# vendors spell it three ways and a drive carries at most one of them; the normalised value is what
# counts down, so it is the figure to compare, not the raw count of program-erase cycles.
def life_left:
  (attr(231) // attr(177) // attr(233)) as $a
  | if $a == null then null else $a.value end;

[
  if (.smart_status.passed == false) then "fail\tthe drive reports its SMART status as FAILED" else empty end,

  counted(5; "fail"; "reallocated sector(s)"),
  counted(197; "fail"; "sector(s) pending reallocation"),
  counted(198; "fail"; "sector(s) unreadable during an offline scan"),
  counted(187; "warn"; "uncorrectable error(s) reported to the host"),

  (if (attr(199) != null and raw(199) > $crc_max) then
     "warn\t\(raw(199)) interface CRC error(s) (\(named(199))) — usually the cable, not the drive"
   else empty end),

  (attrs[] | select((.thresh // 0) > 0 and (.value // 100) <= .thresh)
   | "fail\t\(.name) (id \(.id)) is at \(.value), at or below the failure threshold of \(.thresh) the drive sets"),

  (life_left as $left | if ($left != null and $left < $wear_min) then
     "warn\tsolid-state wear: \($left)% of rated life left"
   else empty end),

  (.nvme_smart_health_information_log // {}) as $nvme
  | (if (($nvme.critical_warning // 0) != 0) then "fail\tthe drive raised NVMe critical warning \($nvme.critical_warning)" else empty end),
  ((.nvme_smart_health_information_log // {}) as $nvme
   | if (($nvme.media_errors // 0) > 0) then "fail\t\($nvme.media_errors) NVMe media error(s)" else empty end),
  ((.nvme_smart_health_information_log // {}) as $nvme
   | if (($nvme.percentage_used // 0) > (100 - $wear_min)) then "warn\tsolid-state wear: \(100 - $nvme.percentage_used)% of rated life left" else empty end),

  (if ((.temperature.current // 0) > $temp_max) then
     "warn\trunning at \(.temperature.current)C, above the \($temp_max)C this check allows"
   else empty end)
]
| .[]
