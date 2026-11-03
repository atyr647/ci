// Runs a command with the kernel's "memory deny write+execute" policy (prctl PR_SET_MDWE, Linux 6.3+): afterwards a mapping can neither be writable and executable at once
// nor gain PROT_EXEC through mprotect; only a fresh mmap that is executable and not writable is allowed. The flag survives exec.
#include <stdio.h>
#include <unistd.h>
#include <sys/prctl.h>
#ifndef PR_SET_MDWE
#define PR_SET_MDWE 65
#define PR_MDWE_REFUSE_EXEC_GAIN 1
#endif
int main(int argc, char **argv) {
  if (argc < 2) return 2;
  if (prctl(PR_SET_MDWE, PR_MDWE_REFUSE_EXEC_GAIN, 0, 0, 0)) { perror("prctl(PR_SET_MDWE)"); return 3; }
  execvp(argv[1], argv + 1); perror("execvp"); return 4;
}
