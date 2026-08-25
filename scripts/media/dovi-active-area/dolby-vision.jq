# Reads mediainfo --Output=JSON and prints the video track Dolby Vision profile, or nothing when the
# file carries no Dolby Vision metadata. The profile is what mediainfo calls HDR_Format_Profile, which
# arrives with a trailing separator for the second (HDR10) format ("dvhe.08 / ") and is trimmed here.
[.media.track[]? | select(."@type" == "Video")] | first
| if . == null then empty
  elif (((.HDR_Format // "") | tostring) | test("Dolby Vision"; "i")) then
    (((.HDR_Format_Profile // "Dolby Vision") | tostring) | sub(" *[/] *$"; ""))
  else empty
  end
