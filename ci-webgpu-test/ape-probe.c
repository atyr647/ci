/* Cosmopolitan APE probe: exit status, PATH, spawning curl. Build: cosmocc -o ape-probe.com ape-probe.c */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
int main(int argc, char **argv) {
  if (argc > 1 && !strcmp(argv[1], "exit7")) return 7;
  printf("PATH=%.300s\n", getenv("PATH") ? getenv("PATH") : "(null)");
  printf("system(curl --version) -> %d\n", system("curl --version"));
  FILE *p = popen("curl --version", "r"); char b[200] = ""; if (p) { fgets(b, sizeof b, p); printf("popen -> %d first line: %s", pclose(p), b); } else puts("popen failed");
  char *av[] = {"curl", "--version", 0}; pid_t pid = fork(); if (!pid) { execvp("curl", av); printf("execvp curl failed\n"); _exit(99); }
  int st = 0; waitpid(pid, &st, 0); printf("fork+execvp curl -> status %d\n", st);
  char *av2[] = {"C:\\Windows\\System32\\curl.exe", "--version", 0}; pid = fork(); if (!pid) { execv(av2[0], av2); printf("execv abs failed\n"); _exit(98); }
  waitpid(pid, &st, 0); printf("fork+execv C:\\Windows\\System32\\curl.exe -> status %d\n", st);
  return 0;
}
