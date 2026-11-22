#include <stdio.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <ApplicationServices/ApplicationServices.h>

int main(int argc, char **argv) {
    printf("AXIsProcessTrusted=%d\n", (int)AXIsProcessTrusted());
    for (int i = 1; i < argc; i++) {
        mach_port_t port = MACH_PORT_NULL;
        kern_return_t kr = bootstrap_look_up(bootstrap_port, argv[i], &port);
        printf("%s -> kr=%d (%s)\n", argv[i], (int)kr, kr == 0 ? "REACHABLE" : "blocked");
    }
    return 0;
}
