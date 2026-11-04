#include "ecc.h"
#include <openssl/bn.h>
#include <openssl/crypto.h>
#include <openssl/ec.h>
#include <openssl/ecdsa.h>
#include <openssl/err.h>
#include <openssl/obj_mac.h>
#include <limits.h>
#include <string.h>

/* Written against the LibreSSL 2.8.3 manual pages (EC_KEY_new(3), EC_GROUP_copy(3),
 * EC_GROUP_new(3), EC_POINT_new(3), EC_POINT_add(3), ECDSA_SIG_new(3), BN_add(3),
 * BN_bn2bin(3), BN_cmp(3)) and headers. Each call builds its own key and frees it
 * before returning; nothing is cached. */

#define SCALAR_LEN 32
#define POINT_LEN 65

struct curve {
    EC_KEY *key;
    const EC_GROUP *group;
    BN_CTX *bn;
    BIGNUM *order;
    BIGNUM *prime;
};

static void cleanse(uint8_t *out, size_t len)
{
    if (out && len)
        OPENSSL_cleanse(out, len);
}

static int curve_open(struct curve *c, int curve)
{
    memset(c, 0, sizeof(*c));
    if (curve != DARLING_ECC_P256)
        return DARLING_ECC_EINVAL;
    c->key = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
    c->bn = BN_CTX_new();
    c->order = BN_new();
    c->prime = BN_new();
    if (!c->key || !c->bn || !c->order || !c->prime)
        return DARLING_ECC_EINTERNAL;
    c->group = EC_KEY_get0_group(c->key);
    if (!c->group || !EC_GROUP_get_order(c->group, c->order, c->bn) ||
        !EC_GROUP_get_curve_GFp(c->group, c->prime, NULL, NULL, c->bn))
        return DARLING_ECC_EINTERNAL;
    return DARLING_ECC_OK;
}

static void curve_close(struct curve *c)
{
    EC_KEY_free(c->key);
    BN_free(c->order);
    BN_free(c->prime);
    BN_CTX_free(c->bn);
    ERR_clear_error();
}

/* Big-endian export of a, left-padded with zeros to exactly len bytes. */
static int pad(const BIGNUM *a, uint8_t *out, size_t len)
{
    int k = BN_num_bytes(a);
    if (k < 0 || (size_t)k > len)
        return DARLING_ECC_EINTERNAL;
    memset(out, 0, len - (size_t)k);
    BN_bn2bin(a, out + len - (size_t)k);
    return DARLING_ECC_OK;
}

static int point_out(const struct curve *c, const EC_POINT *p, uint8_t *out, size_t len)
{
    if (len != POINT_LEN)
        return DARLING_ECC_EINVAL;
    if (EC_POINT_point2oct(c->group, p, POINT_CONVERSION_UNCOMPRESSED, out, len, c->bn)
        != POINT_LEN)
        return DARLING_ECC_EINTERNAL;
    return DARLING_ECC_OK;
}

/* Decodes an octet string whose first byte the caller has already restricted to the
 * form it asked for; rejects anything off the curve and the point at infinity. */
static int point_in(const struct curve *c, const uint8_t *in, size_t len, EC_POINT **out)
{
    EC_POINT *p = EC_POINT_new(c->group);
    if (!p)
        return DARLING_ECC_EINTERNAL;
    if (!EC_POINT_oct2point(c->group, p, in, len, c->bn) ||
        EC_POINT_is_at_infinity(c->group, p)) {
        EC_POINT_free(p);
        return DARLING_ECC_EINVAL;
    }
    *out = p;
    return DARLING_ECC_OK;
}

static int x963_in(const struct curve *c, const uint8_t *in, size_t len, EC_POINT **out)
{
    if (!in || len != POINT_LEN || in[0] != 0x04)
        return DARLING_ECC_EINVAL;
    return point_in(c, in, len, out);
}

