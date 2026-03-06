# TODO

## remove-sidecars: Camera-based exclusion filtering

Add an optional prompt after defining extensions that lets the user exclude
certain cameras from sidecar deletion. Implementation:

1. Read EXIF data (Camera Model) from all files found during traversal.
2. Present the unique list of cameras and let the user pick which to exclude.
3. Store the file-to-camera mapping in memory so EXIF isn't read twice.

Once camera-based filtering is in place, extension matching can be made
case-insensitive (e.g., treating `.dng` and `.DNG` the same) since the camera
distinction (Android vs Lightroom) would be handled by the exclusion list
rather than relying on extension casing.
