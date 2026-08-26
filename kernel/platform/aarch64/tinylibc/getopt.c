#include <stddef.h>
#include <string.h>

int optind = 1;
int opterr = 0;
int optopt = 0;
char *optarg;

static char *scan_ptr;          /* position inside clustered short opts */

int getopt(int argc, char *const argv[], const char *optstring)
{
    const char *p;
    char c;

    if (optind >= argc || !argv[optind] || argv[optind][0] != '-' ||
        !argv[optind][1]) {
        scan_ptr = 0;
        return -1;
    }
    if (strcmp(argv[optind], "--") == 0) {
        optind++;
        return -1;
    }
    if (!scan_ptr)
        scan_ptr = argv[optind] + 1;
    c = *scan_ptr++;
    if (!*scan_ptr) {
        optind++;
        scan_ptr = 0;
    }
    for (p = optstring; *p && *p != c; p++) ;
    if (*p != c) {
        optopt = c;
        return '?';
    }
    if (p[1] == ':') {
        if (*scan_ptr) {
            optarg = scan_ptr;
            scan_ptr = 0;
            optind++;
        } else {
            optarg = argv[++optind];
            scan_ptr = 0;
            optind++;
            if (!optarg)
                return optstring[0] == ':' ? ':' : '?';
        }
    } else {
        optarg = 0;
    }
    return c;
}

struct option {
    const char *name;
    int has_arg;
    int *flag;
    int val;
};

#define no_argument 0
#define required_argument 1
#define optional_argument 2

int getopt_long(int argc, char *const argv[], const char *optstring,
                const struct option *longopts, int *longindex)
{
    size_t i;
    const char *name;
    const struct option *o;

    if (optind < argc && argv[optind] && argv[optind][0] == '-' &&
        argv[optind][1] == '-') {
        name = argv[optind] + 2;
        for (i = 0; longopts && longopts[i].name; i++) {
            size_t nlen = strlen(longopts[i].name);
            o = &longopts[i];
            if (strncmp(name, o->name, nlen) == 0 &&
                (name[nlen] == '\0' ||
                 (name[nlen] == '=' && o->has_arg != no_argument))) {
                if (longindex)
                    *longindex = (int)i;
                optind++;
                if (name[nlen] == '=')
                    optarg = (char *)name + nlen + 1;
                else
                    optarg = 0;
                if (o->flag) {
                    *o->flag = o->val;
                    return 0;
                }
                return o->val;
            }
        }
        optind++;
        return '?';
    }
    return getopt(argc, argv, optstring);
}

int getopt_long_only(int argc, char *const argv[], const char *optstring,
                     const struct option *longopts, int *longindex)
{
    return getopt_long(argc, argv, optstring, longopts, longindex);
}