/* Installs d (range-checked: 1 <= d <= n-1) and Q = d*G in c->key. */
static int install_scalar(struct curve *c, const uint8_t *scalar, size_t len)
{
    int rc = DARLING_ECC_EINTERNAL;
    BIGNUM *d = NULL;
    EC_POINT *q = NULL;
    if (!scalar || len != SCALAR_LEN)
        return DARLING_ECC_EINVAL;
    if (!(d = BN_bin2bn(scalar, (int)len, NULL)))
        goto done;
    if (BN_is_zero(d) || BN_cmp(d, c->order) >= 0) {
        rc = DARLING_ECC_EINVAL;
        goto done;
    }
    if (!EC_KEY_set_private_key(c->key, d) || !(q = EC_POINT_new(c->group)) ||
        !EC_POINT_mul(c->group, q, d, NULL, NULL, c->bn) || !EC_KEY_set_public_key(c->key, q))
        goto done;
    rc = EC_KEY_check_key(c->key) == 1 ? DARLING_ECC_OK : DARLING_ECC_EINVAL;
done:
    EC_POINT_clear_free(q);
    BN_clear_free(d);
    return rc;
}

/* Installs a validated public point in c->key. */
static int install_public(struct curve *c, const EC_POINT *q)
{
    if (!EC_KEY_set_public_key(c->key, q))
        return DARLING_ECC_EINTERNAL;
    return EC_KEY_check_key(c->key) == 1 ? DARLING_ECC_OK : DARLING_ECC_EINVAL;
}

/* swift-crypto's rule (NISTCurvesKeys_boring.swift, _isCompactRepresentable):
 * Y <= (n - Y) mod p, with n the group order and p the field prime. */
static int compact_test(const struct curve *c, const BIGNUM *y)
{
    int rc = DARLING_ECC_EINTERNAL;
    BIGNUM *t = BN_new();
    if (t && BN_mod_sub(t, c->order, y, c->prime, c->bn))
        rc = BN_cmp(y, t) <= 0 ? 1 : 0;
    BN_free(t);
    return rc;
}

int darling_ecc_generate(int curve, int compact,
    uint8_t *scalar_out, size_t scalar_len, uint8_t *public_out, size_t public_len)
{
    struct curve c;
    EC_KEY *key = NULL;
    BIGNUM *y = NULL;
    int rc = curve_open(&c, curve);
    if (rc == DARLING_ECC_OK && (!scalar_out || scalar_len != SCALAR_LEN || !public_out ||
        public_len != POINT_LEN))
        rc = DARLING_ECC_EINVAL;
    if (rc == DARLING_ECC_OK && !(y = BN_new()))
        rc = DARLING_ECC_EINTERNAL;
    for (int attempt = 0; rc == DARLING_ECC_OK; attempt++) {
        if (attempt == 100) {
            rc = DARLING_ECC_EINTERNAL;
            break;
        }
        /* EC_KEY_generate_key keeps an existing private key, so start fresh. */
        EC_KEY_free(key);
        if (!(key = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1)) ||
            !EC_KEY_generate_key(key) || EC_KEY_check_key(key) != 1) {
            rc = DARLING_ECC_EINTERNAL;
            break;
        }
        const EC_POINT *q = EC_KEY_get0_public_key(key);
        if (compact) {
            if (!EC_POINT_get_affine_coordinates_GFp(c.group, q, NULL, y, c.bn)) {
                rc = DARLING_ECC_EINTERNAL;
                break;
            }
            int ok = compact_test(&c, y);
            if (ok < 0) {
                rc = ok;
                break;
            }
            if (!ok)
                continue;
        }
        rc = pad(EC_KEY_get0_private_key(key), scalar_out, scalar_len);
        if (rc == DARLING_ECC_OK)
            rc = point_out(&c, q, public_out, public_len);
        break;
    }
    EC_KEY_free(key);
    BN_free(y);
    curve_close(&c);
    if (rc != DARLING_ECC_OK) {
        cleanse(scalar_out, scalar_len);
        cleanse(public_out, public_len);
    }
    return rc;
}

int darling_ecc_private_import(int curve, const uint8_t *scalar, size_t scalar_len,
    const uint8_t *expected_public, size_t expected_public_len,
    uint8_t *public_out, size_t public_len)
{
    struct curve c;
    EC_POINT *expected = NULL;
    int rc = curve_open(&c, curve);
    if (rc == DARLING_ECC_OK && (!public_out || public_len != POINT_LEN))
        rc = DARLING_ECC_EINVAL;
    if (rc == DARLING_ECC_OK)
        rc = install_scalar(&c, scalar, scalar_len);
    if (rc == DARLING_ECC_OK && (expected_public || expected_public_len)) {
        rc = x963_in(&c, expected_public, expected_public_len, &expected);
        if (rc == DARLING_ECC_OK)
            rc = EC_POINT_cmp(c.group, EC_KEY_get0_public_key(c.key), expected, c.bn) == 0
                ? DARLING_ECC_OK : DARLING_ECC_EINVAL;
    }
    if (rc == DARLING_ECC_OK)
        rc = point_out(&c, EC_KEY_get0_public_key(c.key), public_out, public_len);
    EC_POINT_free(expected);
    curve_close(&c);
    if (rc != DARLING_ECC_OK)
        cleanse(public_out, public_len);
    return rc;
}

