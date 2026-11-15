#!/bin/sh
# fixture.sh HOME - the boards' folders for the chooser's tests (tests/steps.d/62-chooser.sh): ~/Pictures/Iceland,
# ~/Pictures's folders, ~/Documents, Downloads and Music, with the boards' sizes and dates (in 2026), and the drives'
# stand-in (System and Games). Sizes are sparse files.
set -eu
H=$1
mk() { # FILE BYTES DATE
	mkdir -p "$(dirname "$1")"; : > "$1"; truncate -s "$2" "$1"; touch -d "$3" "$1"
}
dir() { mkdir -p "$1"; touch -d "$2" "$1"; }
rm -rf "$H"; mkdir -p "$H/.config/ribbon" "$H/Downloads" "$H/Music"
P=$H/Pictures/Iceland
dir "$P/Drone" "2026-11-03 10:00"; dir "$P/Panoramas" "2026-10-28 10:00"
mk "$P/Höfn harbour.jpg" 9800000 "2026-10-12 10:00"; mk "$P/Jökulsárlón.jpg" 21600000 "2026-10-12 11:00"
mk "$P/Kirkjufell.jpg" 14200000 "2026-10-11 10:00"; mk "$P/Reynisfjara.jpg" 12900000 "2026-10-10 10:00"
mk "$P/Seljalandsfoss.png" 31400000 "2026-10-10 11:00"; mk "$P/Skógafoss.jpg" 16100000 "2026-10-09 10:00"
mk "$P/Vík.jpg" 11300000 "2026-10-09 11:00"
mk "$P/route.gpx" 4000 "2026-10-09 11:00"          # not a picture: not listed under Pictures
for d in "Family 2026-11-08" "Iceland 2026-11-03" "Lisbon 2026-09-21" "Scans 2026-08-02" "Screenshots 2026-11-14" "Wallpapers 2026-11-05"; do
	dir "$H/Pictures/${d% *}" "${d#* } 10:00"
done
mk "$H/Pictures/cover.png" 1000 "2026-11-01 10:00"   # a file: not listed when choosing a folder
D=$H/Documents
dir "$D/Letters" "2026-11-02 10:00"; dir "$D/Recipes" "2026-10-30 10:00"; dir "$D/Work" "2026-11-14 10:00"
mk "$D/Budget.md" 4200 "2026-11-13 10:00"; mk "$D/Packing list.txt" 812 "2026-11-06 10:00"
mk "$D/Reading.md" 2600 "2026-11-01 10:00"; mk "$D/Taxes 2025.pdf" 318000 "2026-04-04 10:00"
touch -d "2026-11-03 10:00" "$P"
printf '%s\n' '{System} / 580000000000 1000000000000 412000000000' '{Games} /run/media/ada/Games 710000000000 1000000000000 540000000000' > "$H/drives"
