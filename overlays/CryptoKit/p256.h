#include <stddef.h>
#include <stdint.h>

/* Decodes a P-256 public key in X9.63 form (uncompressed 0x04 || X || Y, or compressed 0x02/0x03 || X),
   checks the point is on the curve and not the point at infinity, and writes its uncompressed X9.63
   form (65 bytes) to x963. Returns 0, or -1 for an invalid key. */
int darling_p256_public_key_decode(const void *bytes, size_t length, uint8_t x963[65]);
