#include <stddef.h>

int darling_crypto_aead(int encrypt, int aes, const void *key, size_t key_length,
    const void *nonce, size_t nonce_length, const void *input, size_t input_length,
    const void *aad, size_t aad_length, void *output);
