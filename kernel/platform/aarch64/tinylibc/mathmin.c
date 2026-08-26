/* Minimal libm subset for StgPrimFloat.c: correct enough to link and to
   survive incidental float paths; not a quality implementation. */

#include <stddef.h>
#include <stdint.h>
#include <math.h>

static double scalbn_pos(double x, int e)
{
    double f = 1.0;
    while (e >= 1024) { x *= 8.98846567431158e307; e -= 1024; }
    while (e >= 64)   { f *= 18446744073709551616.0; e -= 64; }
    while (e--)       { f *= 2.0; }
    return x * f;
}

double ldexp(double x, int e)
{
    if (x == 0.0 || e == 0)
        return x;
    if (e < 0) {
        while (e <= -1024) { x *= 1.1125369292536007e-308; e += 1024; }
        while (e <= -64)   { x /= 18446744073709551616.0; e += 64; }
        while (e++)        { x /= 2.0; }
        return x;
    }
    return scalbn_pos(x, e);
}

/* ln(x) for x in [1,2): atanh series on t=(x-1)/(x+1), ~1e-12 */
static double ln_unit(double x)
{
    double t = (x - 1.0) / (x + 1.0);
    double t2 = t * t, sum = 0.0, term = t;
    int k;
    for (k = 1; k <= 27; k += 2) {
        sum += term / k;
        term *= t2;
    }
    return 2.0 * sum;
}

#define LN2 0.69314718055994530942

double log(double x)
{
    int exp = 0;
    if (x <= 0.0)
        return x == 0.0 ? -__builtin_huge_val() : __builtin_nan("");
    /* decompose via repeated scaling: keep it simple, bounded loops */
    while (x > 2.0) { x *= 0.5; exp++; }
    while (x < 1.0) { x *= 2.0; exp--; }
    return ln_unit(x) + exp * LN2;
}

double log2(double x)
{
    return log(x) / LN2;
}

double exp(double y)
{
    int k = 0;
    double r, term;
    int neg = y < 0.0;
    if (neg)
        y = -y;
    while (y > LN2) { y -= LN2; k++; }
    r = 1.0;
    term = 1.0;
    {
        int i;
        for (i = 15; i >= 1; i--)
            term = term * y / i + 1.0;
    }
    r = ldexp(term, k);
    return neg ? 1.0 / r : r;
}

double pow(double base, double e)
{
    if (base < 0.0)
        return __builtin_nan("");
    if (base == 0.0)
        return e == 0.0 ? 1.0 : 0.0;
    return exp(e * log(base));
}

float expf(float x) { return (float)exp((double)x); }
float logf(float x) { return (float)log((double)x); }
float log1pf(float x) { return (float)log(1.0 + (double)x); }
float expm1f(float x) { return (float)(exp((double)x) - 1.0); }
double log1p(double x) { return log(1.0 + x); }
double expm1(double x) { return exp(x) - 1.0; }

#define PI_D 3.14159265358979323846

/* range-reduce to [-pi,pi] then Taylor */
static double sin_core(double x)
{
    double t = x, sum = 0.0;
    int n;
    for (n = 1; n <= 19; n += 2) {
        sum += t / n;
        t *= -(x * x) / ((n + 1) * (n + 2));
    }
    return sum;
}

static double cos_core(double x)
{
    double term = 1.0, sum = 1.0;
    int n;
    for (n = 2; n <= 20; n += 2) {
        term *= -(x * x) / ((n - 1) * n);
        sum += term;
    }
    return sum;
}

static double reduce_pi(double x)
{
    while (x > PI_D) x -= 2 * PI_D;
    while (x < -PI_D) x += 2 * PI_D;
    return x;
}

double sin(double x) { return sin_core(reduce_pi(x)); }
double cos(double x) { return cos_core(reduce_pi(x)); }
double tan(double x) { return sin(x) / cos(x); }

double atan(double z)
{
    double term = z, sum = z, z2 = z * z;
    int n;
    if (z > 1.0)
        return PI_D / 2 - atan(1.0 / z);
    if (z < -1.0)
        return -PI_D / 2 - atan(1.0 / z);
    for (n = 1; n < 60; n++) {
        term *= -z2;
        sum += term / (2 * n + 1);
    }
    return sum;
}

double asin(double x)
{
    if (x < -1.0 || x > 1.0)
        return __builtin_nan("");
    return atan(x / __builtin_sqrt(1.0 - x * x));
}

double acos(double x) { return PI_D / 2 - asin(x); }
double sinh(double x) { return (exp(x) - exp(-x)) / 2; }
double cosh(double x) { return (exp(x) + exp(-x)) / 2; }
double tanh(double x) { return sinh(x) / cosh(x); }

