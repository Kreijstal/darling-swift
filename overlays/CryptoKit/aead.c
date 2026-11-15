#include "aead.h"
#include <openssl/evp.h>
#include <openssl/crypto.h>
#include <limits.h>

int darling_crypto_aead(int encrypt, int aes, const void *key, size_t key_length,
    const void *nonce, size_t nonce_length, const void *input, size_t input_length,
    const void *aad, size_t aad_length, void *output)
{
    if (input_length > INT_MAX - 16 || aad_length > INT_MAX || nonce_length > INT_MAX ||
        (!encrypt && input_length < 16))
        return -1;

    if (!aes) {
#if defined(LIBRESSL_VERSION_NUMBER)
        EVP_AEAD_CTX ctx = {0};
        if (!EVP_AEAD_CTX_init(&ctx, EVP_aead_chacha20_poly1305(), key, key_length, 16, NULL))
            return -1;
        size_t written = 0;
        int ok = encrypt
            ? EVP_AEAD_CTX_seal(&ctx, output, &written, input_length + 16,
                nonce, nonce_length, input, input_length, aad, aad_length)
            : EVP_AEAD_CTX_open(&ctx, output, &written, input_length,
                nonce, nonce_length, input, input_length, aad, aad_length);
        EVP_AEAD_CTX_cleanup(&ctx);
        if (!ok) {
            OPENSSL_cleanse(output, input_length);
            return -1;
        }
        return (int)written;
#endif
    }

    const EVP_CIPHER *cipher = key_length == 16 ? EVP_aes_128_gcm()
        : key_length == 24 ? EVP_aes_192_gcm()
        : key_length == 32 ? EVP_aes_256_gcm() : NULL;
#if !defined(LIBRESSL_VERSION_NUMBER)
    if (!aes)
        cipher = key_length == 32 ? EVP_chacha20_poly1305() : NULL;
#endif
    if (!cipher)
        return -1;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx)
        return -1;
    int written = 0, tail = 0, ignored = 0;
    size_t data_length = encrypt ? input_length : input_length - 16;
    int ok = EVP_CipherInit_ex(ctx, cipher, NULL, NULL, NULL, encrypt) &&
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, (int)nonce_length, NULL) &&
        EVP_CipherInit_ex(ctx, NULL, NULL, key, nonce, encrypt);
    if (ok && aad_length)
        ok = EVP_CipherUpdate(ctx, NULL, &ignored, aad, (int)aad_length);
    if (ok && data_length)
        ok = EVP_CipherUpdate(ctx, output, &written, input, (int)data_length);
    if (ok && !encrypt)
        ok = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16,
            (void *)((const unsigned char *)input + data_length));
    if (ok)
        ok = EVP_CipherFinal_ex(ctx, (unsigned char *)output + written, &tail);
    written += tail;
    if (ok && encrypt) {
        ok = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16,
            (unsigned char *)output + written);
        written += 16;
    }
    EVP_CIPHER_CTX_free(ctx);
    if (!ok) {
        OPENSSL_cleanse(output, input_length);
        return -1;
    }
    return written;
}
