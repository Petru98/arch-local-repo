#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

static inline _Bool isexe(int mode) {
    const int mask = S_IXUSR|S_IXGRP|S_IXOTH;
    return (mode & mask) == mask;
}

static inline char* cmdpath(const char* restrict cmd) {
    if(cmd[0] == '/' || (cmd[0] == '.' && cmd[1] == '/')) {
        char* const abspath = realpath(cmd, NULL);
        if(abspath != NULL) {
            struct stat st;
            if(stat(abspath, &st) != -1 && isexe(st.st_mode))
                return abspath;
            free(abspath);
        }
    }

    else {
        const size_t cmdsize = strlen(cmd);
        size_t bufsize = 0;
        char* buf = NULL;

        const char* beg = getenv("PATH");
        if(beg == NULL)
            return NULL;

        while(beg != NULL) {
            const char* end = beg;
            while((*end) != '\0' && (*end) != ':')
                ++end;

            if(end != beg) {
                const size_t pathsize = end - beg;
                const size_t newbufsize = pathsize + 1 + cmdsize;
                if(newbufsize > bufsize) {
                    char* newbuf = (char*)realloc(buf, newbufsize + 1);
                    if(newbuf == NULL) {
                        free(buf);
                        return NULL;
                    }
                    buf = newbuf;
                    bufsize = newbufsize;
                }

                memcpy(buf, beg, pathsize);
                buf[pathsize] = '/';
                memcpy(buf + pathsize + 1, cmd, cmdsize);
                buf[newbufsize] = '\0';

                struct stat st;
                if(stat(buf, &st) == -1) {
                    if(errno != ENOENT) {
                        free(buf);
                        return NULL;
                    }
                }
                else {
                    char* const abspath = realpath(buf, NULL);
                    if(abspath == NULL) {
                        if(errno != ENOENT && errno != ENOTDIR && errno != ELOOP && errno != ENAMETOOLONG && errno != EACCES) {
                            free(buf);
                            return NULL;
                        }
                    }
                    else {
                        if(stat(abspath, &st) == -1) {
                            free(abspath);
                            free(buf);
                            return NULL;
                        }
                        if(isexe(st.st_mode)) {
                            free(buf);
                            return abspath;
                        }
                        free(abspath);
                    }
                }
            }

            beg = ((*end) != '\0' ? end + 1 : NULL);
        }
    }

    return NULL;
}


int main(int argc, char** argv) {
    if(argc == 1)
        return 1;

    char* buf = cmdpath(argv[1]);
    if(buf == NULL || strcmp(buf, "/usr/bin/pacman") != 0)
        return 1;
    argv[0] = buf;
    memmove(argv + 1, argv + 2, (argc - 1) * sizeof(char*));

    if(setuid(0) == -1)
        return 1;
    execv(argv[0], argv);
    return 2;
}