float sinf(float x) { return (float)sin(x); }
float cosf(float x) { return (float)cos(x); }
float tanf(float x) { return (float)tan(x); }
float asinf(float x) { return (float)asin(x); }
float acosf(float x) { return (float)acos(x); }
float atanf(float x) { return (float)atan(x); }
float sinhf(float x) { return (float)sinh(x); }
float coshf(float x) { return (float)cosh(x); }
float tanhf(float x) { return (float)tanh(x); }

/* hardware sqrt/fabs */
double sqrt(double x)
{
    double r;
    if (x < 0.0)
        return __builtin_nan("");
    __asm__ ("fsqrt %d0, %d1" : "=w" (r) : "w" (x));
    return r;
}

float sqrtf(float x)
{
    float r;
    __asm__ ("fsqrt %s0, %s1" : "=w" (r) : "w" (x));
    return r;
}

double fabs(double x)
{
    double r;
    __asm__ ("fabs %d0, %d1" : "=w" (r) : "w" (x));
    return r;
}

float fabsf(float x)
{
    float r;
    __asm__ ("fabs %s0, %s1" : "=w" (r) : "w" (x));
    return r;
}

double asinh(double x)
{
    int s = x < 0;
    x = fabs(x);
    x = log(x + sqrt(x * x + 1.0));
    return s ? -x : x;
}

double acosh(double x)
{
    if (x < 1.0)
        return __builtin_nan("");
    return log(x + sqrt(x * x - 1.0));
}

double atanh(double x)
{
    if (x <= -1.0 || x >= 1.0)
        return __builtin_nan("");
    return 0.5 * log((1.0 + x) / (1.0 - x));
}

float asinhf(float x) { return (float)asinh(x); }
float acoshf(float x) { return (float)acosh(x); }
float atanhf(float x) { return (float)atanh(x); }
float powf(float b, float e) { return (float)pow(b, e); }

double floor(double x)
{
    double r;
    __asm__ ("frintm %d0, %d1" : "=w" (r) : "w" (x));
    return r;
}

double ceil(double x)
{
    double r;
    __asm__ ("frintp %d0, %d1" : "=w" (r) : "w" (x));
    return r;
}

double trunc(double x)
{
    double r;
    __asm__ ("frintz %d0, %d1" : "=w" (r) : "w" (x));
    return r;
}

double round(double x)
{
    double r;
    __asm__ ("frinta %d0, %d1" : "=w" (r) : "w" (x));
    return r;
}

float floorf(float x) { return (float)floor(x); }
float ceilf(float x) { return (float)ceil(x); }
float truncf(float x) { return (float)trunc(x); }
float roundf(float x) { return (float)round(x); }

double fmod(double a, double b)
{
    double q = trunc(a / b);
    return a - q * b;
}

double cbrt(double x)
{
    int neg = x < 0;
    double g = neg ? -x : x, prev;
    if (g == 0.0)
        return 0.0;
    do {
        prev = g;
        g = (2.0 * g + x / (g * g)) / 3.0;
    } while (fabs(g - prev) > 1e-14 * g);
    return neg ? -g : g;
}

double hypot(double a, double b) { return sqrt(a * a + b * b); }
double fmax(double a, double b) { return a > b ? a : b; }
double fmin(double a, double b) { return a < b ? a : b; }

double strtod(const char *n, char **end)
{
    double v = 0.0, frac_scale = 1.0;
    int neg = 0, seen = 0, expo = 0, eneg = 0;

    while (*n == ' ' || (*n >= 9 && *n <= 13)) n++;
    if (*n == '-') { neg = 1; n++; } else if (*n == '+') n++;
    while (*n >= '0' && *n <= '9') {
        v = v * 10.0 + (*n++ - '0');
        seen = 1;
    }
    if (*n == '.') {
        n++;
        while (*n >= '0' && *n <= '9') {
            frac_scale /= 10.0;
            v += (*n++ - '0') * frac_scale;
            seen = 1;
        }
    }
    if (seen && (*n | 0x20) == 'e') {
        const char *save = n;
        n++;
        if (*n == '-') { eneg = 1; n++; } else if (*n == '+') n++;
        if (!(*n >= '0' && *n <= '9')) {
            n = save;           /* no exponent digits: rewind */
        } else {
            while (*n >= '0' && *n <= '9')
                expo = expo * 10 + (*n++ - '0');
            if (eneg)
                expo = -expo;
        }
    }
    if (end)
        *end = (char *)(seen ? n : (n[-1] == '-' || n[-1] == '+' ? n - 1 : n));
    if (!seen)
        return 0.0;
    v = neg ? -v : v;
    return v * pow(10.0, (double)expo);
}
