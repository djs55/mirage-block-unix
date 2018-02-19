#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>

#include <sys/param.h>
#include <sys/mount.h>

/* Demonstrate a problem with fcntl(F_PUNCHHOLE) via the following sequence:

   0. ftruncate the file to 10 blocks in size
   1. fcntl(F_PUNCHHOLE) block 0
   2. pwrite block 0
   3. pwrite block 1
   4. fcntl(F_PUNCHHOLE) block 1

   Step (4) will fail with EINVAL unless any of (1), (2) or (3) are commented-out.

   Compile with

   $ cc -o punchhole punchhole.c

   Example output:

    Underlying filesystem uses a 4096 byte block size.

    ftruncate(40960)
    fcntl(F_PUNCHHOLE, fp_offset = 0, fp_length = 4096)
    pwrite(offset = 0, nbytes = 4096)
    pwrite(offset = 4096, nbytes = 4096)
    fcntl(F_PUNCHHOLE, fp_offset = 4096, fp_length = 4096)

    *** Failed to punch hole: Invalid argument

    The arguments to fcntl(F_PUNCHHOLE) were:
    fp_offset = 4096 fp_length = 4096
*/

int main(int argc, char **argv){

    int fd = open("test.raw", O_TRUNC | O_WRONLY | O_CREAT, 0644);
    if (fd == -1){
        perror("Failed to open test.raw");
    }
    /* Discover underlying filesystem block size */
    struct statfs fsbuf;
    if (fstatfs(fd, &fsbuf) == -1) {
        perror("Failed to discover filesystem block size");
        return 1;
    }
    int blocksize = fsbuf.f_bsize;
    printf("Underlying filesystem uses a %d byte block size.\n\n", blocksize);
    int size = 10 * blocksize;

    printf("ftruncate(%d)\n", size);
    if (ftruncate(fd, size) == -1) {
        perror("Failed to ftruncate the file");
        return 1;
    }

    char *zeroes = (char*)malloc(blocksize); 
    bzero(zeroes, blocksize);

    int offset = 0 * blocksize;
    struct fpunchhole arg = { .fp_flags = 0, .reserved = 0, .fp_offset = (off_t) offset, .fp_length = (off_t) blocksize };

    printf("fcntl(F_PUNCHHOLE, fp_offset = %lld, fp_length = %lld)\n", arg.fp_offset, arg.fp_length);
    if (fcntl(fd, F_PUNCHHOLE, &arg) == -1){
        perror("Failed to punch hole");
        return 1;
    }

    printf("pwrite(offset = %d, nbytes = %d)\n", offset, blocksize);
    if (pwrite(fd, zeroes, blocksize, offset) == -1) {
        perror("Failed to write block");
        return 1;
    }

    offset = 1 * blocksize;
    printf("pwrite(offset = %d, nbytes = %d)\n", offset, blocksize);
    if (pwrite(fd, zeroes, blocksize, offset) == -1) {
        perror("Failed to write block");
        return 1;
    }

    /* This discard always fails, unless I comment out any of the previous pwrite or
       fcntl calls. Discarding any other block is successful. */
    offset = 1 * blocksize;
    arg.fp_offset = (off_t) offset;
    printf("fcntl(F_PUNCHHOLE, fp_offset = %lld, fp_length = %lld)\n\n", arg.fp_offset, arg.fp_length);
    if (fcntl(fd, F_PUNCHHOLE, &arg) == -1){
        perror("*** Failed to punch hole");
        fprintf(stderr, "\nThe arguments to fcntl(F_PUNCHHOLE) were:\n");
        fprintf(stderr, "fp_offset = %lld fp_length = %lld\n", arg.fp_offset, arg.fp_length);
        return 1;
    }

    printf("All operations successful\n");
    return 0;
}