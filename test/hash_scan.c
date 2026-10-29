// NRPT offline validator helper: FNV-1a-64 page scan.
//
// Scans every 4096-byte aligned chunk of the given image files and prints one line for every
// chunk whose FNV-1a-64 hash is listed in the query file:
//
//   <hash 16 hex digits>\t<image index>\t<file offset hex>
//
// The query file contains one 64-bit hash per line (hex). Image indices are the argv order of the
// image paths (0-based, after the query-file argument). This program exists only because a full
// dyld shared cache is several GB and pure-Python FNV-1a is far too slow; it is compiled on demand
// by test/nrpt_validator.py and is never committed as a binary.
//
// Build: clang -O2 -o hash_scan test/hash_scan.c
// Usage: hash_scan <queries.txt> <image0> <image1> ...

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PAGE_SIZE 4096U
#define MAX_QUERIES 1024

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        fprintf(stderr, "usage: %s <queries-file> <image> [image ...]\n", argv[0]);
        return 2;
    }

    FILE* query = fopen(argv[1], "r");
    if (query == NULL)
    {
        perror("hash_scan: queries");
        return 2;
    }

    uint64_t queries[MAX_QUERIES];
    int query_count = 0;
    char line[128];
    while (fgets(line, sizeof(line), query) != NULL && query_count < MAX_QUERIES)
    {
        if (strlen(line) < 16)
        {
            continue;
        }
        queries[query_count++] = strtoull(line, NULL, 16);
    }
    fclose(query);
    if (query_count == 0)
    {
        return 0;
    }

    uint8_t* buffer = malloc(PAGE_SIZE);
    if (buffer == NULL)
    {
        return 2;
    }

    for (int image_index = 2; image_index < argc; image_index++)
    {
        FILE* image = fopen(argv[image_index], "rb");
        if (image == NULL)
        {
            continue;  // Unreadable candidate: the Python side decides how to report it.
        }

        uint64_t offset = 0;
        size_t count = 0;
        while ((count = fread(buffer, 1, PAGE_SIZE, image)) == PAGE_SIZE)
        {
            uint64_t hash = 14695981039346656037ULL;
            for (size_t index = 0; index < PAGE_SIZE; index++)
            {
                hash ^= buffer[index];
                hash *= 1099511628211ULL;
            }
            for (int query_index = 0; query_index < query_count; query_index++)
            {
                if (hash == queries[query_index])
                {
                    printf("%016llx\t%d\t%llx\n", (unsigned long long)hash, image_index - 2,
                           (unsigned long long)offset);
                    break;
                }
            }
            offset += PAGE_SIZE;
        }
        fclose(image);
    }

    free(buffer);
    return 0;
}
