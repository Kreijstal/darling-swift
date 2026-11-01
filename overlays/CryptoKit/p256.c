#include "p256.h"
#include <openssl/ec.h>
#include <openssl/obj_mac.h>

int darling_p256_public_key_decode(const void *bytes, size_t length, uint8_t x963[65])
{
    EC_GROUP *group = EC_GROUP_new_by_curve_name(NID_X9_62_prime256v1);
    EC_POINT *point = group != NULL ? EC_POINT_new(group) : NULL;
    int result = -1;

    if (point != NULL &&
        EC_POINT_oct2point(group, point, bytes, length, NULL) == 1 &&
        !EC_POINT_is_at_infinity(group, point) &&
        EC_POINT_is_on_curve(group, point, NULL) == 1 &&
        EC_POINT_point2oct(group, point, POINT_CONVERSION_UNCOMPRESSED, x963, 65, NULL) == 65)
        result = 0;

    EC_POINT_free(point);
    EC_GROUP_free(group);
    return result;
}