int darling_ecc_public_import(int curve, int encoding, const uint8_t *in, size_t in_len,
    uint8_t *public_out, size_t public_len)
{
    struct curve c;
    EC_POINT *q = NULL;
    BIGNUM *y = NULL, *neg = NULL;
    uint8_t buffer[POINT_LEN];
    int rc = curve_open(&c, curve);
    if (rc == DARLING_ECC_OK && (!in || !public_out || public_len != POINT_LEN))
        rc = DARLING_ECC_EINVAL;
    if (rc != DARLING_ECC_OK)
        goto done;
    switch (encoding) {
    case DARLING_ECC_X963:
        rc = x963_in(&c, in, in_len, &q);
        break;
    case DARLING_ECC_RAW:
        if (in_len != POINT_LEN - 1) {
            rc = DARLING_ECC_EINVAL;
            break;
        }
        buffer[0] = 0x04;
        memcpy(buffer + 1, in, in_len);
        rc = point_in(&c, buffer, POINT_LEN, &q);
        break;
    case DARLING_ECC_COMPRESSED:
        if (in_len != SCALAR_LEN + 1 || (in[0] != 0x02 && in[0] != 0x03)) {
            rc = DARLING_ECC_EINVAL;
            break;
        }
        rc = point_in(&c, in, in_len, &q);
        break;
    case DARLING_ECC_COMPACT:
        /* draft-jivsov-ecc-compact-05 4.1: y = min(y', p - y'). The 0x02 form
         * yields the even root; the other root is p minus it. */
        if (in_len != SCALAR_LEN) {
            rc = DARLING_ECC_EINVAL;
            break;
        }
        buffer[0] = 0x02;
        memcpy(buffer + 1, in, in_len);
        rc = point_in(&c, buffer, SCALAR_LEN + 1, &q);
        if (rc != DARLING_ECC_OK)
            break;
        if (!(y = BN_new()) || !(neg = BN_new()) ||
            !EC_POINT_get_affine_coordinates_GFp(c.group, q, NULL, y, c.bn) ||
            !BN_sub(neg, c.prime, y)) {
            rc = DARLING_ECC_EINTERNAL;
            break;
        }
        if (BN_cmp(y, neg) > 0 && !EC_POINT_invert(c.group, q, c.bn))
            rc = DARLING_ECC_EINTERNAL;
        break;
    default:
        rc = DARLING_ECC_EINVAL;
    }
    if (rc == DARLING_ECC_OK)
        rc = install_public(&c, q);
    if (rc == DARLING_ECC_OK)
        rc = point_out(&c, q, public_out, public_len);
done:
    BN_free(y);
    BN_free(neg);
    EC_POINT_free(q);
    curve_close(&c);
    if (rc != DARLING_ECC_OK)
        cleanse(public_out, public_len);
    return rc;
}

int darling_ecc_is_compact(int curve, const uint8_t *public_x963, size_t public_len)
{
    struct curve c;
    BIGNUM *y = NULL;
    int rc = curve_open(&c, curve);
    if (rc == DARLING_ECC_OK && (!public_x963 || public_len != POINT_LEN ||
        public_x963[0] != 0x04))
        rc = DARLING_ECC_EINVAL;
    if (rc == DARLING_ECC_OK) {
        y = BN_bin2bn(public_x963 + 1 + SCALAR_LEN, SCALAR_LEN, NULL);
        rc = y ? compact_test(&c, y) : DARLING_ECC_EINTERNAL;
    }
    BN_free(y);
    curve_close(&c);
    return rc;
}

