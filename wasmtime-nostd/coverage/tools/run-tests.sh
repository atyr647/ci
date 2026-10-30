#!/bin/bash
# Runs every suite of the coverage run on one target. env: LABEL (target name), F (path of the full executable), B (path of the base executable), COMPONENTS (non-empty when the full runtime has the component model)
# Writes results/<LABEL>/*.out and summary.txt; never fails the step (the summary and the compare job report).
set +e
R=results/$LABEL; mkdir -p $R
if [ "$RUNNER_OS" = Windows ]; then FE=./wnc-full.exe; BE=./wnc-base.exe; cp $F $FE; cp $B $BE; RUNF=($FE); RUNB=($BE); else chmod +x $F $B; RUNF=(sh $F); RUNB=(sh $B); fi
S=$R/summary.txt; : > $S
note() { echo "$*" | tee -a $S; }
sumline() { grep -h '^SUMMARY' "$1" | tail -1; }

# 1. core proposals: every t_* export must return 1, every x_* export must trap
for t in gc eh mem relaxed; do for mode in sig nosig pulley; do
  "${RUNF[@]}" $mode $t --run-tests > $R/core-$t-$mode.out 2> $R/core-$t-$mode.err; rc=$?
  note "core $t $mode rc=$rc $(sumline $R/core-$t-$mode.out) $( [ $rc -ne 0 ] && head -c 300 $R/core-$t-$mode.err | tr '\n' ' ')"
done; done
# GC collectors (the file for each is compiled with that collector selected)
for c in drc null copying; do
  "${RUNF[@]}" sig gc-$c --collector=$c --run-tests > $R/gc-$c.out 2> $R/gc-$c.err; rc=$?
  note "gc-collector $c sig rc=$rc $(sumline $R/gc-$c.out) $( [ $rc -ne 0 ] && head -c 300 $R/gc-$c.err | tr '\n' ' ')"
done
for c in drc copying; do
  "${RUNF[@]}" sig gc-$c --collector=$c --call=s_gcstress:2000000 --call=s_gcstress_arrays:200000 > $R/gcstress-$c.out 2> $R/gcstress-$c.err; rc=$?
  note "gc-stress $c rc=$rc $(grep -h '^CALL' $R/gcstress-$c.out | tr '\n' ';') $( [ $rc -ne 0 ] && head -c 200 $R/gcstress-$c.err | tr '\n' ' ')"
done
"${RUNF[@]}" pulley gc --call=s_gcstress:300000 > $R/gcstress-pulley.out 2> $R/gcstress-pulley.err; note "gc-stress pulley rc=$? $(grep -h '^CALL' $R/gcstress-pulley.out | tr '\n' ';')"
# threads proposal: the runtime was built without the `threads` Cargo feature, so what the loader says is the result
for t in atomics-thr shared-thr; do for mode in sig pulley; do
  "${RUNF[@]}" $mode $t --run-tests > $R/core-$t-$mode.out 2> $R/core-$t-$mode.err; rc=$?
  note "threads $t $mode rc=$rc $(sumline $R/core-$t-$mode.out) $(head -c 400 $R/core-$t-$mode.err | tr '\n' ' ')"
done; done

# 2. WASI preview 1: a real wasi-sdk program, with files, directories, clocks, env, random, stdio and a TCP socket (client thread inside the host)
for mode in sig nosig pulley; do
  rm -rf sbx; mkdir sbx
  printf 'hello stdin\n' | "${RUNF[@]}" $mode wasitest --p1 --dir=/sandbox::sbx '--env=WN_TEST_VAR=hello env' --tcplisten=127.0.0.1:0 --selfclient -- alpha 'two words' > $R/p1-$mode.out 2> $R/p1-$mode.err; rc=$?
  grep -v '^host : \(platform\|engine\|listening\)' $R/p1-$mode.out > $R/p1-$mode.cmp
  note "wasi-p1 $mode rc=$rc $(sumline $R/p1-$mode.out) fails=$(grep -c '^FAIL' $R/p1-$mode.out)"
done
rm -rf sbx; mkdir sbx
"${RUNF[@]}" sig wasitest --p1 --dir=/sandbox::sbx -- exit7 > $R/p1-exit.out 2> $R/p1-exit.err; rc=$?; note "wasi-p1 exit-code propagation rc=$rc (expected 7)"
"${RUNF[@]}" sig no-such-file > /dev/null 2>&1; rc=$?; note "host exit code for a missing file rc=$rc (expected 65)"
"${RUNF[@]}" sig wasitest --p1 --dir=/sandbox::sbx -- exit7 > /dev/null 2>&1; rc=$?; note "same, output discarded rc=$rc (expected 7)"
# the same program on the base runtime (no gc / async / component layers): same output?
rm -rf sbx; mkdir sbx
printf 'hello stdin\n' | "${RUNB[@]}" sig b-wasitest --argv0=wasitest --p1 --dir=/sandbox::sbx '--env=WN_TEST_VAR=hello env' --tcplisten=127.0.0.1:0 --selfclient -- alpha 'two words' > $R/p1-base.out 2> $R/p1-base.err; rc=$?
grep -v '^host : \(platform\|engine\|listening\)' $R/p1-base.out > $R/p1-base.cmp
note "wasi-p1 base-runtime rc=$rc $(sumline $R/p1-base.out) identical-to-full-sig=$(diff -q $R/p1-base.cmp $R/p1-sig.cmp >/dev/null && echo yes || echo NO)"
rm -rf sbx

