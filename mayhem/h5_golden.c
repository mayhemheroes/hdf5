/* hdf5/mayhem/h5_golden.c — self-contained golden oracle over the HDF5 open/read path that the
 * fuzzers exercise (H5Fcreate/H5Dcreate -> H5Fopen/H5Dopen2/H5Aopen_name -> read back -> assert).
 *
 * This is a PATCH-grade functional test, not a no-op stub:
 *   1. Create a file with a 1-D int dataset "dsetname" holding known values and a scalar int
 *      attribute "theattr" with a known value (the exact names the extended harness opens).
 *   2. Re-open read-only, read the dataset + attribute back, assert byte/value equality.
 *   3. Write a file whose superblock signature is corrupted and assert H5Fopen REJECTS it
 *      (returns the invalid HID) — exercising the reader's reject path the fuzzer probes.
 * Any change that breaks encode/decode round-trip or the corruption-rejection makes this fail.
 * Exits 0 on success, nonzero (and prints which check failed) on any mismatch.
 */
#include "hdf5.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define N 8
static const int kData[N]   = {0, 1, 2, 3, 100, -7, 65535, -65536};
static const int kAttrValue = 0x1234abcd;
#define FNAME "/tmp/h5_golden.h5"
#define BADNAME "/tmp/h5_golden_bad.h5"

static int fail(const char *msg)
{
    fprintf(stderr, "GOLDEN FAIL: %s\n", msg);
    return 1;
}

static int make_file(void)
{
    hid_t file = H5Fcreate(FNAME, H5F_ACC_TRUNC, H5P_DEFAULT, H5P_DEFAULT);
    if (file == H5I_INVALID_HID)
        return fail("H5Fcreate");

    hsize_t dims[1] = {N};
    hid_t   space   = H5Screate_simple(1, dims, NULL);
    hid_t   dset    = H5Dcreate2(file, "dsetname", H5T_NATIVE_INT, space, H5P_DEFAULT, H5P_DEFAULT,
                                 H5P_DEFAULT);
    if (dset == H5I_INVALID_HID)
        return fail("H5Dcreate2");
    if (H5Dwrite(dset, H5T_NATIVE_INT, H5S_ALL, H5S_ALL, H5P_DEFAULT, kData) < 0)
        return fail("H5Dwrite");

    /* scalar int attribute "theattr" on the dataset */
    hid_t ascalar = H5Screate(H5S_SCALAR);
    hid_t attr    = H5Acreate2(dset, "theattr", H5T_NATIVE_INT, ascalar, H5P_DEFAULT, H5P_DEFAULT);
    if (attr == H5I_INVALID_HID)
        return fail("H5Acreate2");
    if (H5Awrite(attr, H5T_NATIVE_INT, &kAttrValue) < 0)
        return fail("H5Awrite");

    H5Aclose(attr);
    H5Sclose(ascalar);
    H5Dclose(dset);
    H5Sclose(space);
    H5Fclose(file);
    return 0;
}

static int read_and_check(void)
{
    hid_t file = H5Fopen(FNAME, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (file == H5I_INVALID_HID)
        return fail("H5Fopen(valid) returned invalid");

    hid_t dset = H5Dopen2(file, "dsetname", H5P_DEFAULT);
    if (dset == H5I_INVALID_HID)
        return fail("H5Dopen2(dsetname)");

    int rdata[N];
    memset(rdata, 0, sizeof(rdata));
    if (H5Dread(dset, H5T_NATIVE_INT, H5S_ALL, H5S_ALL, H5P_DEFAULT, rdata) < 0)
        return fail("H5Dread");
    if (memcmp(rdata, kData, sizeof(kData)) != 0)
        return fail("dataset values mismatch after round-trip");

    hid_t attr = H5Aopen_name(dset, "theattr");
    if (attr == H5I_INVALID_HID)
        return fail("H5Aopen_name(theattr)");
    int avalue = 0;
    if (H5Aread(attr, H5T_NATIVE_INT, &avalue) < 0)
        return fail("H5Aread");
    if (avalue != kAttrValue)
        return fail("attribute value mismatch after round-trip");

    H5Aclose(attr);
    H5Dclose(dset);
    H5Fclose(file);
    return 0;
}

/* A file with a flipped superblock signature must be REJECTED by the reader. */
static int check_corrupt_rejected(void)
{
    /* copy the good file, then clobber the first signature byte (\211 -> 'X') */
    FILE *in = fopen(FNAME, "rb");
    if (!in)
        return fail("reopen good file for corruption");
    FILE *out = fopen(BADNAME, "wb");
    if (!out) {
        fclose(in);
        return fail("open corrupt file for write");
    }
    int c, first = 1;
    while ((c = fgetc(in)) != EOF) {
        if (first) {
            c     = 'X'; /* destroy the \x89 'H' 'D' 'F' ... signature */
            first = 0;
        }
        fputc(c, out);
    }
    fclose(in);
    fclose(out);

    /* Suppress HDF5's error stack chatter for the expected-failure open. */
    H5Eset_auto2(H5E_DEFAULT, NULL, NULL);
    hid_t bad = H5Fopen(BADNAME, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (bad != H5I_INVALID_HID) {
        H5Fclose(bad);
        return fail("corrupted file was accepted by H5Fopen (should be rejected)");
    }
    return 0;
}

int main(void)
{
    int rc = 0;
    if ((rc = make_file()) != 0)
        return rc;
    if ((rc = read_and_check()) != 0)
        return rc;
    if ((rc = check_corrupt_rejected()) != 0)
        return rc;
    printf("GOLDEN PASS: round-trip dataset+attribute OK; corrupted superblock rejected\n");
    return 0;
}