int darling_ecc_sign(int curve, const uint8_t *scalar, size_t scalar_len,
    const uint8_t *digest, size_t digest_len, uint8_t *signature_out, size_t signature_len)
{
    struct curve c;
    ECDSA_SIG *sig = NULL;
    int rc = curve_open(&c, curve);
    if (rc == DARLING_ECC_OK && (!digest || digest_len < 1 || digest_len > INT_MAX ||
        !signature_out || signature_len != 2 * SCALAR_LEN))
        rc = DARLING_ECC_EINVAL;
    if (rc == DARLING_ECC_OK)
        rc = install_scalar(&c, scalar, scalar_len);
    if (rc == DARLING_ECC_OK && !(sig = ECDSA_do_sign(digest, (int)digest_len, c.key)))
        rc = DARLING_ECC_EINTERNAL;
    if (rc == DARLING_ECC_OK) {
        const BIGNUM *r = NULL, *s = NULL;
        ECDSA_SIG_get0(sig, &r, &s);
        rc = pad(r, signature_out, SCALAR_LEN);
        if (rc == DARLING_ECC_OK)
            rc = pad(s, signature_out + SCALAR_LEN, SCALAR_LEN);
    }
    ECDSA_SIG_free(sig);
    curve_close(&c);
    if (rc != DARLING_ECC_OK)
        cleanse(signature_out, signature_len);
    return rc;
}

int darling_ecc_verify(int curve, const uint8_t *public_x963, size_t public_len,
    const uint8_t *digest, size_t digest_len, const uint8_t *signature, size_t signature_len)
{
    struct curve c;
    EC_POINT *q = NULL;
    ECDSA_SIG *sig = NULL;
    BIGNUM *r = NULL, *s = NULL;
    int rc = curve_open(&c, curve);
    if (rc == DARLING_ECC_OK && ((!digest && digest_len) || digest_len > INT_MAX ||
        !signature || signature_len != 2 * SCALAR_LEN))
        rc = DARLING_ECC_EINVAL;
    if (rc == DARLING_ECC_OK)
        rc = x963_in(&c, public_x963, public_len, &q);
    if (rc == DARLING_ECC_OK)
        rc = install_public(&c, q);
    if (rc == DARLING_ECC_OK) {
        r = BN_bin2bn(signature, SCALAR_LEN, NULL);
        s = BN_bin2bn(signature + SCALAR_LEN, SCALAR_LEN, NULL);
        sig = ECDSA_SIG_new();
        if (!r || !s || !sig || !ECDSA_SIG_set0(sig, r, s)) {
            rc = DARLING_ECC_EINTERNAL;
        } else {
            r = s = NULL; /* owned by sig now */
            static const uint8_t empty[1];
            rc = ECDSA_do_verify(digest ? digest : empty, (int)digest_len, sig, c.key);
        }
    }
    BN_free(r);
    BN_free(s);
    ECDSA_SIG_free(sig);
    EC_POINT_free(q);
    curve_close(&c);
    return rc;
}

int darling_ecc_ecdh(int curve, const uint8_t *scalar, size_t scalar_len,
    const uint8_t *peer_x963, size_t peer_len, uint8_t *secret_out, size_t secret_len)
{
    struct curve c;
    EC_POINT *peer = NULL, *shared = NULL;
    BIGNUM *x = NULL, *y = NULL;
    int rc = curve_open(&c, curve);
    if (rc == DARLING_ECC_OK && (!secret_out || secret_len != SCALAR_LEN))
        rc = DARLING_ECC_EINVAL;
    if (rc == DARLING_ECC_OK)
        rc = install_scalar(&c, scalar, scalar_len);
    if (rc == DARLING_ECC_OK)
        rc = x963_in(&c, peer_x963, peer_len, &peer);
    if (rc == DARLING_ECC_OK) {
        /* SEC 1 3.3.1: Z = x(d * Q_peer). */
        if (!(shared = EC_POINT_new(c.group)) || !(x = BN_new()) || !(y = BN_new()) ||
            !EC_POINT_mul(c.group, shared, NULL, peer, EC_KEY_get0_private_key(c.key), c.bn))
            rc = DARLING_ECC_EINTERNAL;
        else if (EC_POINT_is_at_infinity(c.group, shared))
            rc = DARLING_ECC_EINVAL;
        else if (!EC_POINT_get_affine_coordinates_GFp(c.group, shared, x, y, c.bn))
            rc = DARLING_ECC_EINTERNAL;
        else
            rc = pad(x, secret_out, secret_len);
    }
    BN_clear_free(x);
    BN_clear_free(y);
    EC_POINT_clear_free(shared);
    EC_POINT_free(peer);
    curve_close(&c);
    if (rc != DARLING_ECC_OK)
        cleanse(secret_out, secret_len);
    return rc;
}
