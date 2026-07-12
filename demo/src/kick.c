/*
 * kick.c — a minimal setuid-root helper that restarts ONLY the millfolio demo
 * launchd daemon, so a NON-admin account (e.g. bgent) can bounce it after a
 * deploy without a sudo password.
 *
 * It takes NO arguments and reads NO environment: it execs a single HARDCODED
 * command as root. That is the whole security model — a setuid-root binary must
 * never let the caller influence what runs (argv/env/PATH injection is how these
 * become root-for-anyone exploits). dyld also strips DYLD_* for setuid binaries.
 *
 * NOTE: macOS ignores the setuid bit on shell SCRIPTS, so this must be a compiled
 * binary. Install it from an ADMIN account (see scripts/setup-kick.sh, or by hand):
 *   cc -O2 -Wall -o kick kick.c
 *   sudo chown root:wheel kick
 *   sudo chmod 4755 kick              # the "+s" (setuid) bit
 *   sudo codesign --force -s - kick   # Apple Silicon: re-sign after chmod
 * Then, as any user:  ./kick
 *
 * Prefer the sudoers NOPASSWD rule (setup-kick.sh, default) unless you specifically
 * want a binary — it's scoped to the exact command, auditable, and reversible.
 */
#include <unistd.h>
#include <stdio.h>

int main(void) {
    /* Become real+effective root so launchctl can act on the system domain. When
     * the setuid bit is set the euid is already 0; this also sets the ruid. If the
     * bit is NOT set (binary run without privilege), these fail and we bail rather
     * than invoke launchctl unprivileged. */
    if (setgid(0) != 0 || setuid(0) != 0) {
        perror("kick: setuid/setgid (is the setuid bit set + root-owned?)");
        return 1;
    }
    char *const argv[] = {
        "/bin/launchctl", "kickstart", "-k",
        "system/app.millfolio.demo", (char *)0
    };
    execv("/bin/launchctl", argv);
    perror("kick: execv /bin/launchctl");
    return 127;
}
