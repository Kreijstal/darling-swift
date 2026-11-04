#include <stddef.h>

/* The context buffer must hold darling_crypto_digest_context_size() bytes. */
size_t darling_crypto_digest_context_size(void);
void darling_crypto_digest_init(int algorithm, void *context);
void darling_crypto_digest_update(int algorithm, void *context, const void *data, size_t length);
void darling_crypto_digest_final(int algorithm, void *context, void *digest);
