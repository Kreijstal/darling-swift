#include "digests.h"
#include <openssl/md5.h>
#include <openssl/sha.h>

/* The algorithms, as Digests.swift numbers them. */
enum { DIGEST_SHA384, DIGEST_SHA512, DIGEST_SHA1, DIGEST_MD5 };

union digest_context {
    SHA512_CTX sha512;
    SHA_CTX sha1;
    MD5_CTX md5;
};

size_t darling_crypto_digest_context_size(void)
{
    return sizeof(union digest_context);
}

void darling_crypto_digest_init(int algorithm, void *context)
{
    union digest_context *c = context;
    switch (algorithm) {
    case DIGEST_SHA384: SHA384_Init(&c->sha512); break;
    case DIGEST_SHA512: SHA512_Init(&c->sha512); break;
    case DIGEST_SHA1: SHA1_Init(&c->sha1); break;
    case DIGEST_MD5: MD5_Init(&c->md5); break;
    }
}

void darling_crypto_digest_update(int algorithm, void *context, const void *data, size_t length)
{
    union digest_context *c = context;
    if (length == 0)
        return;
    switch (algorithm) {
    case DIGEST_SHA384: SHA384_Update(&c->sha512, data, length); break;
    case DIGEST_SHA512: SHA512_Update(&c->sha512, data, length); break;
    case DIGEST_SHA1: SHA1_Update(&c->sha1, data, length); break;
    case DIGEST_MD5: MD5_Update(&c->md5, data, length); break;
    }
}

void darling_crypto_digest_final(int algorithm, void *context, void *digest)
{
    union digest_context *c = context;
    switch (algorithm) {
    case DIGEST_SHA384: SHA384_Final(digest, &c->sha512); break;
    case DIGEST_SHA512: SHA512_Final(digest, &c->sha512); break;
    case DIGEST_SHA1: SHA1_Final(digest, &c->sha1); break;
    case DIGEST_MD5: MD5_Final(digest, &c->md5); break;
    }
}
