#!/bin/bash
# usage: fs-windows.sh <label> <suffix>; run from the workspace root (the fat file is in in/)
set +e; SRC=$PWD/in/wgt-dawn.com; echo "##### $1"
W=/c/fscomp$2; mkdir -p $W/t; cp $SRC $W/orig.bin   # the C: drive: the workspace drive of these runners can be ReFS, which has no file compression
for d in "$PWD" C:; do MSYS_NO_PATHCONV=1 fsutil fsinfo volumeinfo $d 2>&1 | grep -i -E "file system name|supports file-based compression|volume name" | tr '\n' ' '; echo "<- $d"; done
echo "size of the original: $(stat -c %s $W/orig.bin)"
run1() { local f=$1; local t0=$(date +%s%N); $W/t/$f > /dev/null 2>&1; local rc=$?; echo "$(( ($(date +%s%N) - t0) / 1000000 )) $rc"; }
for v in none lzx xpress16k xpress4k none2 none-wait none-rewrite; do : > res.$v; done
# interleaved: every round runs all variants once, in the same order, after one untimed warm-up start of an uncompressed copy
cp $W/orig.bin $W/t/warm.exe; $W/t/warm.exe > /dev/null 2>&1
for i in $(seq 1 ${TRIALS:-8}); do
  for v in none lzx xpress16k xpress4k none2 none-wait none-rewrite; do
    f=f-$v-$i.exe; cp $W/orig.bin $W/t/$f
    # controls for "was the uncompressed start slow only because the file was run right after it was written (virus scanner on first run)": none-wait runs it 6 s after the copy; none-rewrite rewrites it by compressing then uncompressing it (so it is scanned/touched outside the timing)
    case $v in
      none-wait) sleep 6;;
      none-rewrite) (cd $W/t && MSYS_NO_PATHCONV=1 cmd.exe /c "compact /c /exe:lzx $f && compact /u $f") > compact.$v.txt 2>&1;;
      none*) ;;
      *) (cd $W/t && MSYS_NO_PATHCONV=1 cmd.exe /c "compact /c /exe:$v $f") > compact.$v.txt 2>&1;;
    esac
    run1 $f >> res.$v
  done
done
for v in none lzx xpress16k xpress4k none2 none-wait none-rewrite; do
  ms=$(awk '{print $1}' res.$v | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'); mn=$(awk '{print $1}' res.$v | sort -n | head -1); rcs=$(awk '{print $2}' res.$v | sort -u | tr '\n' ' ')
  echo "variant $v: fresh start median $ms ms, min $mn ms, all: $(awk '{printf "%s ", $1}' res.$v) (exit codes: $rcs); $(grep -i -E 'compressed|ratio' compact.$v.txt 2>/dev/null | tail -2 | tr '\n' ' ')"
done
echo "--- compact /q for the last copy of each variant"; for v in lzx xpress16k xpress4k; do (cd $W/t && MSYS_NO_PATHCONV=1 cmd.exe /c "compact /q f-$v-${TRIALS:-8}.exe") 2>&1 | grep -E "stored in|ratio"; done
