#include <stddef.h>
#include <stdint.h>

/* Stateless NIST curve operations over the runtime's LibreSSL. Every buffer is
 * caller-owned and its length must be exact (P-256: scalar 32, public key in
 * x9.63 form 65, signature r||s 64, shared secret 32). On failure every output
 * buffer is cleansed. */

enum { DARLING_ECC_P256 = 1 };
enum { DARLING_ECC_OK = 0, DARLING_ECC_EINVAL = -1, DARLING_ECC_EINTERNAL = -2 };
enum { DARLING_ECC_X963 = 0, DARLING_ECC_RAW = 1, DARLING_ECC_COMPRESSED = 2, DARLING_ECC_COMPACT = 3 };

int darling_ecc_generate(int curve, int compact,
    uint8_t *scalar_out, size_t scalar_len, uint8_t *public_out, size_t public_len);
int darling_ecc_private_import(int curve, const uint8_t *scalar, size_t scalar_len,
    const uint8_t *expected_public, size_t expected_public_len,
    uint8_t *public_out, size_t public_len);
int darling_ecc_public_import(int curve, int encoding, const uint8_t *in, size_t in_len,
    uint8_t *public_out, size_t public_len);
/* 1 if compact-representable, 0 if not, negative on error. */
int darling_ecc_is_compact(int curve, const uint8_t *public_x963, size_t public_len);
int darling_ecc_sign(int curve, const uint8_t *scalar, size_t scalar_len,
    const uint8_t *digest, size_t digest_len, uint8_t *signature_out, size_t signature_len);
/* 1 if valid, 0 if invalid, negative on error. */
int darling_ecc_verify(int curve, const uint8_t *public_x963, size_t public_len,
    const uint8_t *digest, size_t digest_len, const uint8_t *signature, size_t signature_len);
int darling_ecc_ecdh(int curve, const uint8_t *scalar, size_t scalar_len,
    const uint8_t *peer_x963, size_t peer_len, uint8_t *secret_out, size_t secret_len);