# WASI call cost (preview 1, native code and Pulley)
for mode in sig pulley; do rm -rf sbx; mkdir sbx; "${RUNF[@]}" $mode wasibench --p1 --dir=/sandbox::sbx > $R/bench-p1-$mode.out 2>&1; done; rm -rf sbx
note "wasi-p1 call cost sig: $(grep -h '^BENCH' $R/bench-p1-sig.out | sed 's/BENCH //; s/  */ /g' | tr '\n' ';')"
note "wasi-p1 call cost pulley: $(grep -h '^BENCH' $R/bench-p1-pulley.out | sed 's/BENCH //; s/  */ /g' | tr '\n' ';')"

# 3. async (fibers)
for mode in sig nosig pulley; do
  "${RUNF[@]}" $mode yield --async --run-tests > $R/async-$mode.out 2> $R/async-$mode.err; rc=$?
  note "async $mode rc=$rc $(sumline $R/async-$mode.out) $( [ $rc -ne 0 ] && head -c 300 $R/async-$mode.err | tr '\n' ' ')"
done
for mode in sig pulley; do
  "${RUNF[@]}" $mode yield --async --call=s_async_loop:100000 --call=s_sync_loop:100000 > $R/async-timing-$mode.out 2> $R/async-timing-$mode.err
  note "async-timing $mode $(grep -h '^CALL' $R/async-timing-$mode.out | tr '\n' ';')"
done

# 4. asyncify (stackless, made by wasm-opt --asyncify) against the same code with a synchronous host call
for d in 0 50; do for mode in sig pulley; do
  "${RUNF[@]}" $mode asy-d$d --plain-await --call=run > $R/asyncify-plain-d$d-$mode.out 2>&1
  "${RUNF[@]}" $mode asy-d$d-opt --asyncify=run:asyncify_data_addr:65544 > $R/asyncify-opt-d$d-$mode.out 2>&1
  "${RUNF[@]}" $mode asy-d$d-opt --plain-await --call=run > $R/asyncify-optplain-d$d-$mode.out 2>&1
  note "asyncify depth=$d $mode | plain: $(grep -h '^CALL' $R/asyncify-plain-d$d-$mode.out) | instrumented, no unwinding: $(grep -h '^CALL' $R/asyncify-optplain-d$d-$mode.out) | unwinding: $(grep -h '^ASYNCIFY' $R/asyncify-opt-d$d-$mode.out)"
done; done
# C++20 coroutines
for mode in sig nosig pulley; do
  "${RUNF[@]}" $mode coro --p1 --run-tests > $R/coro-$mode.out 2> $R/coro-$mode.err; rc=$?
  note "coroutines $mode rc=$rc $(sumline $R/coro-$mode.out)"
done
for mode in sig pulley; do
  "${RUNF[@]}" $mode coro --p1 --call=s_coro:3000000 --call=s_plain:3000000 > $R/coro-timing-$mode.out 2>&1
  note "coroutine-timing $mode $(grep -h '^CALL' $R/coro-timing-$mode.out | tr '\n' ';')"
done

# 5. components / WASI preview 2
if [ -n "$COMPONENTS" ]; then
  "${RUNF[@]}" sig cm --component --run-tests > $R/cm-selftest.out 2> $R/cm-selftest.err; note "component canonical-ABI selftest sig rc=$? $(sumline $R/cm-selftest.out)"
  for mode in sig nosig pulley; do
    rm -rf sbx; mkdir sbx
    printf 'hello stdin\n' | "${RUNF[@]}" $mode wasitest.p2 --component --dir=/sandbox::sbx '--env=WN_TEST_VAR=hello env' -- alpha 'two words' > $R/p2-$mode.out 2> $R/p2-$mode.err; rc=$?
    grep -v '^host : \(platform\|engine\|component\)' $R/p2-$mode.out > $R/p2-$mode.cmp
    note "wasi-p2 $mode rc=$rc $(sumline $R/p2-$mode.out) fails=$(grep -c '^FAIL' $R/p2-$mode.out) | $(head -c 300 $R/p2-$mode.err | tr '\n' ' ')"
  done
  rm -rf sbx; mkdir sbx
  "${RUNF[@]}" sig wasibench.p2 --component --dir=/sandbox::sbx > $R/bench-p2-sig.out 2>&1; rm -rf sbx
  note "wasi-p2 call cost sig: $(grep -h '^BENCH' $R/bench-p2-sig.out | sed 's/BENCH //; s/  */ /g' | tr '\n' ';')"
fi

# 6. speed: the base runtime against the full runtime on the same kernels (interleaved, best of 3)
PY=$(command -v python3 || command -v python)
if [ -n "$PY" ]; then
  AB_TITLE="$LABEL: so-scalar, base runtime vs full runtime" "$PY" wasmtime-nostd/ab.py 3 "base runtime|${RUNB[*]} sig b-so-scalar --p1" "full runtime (gc+async+component)|${RUNF[*]} sig so-scalar --p1" > $R/ab.out 2>&1
  cat $R/ab.out; note "speed table in $R/ab.out"
fi
note "done"
