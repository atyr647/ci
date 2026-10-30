/* Native launcher of the .app: starts the Cosmopolitan loader on the unmodified fat file kept as a resource. Arguments are passed through. */
#include <libgen.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  char self[4096], dir[4096], loader[4200], game[4200];
  uint32_t n = sizeof self;
  if (_NSGetExecutablePath(self, &n)) return 90;
  char *real = realpath(self, NULL); if (!real) return 91;
  strncpy(dir, dirname(real), sizeof dir - 1); dir[sizeof dir - 1] = 0;
  snprintf(loader, sizeof loader, "%s/ape-loader", dir);
  snprintf(game, sizeof game, "%s/../Resources/game.com", dir);
  char **nargv = calloc((size_t)argc + 3, sizeof *nargv);
  nargv[0] = loader; nargv[1] = game; for (int i = 1; i < argc; i++) nargv[i + 1] = argv[i];
  execv(loader, nargv);
  perror("execv ape-loader"); return 92;
}
