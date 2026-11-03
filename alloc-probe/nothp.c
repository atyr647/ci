// Runs a command with transparent huge pages disabled for the process (and its children); the flag survives exec.
#include <stdio.h>
#include <unistd.h>
#include <sys/prctl.h>
#ifndef PR_SET_THP_DISABLE
#define PR_SET_THP_DISABLE 41
#endif
int main(int argc, char **argv) {
  if (argc < 2) return 2;
  if (prctl(PR_SET_THP_DISABLE, 1, 0, 0, 0)) { perror("prctl(PR_SET_THP_DISABLE)"); return 3; }
  execvp(argv[1], argv + 1); perror("execvp"); return 4;
}
