# Reads the JSON dovi_tool prints for one frame and emits the L5 active-area offsets as
# "left right top bottom", or nothing when the frame carries no L5 block.
#
# The block is found by searching the whole document rather than by naming a path, because its
# location depends on the display-management version: a CM v2.9 RPU carries it under
# vdr_dm_data.cmv29_metadata and a v4.0 one under cmv40_metadata, and a tool that knew only one of
# those would silently report every file of the other kind as having no active area at all.
[.. | objects | select(has("active_area_top_offset"))] | first
| if . == null then empty
  else [.active_area_left_offset, .active_area_right_offset, .active_area_top_offset, .active_area_bottom_offset] | @tsv
  end
