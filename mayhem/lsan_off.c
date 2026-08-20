/* Build-time LeakSanitizer off-switch (fleet convention, SPEC §6.2 item 15).
 *
 * -fsanitize=address always bundles LeakSanitizer; leaks are not the defect class this target is
 * fuzzed for, and LSan's ptrace-based exit scan conflicts with Mayhem's ptrace-based coverage
 * collection (a 0-edge "Run Failed"). LSan consults this hook at exit, so leak detection is skipped
 * while ASan's memory-error checks and UBSan stay fully active. build.sh compiles it with
 * $SANITIZER_FLAGS and links it into the fuzz binary and the standalone reproducer. */
int __lsan_is_turned_off(void) { return 1; }
